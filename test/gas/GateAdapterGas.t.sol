// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WHAT THE GATE MODE COSTS, PINNED.
//
//  The Gate gives an outside venue a V3-shaped wrapper with an adapter behind it.
//  This file measures every door of that mode on the four adapters at once (Curve
//  StableSwap-NG, Balancer V2, Balancer V3, Curve Twocrypto-NG), each over the
//  same funded pair and the same mocks the adapter tests use:
//  - the Gate: create (one wrapper per slot of a pair), the views (wrapperAddress,
//    liveAdapter, wrappersOf) and vitalOf, fresh and after a material swap;
//  - the wrapper: quote (view), quoteCall (the eth_call door) and swap, called the
//    way the Router calls it;
//  - the Router: a kind-9 leg at one hop and at two hops, and the automatic door
//    (findBestRoutePlan, then swapBestExactIn) over a kind-9 candidate;
//  - the Quoter: gateVitalOf, the registry check in front of the Gate's vitalOf.
//
//  THE INSTRUMENT (isolation mode: `isolate = true` in foundry.toml, asserted in
//  setUp, so each top-level call is its own transaction):
//  - Every budget is the measured snapshot itself (`vm.startSnapshotGas` ..
//    `vm.stopSnapshotGas`, written to snapshots/<group>.json). No ceiling is set
//    by hand. The gate is equality: with FORGE_SNAPSHOT_CHECK=true any window that
//    moves, up or down, fails the run while every assert still passes. A change
//    meant to move gas regenerates the files in the same commit.
//  - One group per test function, named after it: a partial run (`--match-test`,
//    as the mutation guard runs) rewrites the groups it ran, and only those.
//  - A window around a door that is not `view` runs as its own transaction and
//    carries the intrinsic cost (21 000 + calldata): those entries end in `_tx`.
//    A `view` door is a STATICCALL, which forge starts with every account and
//    slot cold, and carries no intrinsic cost.
//  - Each window touches its target first (EXTCODESIZE), so the call into it is
//    always the warm access and no window pays for the one before it.
//  - Where state moves (a swap, a fee paid to the treasuries), each adapter runs
//    from the same state (snapshotState / revertToState), so its entries compare.
//  - The asserts are the fixture's own answers (what each door returns on these
//    balances and prices), never a gas figure.
//
//  TWO RELATIONS, derived here and asserted next to the snapshots:
//  1. create. A wrapper born at slot k of a pair scans k + 1 words of the pair's
//     list, each cold; the first wrapper of a pair scans one. The rest is the same
//     work in both windows: the same Twocrypto-NG adapter, the same resolve (two
//     coins, both in address order), the same wrapper init code and deployed size,
//     the same writes (isWrapper 0 -> 1 cold, list[slot] 0 -> x after its read,
//     six transient variables in five slots: _pT1 and _pKey share one) and the
//     same event. So, calldata apart (the window is
//     a transaction: 21 000 + 4 a zero byte + 16 a nonzero one, EIP-2028),
//        gas(slot k) - calldata(slot k) >= gas(slot 0) - calldata(slot 0) + k * COLD_SLOAD.
//     The slot-0 window runs first: the test frame's memory only grows, so what a later
//     window pays for it lands on the larger side, never against the relation.
//  2. Quoter.gateVitalOf(w) is Core.gateWrapperLive (a public library function,
//     reached by DELEGATECALL) followed by the Gate's vitalOf(w). Measured from a
//     fresh frame with every account and slot cold, each of w, the Gate, the
//     Gate's adapter rows, isWrapper[w], vitalSlot, the adapter, the venue and the
//     tokens is paid cold once on each side. Only gateVitalOf touches four more:
//     the Quoter, the Core library, the Hub and the Hub's codehash row of the Gate
//     (EIP-2929: 2 600 a cold account, 2 100 a cold slot). So
//        gas(gateVitalOf) >= gas(vitalOf) + 3 * COLD_ACCOUNT_ACCESS + COLD_SLOAD.
//
//  FOUNDRY_PROFILE=release forge test --match-path test/gas/GateAdapterGas.t.sol
//  FOUNDRY_PROFILE=release FORGE_SNAPSHOT_CHECK=true forge test --match-path test/gas/GateAdapterGas.t.sol
// =============================================================================

