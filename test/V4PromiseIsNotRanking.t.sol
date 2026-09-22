// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE PROMISE LAYER'S NUMBER IS NOT THE RANKING LAYER'S.
//
//  `universalQuote` answers "which pool delivers more?" and is deliberately left
//  unclamped: Core:1699 records the measured reason - clamping only the
//  concentrated families lets a shallow V2 out-rank a deep V4 on any trade that
//  leaves the current range, because V2 has no tick structure to clamp against.
//
//  `expectedOut` answers a different question. It travels to the Router and
//  becomes the floor enforced at Router:1619, so for a single-tick venue the
//  Solver attests the promise layer's figure - the same call the Router makes in
//  frame - and keeps the ranking figure for ranking.
//
//  These three hold the separation from both sides: a route the protocol's own
//  preview calls executable settles; the published floor never asks for more than
//  the venue can pay; and the clamped attestation is what a correct plan carries.
//
//  The apparatus, the range-exit manager and two of the three tests are the
//  reporter's. The third asserted the behaviour before this change and is kept with its
//  assertion turned around, because a test that asserts a defect is red for ever
//  once the defect is gone - the property it was measuring is the one above.
//
//  Reported by acit aja, ninth bounty wave, with thirty measured cases on Base at
//  commit c45aa4e. mohaseenbasha reached the same root independently, through a
//  V4 clamp gap rather than through the published preview.
//
//  RED AT b2ecf64, which capped the Router's per-leg bound by its in-frame quote
//  instead of fixing the plan: the two figures side by side, the parity with the
//  Router's own ExecutionProof, and the multi-hop chain were all red there, and
//  that cap turned RouteIntegrityV4's substituted-hook gate test red as well - a
//  frame-side cap quotes the pool that executes, so a substituted pool set its
//  own floor. The promise is now written into the plan's legs by the Solver.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev V4 PoolManager mock whose pool has ONE tick range and NOTHING beyond it.
///      A swap that would leave the range is truncated at the range's edge —
///      the price reaches the edge and the remaining input is never consumed.
///      That is exactly what a real pool does when no initialized tick lies
///      beyond the range (the swap loop moves the price for free and ends at
///      the price limit), so the numbers below are the pool's own, not a model.
contract MockV4RangeManager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }

    address public pendingCur;
    uint256 public pendingOwe;
    bool    public syncedFlag;
    address public syncedCur;
    uint256 public syncBal;

    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) =
            msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        // Bubble the callback's own revert (what the canonical PoolManager does),
        // so the Router's error code reaches the test unmasked.
        if (!ok) { assembly { revert(add(ret, 32), mload(ret)) } }
        return ret;
    }

    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata)
        external returns (int256)
    {
        uint256 amt = uint256(-p.amountSpecified);
        bytes32 pid = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        bytes32 w0 = slots[base];
        uint160 sp   = uint160(uint256(w0));
        int24   tick = int24(uint24(uint256(w0) >> 160));
        uint24  lpF  = uint24(uint256(w0) >> 208);
        uint128 liq  = uint128(uint256(slots[bytes32(uint256(base) + 3)]));
        uint24  fee  = key.fee == 0x800000 ? lpF : key.fee;

        // The pool's own deliverable: truncated at the current range's edge.
        uint160 limit = BPC.sqrtBoundary(sp, tick, key.tickSpacing, p.zeroForOne);
        uint256 out   = BPC.outV3(amt, sp, liq, fee, p.zeroForOne, limit);

        // The input the pool actually consumes for that (possibly truncated) move.
        uint256 amtAfterFee = amt * (1_000_000 - fee) / 1_000_000;
        uint256 sqrtNew;
        uint256 consumedAfterFee;
        if (p.zeroForOne) {
            uint256 product = BPC.mulDiv(amtAfterFee, sp, BPC.Q96);
            sqrtNew = BPC.mulDiv(liq, sp, liq + product);
            if (limit != 0 && sqrtNew < limit) sqrtNew = limit;
            consumedAfterFee = BPC.mulDiv(BPC.mulDiv(liq, sp - sqrtNew, sqrtNew), BPC.Q96, sp);
        } else {
            sqrtNew = uint256(sp) + BPC.mulDiv(amtAfterFee, BPC.Q96, liq);
            if (limit != 0 && sqrtNew > limit) sqrtNew = limit;
            consumedAfterFee = BPC.mulDiv(liq, sqrtNew - sp, BPC.Q96);
        }
        uint256 owe = fee >= 1_000_000 ? 0 : consumedAfterFee * 1_000_000 / (1_000_000 - fee);
        if (owe > amt) owe = amt;

        pendingCur = p.zeroForOne ? key.currency0 : key.currency1;
        pendingOwe = owe;
        int128 oweD  = -int128(int256(owe));
        int128 recvD =  int128(int256(out));
        return p.zeroForOne
            ? int256((uint256(uint128(oweD)) << 128) | uint256(uint128(recvD)))
            : int256((uint256(uint128(recvD)) << 128) | uint256(uint128(oweD)));
    }

    function sync(address currency) external {
        syncedFlag = true;
        syncedCur = currency;
        syncBal = IERC20Min(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256) {
        require(msg.value == 0, "settle: no native here");
        require(syncedFlag && syncedCur == pendingCur, "settle: not synced");
        require(IERC20Min(pendingCur).balanceOf(address(this)) - syncBal >= pendingOwe, "settle: unpaid");
        syncedFlag = false;
        uint256 p = pendingOwe;
        pendingOwe = 0;
        return p;
    }

    function take(address currency, address to, uint256 amount) external {
        require(IERC20Min(currency).transfer(to, amount), "take: transfer failed");
    }
}

