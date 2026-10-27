// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WHAT A V3 LEG PROMISES IS WHAT ITS POOL PAYS (DEX-01 / 3331).
//
//  The V3 arm of the quote dispatcher (`Core.universalQuote`) and the Router's in-frame quote
//  (`Core.legQuoteImpact`) priced a concentrated pool as if its current liquidity went on for
//  ever (`outV3`, single range). A pool pays what its book holds: past the next initialized
//  tick the liquidity is whatever the book says. On a Base fork at block 52,900,000 a 4 ETH
//  WETH->DAI route the Quoter called executable was refused with RouterE(5) at every door
//  (reports/fork-1023/anomalias.md A, reports/plano-1026/pocs/3331.log). V4 met the same defect
//  first and answered it with the walk (V4PromiseIsWhatThePoolPays.t.sol); these pin the same
//  properties for V3: a preview that says executable settles; the published floor never asks
//  for more than the pool pays; the attestation is what the pool pays and the Router's own
//  in-frame number; and at the edge of a range, one wei either side, the same holds.
//
//  The pool is MockV3TickPool: a thick range around the price that ends one tick ahead of the
//  order, a thin book beyond it, and a swap written from the specification.
//
//  Red at integ-1027 @ 6a05394, where both sides priced the leg on the single range: the five
//  properties above fail (two with RouterE(5)), and so does the plan the capacity rebuild
//  returns. The fix gives the Solver's promise and the Router's in-frame quote one producer,
//  `Core.v3PaysOnBudget`: the pool's book walked on V3_PAY_READS reads, the single-range
//  figure kept (the band) when the walk cannot finish inside them. The edge and the hostile
//  books below pass at the red as well: each one is a guard whose red is its mutant.
//
//  N1 (reports/plano-1026/onda5/N1-fix.md): the fix promised the leader what its books pay and
//  left the ranking on the band, so a venue that paid more than the walked leg was passed over
//  for it. Red at 027a26c: beside a 1e18/1e18 V2 pair, the plan settles 140427106070046065,
//  and 384887155267496486 when the book is held, where the pair alone settles
//  498547894994324565. The leader now answers for what its books pay: when a promise falls
//  the build is rebuilt without the books that fell, and the better of the two leads.
// =============================================================================

