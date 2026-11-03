// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "../../../src/BlazePhoenixCore.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../../../src/BlazePhoenixGate.sol";
import {ExtAdapterBase} from "../../../src/adapters/ExtAdapterBase.sol";
import {BlazePhoenixAdapterLB} from "../../../src/adapters/BlazePhoenixAdapterLB.sol";
import {AvaxForkBase} from "./AvaxForkBase.sol";

interface IErc20L {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ILBPairL {
    function getTokenX() external view returns (address);
    function getTokenY() external view returns (address);
    function getBinStep() external view returns (uint16);
    function getFactory() external view returns (address);
    function getLBHooksParameters() external view returns (bytes32);
    function getSwapOut(uint128 amountIn, bool swapForY) external view returns (uint128, uint128, uint128);
    function swap(bool swapForY, address to) external returns (bytes32);
}

/// LFJ v2.2 LBFactory and Pharaoh DLMMFactory: AccessControl with DEFAULT_ADMIN_ROLE = owner().
interface ILBFactoryL {
    function owner() external view returns (address);
    function LB_HOOKS_MANAGER_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function setLBHooksParametersOnPair(
        address tokenX, address tokenY, uint16 binStep, bytes32 hooksParameters, bytes calldata onHooksSetData
    ) external;
}

/// @notice The oracle: a raw PUSH swap straight on the LB pair (transfer, then swap), paid from
///         its own balance; the direction comes from the pair's own getTokenX. It shares no code
///         with the adapter, the Gate, the Router or the Quoter.
contract RawLBOracle {
    function swapIn(address pair, address tokenIn, uint256 amtIn) external returns (uint256 out) {
        address x = ILBPairL(pair).getTokenX();
        bool swapForY = tokenIn == x;
        address tokenOut = swapForY ? ILBPairL(pair).getTokenY() : x;
        uint256 b = IErc20L(tokenOut).balanceOf(address(this));
        require(IErc20L(tokenIn).transfer(pair, amtIn), "oracle: pay");
        ILBPairL(pair).swap(swapForY, address(this));
        out = IErc20L(tokenOut).balanceOf(address(this)) - b;
    }
}

/// @notice A hooks contract for the factory's own setLBHooksParametersOnPair path: it names its
///         pair (setHooksParameters asks getLBPair) and answers every other hook call with that
///         call's own selector, which is all Hooks._safeCall checks.
contract HookStub {
    address private immutable PAIR;

    constructor(address p) {
        PAIR = p;
    }

    function getLBPair() external view returns (address) {
        return PAIR;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0x00, shl(224, shr(224, calldataload(0))))
            return(0x00, 0x20)
        }
    }
}