contract V4PromiseIsNotRanking is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockV4RangeManager mgr;
    MockERC20 A;
    MockERC20 B;

    address user = address(0xBEEF);
    uint24  constant FEE = 3000;      // 0.30 %
    int24   constant TS  = 60;        // 0.60 % spacing
    uint128 constant LIQ = 1e18;      // one thin range
    uint256 constant AMT = 1e21;      // an order that LEAVES the range

    bytes32 pid;
    uint160 P;
    int24   tick;

    function setUp() public {
        mgr = new MockV4RangeManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        A = new MockERC20("AAA", "AAA");
        B = new MockERC20("BBB", "BBB");
        (address t0, address t1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));

        // Price inside the range's top tick (tick 59 of a 60-spaced range), so a
        // down-swap has 59 ticks of range below it and NOTHING beyond.
        tick = 59;
        P = uint160(uint256(BPC.Q96) + uint256(BPC.Q96) * 59 / 20_000);
        pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(
            uint256(P) | (uint256(uint24(tick)) << 160) | (uint256(FEE) << 208)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));

        // The pool enters the registry through the operator door.
        hub.addV4(address(A), address(B), FEE, TS, address(0));

        // Funding: the user spends A; the manager pays B out of its inventory.
        A.mint(user, AMT);
        B.mint(address(mgr), 1e21);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function _zfo() internal view returns (bool) { return address(A) < address(B); }

    /// @dev The deliverable output: the pool's own number, truncated at the edge.
    function _clampedPromise(uint256 legAmt) internal view returns (uint256) {
        uint160 limit = BPC.sqrtBoundary(P, tick, TS, _zfo());
        return BPC.outV3(legAmt, P, LIQ, FEE, _zfo(), limit);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  THE DEFECT — preview says executable, Router refuses.
    // ────────────────────────────────────────────────────────────────────────
    function test_ThePublishedFloorNeverExceedsWhatTheVenueCanPay() public {
        // 1. The protocol's own preview.
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), AMT);
        assertTrue(pv.canExecute, "preview must say the route is executable");

        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        uint256 attested = plan.best.hops[0].legs[0].expectedOut;   // the Solver's promise
        uint256 routeFloor = plan.best.singleOutFloor;              // enforced as effMin

        uint256 legAmt = AMT - BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 deliverable = _clampedPromise(legAmt);              // what the pool can pay

        console2.log("=== the promise the protocol published ===");
        console2.log("preview.canExecute          :", pv.canExecute);
        console2.log("preview.netOut              :", pv.netOut);
        console2.log("preview.ironFloor           :", pv.ironFloor);
        console2.log("solver leg.expectedOut      :", attested);
        console2.log("solver route.singleOutFloor :", routeFloor);
        console2.log("=== what the pool can actually deliver ===");
        console2.log("clamped deliverable         :", deliverable);
        console2.log("attested / deliverable (x100):", (attested * 100) / deliverable);

        // THE PROPERTY, from the side that used to fail. The floor the protocol
        // publishes cannot ask for more than the venue can pay, or the preview
        // endorses a route the Router then refuses. Asserted with <= rather than
        // < because equality is the honest boundary: the promise layer's figure
        // IS the deliverable one.
        assertLe(routeFloor, deliverable,
            "the published floor asks for more than the venue can deliver");

        // 2. Execute EXACTLY what the preview endorsed, with a near-zero userMinOut
        //    so the user's own bound is excluded by construction. It must settle.
        vm.prank(user);
        router.swapExactIn(pv.route, AMT, 1, user, block.timestamp + 1);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  THE CONTROL — same pool, same order; only the attestation is the
    //  clamped (deliverable) figure instead of the unclamped one. It settles.
    // ────────────────────────────────────────────────────────────────────────
    function test_Control_ClampedAttestation_Settles() public {
        uint256 legAmt = AMT - BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 deliverable = _clampedPromise(legAmt);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0),
            kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS,
            zeroForOne: _zfo(), stable: false,
            amountIn: AMT, expectedOut: deliverable, auxId: bytes32(uint256(uint160(address(B))))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(A), tokenOut: address(B), amountIn: AMT, expectedOut: deliverable, legs: legs });
        Route memory route = Route({
            hops: hops, totalOut: deliverable, singleOut: deliverable, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        vm.prank(user);
        uint256 got = router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
        console2.log("control settled, delivered :", got);
        assertApproxEqAbs(got, deliverable, 2, "the clamped attestation settles at the deliverable output");
    }

    // ────────────────────────────────────────────────────────────────────────
    //  THE RED-FIRST TEST — in the shape docs/BOUNTY_METHOD.md §2 asks for:
    //  measures the property from the executing side, not from the plan are
    //  clamped. It asserts the property QuoteExecDivergence pins: a preview
    //  that says `canExecute` must not be refused by the Router.
    // ────────────────────────────────────────────────────────────────────────
    function test_Red_CanExecuteMustNotBeRefused() public {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), AMT);
        // Asserted, not returned on: an early return here passes on a preview that
        // stopped promising anything, which is the one regression this cannot miss.
        assertTrue(pv.canExecute, "preview must say the route is executable");

        vm.prank(user);
        // No expectRevert: the preview endorsed this route, so the Router settles it
        // and the control below shows the same call with the clamped attestation
        // reaching the same delivery.
        router.swapExactIn(pv.route, AMT, 1, user, block.timestamp + 1);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  THE TWO FIGURES, SIDE BY SIDE. The leg attests the promise - the number
    //  the Router holds it to - and the hop and the route keep the capacity
    //  figure ranking compared. Core:1720 names the leg's `expectedOut` as the
    //  promise layer; nothing that ranks moves.
    // ────────────────────────────────────────────────────────────────────────
    function test_TheLegAttestsThePromise_TheHopKeepsTheCapacity() public view {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        Leg memory lg = plan.best.hops[0].legs[0];
        uint256 deliverable = _clampedPromise(lg.amountIn);

        console2.log("leg.expectedOut (attested) :", lg.expectedOut);
        console2.log("clamped deliverable        :", deliverable);
        console2.log("route.totalOut (capacity)  :", plan.best.totalOut);

        assertLe(lg.expectedOut, deliverable, "the leg attests more than the venue can pay");
        assertGt(plan.best.totalOut, lg.expectedOut, "the capacity figure moved with the promise: ranking would too");
        assertEq(plan.best.hops[0].expectedOut, plan.best.totalOut, "the hop keeps the capacity figure");
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ONE EVALUATOR. The attestation the Solver writes and the quote the
    //  Router takes in the executing frame are the same Core call on the same
    //  pool at the same amount, so on one block they are one number. The
    //  Router's side is read back from its own ExecutionProof, not recomputed
    //  here, so the two producers are compared and neither is trusted.
    // ────────────────────────────────────────────────────────────────────────
    function test_Parity_TheLegAttestsWhatTheRouterQuotesInFrame() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        assertEq(plan.best.hops.length, 1, "one hop");
        assertEq(plan.best.hops[0].legs.length, 1, "one leg, so the hop's quote is the leg's");
        uint256 attested = plan.best.hops[0].legs[0].expectedOut;

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(plan.best, AMT, 1, user, block.timestamp + 1);

        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 quoted;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != sig) continue;
            found = true;
            (quoted, , , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        assertTrue(found, "ExecutionProof missing");
        console2.log("solver attestation   :", attested);
        console2.log("router in-frame quote:", quoted);
        assertEq(attested, quoted, "the plan's attestation and the Router's in-frame quote are two numbers");
    }
}

