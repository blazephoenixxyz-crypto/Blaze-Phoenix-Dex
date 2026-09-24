// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  BPX-2026-009 — ROUTE SELF-CONSISTENCY FOR V4 LEGS (reported by Karan Rathod).
//
//  A V4 leg is executed by the key derived from (tokenIn, auxId, fee,
//  tickSpacing, hooks); `leg.pool` carries the truncated poolId the Solver and
//  Quoter derive from that key. Guarantee: the two must agree, or the leg is
//  refused before any token moves (RouterE(11)), and the Quoter refuses to price
//  it. These tests run the REAL Router, the REAL Hub and a per-pool priced
//  singleton and record the bound around the guarantee:
//
//    1. an honest route settles;
//    2. a leg executing under another admitted hook with the honest attestation
//       is refused by the attestation gate (RouterE(5));
//    3. a leg whose fields disagree with the pool it names is refused (RouterE(11));
//    4. a route that is consistent in every field is the caller's signed intent
//       and settles, bounded like every route by the in-frame promise, the gate
//       and userMinOut (registered as SOK-ROUTE-SELF / SOK-ROUTE-AUTHOR).
//
//  Red first: test 3 fails on the tree before the check; the mutant registry
//  removes the check and expects it to go red.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20Min { function balanceOf(address) external view returns (uint256); function transfer(address, uint256) external returns (bool); }

/// @dev A singleton with one exchange rate PER POOL ID, real ERC20 movement and
///      the extsload backing store the Router's in-frame quote reads.
contract PricedV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    mapping(bytes32 => uint256) public rate;      // out = in * rate / 1000
    mapping(bytes32 => bytes32) public slots;     // extsload backing store
    bytes32 public lastPid;
    address pendingCur; uint256 pendingOwe; bool synced; address syncedCur; uint256 syncBal;
    address public probe;        // a "hook" that runs inside the next swap (one shot)
    uint256 public extraOwe;     // what the next swap demands beyond its own input (one shot)
    function setProbe(address p) external { probe = p; }
    function setExtraOwe(uint256 x) external { extraOwe = x; }
    function setRate(bytes32 pid, uint256 r) external { rate[pid] = r; }
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        // bubble the callback's revert data: the Quoter's dry-run returns its deltas that way
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        // THE MANAGER'S OWN INVARIANT: every delta is settled when the unlock returns.
        // Without it a callback that skipped its settle passed here, and only the fork
        // job - with the real PoolManager - could see it (V4 campaign, 2026-09-23).
        require(pendingOwe == 0, "CurrencyNotSettled");
        return ret;
    }
    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (int256) {
        if (probe != address(0)) { address pr = probe; probe = address(0); IMidSwapProbe(pr).poke(); }
        bytes32 pid = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        lastPid = pid;
        // The real manager's price-limit rule: exact-in only, and the limit strictly on the
        // far side of the current price, inside the MIN/MAX sqrt price bounds.
        require(p.amountSpecified < 0, "exact-in only");
        uint160 sp = uint160(uint256(slots[keccak256(abi.encode(pid, uint256(6)))]));
        require(p.zeroForOne
            ? (p.sqrtPriceLimitX96 < sp && p.sqrtPriceLimitX96 > 4295128739)
            : (p.sqrtPriceLimitX96 > sp && p.sqrtPriceLimitX96 < 1461446703485210103287273052203988822378723970342),
            "PriceLimitOutOfBounds");
        uint256 amt = uint256(-p.amountSpecified);
        // price is per direction: c0 -> c1 at rate, c1 -> c0 at its inverse
        uint256 out = p.zeroForOne ? amt * rate[pid] / 1000 : amt * 1000 / rate[pid];
        pendingCur = p.zeroForOne ? key.currency0 : key.currency1;
        uint256 due = amt + extraOwe; extraOwe = 0;
        pendingOwe = due;
        int128 owe = -int128(int256(due));
        int128 recv = int128(int256(out));
        return p.zeroForOne
            ? int256((uint256(uint128(owe)) << 128) | uint256(uint128(recv)))
            : int256((uint256(uint128(recv)) << 128) | uint256(uint128(owe)));
    }
    function sync(address currency) external { synced = true; syncedCur = currency; syncBal = IERC20Min(currency).balanceOf(address(this)); }
    function settle() external payable returns (uint256) {
        require(synced && syncedCur == pendingCur, "settle: not synced");
        require(IERC20Min(pendingCur).balanceOf(address(this)) - syncBal >= pendingOwe, "settle: unpaid");
        synced = false; pendingCur = address(0); pendingOwe = 0;
        return 0;
    }
    function take(address currency, address to, uint256 amount) external { require(IERC20Min(currency).transfer(to, amount), "take: transfer"); }
}