import {AdapterHarness} from "../adapters/AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {
    BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan, GATE_MAX_WRAPPERS
} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixAdapterCurveNG} from "../../src/adapters/BlazePhoenixAdapterCurveNG.sol";
import {BlazePhoenixAdapterCurveCryptoNG} from "../../src/adapters/BlazePhoenixAdapterCurveCryptoNG.sol";
import {BlazePhoenixAdapterBalancerV2} from "../../src/adapters/BlazePhoenixAdapterBalancerV2.sol";
import {BlazePhoenixAdapterBalancerV3, IBalancerV3Vault} from "../../src/adapters/BlazePhoenixAdapterBalancerV3.sol";
import {MockCurveNGFactory, MockCurveNGPool} from "../adapters/mocks/MockCurveNG.sol";
import {MockCurveCryptoNGFactory, MockCurveCryptoNGPool} from "../adapters/mocks/MockCurveCryptoNG.sol";
import {MockBalancerFactory, MockBalancerV2Vault} from "../adapters/mocks/MockBalancerV2.sol";
import {MockBalancerV3Vault} from "../adapters/mocks/MockBalancerV3.sol";

/// Gas of one read, measured inside a fresh frame: called by STATICCALL from the test, it
/// starts with every account and slot cold, and its own memory starts empty.
contract GateGasProbe {
    function gasOf(address target, bytes calldata data) external view returns (uint256 used) {
        uint256 g = gasleft();
        (bool ok, ) = target.staticcall(data);
        used = g - gasleft();
        require(ok, "probe: read failed");
    }
}

