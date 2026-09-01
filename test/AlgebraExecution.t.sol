// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ALGEBRA EXECUTION — first swaps ever executed through the KIND_ALGEBRA arm.
//
//  KIND_ALGEBRA (Core:184) ships in production — the deploy script registers
//  Camelot V3 on Arbitrum as this kind — yet until this file no test had ever
//  EXECUTED a swap through it: the family was quoted (AlgebraFeeMeasured.t.sol)
//  and registered (BlazePhoenixHub.t.sol:135), never driven through a Router
//  door, because test/mocks/ had no executable Algebra pool. MockAlgebraPool
//  closes that: globalState() instead of slot0(), no fee() getter, a dynamic
//  fee that can move between quote and execution.
//
//  What is asserted:
//    1. A swap SETTLES and delivers exactly what the quote promised
//       (tolerance: 0 wei — mock and Router price through the same BPC.outV3
//       on state the mock never mutates, so any drift is a real defect).
//    2. The fee that prices execution is the one MEASURED on the pool
//       (globalState word 2, via v3StateAndDynFee -> quoteV3Fee with
//       cfgFee hard-coded 0 at Router:812), never the leg's calldata fee:
//       a forged leg.fee = 999_999 changes neither delivery nor treasuries
//       by a single wei.
//    3. THE FEE MOVING BETWEEN QUOTE AND EXECUTION — the verdict, measured,
//       not preferred: THE USER IS EXPOSED; ONLY userMinOut PROTECTS.
//         • Fee moved BEFORE the tx (quote in block N, fee moves, execute in
//           block N+1): the protocol floor is a fraction of the IN-FRAME
//           quote (protocolFloorOut = finalHopQuote * floorBps, Router:1270),
//           and the in-frame quote re-reads globalState() in the SAME frame
//           as execution — the floor re-prices at the moved fee and moves
//           DOWN with it, so the swap settles below the pre-move promise
//           without a whisper. The only thing anchored to the pre-move quote
//           is userMinOut (Router:1307/1347): set from the quote, it
//           reverts; set lax, the loss is silently accepted.
//         • Fee shifted INSIDE the swap (Algebra's adaptive fee is
//           recomputed at swap time, after the Router's in-frame quote at
//           Router:752-816 and before _execScaled executes): here the floor
//           IS anchored pre-shift, but it only catches a shift that eats
//           more than (10000 - floorBps) of the output — floorBps =
//           9600 - impactBps (Core:1911-1924), ~4-5% for this pool — and
//           uint16-max Algebra fees (65535 ppm = 6.55%) can cross that; any
//           realistic fee move (0.05% -> 1% costs ~0.95% of output) passes
//           SILENTLY under both the protocol floor and the 80% per-leg
//           floor (Core:305).
//    4. A control against a static-fee MockV3Pool through the same door on
//       identical state: it delivers the same number the Algebra pool does
//       at the same live fee, so any Algebra failure above is attributable
//       to the family difference, not the harness.
//
//  forge test --match-contract AlgebraExecution -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract AlgebraExecutionTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockAlgebraPool alg;
    MockV3Pool v3; // static-fee control, same state, same door

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    // sqrtPriceX96 for price 1.0 (2**96), deep single-tick liquidity — same
    // numbers as HardeningA1_FeeCoverage so quote == execution stays exact.
    uint160 constant SQRT_P_1  = 79228162514264337593543950336;
    uint128 constant LIQ       = 1_000_000e18;
    uint256 constant AMOUNT_IN = 10_000e18;

    uint16 constant LIVE_FEE   = 3000;    // 0.30% — the pool's real dynamic fee
    uint16 constant QUOTE_FEE  = 500;     // 0.05% — fee at quote time in the move tests
    uint16 constant MOVED_FEE  = 10_000;  // 1.00% — a realistic dynamic-fee move
    uint16 constant MAX_FEE    = 65535;   // uint16 max: the largest fee Algebra V1 can express
    uint24 constant FORGED_FEE = 999_999; // calldata-only forgery: outV3 keeps ~1e-6 of the input

    // The protocol fee is anchored on the INPUT (28 bps of amountIn, charged
    // in tokenIn before the route runs — see HardeningA1_FeeCoverage); the
    // pool prices what remains.
    uint256 constant FEE_IN = (AMOUNT_IN * BPC.PROTOCOL_FEE_BPS) / 10_000;
    uint256 constant IN_NET = AMOUNT_IN - FEE_IN;

    bool zfo; // tokenA -> tokenB direction on the sorted pair

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        alg = new MockAlgebraPool(address(tokenA), address(tokenB), LIVE_FEE);
        alg.setState(SQRT_P_1, LIQ);
        v3 = new MockV3Pool(address(tokenA), address(tokenB), LIVE_FEE);
        v3.setState(SQRT_P_1, LIQ);

        // Output-side inventory: execution must never be capacity-limited.
        tokenB.mint(address(alg), 1_000_000e18);
        tokenB.mint(address(v3), 1_000_000e18);

        // Registry entries as production would hold them: Algebra carries the
        // 0 fee sentinel (Hub rule R2, Hub:603-609 — every declared Algebra
        // fee must be 0, the "measure live" marker), V3 its static tier.
        hub.seedPool(address(alg), BPC.KIND_ALGEBRA, 0, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(v3), BPC.KIND_V3, LIVE_FEE, address(0), address(tokenA), address(tokenB));

        zfo = alg.token0() == address(tokenA);

        tokenA.mint(user, 10_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    /// @dev One-hop, one-leg tokenA -> tokenB route through `pool`.
    ///      expectedOut = 0: the per-leg floor rests on the in-frame quote.
    function _route(address pool, uint8 kind, uint24 legFee)
        internal view returns (Route memory r)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool,
            hooks: address(0),
            kind: kind,
            fee: legFee,
            tickSpacing: 0,
            zeroForOne: zfo,
            stable: false,
            amountIn: AMOUNT_IN,
            expectedOut: 0,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: AMOUNT_IN,
            expectedOut: 0,
            legs: legs
        });
        r = Route({
            hops: hops,
            totalOut: 0,
            singleOut: 0,
            singleOutFloor: 0,
            expectedImpactBps: 0,
            confidenceWad: 0,
            estGas: 0,
            hasSurplus: false,
            isV4Bundle: false
        });
    }

    /// @dev The promise: the quote the Solver/Quoter door produces for this
    ///      pool via universalQuote (Core:1493-1530), with the Hub's R2 fee
    ///      sentinel — so the fee is MEASURED from globalState(), exactly as
    ///      production quotes an Algebra pool.
    function _algebraPromise(uint256 amountInNet) internal view returns (uint256 out) {
        QuoteCtx memory c;
        c.pool = address(alg);
        c.kind = BPC.KIND_ALGEBRA;
        c.fee = 0; // Hub R2 sentinel — never a declared value
        c.tokenIn = address(tokenA);
        c.tokenOther = address(tokenB);
        c.zeroForOne = zfo;
        (out,) = BPC.universalQuote(c, amountInNet);
    }

    function _treasuries() internal view returns (uint256) {
        return tokenA.balanceOf(T1) + tokenA.balanceOf(T2);
    }

    // ─── 1. the family executes: settlement delivers the quote ──────────────

    function test_Algebra_SwapSettles_AndDeliversTheQuote() public {
        uint256 promised = _algebraPromise(IN_NET);
        assertGt(promised, 0, "setup: the Algebra pool must quote at all");
        // The promise is priced at the MEASURED live fee, not the 0 sentinel:
        assertEq(promised, BPC.outV3(IN_NET, SQRT_P_1, LIQ, LIVE_FEE, zfo, 0),
            "setup: the quote must already price the measured dynamic fee");

        uint256 userBefore = tokenB.balanceOf(user);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _route(address(alg), BPC.KIND_ALGEBRA, 0), AMOUNT_IN, 1, user, block.timestamp + 1);

        // Tolerance: 0 wei. Both sides run the same BPC.outV3 on state the
        // mock never mutates; any gap would be a real quote/execution seam.
        assertEq(delivered, promised, "an Algebra swap must deliver exactly what the quote promised");
        assertEq(tokenB.balanceOf(user) - userBefore, delivered, "reported == received");
        assertEq(_treasuries(), FEE_IN, "protocol fee: 28 bps of the input, in tokenIn");
    }

    // ─── 2. the measured fee wins over any calldata fee ──────────────────────

    function test_Algebra_MeasuredFeeWins_ForgedLegFeeChangesNothing() public {
        uint256 atMeasured = BPC.outV3(IN_NET, SQRT_P_1, LIQ, LIVE_FEE, zfo, 0);
        uint256 atForged   = BPC.outV3(IN_NET, SQRT_P_1, LIQ, FORGED_FEE, zfo, 0);
        // Precondition: if calldata ever priced this arm, the difference
        // would be enormous and unmissable — the two fees must disagree.
        assertLt(atForged, atMeasured / 2,
            "setup: the forged fee must produce an observably different number");

        // Honest leg: fee = 0, the production R2 sentinel.
        uint256 t0 = _treasuries();
        vm.prank(user);
        uint256 deliveredHonest = router.swapExactIn(
            _route(address(alg), BPC.KIND_ALGEBRA, 0), AMOUNT_IN, 1, user, block.timestamp + 1);
        uint256 honestFees = _treasuries() - t0;

        // Forged leg: fee = 999_999 in calldata. The quote channel ignores it
        // (Router:812 passes cfgFee = 0 into quoteV3Fee; dyn wins) and the
        // pool charges its own fee — so NOTHING may change.
        uint256 t1 = _treasuries();
        vm.prank(user);
        uint256 deliveredForged = router.swapExactIn(
            _route(address(alg), BPC.KIND_ALGEBRA, FORGED_FEE), AMOUNT_IN, 1, user, block.timestamp + 1);
        uint256 forgedFees = _treasuries() - t1;

        assertEq(deliveredHonest, atMeasured, "execution prices with the pool's measured fee");
        assertEq(deliveredForged, deliveredHonest,
            "a forged leg.fee must not move the delivery by a single wei");
        assertEq(forgedFees, honestFees,
            "a forged leg.fee must not move the protocol fee by a single wei");
    }

    // ─── 3a. fee moves BETWEEN the quote tx and the execution tx ─────────────
    //
    //  VERDICT: EXPOSED. The protocol floor re-prices on the in-frame quote,
    //  which reads globalState() in the same frame as execution — floor and
    //  fill both move to the new fee together, and the swap settles below the
    //  pre-move promise without reverting. Only userMinOut, set from the
    //  pre-move quote, holds the promise.

    function test_Algebra_FeeMovesBeforeExecution_FloorDoesNotCatchIt() public {
        alg.setDynamicFee(QUOTE_FEE);
        uint256 promised = _algebraPromise(IN_NET); // the user's quote, at 0.05%

        // The fee moves before the swap lands (next block, adaptive update…).
        alg.setDynamicFee(MOVED_FEE);

        // Lax minOut — what a user who trusts the quote-screen sends today.
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _route(address(alg), BPC.KIND_ALGEBRA, 0), AMOUNT_IN, 1, user, block.timestamp + 1);

        // The swap SETTLED — no floor caught the move — and it settled at the
        // moved fee, short of the promise. This is the actual behaviour: the
        // in-frame floor (protocolFloorOut, Router:1270) re-priced at 1% and
        // moved down with the fill.
        assertEq(delivered, BPC.outV3(IN_NET, SQRT_P_1, LIQ, MOVED_FEE, zfo, 0),
            "execution prices at the moved fee");
        assertLt(delivered, promised, "the user received less than the quote promised");
    }

    function test_Algebra_FeeMovesBeforeExecution_OnlyUserMinOutProtects() public {
        alg.setDynamicFee(QUOTE_FEE);
        uint256 promised = _algebraPromise(IN_NET);
        alg.setDynamicFee(MOVED_FEE);

        // The same swap with userMinOut set FROM the quote reverts: the
        // user's own bound is the only guard anchored to the pre-move number.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(
            _route(address(alg), BPC.KIND_ALGEBRA, 0), AMOUNT_IN, promised, user, block.timestamp + 1);
    }

    // ─── 3b. fee shifts INSIDE the swap (adaptive fee recomputed at swap) ────
    //
    //  Here the in-frame quote IS pre-shift, so the floors are anchored — but
    //  a realistic shift passes under them silently; only a shift near the
    //  family's uint16 ceiling trips the protocol floor.

    function test_Algebra_FeeShiftsInsideTheSwap_RealisticShiftPassesSilently() public {
        alg.setDynamicFee(QUOTE_FEE);
        uint256 inFrameQuote = _algebraPromise(IN_NET); // what the Router will price the leg at

        // 0.05% -> 1.00%, applied at swap() entry: after the Router's
        // in-frame quote, before the trade is priced. Costs ~0.95% of the
        // output — under the ~4.5% the protocol floor tolerates here and far
        // under the 80% per-leg floor.
        alg.setFeeShiftOnSwap(MOVED_FEE);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _route(address(alg), BPC.KIND_ALGEBRA, 0), AMOUNT_IN, 1, user, block.timestamp + 1);

        assertEq(delivered, BPC.outV3(IN_NET, SQRT_P_1, LIQ, MOVED_FEE, zfo, 0),
            "execution prices at the shifted fee");
        assertLt(delivered, inFrameQuote,
            "the fill lands below the in-frame quote and no floor fires");
    }

    function test_Algebra_FeeShiftsInsideTheSwap_GrossShiftTripsTheProtocolFloor() public {
        alg.setDynamicFee(QUOTE_FEE);

        // 0.05% -> 6.55% (uint16 max, the largest fee the family can
        // express). Delivery falls to ~93.5% of the in-frame quote, below
        // floorBps = 9600 - impact (~9496 here) — protocolFloorOut fires.
        alg.setFeeShiftOnSwap(MAX_FEE);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(
            _route(address(alg), BPC.KIND_ALGEBRA, 0), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    // ─── 4. control: static-fee V3 through the same code path ────────────────

    function test_Control_StaticV3_SameDoorSameState_DeliversTheSameNumber() public {
        // Same door, same state, same live fee — the only difference is the
        // family (slot0+fee() vs globalState). If this delivers and an
        // Algebra test fails, the failure is the Algebra difference.
        uint256 expected = BPC.outV3(IN_NET, SQRT_P_1, LIQ, LIVE_FEE, zfo, 0);

        vm.prank(user);
        uint256 deliveredV3 = router.swapExactIn(
            _route(address(v3), BPC.KIND_V3, LIVE_FEE), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertEq(deliveredV3, expected, "the static-fee control settles the same formula");

        vm.prank(user);
        uint256 deliveredAlg = router.swapExactIn(
            _route(address(alg), BPC.KIND_ALGEBRA, 0), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertEq(deliveredAlg, deliveredV3,
            "at the same live fee the two families deliver the same number");
    }
}