interface IMidSwapProbe { function poke() external; }

/// @dev Stands in for a hook that runs inside the swap and calls the Router's
///      unlockCallback itself, with a well-formed payload, while the Router's
///      transient context is live. Records what the Router answered.
contract MidSwapCaller {
    address immutable router; bytes payload;
    bool public called; bool public ok; bytes public ret;
    constructor(address r, bytes memory p) { router = r; payload = p; }
    function poke() external {
        called = true;
        (bool o, bytes memory r) = router.call(abi.encodeWithSignature("unlockCallback(bytes)", payload));
        ok = o; ret = r;
    }
}

/// @dev An admitted hook: bit 7 set (beforeSwap), bits 2 and 3 clear (no delta
///      alteration), deployed at such an address by CREATE2 salt search.
contract AdmittedHook { constructor(uint256) {} }
contract HookDeployer {
    function deploy() external returns (address hook) {
        bytes memory initCode = abi.encodePacked(type(AdmittedHook).creationCode, abi.encode(uint256(0)));
        for (uint256 salt; salt < 4096; ++salt) {
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), keccak256(initCode))))));
            uint160 bits = uint160(predicted);
            if ((bits & 0x80) != 0 && (bits & 0x0C) == 0) {
                assembly { hook := create2(0, add(initCode, 32), mload(initCode), salt) }
                require(hook != address(0), "create2");
                return hook;
            }
        }
        revert("no salt");
    }
}

/// @dev A Solver that answers with one fixed plan, so the Quoter can be asked to
///      price a route the real Solver would never build.
contract FixedPlanSolver {
    RoutePlan plan;
    function setPlan(Route memory best) external { plan.best = best; plan.hasFallback = false; }
    function findBestRoutePlan(address, address, uint256) external view returns (RoutePlan memory) { return plan; }
}