// =============================================================================
//  THE SAME RULE ACROSS HOPS.
//
//  A later hop is SIZED on the ranking figure of the hop before it, and can only
//  count on that hop's promise. When the first hop leaves its range, the second
//  receives a fraction of what it was planned on, so a floor taken from the last
//  hop alone asks for output the chain never had the input to produce.
//
//  A -> B leaves its one thin range (the pool from the single-hop case above);
//  B -> C is deep and never leaves its range, so the only gap is the one carried
//  in from the first hop.
// =============================================================================
contract V4PromiseAcrossHops is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV4RangeManager mgr;
    MockERC20 A;
    MockERC20 B;
    MockERC20 C;

    address user = address(0xBEEF);
    uint24  constant FEE = 3000;
    int24   constant TS  = 60;
    uint256 constant AMT = 1e21;

    function setUp() public {
        mgr = new MockV4RangeManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        A = new MockERC20("AAA", "AAA");
        B = new MockERC20("BBB", "BBB");
        C = new MockERC20("CCC", "CCC");

        // A/B: one thin range, the price in its top tick - the order leaves it.
        _pool(address(A), address(B), 59, 1e18);
        // B/C: mid-range and deep - the order never reaches an edge.
        _pool(address(B), address(C), 30, 1e27);

        hub.addV4(address(A), address(B), FEE, TS, address(0));
        hub.addV4(address(B), address(C), FEE, TS, address(0));
        hub.addBridge(address(B));

        A.mint(user, AMT);
        B.mint(address(mgr), 1e21);
        C.mint(address(mgr), 1e21);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function _pool(address x, address y, int24 tick, uint128 liq) internal {
        (address t0, address t1) = x < y ? (x, y) : (y, x);
        uint160 p = uint160(uint256(BPC.Q96) + uint256(BPC.Q96) * uint256(int256(tick)) / 20_000);
        bytes32 id = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(id, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(p) | (uint256(uint24(tick)) << 160) | (uint256(FEE) << 208)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    /// @dev What the thin A/B range can pay for `amt`: the pool's own number,
    ///      truncated at the edge - the same computation the manager settles.
    function _abDeliverable(uint256 amt) internal view returns (uint256) {
        bool zfo = address(A) < address(B);
        uint160 p = uint160(uint256(BPC.Q96) + uint256(BPC.Q96) * 59 / 20_000);
        return BPC.outV3(amt, p, 1e18, FEE, zfo, BPC.sqrtBoundary(p, 59, TS, zfo));
    }

    function test_TheMultiHopFloorFollowsTheChainOfPromises() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(C), AMT);
        assertEq(plan.best.hops.length, 2, "the route bridges through B");
        // The regime this is about, asserted rather than assumed: the first hop
        // was ranked on more than its range can pay, so the second hop was sized
        // on output that never arrives.
        assertGt(plan.best.hops[0].expectedOut, _abDeliverable(plan.best.hops[0].amountIn),
            "the first hop never left its range: the regime this test is about was not reached");

        console2.log("hop 0 ranking (what hop 1 was sized on):", plan.best.hops[0].expectedOut);
        console2.log("hop 0 leg attestation (its promise)    :", plan.best.hops[0].legs[0].expectedOut);
        console2.log("route.totalOut                         :", plan.best.totalOut);
        console2.log("route.singleOutFloor                   :", plan.best.singleOutFloor);

        // The plan exactly as published, with the user's own bound excluded by
        // construction: every floor that can refuse it is one the protocol wrote.
        vm.prank(user);
        uint256 got = router.swapExactIn(plan.best, AMT, 1, user, block.timestamp + 1);
        console2.log("delivered                              :", got);
        assertGe(got, plan.best.singleOutFloor, "delivered below the floor the plan published");
    }
}