/// @notice avax-1103 wave 3 (lb-fork): BlazePhoenixAdapterLB against the three live Liquidity Book
///         factories on Avalanche (LFJ v2.1, LFJ v2.2, Pharaoh DLMM), block 99270000, through the
///         Gate, the Gate's Hub row (KIND_EXTERNAL), the Quoter and the Router. No src change:
///         every test pins current behaviour and has its own mutant (lb-fork-mutantes.tsv).
///         Oracle: RawLBOracle above, on the same pre-state (snapshot), fed what the pair itself
///         received during the Router's run (its balance delta). The route's use of the pair is
///         proven by the pair's own balance deltas.
contract AvaxLBFork is AvaxForkBase {
    address internal constant LB21_FACTORY = 0x8e42f2F4101563bF679975178e880FD87d3eFd4e;
    address internal constant LB22_FACTORY = 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c;
    address internal constant DLMM_FACTORY = 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D;
    // WAVAX/USDC, one per factory: bin step 20 (v2.1), 10 (v2.2), 5 (DLMM).
    address internal constant LB21_WU = 0xD446eb1660F766d533BeCeEf890Df7A69d26f7d1;
    address internal constant LB22_WU = 0x864d4e5Ee7318e97483DB7EB0912E09F161516EA;
    address internal constant DLMM_WU = 0x8aC5707f8D4BDe1d771d34c7AfD81c3922b73379;
    // getLBHooksParameters at FORK_BLOCK: flags 0x151 (BEFORE_SWAP, BEFORE_MINT, BEFORE_BURN,
    // BEFORE_TRANSFER; no AFTER_SWAP) over the hook in the low 160 bits. v2.1 has no hooks.
    bytes32 internal constant LB22_HOOKS = 0x000000000000000000000151ba83987a28b1c7514576e15d58c134b8f0e00fa9;
    bytes32 internal constant DLMM_HOOKS = 0x000000000000000000000151138ce0008f7febdcffdf27c0ad156584eca7d5b6;

    uint256 internal constant BEFORE_SWAP = 1 << 160; // Hooks.sol (LFJ v2.2 = DLMM)
    uint256 internal constant AFTER_SWAP = 1 << 161;
    uint256 internal constant X0 = 1; // the adapter's aux0 bits
    uint256 internal constant HOOKED = 2;

    address internal constant USER = address(0xA11ce0000000000000000000000000000000a11c);

    // Index 0 = LFJ v2.1, 1 = LFJ v2.2, 2 = Pharaoh DLMM. Gate family = index + 1, slot 1.
    address[3] internal factories;
    address[3] internal pairs;
    uint16[3] internal binSteps;
    BlazePhoenixAdapterLB[3] internal adapters;
    address[3] internal wrappers;

    struct Run {
        uint256 amt;
        uint256 quote;   // Quoter.previewRouteExact
        uint256 exec;    // what the recipient received from Router.swapExactIn
        uint256 pairIn;  // tokenIn the pair received (its balance delta)
        uint256 pairOut; // tokenOut the pair paid (its balance delta)
        uint256 feeIn;   // the treasuries' tokenIn delta
        uint256 feeOut;  // the treasuries' tokenOut delta
        uint256 kept;    // Router, wrapper and adapter holdings after the run, both tokens
        uint256 oracle;  // RawLBOracle output for pairIn, same pre-state
        uint256 gas;     // gasleft() around the Router call, main accounts cooled first
    }

    /// The three instances exist from setUp; the Gate learns of them only in `_mount`, inside
    /// each test, so a refusal there fails the named test.
    function _afterDeploy() internal override {
        (factories[0], factories[1], factories[2]) = (LB21_FACTORY, LB22_FACTORY, DLMM_FACTORY);
        (pairs[0], pairs[1], pairs[2]) = (LB21_WU, LB22_WU, DLMM_WU);
        (binSteps[0], binSteps[1], binSteps[2]) = (20, 10, 5);
        for (uint256 i; i < 3; ++i) adapters[i] = new BlazePhoenixAdapterLB(address(gate), factories[i]);
    }

    function _family(uint256 i) internal pure returns (uint8) {
        return uint8(i + 1);
    }

    function _key(uint256 i) internal pure returns (uint24) {
        return (uint24(i + 1) << 16) | 1;
    }

    /// propose -> ADAPTER_DELAY -> accept for the three families (one warp), one wrapper per pair
    /// (hint = the bin step), then the Gate's Hub row with the three venue keys.
    function _mount() internal {
        for (uint256 i; i < 3; ++i) gate.proposeAdapter(_family(i), address(adapters[i]));
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        for (uint256 i; i < 3; ++i) {
            gate.acceptAdapter(_family(i));
            wrappers[i] = gate.create(WAVAX, USDC, _key(i), abi.encode(uint256(binSteps[i])));
        }
        uint24[] memory keys = new uint24[](3);
        (keys[0], keys[1], keys[2]) = (_key(0), _key(1), _key(2));
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, MODE_CREATE2_V3, gate.WRAPPER_INIT_HASH(), keys, new int24[](0));
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IErc20L(t).balanceOf(who);
    }

    function _held(uint256 i, address tA, address tB) internal view returns (uint256) {
        address w = wrappers[i];
        address a = address(adapters[i]);
        return _bal(tA, address(router)) + _bal(tB, address(router)) + _bal(tA, w) + _bal(tB, w)
            + _bal(tA, a) + _bal(tB, a);
    }

    function _route(uint256 i, address tIn, address tOut, uint256 amt) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg(wrappers[i], address(0), BPC.KIND_EXTERNAL, _key(i), 0, tIn == WAVAX, false, amt, 0, bytes32(0));
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop(tIn, tOut, amt, 0, legs);
        r.hops = hops;
    }

    function _fund(address tIn, uint256 amt) internal {
        deal(tIn, USER, amt);
        vm.prank(USER);
        IErc20L(tIn).approve(address(router), amt);
    }

    function _cool(uint256 i) internal {
        vm.cool(address(router));
        vm.cool(address(hub));
        vm.cool(address(gate));
        vm.cool(wrappers[i]);
        vm.cool(address(adapters[i]));
        vm.cool(pairs[i]);
        vm.cool(WAVAX);
        vm.cool(USDC);
        vm.cool(address(uint160(uint256(BlazePhoenixGateWrapper(wrappers[i]).aux1()))));
    }

    function _fees(address t) internal view returns (uint256) {
        return _bal(t, TEST_TREASURY_1) + _bal(t, TEST_TREASURY_2);
    }

    function _oracle(uint256 i, address tIn, uint256 amt) internal returns (uint256) {
        RawLBOracle o = new RawLBOracle();
        deal(tIn, address(o), amt);
        return o.swapIn(pairs[i], tIn, amt);
    }

    // ─── 1. mount ─────────────────────────────────────────────────────────

    /// @notice The three instances, one per factory and one Gate family each: propose ->
    ///         ADAPTER_DELAY -> accept. The Gate's scan passes over the real runtime code, an
    ///         early accept is refused (GateE(7)), and the accept pins the codehash.
    function test_AvaxLB_Mount_ThreeFamiliesPinnedAndClean() public {
        for (uint256 i; i < 3; ++i) {
            address a = address(adapters[i]);
            assertEq(address(adapters[i].FACTORY()), factories[i], "one instance per factory");
            assertEq(address(adapters[i].GATE()), address(gate), "bound to this Gate");
            assertTrue(gate.codeIsClean(a), "the Gate's scan passes the real code");
            gate.proposeAdapter(_family(i), a);
            vm.expectRevert(abi.encodeWithSelector(BlazePhoenixGate.GateE.selector, uint8(7)));
            gate.acceptAdapter(_family(i));
        }
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        for (uint256 i; i < 3; ++i) {
            address a = address(adapters[i]);
            gate.acceptAdapter(_family(i));
            assertEq(gate.adapterOf(_family(i)), a, "its own family");
            assertEq(gate.pinOf(_family(i)), keccak256(a.code), "the accept pins the codehash");
            assertEq(gate.liveAdapter(_family(i)), a, "live");
            console2.log("adapter", a, a.code.length, uint256(_family(i)));
        }
    }

    /// @notice create with hint = abi.encode(binStep): the wrapper's venue is the factory's own
    ///         record (the pair named here, read on chain at FORK_BLOCK), and what resolve pinned
    ///         matches the pair: X0 by getTokenX, HOOKED by whether getLBHooksParameters answers,
    ///         and the BEFORE_SWAP hook pinned = the low 160 bits of the pair's hooks.
    function test_AvaxLB_Create_PinsTheRealPairAndItsHooks() public {
        _mount();
        for (uint256 i; i < 3; ++i) {
            BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(wrappers[i]);
            ILBPairL p = ILBPairL(pairs[i]);
            assertEq(address(w), gate.wrapperAddress(USDC, WAVAX, _key(i)), "the Gate's derive");
            assertEq(w.venuePool(), pairs[i], "the factory's record of (WAVAX, USDC, binStep)");
            assertEq(p.getFactory(), factories[i], "the pair names its factory");
            assertEq(uint256(p.getBinStep()), uint256(binSteps[i]), "bin step");
            assertEq(w.token0(), WAVAX, "sorted: WAVAX below USDC");
            bool x0 = p.getTokenX() == w.token0();
            (bool hooked, bytes memory hp) = pairs[i].staticcall(abi.encodeWithSignature("getLBHooksParameters()"));
            assertEq(uint256(w.aux0()), (x0 ? X0 : 0) | (hooked ? HOOKED : 0), "aux0 = X0 | HOOKED, by the pair");
            console2.log("wrapper", address(w), uint256(w.aux0()), hooked ? 1 : 0);
            if (!hooked) {
                assertEq(i, 0, "only the v2.1 pair has no hooks");
                assertEq(w.aux1(), bytes32(0), "no hook pinned");
                continue;
            }
            uint256 h = uint256(abi.decode(hp, (bytes32)));
            assertEq(bytes32(h), i == 1 ? LB22_HOOKS : DLMM_HOOKS, "the pair's hooks at FORK_BLOCK");
            assertTrue((h & BEFORE_SWAP) != 0, "BEFORE_SWAP on");
            assertEq(h & AFTER_SWAP, 0, "AFTER_SWAP off");
            assertEq(uint256(w.aux1()), uint256(uint160(h)), "the hook pinned at create");
        }
    }

    /// @notice Discovery: the Gate's Hub row (KIND_EXTERNAL, V3 CREATE2 salt, the wrapper init
    ///         hash, the three venue keys) lists the three wrappers for (USDC, WAVAX). Each record
    ///         is read whole by its ABI layout and checked field by field; the Core's derive and the
    ///         Gate's own list agree with it.
    function test_AvaxLB_Hub_RowListsTheThreeWrappers() public {
        _mount();
        PoolInfo[] memory hits = hub.discoverFor(USDC, WAVAX);
        assertEq(hits.length, 3, "three records, all the Gate's");
        uint256[4] memory byGate = gate.wrappersOf(USDC, WAVAX);
        for (uint256 j; j < hits.length; ++j) {
            (bool active, , uint8 kind, uint24 key, , address a0, address a1, address listed, address hk) = abi.decode(
                abi.encode(hits[j]), (bool, bool, uint8, uint24, int24, address, address, address, address)
            );
            uint256 i = uint256(key >> 16) - 1;
            assertLt(i, 3, "a venue key of the row");
            assertEq(key, _key(i), "slot 1");
            assertEq(listed, wrappers[i], "the record lists the wrapper");
            assertEq(kind, BPC.KIND_EXTERNAL, "kind 9");
            assertEq(a0, WAVAX, "token0");
            assertEq(a1, USDC, "token1");
            assertEq(hk, address(0), "no hooks field");
            assertEq(
                BPC.deriveAddress(address(gate), USDC, WAVAX, key, false, 0, MODE_CREATE2_V3, gate.WRAPPER_INIT_HASH()),
                listed, "Core derive"
            );
            assertEq(byGate[i], (uint256(key) << 160) | uint160(listed), "the Gate's list, in creation order");
            console2.log("hit", listed, uint256(key), active ? 1 : 0);
        }
    }

    // ─── 2. quote == exec == oracle, three sizes each way ────────────────

    /// @dev One order through the Router: Quoter preview, Router execution with the pair's and the
    ///      treasuries' deltas, then (state reverted) the raw oracle on what the pair received.
    function _fill(uint256 i, address tIn, address tOut, uint256 amt) internal returns (Run memory r) {
        r.amt = amt;
        Route memory route = _preview(i, tIn, tOut, r);
        assertGt(r.quote, 0, "the Quoter prices the leg");
        _fund(tIn, amt);
        uint256 snap = vm.snapshotState();
        _exec(i, route, tIn, tOut, r.quote, r);
        vm.revertToState(snap);
        r.oracle = _oracle(i, tIn, r.pairIn);
        _check(r);
    }

    function _preview(uint256 i, address tIn, address tOut, Run memory r) internal returns (Route memory route) {
        (route, r.quote) = quoter.previewRouteExact(_route(i, tIn, tOut, r.amt), r.amt);
    }

    /// @dev The Router's run with the floor `floor`, main accounts cooled first; every delta
    ///      lands in `r`.
    function _exec(uint256 i, Route memory route, address tIn, address tOut, uint256 floor, Run memory r) internal {
        address pair = pairs[i];
        uint256[5] memory b;
        b[0] = _bal(tIn, pair);
        b[1] = _bal(tOut, pair);
        b[2] = _fees(tIn);
        b[3] = _fees(tOut);
        b[4] = _bal(tOut, USER);
        _cool(i);
        vm.prank(USER);
        uint256 g = gasleft();
        uint256 got = router.swapExactIn(route, r.amt, floor, USER, block.timestamp + 600);
        r.gas = g - gasleft();
        r.pairIn = _bal(tIn, pair) - b[0];
        r.pairOut = b[1] - _bal(tOut, pair);
        r.feeIn = _fees(tIn) - b[2];
        r.feeOut = _fees(tOut) - b[3];
        r.exec = _bal(tOut, USER) - b[4];
        r.kept = _held(i, tIn, tOut);
        assertEq(got, r.exec, "the Router returns what the recipient received");
        assertEq(_bal(tIn, USER), 0, "the user spent the whole order");
    }

    function _check(Run memory r) internal pure {
        assertEq(r.quote, r.exec, "Quoter == Router, to the wei");
        _settled(r);
    }

    /// @dev What every executed order owes, priced or not: the pair took the order less the
    ///      fee, paid the recipient plus the fee, paid what the raw oracle pays, and nothing
    ///      stayed behind.
    function _settled(Run memory r) internal pure {
        assertGt(r.pairIn, 0, "the route used this pair (input side)");
        assertGt(r.pairOut, 0, "the route used this pair (output side)");
        assertEq(r.pairIn + r.feeIn, r.amt, "input: pair + fee == order");
        assertEq(r.exec + r.feeOut, r.pairOut, "output: recipient + fee == pair paid");
        assertEq(r.oracle, r.pairOut, "raw oracle == what the pair paid in the Router's run");
        assertEq(r.kept, 0, "Router, wrapper and adapter keep nothing");
    }

    /// @dev The Router's run of a route the Quoter priced 0 (floor 1 wei) reverts with `err`.
    function _routerRefuses(Route memory route, uint256 amt, bytes memory err) internal {
        vm.prank(USER);
        (bool ok, bytes memory ret) =
            address(router).call(abi.encodeCall(router.swapExactIn, (route, amt, 1, USER, block.timestamp + 600)));
        assertFalse(ok, "the Router refuses");
        console2.logBytes(ret);
        assertEq(ret, err, "the refusal's error");
    }

    /// @dev An order the pair cannot fill: its own loop leaves input over, the Quoter prices 0,
    ///      the wrapper's own quote with all the gas prices 0 too (a partial fill is no price,
    ///      whatever gas the Quoter leaves), the Router refuses, and the raw swap of the same
    ///      order on the same state refuses too, both with the pair's own error `err`.
    function _refused(uint256 i, address tIn, address tOut, uint256 amt, bytes memory err) internal returns (Run memory r) {
        r.amt = amt;
        Route memory route = _preview(i, tIn, tOut, r);
        assertEq(r.quote, 0, "no price for an order the pair cannot fill");
        (uint128 left, , ) = ILBPairL(pairs[i]).getSwapOut(uint128(amt), tIn == ILBPairL(pairs[i]).getTokenX());
        assertGt(uint256(left), 0, "the venue's own loop leaves input over");
        (uint256 full, ) = BlazePhoenixGateWrapper(wrappers[i]).quote(tIn == WAVAX, amt);
        assertEq(full, 0, "with all the gas, the wrapper prices no partial fill");
        _fund(tIn, amt);
        _routerRefuses(route, amt, err);
        RawLBOracle o = new RawLBOracle();
        deal(tIn, address(o), amt);
        (bool ok, bytes memory ret) = address(o).call(abi.encodeCall(o.swapIn, (pairs[i], tIn, amt)));
        assertFalse(ok, "the raw swap refuses too");
        assertEq(ret, err, "the same error");
    }

    /// @dev An order the venue fills whole but the Quoter prices 0: the venue's own loop on it
    ///      needs more gas than GATE_QUOTE_GAS leaves the adapter (cold slots). Pinned whole:
    ///      the Quoter prices 0, the Core's producer prices 0 with the wrapper live, the
    ///      wrapper's own quote with all the gas is the venue's answer, and the Router's run of
    ///      the order (floor 1 wei) settles like a priced one, to the raw oracle.
    function _unpriced(uint256 i, address tIn, address tOut, uint256 amt) internal returns (Run memory r) {
        r.amt = amt;
        Route memory route = _preview(i, tIn, tOut, r);
        assertEq(r.quote, 0, "the Quoter prices 0");
        _cappedZero(i, tIn, tOut, amt);
        uint256 o = _venueFills(i, tIn, amt);
        (uint256 full, ) = BlazePhoenixGateWrapper(wrappers[i]).quote(tIn == WAVAX, amt);
        assertEq(full, o, "with all the gas, the wrapper prices the venue's answer");
        _fund(tIn, amt);
        uint256 snap = vm.snapshotState();
        _exec(i, route, tIn, tOut, 1, r);
        vm.revertToState(snap);
        r.oracle = _oracle(i, tIn, r.pairIn);
        assertEq(r.pairOut, o, "the venue paid its own answer");
        _settled(r);
    }

    /// @dev The producer the Quoter prices a Gate leg with (BPC.gateQuote: the wrapper's view
    ///      quote under GATE_QUOTE_GAS), on the cooled venue: live, and 0.
    function _cappedZero(uint256 i, address tIn, address tOut, uint256 amt) internal {
        vm.cool(pairs[i]);
        (bool live, uint256 out, ) =
            BPC.gateQuote(address(hub), wrappers[i], tIn, tOut, _key(i), tIn == WAVAX, amt, false);
        assertTrue(live, "the wrapper is live");
        assertEq(out, 0, "under GATE_QUOTE_GAS the producer prices 0");
    }

    /// @dev The venue's own loop on the order, cooled and with all the gas: it fills the whole
    ///      order. Returns its answer and logs the gas the read took.
    function _venueFills(uint256 i, address tIn, uint256 amt) internal returns (uint256 o) {
        ILBPairL p = ILBPairL(pairs[i]);
        bool swapForY = tIn == p.getTokenX();
        vm.cool(pairs[i]);
        uint256 g = gasleft();
        (uint128 left, uint128 out, ) = p.getSwapOut(uint128(amt), swapForY);
        g -= gasleft();
        assertEq(uint256(left), 0, "the venue's own loop fills the whole order");
        assertGt(uint256(out), 0, "and pays out");
        console2.log("  venue read gas (cold), GATE_QUOTE_GAS", g, BPC.GATE_QUOTE_GAS);
        o = out;
    }

    function _log(uint256 i, bool usdcIn, Run memory r) internal pure {
        console2.log("run", i, usdcIn ? 1 : 0, r.amt);
        console2.log("  quote exec oracle", r.quote, r.exec, r.oracle);
        console2.log("  pairIn pairOut gas", r.pairIn, r.pairOut, r.gas);
        console2.log("  feeIn feeOut kept", r.feeIn, r.feeOut, r.kept);
    }

    uint8 internal constant FILLS = 0;    // quote == exec == oracle
    uint8 internal constant PARTIAL = 1;  // the venue leaves input over: refused
    uint8 internal constant UNPRICED = 2; // the venue fills it, the Quoter prices 0 (gas)

    /// @dev 1 000, 10 000 and 100 000 USD each way. WAVAX sizes at 1 WAVAX ~ 8.35 USDC at
    ///      FORK_BLOCK (the v2.2 and DLMM getSwapOut of 1 WAVAX: 8341852 and 8345783). Each size
    ///      starts from the same state. At 100 000 USD four of the six legs are UNPRICED (measured
    ///      at FORK_BLOCK: the venue's loop runs out of the gas GATE_QUOTE_GAS leaves the adapter).
    function _sizes(uint256 i, bool usdcIn, uint8[3] memory modes, bytes memory err) internal {
        _mount();
        (address tIn, address tOut) = usdcIn ? (USDC, WAVAX) : (WAVAX, USDC);
        uint256[3] memory amts = usdcIn
            ? [uint256(1_000e6), 10_000e6, 100_000e6]
            : [uint256(120e18), 1_200e18, 12_000e18];
        for (uint256 k; k < 3; ++k) {
            uint256 base = vm.snapshotState();
            Run memory r;
            if (modes[k] == FILLS) r = _fill(i, tIn, tOut, amts[k]);
            else if (modes[k] == PARTIAL) r = _refused(i, tIn, tOut, amts[k], err);
            else r = _unpriced(i, tIn, tOut, amts[k]);
            _log(i, usdcIn, r);
            vm.revertToState(base);
        }
    }

    function _lbOutOfLiquidity() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("LBPair__OutOfLiquidity()");
    }

    function test_AvaxLB_Lb21_UsdcToWavax_QuoteExecOracle() public {
        _sizes(0, true, [FILLS, FILLS, UNPRICED], _lbOutOfLiquidity());
    }

    function test_AvaxLB_Lb21_WavaxToUsdc_QuoteExecOracle() public {
        _sizes(0, false, [FILLS, FILLS, FILLS], _lbOutOfLiquidity());
    }

    function test_AvaxLB_Lb22_UsdcToWavax_QuoteExecOracle() public {
        _sizes(1, true, [FILLS, FILLS, UNPRICED], _lbOutOfLiquidity());
    }

    function test_AvaxLB_Lb22_WavaxToUsdc_QuoteExecOracle() public {
        _sizes(1, false, [FILLS, FILLS, UNPRICED], _lbOutOfLiquidity());
    }

    function test_AvaxLB_Dlmm_UsdcToWavax_QuoteExecOracle() public {
        _sizes(2, true, [FILLS, FILLS, UNPRICED], _lbOutOfLiquidity());
    }

    /// @notice 100 000 USD of WAVAX is more than the pair's USDC side: quote 0 and refused, with
    ///         LBPair__OutOfLiquidity() (0xd36bfd88), the error the DLMM pair kept.
    function test_AvaxLB_Dlmm_WavaxToUsdc_QuoteExecOracle() public {
        _sizes(2, false, [FILLS, FILLS, PARTIAL], _lbOutOfLiquidity());
    }

    // ─── 3. live hooks: changed after create, refused at once ────────────

    /// @dev The factory's own path: its owner (DEFAULT_ADMIN_ROLE) grants LB_HOOKS_MANAGER_ROLE,
    ///      and the manager calls setLBHooksParametersOnPair.
    function _setHooks(uint256 i, bytes32 hp) internal {
        ILBFactoryL f = ILBFactoryL(factories[i]);
        address mgr = makeAddr("lb-hooks-manager");
        bytes32 role = f.LB_HOOKS_MANAGER_ROLE();
        address own = f.owner();
        vm.prank(own);
        f.grantRole(role, mgr);
        vm.prank(mgr);
        f.setLBHooksParametersOnPair(WAVAX, USDC, binSteps[i], hp, "");
        assertEq(ILBPairL(pairs[i]).getLBHooksParameters(), hp, "the factory's path landed");
    }

    /// @dev Priced before the change; after it the wrapper's quote and quoteCall are 0, the
    ///      Quoter prices 0, and the Router's execution reverts with the adapter's AdapterE(7).
    function _hooksRefused(uint256 i, bytes32 hp) internal {
        _mount();
        uint256 amt = 1_000e6;
        BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(wrappers[i]);
        (uint256 q0, ) = w.quote(false, amt);
        assertGt(q0, 0, "priced before the change");
        _setHooks(i, hp);
        (uint256 q, uint256 d) = w.quote(false, amt);
        assertEq(q, 0, "quote 0");
        assertEq(d, 0, "no depth declared");
        assertEq(w.quoteCall(false, amt), 0, "quoteCall 0");
        Run memory r;
        r.amt = amt;
        Route memory route = _preview(i, USDC, WAVAX, r);
        assertEq(r.quote, 0, "the Quoter prices 0");
        _fund(USDC, amt);
        _routerRefuses(route, amt, abi.encodeWithSelector(ExtAdapterBase.AdapterE.selector, uint8(7)));
    }

    /// Same flags, the BEFORE_SWAP hook moved to another contract.
    function _moved(bytes32 hp, address hook) internal pure returns (bytes32) {
        return bytes32(((uint256(hp) >> 160) << 160) | uint160(hook));
    }

    /// @notice The BEFORE_SWAP hook of the v2.2 pair moves after create: refused.
    function test_AvaxLB_Lb22_BeforeSwapHookMoved_Refused() public {
        _hooksRefused(1, _moved(LB22_HOOKS, address(new HookStub(LB22_WU))));
    }

    /// @notice AFTER_SWAP turned on for the v2.2 pair after create (alone, so no other check is
    ///         what refuses): refused.
    function test_AvaxLB_Lb22_AfterSwapTurnedOn_Refused() public {
        _hooksRefused(1, bytes32(AFTER_SWAP | uint160(address(new HookStub(LB22_WU)))));
    }

    /// @notice The BEFORE_SWAP hook of the DLMM pair moves after create: refused.
    function test_AvaxLB_Dlmm_BeforeSwapHookMoved_Refused() public {
        _hooksRefused(2, _moved(DLMM_HOOKS, address(new HookStub(DLMM_WU))));
    }

    /// @notice AFTER_SWAP turned on for the DLMM pair after create (alone): refused.
    function test_AvaxLB_Dlmm_AfterSwapTurnedOn_Refused() public {
        _hooksRefused(2, bytes32(AFTER_SWAP | uint160(address(new HookStub(DLMM_WU)))));
    }
}