contract RouteIntegrityV4Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    PricedV4Manager mgr;
    MockERC20 tokA; MockERC20 tokB;
    address c0; address c1;          // sorted currencies; the swap goes c0 -> c1
    address user = address(0xBEEF);
    address hookB;
    uint24 constant FEE = 3000; int24 constant TS = 60; uint128 constant LIQ = 1e30;
    bytes32 pidA; bytes32 pidB;      // hookless pool A (price 4), hooked pool B (price 1)

    function setUp() public {
        mgr = new PricedV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        tokA = new MockERC20("A", "A"); tokB = new MockERC20("B", "B");
        (c0, c1) = address(tokA) < address(tokB) ? (address(tokA), address(tokB)) : (address(tokB), address(tokA));
        hookB = new HookDeployer().deploy();
        hub.allowHook(hookB, true);
        assertTrue(hub.isHookLive(hookB), "hook B admitted");
        pidA = BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
        pidB = BPC.computeV4PoolId(c0, c1, FEE, TS, hookB);
        _seed(pidA, uint160(2 * BPC.Q96)); mgr.setRate(pidA, 4000);   // pool A: price 4, fills 4:1
        _seed(pidB, uint160(BPC.Q96));     mgr.setRate(pidB, 1000);   // pool B: price 1, fills 1:1
        MockERC20(c0).mint(user, 100e18); MockERC20(c1).mint(address(mgr), 1_000e18);
        vm.prank(user); MockERC20(c0).approve(address(router), type(uint256).max);
    }

    function _seed(bytes32 pid, uint160 sqrtP) internal {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(sqrtP)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
    }

    function _quote(bytes32 pid, uint256 amt) internal view returns (uint256) {
        return BPC.v4LegOut(address(mgr), pid, amt, FEE, TS, true);
    }

    /// @param named the pool the leg NAMES (leg.pool); @param hooks the hook its key EXECUTES
    function _route(bytes32 named, address hooks, uint256 amt, uint256 attested) internal view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({ pool: address(uint160(uint256(named))), hooks: hooks, kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS,
                        zeroForOne: true, stable: false, amountIn: amt, expectedOut: attested, auxId: bytes32(uint256(uint160(c1))) });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: c0, tokenOut: c1, amountIn: amt, expectedOut: attested, legs: legs });
        route = Route({ hops: hops, totalOut: attested, singleOut: attested, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
                        estGas: 0, hasSurplus: false, isV4Bundle: false });
    }

    function test_HonestRoute_PoolA_Settles() public {
        uint256 amt = 1e18; uint256 qa = _quote(pidA, amt);
        assertGt(qa, 3 * amt, "sanity: pool A quotes about 4x");
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(pidA, address(0), amt, qa), amt, 1, user, block.timestamp + 1);
        assertEq(mgr.lastPid(), pidA, "executed pool A");
        assertGt(got, 3 * amt, "delivered about 4x");
    }

    /// The protection that existed before the fix: an honest attestation from pool A's
    /// quote makes the substituted, 4x-worse pool B fail the attestation gate.
    function test_SubstitutedHook_HonestAttestation_IsRefusedByTheGate() public {
        uint256 amt = 1e18; uint256 qa = _quote(pidA, amt);
        // consistent naming (pool B) so that ONLY the gate can refuse
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(_route(pidB, hookB, amt, qa), amt, 1, user, block.timestamp + 1);
    }

    /// A leg whose hooks derive pool B while leg.pool names pool A, with attestation and
    /// minimum consistent with B: refused before any token moves. Red on the tree before
    /// the check.
    function test_SubstitutedHook_RouteNamesPoolA_IsRefused() public {
        uint256 amt = 1e18; uint256 qb = _quote(pidB, amt);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(11)));
        router.swapExactIn(_route(pidA, hookB, amt, qb), amt, 1, user, block.timestamp + 1);
    }

    /// A route consistent in every field is the caller's signed intent: pool B named,
    /// pool B attested, pool B executed. Bounded like every route (SOK-ROUTE-AUTHOR).
    function test_ConsistentRoute_PoolB_Settles_ByDesign() public {
        uint256 amt = 1e18; uint256 qb = _quote(pidB, amt);
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(pidB, hookB, amt, qb), amt, 1, user, block.timestamp + 1);
        assertEq(mgr.lastPid(), pidB, "executed pool B");
        assertGe(got, qb * 8 / 10, "within pool B's own promise");
    }

    /// Every other field of the key is pinned by the same check: a leg that names pool A
    /// but carries pool B's tick spacing (or fee) is refused the same way.
    function test_SwappedTickSpacing_RouteNamesPoolA_IsRefused() public {
        uint256 amt = 1e18;
        Route memory route = _route(pidA, address(0), amt, amt);
        route.hops[0].legs[0].tickSpacing = 10;   // key now derives a different pool
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(11)));
        router.swapExactIn(route, amt, 1, user, block.timestamp + 1);
    }

    /// Preview and execution agree. The Quoter's exact preview dry-runs every V4 leg on
    /// the singleton; a leg whose named pool is not the pool its key derives is refused
    /// there too, and the preview holds the plan's own point.
    function test_Quoter_MismatchedLeg_IsNotPricedOnTheSubstitutedPool() public {
        uint256 amt = 1e18; uint256 qa = _quote(pidA, amt);
        FixedPlanSolver solver = new FixedPlanSolver();
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        // sanity: the dry-run is live in this harness - a consistent pool B plan prices about 1:1
        solver.setPlan(_route(pidB, hookB, amt, qa));
        (, uint256 exactB) = quoter.previewPlanExact(c0, c1, amt);
        assertLt(exactB, amt, "consistent pool B plan is priced on pool B (1:1 less fee)");
        assertGt(exactB, amt * 9 / 10, "and not clamped to the attested 4x point");
        // the researcher's leg: names pool A, key derives pool B
        solver.setPlan(_route(pidA, hookB, amt, qa));
        (, uint256 exactMismatch) = quoter.previewPlanExact(c0, c1, amt);
        assertGt(exactMismatch, 3 * amt, "held at the plan's own point, not priced on pool B");
    }

    // ── V4 campaign (2026-09-23): guards that had no test able to see them ──────

    /// The manager check on the callback is the only barrier while the Router's context
    /// is live: a hook inside the swap calls unlockCallback with a forged, well-formed
    /// payload. The old test sent an empty payload and died in abi.decode, not here.
    function test_V4ImpostorCallingUnlockCallbackMidSwapIsNeverPaid() public {
        uint256 amt = 1e18; uint256 qa = _quote(pidA, amt);
        bytes memory forged = abi.encode(c0, c1, FEE, TS, address(0), true, amt, bytes(""));
        MidSwapCaller probe = new MidSwapCaller(address(router), forged);
        mgr.setProbe(address(probe));
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(pidA, address(0), amt, qa), amt, 1, user, block.timestamp + 1);
        assertTrue(probe.called(), "setup: the probe must run inside the swap");
        assertFalse(probe.ok(), "an impostor inside the swap was served by the callback");
        assertEq(keccak256(probe.ret()),
            keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(6))),
            "the impostor was refused, but not by the manager check");
        assertGt(got, 3 * amt, "and the real swap settled around it");
    }

    /// A pool (or its hook) that demands more input than the leg committed would be paid
    /// out of the input budgeted to the sibling legs; the leg's own budget caps it.
    function test_V4LegCannotPullSiblingBudget() public {
        uint256 amt = 1e18;
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({ pool: address(uint160(uint256(pidA))), hooks: address(0), kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS,
                        zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(uint256(uint160(c1))) });
        legs[1] = Leg({ pool: address(uint160(uint256(pidB))), hooks: hookB, kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS,
                        zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(uint256(uint160(c1))) });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: c0, tokenOut: c1, amountIn: 2 * amt, expectedOut: 0, legs: legs });
        Route memory r = Route({ hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
                                 confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false });
        // The first leg's swap asks for HALF its sibling's budget on top of its own. Half, not
        // all: the Router holds 2*amt less the protocol fee, so a demand of a whole extra `amt`
        // exceeds everything it holds and any balance check refuses it. A demand that fits in
        // the Router's balance but not in the leg's budget is refused by the leg's cap alone.
        mgr.setExtraOwe(amt / 2);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(r, 2 * amt, 1, user, block.timestamp + 1);
    }

    /// Preview and execution ask the same hook question: a listed hook whose code moved
    /// since its pin is paused, the Router refuses its leg with RouterE(9), and the
    /// preview must not call that route executable.
    function test_PreviewRoute_PausedHookLeg_CannotExecute() public {
        uint256 amt = 1e18; uint256 qb = _quote(pidB, amt);
        FixedPlanSolver solver = new FixedPlanSolver();
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        Route memory r = _route(pidB, hookB, amt, qb);
        assertTrue(quoter.previewRoute(r, 1).canExecute, "setup: the live hook's route is executable");
        vm.etch(hookB, hex"00");
        assertTrue(hub.hookPaused(hookB), "setup: a hook whose code moved is paused");
        assertFalse(quoter.previewRoute(r, 1).canExecute, "the preview endorsed a route the Router refuses");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(9)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }
}