import {Test, Vm, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract V3PromiseIsWhatThePoolPays is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockV3TickPool     pool;
    MockERC20 A;
    MockERC20 B;

    address user = address(0xBEEF);
    uint24  constant FEE   = 3000;
    int24   constant TS    = 60;
    uint128 constant THICK = 1e21;    // the range around the price
    uint128 constant THIN  = 1e17;    // the book beyond it
    uint256 constant AMT   = 1e18;    // an order that leaves the thick range

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        A = new MockERC20("AAA", "AAA");
        B = new MockERC20("BBB", "BBB");
        pool = new MockV3TickPool(address(A), address(B), FEE, TS);
        // The price one tick inside [0, 60) on the side the order moves toward, so the thick
        // range ends one tick ahead and only the thin book is beyond it.
        pool.initialize(_zfo() ? int24(1) : int24(59));
        pool.addPosition(0, 60, THICK);
        pool.addPosition(-887220, 887220, THIN);
        A.mint(address(pool), 1e21);
        B.mint(address(pool), 1e21);
        hub.seedPool(address(pool), BPC.KIND_V3, FEE, address(0), address(A), address(B));

        A.mint(user, 1e24);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function _zfo() internal view returns (bool) { return address(A) < address(B); }

    function _limit() internal view returns (uint160) {
        return _zfo() ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE;
    }

    /// What the pool pays for `amt`, from the specification's swap - not from the Core.
    function _pays(uint256 amt) internal view returns (uint256 out) {
        (, out, , , ) = pool.specSwap(amt, _zfo(), _limit());
    }

    /// The input that takes the price exactly to the thick range's edge, fee included.
    function _cross() internal view returns (uint256 used) {
        (used, , , , ) = pool.specSwap(type(uint128).max, _zfo(), pool.sqrtAt(_zfo() ? int24(0) : int24(60)));
    }

    /// A preview that says `canExecute` must not be refused by the Router.
    function test_V3_Red_CanExecuteMustNotBeRefused() public {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), AMT);
        assertTrue(pv.canExecute, "preview must say the route is executable");
        console2.log("netOut          :", pv.netOut);
        console2.log("effectiveMinOut :", pv.effectiveMinOut);
        console2.log("the pool pays   :", _pays(AMT));
        vm.prank(user);
        uint256 got = router.swapExactIn(pv.route, AMT, pv.effectiveMinOut, user, block.timestamp + 1);
        assertGe(got, pv.effectiveMinOut, "delivered below the floor the preview encoded");
    }

    function test_V3_ThePublishedFloorNeverExceedsWhatTheVenueCanPay() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        assertEq(plan.best.hops.length, 1, "premise: one hop");
        Leg memory lg = plan.best.hops[0].legs[0];
        assertEq(lg.pool, address(pool), "premise: the leg is the V3 pool");
        uint256 pays = _pays(lg.amountIn);
        console2.log("leg amountIn    :", lg.amountIn);
        console2.log("leg attestation :", lg.expectedOut);
        console2.log("the pool pays   :", pays);
        console2.log("published floor :", plan.best.singleOutFloor);
        assertLe(plan.best.singleOutFloor, pays, "the published floor asks for more than the pool pays");

        vm.prank(user);
        uint256 got = router.swapExactIn(plan.best, AMT, 1, user, block.timestamp + 1);
        assertGe(got, plan.best.singleOutFloor, "delivered below the floor the plan published");
    }

    /// The leg attests what its pool pays. The ranking is not pinned here: a build ranks on the
    /// single-range figure, and the leader answers for what its books pay (N1, below).
    function test_V3_TheLegAttestsWhatThePoolPays() public view {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        Leg memory lg = plan.best.hops[0].legs[0];
        assertApproxEqAbs(lg.expectedOut, _pays(lg.amountIn), 4, "the leg attests other than what the pool pays");
    }

    /// One producer: the attestation and the Router's in-frame quote, read back from its own
    /// ExecutionProof rather than recomputed here. The output is made a bridge so the Router
    /// takes its fee off the output and funds the leg with the whole input: the frame quotes
    /// the input the plan attested (with the fee off the input it quotes a smaller one, and
    /// past the edge of the range the two figures differ by the book, not by the producer).
    function test_V3_Parity_TheLegAttestsWhatTheRouterQuotesInFrame() public {
        hub.addBridge(address(B));
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
        assertEq(attested, quoted, "the plan's attestation and the Router's in-frame quote are two numbers");
    }

    /// The door that solves in the transaction (`swapBestExactIn` -> `_solve`) settles on the
    /// same two producers: the promise of the plan built at the cap, walked at the end of
    /// `findBestRoutePlan`, and the Router's in-frame quote. The plan it solves is the one the
    /// Solver answers here (R1: the state's, never the gas's), and the route pays at least the
    /// floor that plan published.
    function test_V3_TheDoorThatSolvesSettlesAtItsPlansFloor() public {
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(A), address(B), AMT);
        assertTrue(pv.canExecute, "premise: the preview says the route is executable");
        vm.prank(user);
        uint256 got = router.swapBestExactIn(address(A), address(B), AMT, pv.netOut, user, block.timestamp + 1);
        assertGe(got, plan.best.singleOutFloor, "the door that solves delivered below the floor its plan published");
    }

    /// At the edge of the range: the input that takes the price exactly to the next initialized
    /// tick, one wei less and one wei more. The leg promises no more than the pool pays, and
    /// the route settles at the floor it published.
    function test_AtTheEdgeOfARangeThePromiseIsWhatThePoolPays() public {
        uint256 x = _cross();
        assertGt(x, 1, "premise: the range has an edge to reach");
        for (uint256 d; d < 3; ++d) {
            uint256 amt = x - 1 + d;
            RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), amt);
            Leg memory lg = plan.best.hops[0].legs[0];
            assertLe(lg.expectedOut, _pays(lg.amountIn), "a leg that promises more than its pool pays");
            // One wei past the edge the walk crosses and reads a second stretch: what it
            // promises is still the whole of what the pool pays, not the last stretch's share.
            assertApproxEqAbs(lg.expectedOut, _pays(lg.amountIn), 4, "at the edge the leg attests other than what the pool pays");
            uint256 snap = vm.snapshotState();
            vm.prank(user);
            uint256 got = router.swapExactIn(plan.best, amt, plan.best.singleOutFloor, user, block.timestamp + 1);
            assertGe(got, plan.best.singleOutFloor, "delivered below the floor the plan published");
            vm.revertToState(snap);
        }
    }

    /// Any order from inside the range to far past its edge: what the plan promises, the pool
    /// pays, and the Router settles it at the floor the plan published.
    function testFuzz_APlanOverTheEdgeSettlesAtItsFloor(uint256 seed) public {
        uint256 x = _cross();
        uint256 amt = bound(seed, x / 2, x * 40);
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), amt);
        assertEq(plan.best.hops.length, 1, "premise: the order is routed through the pool");
        Leg memory lg = plan.best.hops[0].legs[0];
        assertLe(lg.expectedOut, _pays(lg.amountIn), "a leg that promises more than its pool pays");
        vm.prank(user);
        uint256 got = router.swapExactIn(plan.best, amt, plan.best.singleOutFloor, user, block.timestamp + 1);
        assertGe(got, plan.best.singleOutFloor, "delivered below the floor the plan published");
    }

    // --- a promise only falls -------------------------------------------------------------

    uint128 constant THICKER = 1e22;  // the book past the edge, deeper than the range at the price

    /// A book that THICKENS past the edge of the range around the price pays more than the
    /// single-range figure the plan was ranked on. The walk finishes inside the reads and finds
    /// that more; the promise stays the band, because a promise only falls
    /// (`Solver._paysWhatItWalks`). The band is read off the same book with its spacing hidden,
    /// where the walk cannot start and answers the single-range figure.
    function test_ABookThatThickensPastTheEdgeIsPromisedNoMoreThanTheBand() public {
        MockERC20 x = new MockERC20("XXX", "XXX");
        MockERC20 y = new MockERC20("YYY", "YYY");
        bool z = address(x) < address(y);
        MockV3TickPool t = new MockV3TickPool(address(x), address(y), FEE, TS);
        t.initialize(z ? int24(1) : int24(59));
        t.addPosition(0, 60, THICK);
        if (z) t.addPosition(-600, 0, THICKER);
        else t.addPosition(60, 660, THICKER);
        x.mint(address(t), 1e21);
        y.mint(address(t), 1e21);
        hub.seedPool(address(t), BPC.KIND_V3, FEE, address(0), address(x), address(y));

        Leg memory lg = solver.findBestRoutePlan(address(x), address(y), AMT).best.hops[0].legs[0];
        assertEq(lg.pool, address(t), "premise: the book is the leg");
        (, uint256 pays, , , ) = t.specSwap(lg.amountIn, z, z ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE);
        t.lieAboutTheSpacing(0);
        Leg memory band = solver.findBestRoutePlan(address(x), address(y), AMT).best.hops[0].legs[0];
        assertEq(band.amountIn, lg.amountIn, "premise: the same order on the same leg");
        assertGt(pays, band.expectedOut + band.expectedOut / 10_000, "premise: past the edge the book pays more than the band");
        assertEq(lg.expectedOut, band.expectedOut, "the promise rose above the figure the plan was ranked on");
    }

    // --- the rebuild's own return, and books that lie about their tick ------------------------

    uint128 constant NEXT = 1e20;     // the book past the edge, deep enough to finish the order
    uint256 constant HELD = 1.5e18;   // what the held book holds of its output

    /// The plan the rebuild returns. `_walkOnItsOwnBudget` splices the rebuild's answer in as the
    /// solve's own return, in assembly, so nothing after it in `findBestRoutePlan` reaches that
    /// plan. Hop 2 is deep but holds little of its output: its leg is held at the cap and the
    /// plan comes back from the rebuild. Hop 1 crosses the edge of its range into a book that
    /// finishes the order inside the reads. That leg promises no more than its pool pays, hop 2
    /// is sized on that promise, and the route settles at its floor.
    function test_TheRebuildsOwnReturnPromisesWhatTheBookPays() public {
        MockERC20 c = new MockERC20("CCC", "CCC");
        MockERC20 mid = new MockERC20("MMM", "MMM");
        MockERC20 d = new MockERC20("DDD", "DDD");
        bool zq = address(c) < address(mid);
        MockV3TickPool q = new MockV3TickPool(address(c), address(mid), FEE, TS);
        q.initialize(zq ? int24(1) : int24(59));
        q.addPosition(0, 60, THICK);
        if (zq) q.addPosition(-600, 0, NEXT);
        else q.addPosition(60, 660, NEXT);
        c.mint(address(q), 1e21);
        mid.mint(address(q), 1e21);
        hub.seedPool(address(q), BPC.KIND_V3, FEE, address(0), address(c), address(mid));
        MockV3TickPool p = new MockV3TickPool(address(mid), address(d), FEE, TS);
        p.initialize(0);
        p.addPosition(-887220, 887220, THICK);
        mid.mint(address(p), 1e21);
        d.mint(address(p), HELD);
        hub.seedPool(address(p), BPC.KIND_V3, FEE, address(0), address(mid), address(d));
        hub.addBridge(address(mid));

        RoutePlan memory plan = solver.findBestRoutePlan(address(c), address(d), AMT);
        assertEq(plan.best.hops.length, 2, "premise: the route bridges");
        Leg memory lq = plan.best.hops[0].legs[0];
        Leg memory lp = plan.best.hops[1].legs[0];
        assertEq(lq.pool, address(q), "premise: hop 1 is the book with an edge");
        assertEq(lp.pool, address(p), "premise: hop 2 is the held book");
        // 3_000 = the Solver's MAX_CONC_DRAIN_BPS: the plan built at the cap promises no more.
        assertGt(lp.expectedOut, BPC.mulDiv(HELD, 3_000, BPC.BPS), "premise: the plan is the rebuild's");
        (, uint256 pays, , , ) = q.specSwap(
            lq.amountIn, zq, zq ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE
        );
        assertLe(lq.expectedOut, pays, "the rebuild's plan promises more than its pool pays");
        assertEq(plan.best.hops[1].amountIn, plan.best.hops[0].expectedOut, "hop 2 commits other than hop 1 promises");
        assertEq(lp.amountIn, plan.best.hops[0].expectedOut, "hop 2's leg spends other than hop 1 promises");

        c.mint(user, AMT);
        vm.prank(user);
        c.approve(address(router), type(uint256).max);
        vm.prank(user);
        uint256 got = router.swapExactIn(plan.best, AMT, plan.best.singleOutFloor, user, block.timestamp + 1);
        assertGe(got, plan.best.singleOutFloor, "delivered below the floor the plan published");
    }

    /// N1 (reports/plano-1026/onda5/X-dex01b.md X4): a venue that pays more than the walked leg
    /// is not passed over for it. The thick range ends one tick ahead of the order, so the band
    /// (the single range) promises more for AMT than a 1e18/1e18 V2 pair pays, and the book,
    /// walked, pays far less. The route settles no less than the better venue alone pays, at
    /// the door that takes the plan and at the door that solves in the transaction. Oracles:
    /// the specification's swap for the pool, x*y=k at 0.3 % for the pair. The Router funds any
    /// route with the order less its fee (`_pairAlone`); the premises compare the venues on the
    /// whole order, as the Solver ranks them.
    function test_AVenueThatPaysMoreThanTheWalkedLegIsNotPassedOver() public {
        MockV2Pair pair = new MockV2Pair(address(A), address(B));
        A.mint(address(pair), 1e18);
        B.mint(address(pair), 1e18);
        pair.setReserves(1e18, 1e18);
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(A), address(B));
        uint256 pairPays = _pairPays(AMT);
        (uint160 sp, , , , , , ) = pool.slot0();
        assertGt(BPC.outV3(AMT, sp, pool.liquidity(), FEE, _zfo(), _limit()), pairPays, "premise: the band ranks the pool above the pair");
        uint256 poolPays = _pays(AMT);
        assertLt(poolPays, pairPays, "premise: the pool, walked, pays less than the pair");
        pairPays = _pairAlone();

        uint256 snap = vm.snapshotState();
        RoutePlan memory plan = solver.findBestRoutePlan(address(A), address(B), AMT);
        vm.prank(user);
        uint256 got = router.swapExactIn(plan.best, AMT, 1, user, block.timestamp + 1);
        console2.log("the pair pays alone :", pairPays);
        console2.log("the pool pays alone :", poolPays);
        console2.log("the plan settles    :", got);
        assertGe(got, pairPays, "the plan settles below what the pair alone pays");

        vm.revertToState(snap);
        vm.prank(user);
        got = router.swapBestExactIn(address(A), address(B), AMT, 1, user, block.timestamp + 1);
        console2.log("the door that solves:", got);
        assertGe(got, pairPays, "the door that solves settles below what the pair alone pays");
    }

    /// What the 1e18/1e18 pair pays for `amt`: x*y=k at 0.3 %.
    function _pairPays(uint256 amt) internal pure returns (uint256) {
        return amt * 997 * 1e18 / (1e18 * 1000 + amt * 997);
    }

    /// What the pair alone settles for AMT through the Router: every route is funded with the
    /// order less the protocol's fee, taken off the input and rounded up (`Router._chargeHopFee`).
    function _pairAlone() internal pure returns (uint256) {
        return _pairPays(AMT - BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
    }

    uint256 constant HOLDS = 2e18;    // the held book's output: the band of AMT is above 30 % of it

    /// N1, held: the same book holding HOLDS of its output, so the band of AMT is above the cap
    /// (30 % of what the pool holds) and every build ranks the leg at the cap, while the book,
    /// walked, pays less than the pair. The rebuild of a held leader once kept the cap as a
    /// floor under the walk; the route settles no less than the better venue alone pays.
    function test_AHeldLegIsRankedOnWhatItPaysNotOnItsCap() public {
        MockERC20 c = new MockERC20("CCC", "CCC");
        MockERC20 d = new MockERC20("DDD", "DDD");
        bool z = address(c) < address(d);
        uint160 lim = z ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE;
        MockV3TickPool q = new MockV3TickPool(address(c), address(d), FEE, TS);
        q.initialize(z ? int24(1) : int24(59));
        q.addPosition(0, 60, THICK);
        q.addPosition(-887220, 887220, THIN);
        c.mint(address(q), 1e21);
        d.mint(address(q), HOLDS);
        hub.seedPool(address(q), BPC.KIND_V3, FEE, address(0), address(c), address(d));
        MockV2Pair pair = new MockV2Pair(address(c), address(d));
        c.mint(address(pair), 1e18);
        d.mint(address(pair), 1e18);
        pair.setReserves(1e18, 1e18);
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(c), address(d));
        uint256 pairPays = _pairPays(AMT);
        // 3_000 = the Solver's MAX_CONC_DRAIN_BPS.
        uint256 cap = BPC.mulDiv(HOLDS, 3_000, BPC.BPS);
        (uint160 sp, , , , , , ) = q.slot0();
        uint256 band = BPC.outV3(AMT, sp, q.liquidity(), FEE, z, lim);
        (, uint256 qPays, , , ) = q.specSwap(AMT, z, lim);
        assertGt(band, cap, "premise: the band is above the cap, the leg is held");
        assertLe(band, HOLDS, "premise: the pool holds what the band asks");
        assertGt(cap, pairPays, "premise: at the cap the leg ranks above the pair");
        assertLt(qPays, pairPays, "premise: the book, walked, pays less than the pair");
        pairPays = _pairAlone();

        c.mint(user, 2 * AMT);
        vm.prank(user);
        c.approve(address(router), type(uint256).max);
        uint256 snap = vm.snapshotState();
        RoutePlan memory plan = solver.findBestRoutePlan(address(c), address(d), AMT);
        vm.prank(user);
        uint256 got = router.swapExactIn(plan.best, AMT, 1, user, block.timestamp + 1);
        console2.log("the pair pays alone :", pairPays);
        console2.log("the pool pays alone :", qPays);
        console2.log("the plan settles    :", got);
        assertGe(got, pairPays, "the plan settles below what the pair alone pays");

        vm.revertToState(snap);
        vm.prank(user);
        got = router.swapBestExactIn(address(c), address(d), AMT, 1, user, block.timestamp + 1);
        console2.log("the door that solves:", got);
        assertGe(got, pairPays, "the door that solves settles below what the pair alone pays");
    }

    // The walk that promises the plan built at the cap runs before the rebuild's self-call, in
    // the solve itself: a revert inside it would be the whole solve's. Each book below is one a
    // step of the walk could not take without reverting; the walk answers the band instead.

    uint128 constant DENSE = 1e19;    // a range on every spacing: the order crosses dozens
    uint128 constant FLAT  = 6.4e18;  // one range: AMT moves the price ~2,900 ticks

    /// slot0 reports int24's last tick on spacing 1, the price rising: the next-tick search
    /// would overflow on it.
    function test_ABookWhoseTickIsPastTheBoundsLeavesTheSolveStanding() public {
        MockV3TickPool lie = _liar(1);
        lie.addPosition(-887272, 887272, THICK);
        _seed(lie);
        lie.lieAboutTheTick(type(int24).max);
        _standsOn(lie, false);
    }

    /// slot0 reports a tick above its own price, the price falling: the next initialized tick
    /// is above the price, and a step toward it would run the wrong way.
    function test_ABookWhoseTickDisagreesWithItsPriceLeavesTheSolveStanding() public {
        MockV3TickPool lie = _liar(TS);
        lie.addPosition(-600, 600, THICK);
        lie.addPosition(600, 1200, THICK);
        _seed(lie);
        lie.lieAboutTheTick(1000);
        _standsOn(lie, true);
    }

    /// tickSpacing() answers zero: the next-tick search would divide by it.
    function test_ABookWithNoSpacingLeavesTheSolveStanding() public {
        MockV3TickPool lie = _liar(TS);
        lie.addPosition(-600, 600, THICK);
        _seed(lie);
        lie.lieAboutTheSpacing(0);
        _standsOn(lie, true);
    }

    /// A range on every spacing: every stretch ends on an initialized tick, and the reads run
    /// out on a crossing, with no read left to spend on it.
    function test_ABookTooDenseForTheReadsLeavesTheSolveStanding() public {
        MockV3TickPool lie = _liar(TS);
        for (int24 k = -40; k < 40; ++k) lie.addPosition(k * TS, (k + 1) * TS, DENSE);
        _seed(lie);
        _standsOn(lie, true);
    }

    /// The thick range's edge, the tick the order crosses, takes away twice what the book
    /// holds: subtracted as it stands, the liquidity would underflow. The walk saturates at
    /// zero, as `_v4Walk` does, and on a book with nothing left in it the leg keeps the band.
    /// The book the solve ranks is the one around the price, so only the walk meets the edge.
    function test_ABookWhoseCrossingTakesMoreThanItHoldsLeavesTheSolveStanding() public {
        int128 more = int128(2 * (THICK + THIN));
        if (_zfo()) pool.lieAboutTheNet(0, more);
        else pool.lieAboutTheNet(60, -more);
        _standsOn(pool, _zfo());
    }

    /// One range over the whole price line, on spacing 1: the walk meets no initialized tick,
    /// so each read after the first five is a bitmap word of 256 ticks, and the order needs
    /// more words than the reads hold. A walk that does not finish keeps the band: the leg
    /// promises the single-range figure (on a book this flat, what the pool pays), not the
    /// share of it that the stretches it read would pay.
    function test_AWalkTheReadsCannotFinishKeepsTheBand() public {
        MockV3TickPool lie = _liar(1);
        lie.addPosition(-887272, 887272, FLAT);
        _seed(lie);
        Leg memory lg = _standsOn(lie, true);
        (uint256 used, uint256 pays, , int24 tickEnd, ) = lie.specSwap(lg.amountIn, true, BPC.MIN_SQRT_PRICE_PLUS_ONE);
        assertEq(used, lg.amountIn, "premise: the pool takes the whole order");
        // Seven bitmap words: the first stretch ends where it starts, six more cover 1,536 ticks.
        assertLt(tickEnd, -1536, "premise: the order needs more stretches than the reads hold");
        assertApproxEqAbs(lg.expectedOut, pays, 4, "the leg promises other than the band");
    }

    /// A pool on two fresh tokens, priced at tick 0 and holding plenty of both.
    function _liar(int24 ts) internal returns (MockV3TickPool lie) {
        MockERC20 x = new MockERC20("XXX", "XXX");
        MockERC20 y = new MockERC20("YYY", "YYY");
        lie = new MockV3TickPool(address(x), address(y), FEE, ts);
        lie.initialize(0);
        x.mint(address(lie), 1e21);
        y.mint(address(lie), 1e21);
    }

    function _seed(MockV3TickPool lie) internal {
        hub.seedPool(address(lie), BPC.KIND_V3, FEE, address(0), lie.token0(), lie.token1());
    }

    /// The solve in the direction `zfo` stands, routes through the book, and its leg promises.
    function _standsOn(MockV3TickPool lie, bool zfo) internal view returns (Leg memory lg) {
        (address t0, address t1) = (lie.token0(), lie.token1());
        RoutePlan memory plan = zfo
            ? solver.findBestRoutePlan(t0, t1, AMT)
            : solver.findBestRoutePlan(t1, t0, AMT);
        lg = plan.best.hops[0].legs[0];
        assertEq(lg.pool, address(lie), "premise: the book is the leg");
        assertEq(lg.zeroForOne, zfo, "premise: the direction the book needs");
        assertGt(lg.expectedOut, 0, "the leg lost its promise");
    }
}