contract GateAdapterGasTest is AdapterHarness {
    // The four adapters, in creation order: index k is also the wrapper's slot in the pair.
    uint256 internal constant ADAPTERS = 4;
    uint256 internal constant I_NG = 0;
    uint256 internal constant I_V2 = 1;
    uint256 internal constant I_V3 = 2;
    uint256 internal constant I_CR = 3;
    /// The Twocrypto-NG wrapper is the last one created for (t0, t1): its slot.
    uint256 internal constant SLOT_CR = I_CR;

    // Families as the adapter tests admit them; every venue key is family << 16 | 1.
    uint8 internal constant FAM_NG = 1;
    uint8 internal constant FAM_V2 = 2;
    uint8 internal constant FAM_V3 = 3;
    uint8 internal constant FAM_CR = 4;
    uint24 internal constant VENUE_SLOT = 1;
    uint24 internal constant KEY_CR = uint24(FAM_CR) << 16 | VENUE_SLOT;
    /// The Hub's derive mode of a V3-shaped CREATE2 factory (BlazePhoenixHub MODE_CREATE2_V3).
    uint8 internal constant MODE_CREATE2_V3 = 5;
    bytes32 internal constant PID = keccak256("pool-1");

    // The fixture: every venue holds HELD of each side, prices 1:1 (PAR) less its own fee,
    // and every swap moves AMT (a thousandth of a side: material, MATERIAL_SHIFT is 2^-16).
    uint256 internal constant HELD = 1_000_000e18;
    uint256 internal constant AMT = HELD / 1_000;
    uint256 internal constant PAR = 1e18;
    // Out per MOCK_BPS in, as the mocks price (asserted in setUp).
    uint256 internal constant MOCK_BPS = 10_000;
    uint256 internal constant NG_OUT_BPS = 9_996;
    uint256 internal constant CR_OUT_BPS = 9_995;
    uint256 internal constant BAL_OUT_BPS = 9_970;

    // EIP-2028 calldata and the transaction base; EIP-2929 cold access.
    uint256 internal constant TX_BASE = 21_000;
    uint256 internal constant CALLDATA_ZERO = 4;
    uint256 internal constant CALLDATA_NONZERO = 16;
    uint256 internal constant COLD_SLOAD = 2_100;
    uint256 internal constant COLD_ACCOUNT_ACCESS = 2_600;

    MockERC20 internal t2;
    address internal lo12;
    address internal hi12;
    MockCurveNGPool internal ngPool;
    MockCurveCryptoNGFactory internal crFactory;
    MockCurveCryptoNGPool internal crPool;
    MockCurveCryptoNGPool internal crPool12;
    MockBalancerV2Vault internal vault2;
    MockBalancerV3Vault internal vault3;
    address internal v3Pool;
    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    BlazePhoenixQuoter internal quoter;
    GateGasProbe internal probe;
    address internal user;
    address[ADAPTERS] internal adapters;
    address[ADAPTERS] internal venues;
    address[ADAPTERS] internal wrappers;
    /// The Twocrypto-NG wrapper of (t1, t2): the second hop, and the solve's candidate.
    address internal w12;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
        assertLe(ADAPTERS, GATE_MAX_WRAPPERS, "one pair holds a wrapper of every adapter");
        _tokens();
        t2 = new MockERC20("C", "C");
        (lo12, hi12) = address(t1) < address(t2) ? (address(t1), address(t2)) : (address(t2), address(t1));

        MockCurveNGFactory ngFactory = new MockCurveNGFactory();
        ngPool = new MockCurveNGPool(_list2(address(t0), address(t1)), _twice(PAR));
        _fundWith(address(ngPool), address(t0), address(t1));
        ngPool.sync();
        ngFactory.register(address(ngPool), _list2(address(t0), address(t1)), new uint8[](2), false);

        crFactory = new MockCurveCryptoNGFactory(2);
        crPool = _crPool(address(t0), address(t1));
        crPool12 = _crPool(lo12, hi12);

        // Balancer: the Vault holds the pool's tokens. V3 reads its reserves at registration,
        // so it is funded first, and its raw pool balances are set to the same holding.
        vault2 = new MockBalancerV2Vault();
        MockBalancerFactory f2 = new MockBalancerFactory();
        _fundWith(address(vault2), address(t0), address(t1));
        address v2Pool = makeAddr("balancerV2Pool");
        vault2.registerPool(PID, v2Pool, _list2(address(t0), address(t1)));
        f2.add(v2Pool);
        vault3 = new MockBalancerV3Vault();
        MockBalancerFactory f3 = new MockBalancerFactory();
        _fundWith(address(vault3), address(t0), address(t1));
        v3Pool = makeAddr("balancerV3Pool");
        IBalancerV3Vault.HooksConfig memory noHooks;
        vault3.registerPool(v3Pool, _list2(address(t0), address(t1)), noHooks);
        f3.add(v3Pool);
        vault3.setPoolBalances(v3Pool, _twice(HELD));

        assertEq(ngPool.get_dy(0, 1, MOCK_BPS), NG_OUT_BPS, "StableSwap-NG prices 1:1 less its fee");
        assertEq(crPool.get_dy(0, 1, MOCK_BPS), CR_OUT_BPS, "Twocrypto-NG prices 1:1 less its fee");
        assertEq(vault2.rateBps(), BAL_OUT_BPS, "Balancer V2 prices 1:1 less its fee");
        assertEq(vault3.rateBps(), BAL_OUT_BPS, "Balancer V3 prices 1:1 less its fee");

        adapters[I_NG] = address(new BlazePhoenixAdapterCurveNG(address(gate), address(ngFactory)));
        adapters[I_V2] = address(new BlazePhoenixAdapterBalancerV2(
            address(gate), address(vault2), [address(f2), address(0), address(0), address(0)]
        ));
        adapters[I_V3] = address(new BlazePhoenixAdapterBalancerV3(
            address(gate), address(vault3), [address(f3), address(0)], [bytes32(0), bytes32(0)]
        ));
        adapters[I_CR] = address(new BlazePhoenixAdapterCurveCryptoNG(address(gate), address(crFactory)));
        for (uint256 k; k < ADAPTERS; ++k) _accept(_family(k), adapters[k]);
        // The pool a wrapper names as its venue: the Curve pool itself, a Balancer Vault.
        venues = [address(ngPool), address(vault2), address(vault3), address(crPool)];

        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        uint24[] memory keys = new uint24[](ADAPTERS);
        for (uint256 k; k < ADAPTERS; ++k) keys[k] = _venueKey(k);
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, MODE_CREATE2_V3, gate.WRAPPER_INIT_HASH(), keys, new int24[](0));
        solver = new BlazePhoenixSolver(address(hub), address(gate));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2")
        );
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        probe = new GateGasProbe();
        // No bridge token: every hop of a route pays the protocol fee on its own input
        // (Core.feeCalendar, Core.paysOnInput).
        assertFalse(hub.isBridgeToken(address(t0)), "t0 is no bridge");
        assertFalse(hub.isBridgeToken(address(t1)), "t1 is no bridge");
        assertFalse(hub.isBridgeToken(address(t2)), "t2 is no bridge");

        user = makeAddr("user");
        vm.startPrank(user);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        t2.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ─── the Gate ───

    /// Quantity: the gas of create, per adapter, at slots 0..3 of one pair, and of the first
    /// wrapper of another pair; relation 1 (header) between that first wrapper and slot 3.
    /// Each create lands where wrapperAddress derives it, is a wrapper of this Gate, names its
    /// venue and is packed into the pair's list at its slot.
    function test_Gas_GateCreate_DeploysWrapper() public {
        string memory g = "test_Gas_GateCreate_DeploysWrapper";
        bytes memory cd12 = abi.encodeCall(BlazePhoenixGate.create, (lo12, hi12, KEY_CR, abi.encode(address(crPool12))));
        bytes[ADAPTERS] memory cds;
        string[ADAPTERS] memory names;
        for (uint256 k; k < ADAPTERS; ++k) {
            cds[k] = abi.encodeCall(BlazePhoenixGate.create, (address(t0), address(t1), _venueKey(k), _hint(k)));
            names[k] = string.concat(_venueName(k), "_slot", vm.toString(k), "_tx");
        }

        (uint256 g12, bytes memory r12) =
            _txWindow(g, "curveCryptoNG_slot0_otherPair_tx", address(this), false, address(gate), cd12);
        uint256[ADAPTERS] memory used;
        bytes[ADAPTERS] memory rets;
        for (uint256 k; k < ADAPTERS; ++k) {
            (used[k], rets[k]) = _txWindow(g, names[k], address(this), false, address(gate), cds[k]);
        }

        assertGe(
            used[I_CR] - _cd(cds[I_CR]),
            g12 - _cd(cd12) + SLOT_CR * COLD_SLOAD,
            "slot k scans k more cold words of the list than slot 0, and does no less"
        );
        w12 = abi.decode(r12, (address));
        uint256[GATE_MAX_WRAPPERS] memory list = gate.wrappersOf(address(t0), address(t1));
        for (uint256 k; k < ADAPTERS; ++k) {
            address w = abi.decode(rets[k], (address));
            assertEq(gate.wrapperAddress(address(t0), address(t1), _venueKey(k)), w, "where the derive puts it");
            assertTrue(gate.isWrapper(w), "a wrapper of this Gate");
            assertEq(BlazePhoenixGateWrapper(w).venuePool(), venues[k], "its venue");
            assertEq(list[k], uint256(_venueKey(k)) << 160 | uint160(w), "packed at its slot");
        }
        uint256[GATE_MAX_WRAPPERS] memory other = gate.wrappersOf(lo12, hi12);
        assertEq(other[0], uint256(KEY_CR) << 160 | uint160(w12), "the other pair's first slot");
        for (uint256 i = 1; i < GATE_MAX_WRAPPERS; ++i) assertEq(other[i], 0, "and nothing after it");
    }

    /// Quantity: the gas of wrapperAddress and liveAdapter per adapter, and of wrappersOf over
    /// a full pair. They answer the created wrapper, the accepted adapter and the packed list.
    function test_Gas_GateViews_WrapperAddressAndLiveAdapter() public {
        _createAll();
        string memory g = "test_Gas_GateViews_WrapperAddressAndLiveAdapter";
        for (uint256 k; k < ADAPTERS; ++k) {
            bytes memory r = _viewWindow(
                g, string.concat("wrapperAddress_", _venueName(k)), address(gate),
                abi.encodeCall(BlazePhoenixGate.wrapperAddress, (address(t0), address(t1), _venueKey(k)))
            );
            assertEq(abi.decode(r, (address)), wrappers[k], "the created wrapper");
            r = _viewWindow(
                g, string.concat("liveAdapter_", _venueName(k)), address(gate),
                abi.encodeCall(BlazePhoenixGate.liveAdapter, (_family(k)))
            );
            assertEq(abi.decode(r, (address)), adapters[k], "the accepted adapter");
        }
        bytes memory rl = _viewWindow(
            g, "wrappersOf", address(gate), abi.encodeCall(BlazePhoenixGate.wrappersOf, (address(t0), address(t1)))
        );
        uint256[GATE_MAX_WRAPPERS] memory list = gate.wrappersOf(address(t0), address(t1));
        assertEq(rl, abi.encode(list), "the window's answer");
        for (uint256 k; k < ADAPTERS; ++k) {
            assertEq(list[k], uint256(_venueKey(k)) << 160 | uint160(wrappers[k]), "packed at its slot");
        }
    }

    /// Quantity: the gas of vitalOf per adapter, on a fresh wrapper and after one material swap.
    /// Fresh: no use, the venue's whole side as depth. After: Core's vitality of the wrapper's
    /// slot, the side the swap left, and Core's psi of that slot at that depth's bucket.
    function test_Gas_GateVitalOf_PerAdapter() public {
        _createAll();
        string memory g = "test_Gas_GateVitalOf_PerAdapter";
        uint32 ts = uint32(block.timestamp);
        for (uint256 k; k < ADAPTERS; ++k) {
            bytes memory r = _viewWindow(
                g, string.concat(_venueName(k), "_fresh"), address(gate),
                abi.encodeCall(BlazePhoenixGate.vitalOf, (wrappers[k]))
            );
            (uint256 v, uint256 d, uint256 p) = abi.decode(r, (uint256, uint256, uint256));
            assertEq(v, 0, "a fresh wrapper has no use");
            assertEq(d, HELD, "the venue's whole side");
            assertEq(p, BPC.psi(BPC.setBucket(0, BPC.depthBucket(HELD)), ts, false, false), "Core's psi, fresh");
        }
        uint256[ADAPTERS] memory out;
        for (uint256 k; k < ADAPTERS; ++k) out[k] = _swap(wrappers[k], true, AMT);
        for (uint256 k; k < ADAPTERS; ++k) {
            bytes memory r = _viewWindow(
                g, string.concat(_venueName(k), "_used"), address(gate),
                abi.encodeCall(BlazePhoenixGate.vitalOf, (wrappers[k]))
            );
            (uint256 v, uint256 d, uint256 p) = abi.decode(r, (uint256, uint256, uint256));
            uint256 s = BlazePhoenixGateWrapper(wrappers[k]).vitalSlot();
            assertEq(out[k], _venueOut(k, AMT), "the swap paid the venue's price");
            assertEq(v, BPC.vitality(s, ts), "Core's vitality of the wrapper's slot");
            assertGt(v, 0, "a material swap is use");
            assertEq(d, HELD - out[k], "the side the swap left");
            assertEq(p, BPC.psi(BPC.setBucket(s, BPC.depthBucket(HELD - out[k])), ts, false, false), "Core's psi");
            assertGt(p, 0, "a used wrapper ranks");
        }
    }

    // ─── the wrapper ───

    /// Quantity: the gas of the wrapper's view quote per adapter. Curve prices in a view, a
    /// Balancer Vault only in its query (so the view answers 0 out); all four declare depth.
    function test_Gas_GateQuote_PerAdapter() public {
        _createAll();
        string memory g = "test_Gas_GateQuote_PerAdapter";
        for (uint256 k; k < ADAPTERS; ++k) {
            bytes memory r = _viewWindow(
                g, _venueName(k), wrappers[k], abi.encodeCall(BlazePhoenixGateWrapper.quote, (true, AMT))
            );
            (uint256 o, uint256 d) = abi.decode(r, (uint256, uint256));
            assertEq(o, _viewOut(k, AMT), "the view's price");
            assertEq(d, HELD, "the declared depth");
        }
    }

    /// Quantity: the gas of quoteCall per adapter, in the eth_call context (tx.origin 0, which
    /// Balancer V3's Vault.quote demands). Every adapter answers its venue's price.
    function test_Gas_GateQuoteCall_PerAdapter() public {
        _createAll();
        string memory g = "test_Gas_GateQuoteCall_PerAdapter";
        for (uint256 k; k < ADAPTERS; ++k) {
            (, bytes memory r) = _txWindow(
                g, string.concat(_venueName(k), "_tx"), address(this), true, wrappers[k],
                abi.encodeCall(BlazePhoenixGateWrapper.quoteCall, (true, AMT))
            );
            assertEq(abi.decode(r, (uint256)), _venueOut(k, AMT), "the venue's price");
        }
    }

    /// Quantity: the gas of one exact-in swap per adapter, called the Router's way (recipient
    /// the caller, paid in the callback). V3 signs; custody ends at 0; the swap is use.
    function test_Gas_WrapperSwap_PerAdapter() public {
        _createAll();
        string memory g = "test_Gas_WrapperSwap_PerAdapter";
        t0.mint(address(this), AMT);
        bytes memory data =
            abi.encodeCall(BlazePhoenixGateWrapper.swap, (address(this), true, int256(AMT), uint160(0), bytes("")));
        for (uint256 k; k < ADAPTERS; ++k) {
            uint256 snap = vm.snapshotState();
            (, bytes memory r) = _txWindow(g, string.concat(_venueName(k), "_tx"), address(this), false, wrappers[k], data);
            (int256 a0, int256 a1) = abi.decode(r, (int256, int256));
            assertEq(a0, int256(AMT), "paid in");
            assertEq(a1, -int256(_venueOut(k, AMT)), "the venue's price out");
            assertEq(t1.balanceOf(address(this)), _venueOut(k, AMT), "delivered");
            _assertEmpty(adapters[k], wrappers[k], venues[k]);
            assertGt(BlazePhoenixGateWrapper(wrappers[k]).vitalSlot(), 0, "a material swap is use");
            vm.revertToState(snap);
        }
    }

    // ─── the Router ───

    /// Quantity: the gas of swapExactIn over one kind-9 leg per adapter. The leg trades the
    /// input less the protocol fee and delivers exactly the venue's price of it.
    function test_Gas_Router_GateLeg_OneHop() public {
        _createAll();
        string memory g = "test_Gas_Router_GateLeg_OneHop";
        t0.mint(user, AMT);
        for (uint256 k; k < ADAPTERS; ++k) {
            uint256 exp = _venueOut(k, AMT - _protocolFee(AMT));
            bytes memory data =
                abi.encodeCall(BlazePhoenixRouter.swapExactIn, (_route1(k), AMT, exp, user, block.timestamp));
            uint256 snap = vm.snapshotState();
            (, bytes memory r) = _txWindow(g, string.concat(_venueName(k), "_tx"), user, false, address(router), data);
            assertEq(abi.decode(r, (uint256)), exp, "the venue's price of the input less the fee");
            assertEq(t1.balanceOf(user), exp, "delivered to the user");
            assertEq(t0.balanceOf(address(router)) + t1.balanceOf(address(router)), 0, "Router at 0");
            _assertEmpty(adapters[k], wrappers[k], venues[k]);
            vm.revertToState(snap);
        }
    }

    /// Quantity: the gas of swapExactIn over two kind-9 hops: each adapter's leg t0 -> t1, then
    /// the Twocrypto-NG leg t1 -> t2. Each hop trades its input less the protocol fee.
    function test_Gas_Router_GateLeg_TwoHops() public {
        _createAll();
        string memory g = "test_Gas_Router_GateLeg_TwoHops";
        t0.mint(user, AMT);
        for (uint256 k; k < ADAPTERS; ++k) {
            uint256 mid = _venueOut(k, AMT - _protocolFee(AMT));
            uint256 exp = _cr12(mid - _protocolFee(mid));
            bytes memory data =
                abi.encodeCall(BlazePhoenixRouter.swapExactIn, (_route2(k), AMT, exp, user, block.timestamp));
            uint256 snap = vm.snapshotState();
            (, bytes memory r) = _txWindow(
                g, string.concat(_venueName(k), "_then_curveCryptoNG_tx"), user, false, address(router), data
            );
            assertEq(abi.decode(r, (uint256)), exp, "both hops at their venue's price, each net of the fee");
            assertEq(t2.balanceOf(user), exp, "delivered to the user");
            assertEq(t1.balanceOf(user), 0, "nothing left in the middle token");
            assertEq(
                t0.balanceOf(address(router)) + t1.balanceOf(address(router)) + t2.balanceOf(address(router)), 0,
                "Router at 0"
            );
            _assertEmpty(adapters[k], wrappers[k], venues[k]);
            assertEq(t1.balanceOf(w12) + t2.balanceOf(w12), 0, "second wrapper at 0");
            assertEq(t1.balanceOf(adapters[I_CR]) + t2.balanceOf(adapters[I_CR]), 0, "second adapter at 0");
            vm.revertToState(snap);
        }
    }

    /// Quantity: the gas of the automatic door over a kind-9 candidate: the Solver's plan of
    /// (t1, t2), whose one venue is the Twocrypto-NG wrapper, then swapBestExactIn. The plan is
    /// one kind-9 leg priced by the adapter's quote; the door delivers it net of the fee.
    function test_Gas_SwapBestExactIn_GateCandidate_OneHop() public {
        _createAll();
        string memory g = "test_Gas_SwapBestExactIn_GateCandidate_OneHop";
        uint256 exp = _cr12(AMT - _protocolFee(AMT));
        bytes memory planData = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (address(t1), address(t2), AMT));
        bytes memory swapData = abi.encodeCall(
            BlazePhoenixRouter.swapBestExactIn, (address(t1), address(t2), AMT, exp, user, block.timestamp)
        );
        t1.mint(user, AMT);

        bytes memory rp = _viewWindow(g, "findBestRoutePlan", address(solver), planData);
        (, bytes memory rs) = _txWindow(g, "swapBestExactIn_tx", user, false, address(router), swapData);

        RoutePlan memory p = abi.decode(rp, (RoutePlan));
        assertEq(p.best.hops.length, 1, "one hop");
        assertEq(p.best.hops[0].tokenIn, address(t1), "from t1");
        assertEq(p.best.hops[0].tokenOut, address(t2), "to t2");
        assertEq(p.best.hops[0].legs.length, 1, "one leg");
        Leg memory l = p.best.hops[0].legs[0];
        assertEq(l.pool, w12, "on the wrapper");
        assertEq(l.kind, BPC.KIND_EXTERNAL, "as kind 9");
        assertEq(l.fee, KEY_CR, "under its venue key");
        assertEq(l.amountIn, AMT, "the whole input");
        assertEq(l.expectedOut, _cr12(AMT), "priced by the adapter's quote");
        assertEq(abi.decode(rs, (uint256)), exp, "the best door delivers the quote of the input less the fee");
        assertEq(t2.balanceOf(user), exp, "delivered to the user");
        assertGt(BlazePhoenixGateWrapper(w12).vitalSlot(), 0, "and is use");
    }

    // ─── the Quoter ───

    /// Quantity: the gas of Quoter.gateVitalOf per adapter, on wrappers after one material
    /// swap; relation 2 (header) against the Gate's own vitalOf. It answers the Gate's vitalOf.
    function test_Gas_QuoterGateVitalOf_PerAdapter() public {
        _createAll();
        string memory g = "test_Gas_QuoterGateVitalOf_PerAdapter";
        for (uint256 k; k < ADAPTERS; ++k) _swap(wrappers[k], true, AMT);
        bytes[ADAPTERS] memory dData;
        bytes[ADAPTERS] memory qData;
        for (uint256 k; k < ADAPTERS; ++k) {
            dData[k] = abi.encodeCall(BlazePhoenixGate.vitalOf, (wrappers[k]));
            qData[k] = abi.encodeCall(
                BlazePhoenixQuoter.gateVitalOf, (wrappers[k], address(t0), address(t1), _venueKey(k))
            );
        }
        for (uint256 k; k < ADAPTERS; ++k) {
            bytes memory r = _viewWindow(g, _venueName(k), address(quoter), qData[k]);
            (uint256 v, uint256 d, uint256 p) = abi.decode(r, (uint256, uint256, uint256));
            (uint256 gv, uint256 gd, uint256 gp) = gate.vitalOf(wrappers[k]);
            assertEq(v, gv, "the Gate's vitality");
            assertEq(d, gd, "the Gate's depth");
            assertEq(p, gp, "the Gate's psi");
            assertGt(v, 0, "a used wrapper");
            assertGt(p, 0, "that ranks");
        }

        uint256[ADAPTERS] memory dGas;
        uint256[ADAPTERS] memory qGas;
        for (uint256 k; k < ADAPTERS; ++k) dGas[k] = probe.gasOf(address(gate), dData[k]);
        for (uint256 k; k < ADAPTERS; ++k) qGas[k] = probe.gasOf(address(quoter), qData[k]);
        for (uint256 k; k < ADAPTERS; ++k) {
            assertGe(
                qGas[k], dGas[k] + 3 * COLD_ACCOUNT_ACCESS + COLD_SLOAD,
                "the registry check pays the Quoter, Core, the Hub and its row, cold"
            );
        }
    }

    // ─── fixture ───

    /// The (t1, t2) wrapper first, then one wrapper per adapter on (t0, t1), in index order.
    function _createAll() internal {
        w12 = gate.create(lo12, hi12, KEY_CR, abi.encode(address(crPool12)));
        for (uint256 k; k < ADAPTERS; ++k) {
            wrappers[k] = gate.create(address(t0), address(t1), _venueKey(k), _hint(k));
        }
    }

    function _venueName(uint256 k) internal pure returns (string memory) {
        if (k == I_NG) return "curveNG";
        if (k == I_V2) return "balancerV2";
        if (k == I_V3) return "balancerV3";
        return "curveCryptoNG";
    }

    function _family(uint256 k) internal pure returns (uint8) {
        if (k == I_NG) return FAM_NG;
        if (k == I_V2) return FAM_V2;
        if (k == I_V3) return FAM_V3;
        return FAM_CR;
    }

    function _venueKey(uint256 k) internal pure returns (uint24) {
        return uint24(_family(k)) << 16 | VENUE_SLOT;
    }

    /// What `create` hands the adapter's resolve: the Curve pool, the V2 pool id, the V3 pool.
    function _hint(uint256 k) internal view returns (bytes memory) {
        if (k == I_NG) return abi.encode(address(ngPool));
        if (k == I_V2) return abi.encode(PID);
        if (k == I_V3) return abi.encode(v3Pool);
        return abi.encode(address(crPool));
    }

    function _venueOut(uint256 k, uint256 x) internal pure returns (uint256) {
        uint256 bps = k == I_NG ? NG_OUT_BPS : k == I_CR ? CR_OUT_BPS : BAL_OUT_BPS;
        return x * bps / MOCK_BPS;
    }

    /// The view quote's price: a Balancer Vault prices only in its query, so its view says 0.
    function _viewOut(uint256 k, uint256 x) internal pure returns (uint256) {
        return k == I_V2 || k == I_V3 ? 0 : _venueOut(k, x);
    }

    function _cr12(uint256 x) internal pure returns (uint256) {
        return x * CR_OUT_BPS / MOCK_BPS;
    }

    /// The protocol fee a hop pays on its input (the Router's mulDivUp of PROTOCOL_FEE_BPS).
    function _protocolFee(uint256 x) internal pure returns (uint256) {
        return BPC.mulDivUp(x, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// The intrinsic gas of a transaction carrying `data` (EIP-2028).
    function _cd(bytes memory data) internal pure returns (uint256 c) {
        c = TX_BASE;
        for (uint256 i; i < data.length; ++i) c += data[i] == 0 ? CALLDATA_ZERO : CALLDATA_NONZERO;
    }

    function _list2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _twice(uint256 x) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (x, x);
    }

    function _fundWith(address holder, address a, address b) internal {
        MockERC20(a).mint(holder, HELD);
        MockERC20(b).mint(holder, HELD);
    }

    /// A Twocrypto-NG pool of (a, b), coins in that order, funded HELD a side and registered.
    function _crPool(address a, address b) internal returns (MockCurveCryptoNGPool p) {
        p = new MockCurveCryptoNGPool(_list2(a, b), _twice(PAR));
        _fundWith(address(p), a, b);
        p.sync();
        crFactory.register(address(p), _list2(a, b));
    }

    function _hop(address pool, uint24 key, address tIn, address tOut, uint256 amt, uint256 exp)
        internal pure returns (Hop memory)
    {
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: pool, hooks: address(0), kind: BPC.KIND_EXTERNAL, fee: key, tickSpacing: 0,
            zeroForOne: tIn < tOut, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: exp, legs: l});
    }

    function _route1(uint256 k) internal view returns (Route memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(wrappers[k], _venueKey(k), address(t0), address(t1), AMT, _venueOut(k, AMT));
        return _routeOf(hops);
    }

    function _route2(uint256 k) internal view returns (Route memory) {
        Hop[] memory hops = new Hop[](2);
        uint256 mid = _venueOut(k, AMT);
        hops[0] = _hop(wrappers[k], _venueKey(k), address(t0), address(t1), AMT, mid);
        hops[1] = _hop(w12, KEY_CR, address(t1), address(t2), mid, _cr12(mid));
        return _routeOf(hops);
    }

    function _routeOf(Hop[] memory hops) internal pure returns (Route memory) {
        return Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    // ─── windows ───

    /// A door that is not `view`, as its own transaction from `from` (tx.origin 0 when `query`,
    /// the eth_call context). Returns the window's gas and the door's answer.
    function _txWindow(string memory g, string memory name, address from, bool query, address target, bytes memory data)
        internal returns (uint256 used, bytes memory ret)
    {
        require(target.code.length != 0, "window: no code at the target");
        if (query) vm.prank(from, address(0));
        else vm.prank(from);
        vm.startSnapshotGas(g, name);
        (bool ok, bytes memory r) = target.call(data);
        used = vm.stopSnapshotGas();
        _bubble(ok, r);
        ret = r;
    }

    /// A `view` door, by STATICCALL. Returns the door's answer.
    function _viewWindow(string memory g, string memory name, address target, bytes memory data)
        internal returns (bytes memory ret)
    {
        require(target.code.length != 0, "window: no code at the target");
        vm.startSnapshotGas(g, name);
        (bool ok, bytes memory r) = target.staticcall(data);
        vm.stopSnapshotGas();
        _bubble(ok, r);
        ret = r;
    }

    function _bubble(bool ok, bytes memory r) internal pure {
        if (!ok) assembly ("memory-safe") { revert(add(r, 32), mload(r)) }
    }
}
