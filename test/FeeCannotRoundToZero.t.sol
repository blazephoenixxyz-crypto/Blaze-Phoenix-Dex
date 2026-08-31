// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  I-FEE / dust clause — the protocol fee must never round through zero.
//
//  The fee is anchored on the INPUT and derived with a FLOOR division at three
//  independent sites:
//
//      Router.sol:600   feeH = mulDiv(baseH,     PROTOCOL_FEE_BPS, BPS)
//      Router.sol:1270  fOut = mulDiv(amountOut, PROTOCOL_FEE_BPS, BPS)
//      Quoter.sol:250   afterFee -= mulDiv(afterFee, PROTOCOL_FEE_BPS, BPS)
//
//  With PROTOCOL_FEE_BPS = 28 and BPS = 10_000, mulDiv(b, 28, 10_000) == 0 for
//  every b <= 357. Router:601 then reads `if (feeH == 0) return amountIn;` and
//  the swap PROCEEDS — delivered, recorded, fee-free. That is a fail-open in
//  the fee dimension: the guard detects the zero and waves it through.
//
//  Why 357 wei is not "obviously dust": the threshold is in WEI, so its real
//  size is set by the token's decimals, not by value. At 18 decimals it is
//  nothing; at 2 decimals it is 3.58 tokens; at 0 decimals it is 358 tokens.
//  A fee floor that is blind to decimals is the same equivariance break that
//  produced the depth-bucket defect (vault note 138).
//
//  The chosen fix is NOT a revert (which would block those legitimate small
//  trades) but a round-UP: mulDivUp makes fee == 0 unreachable for any base
//  >= 1 wei, so nothing legitimate is refused and the zero simply cannot be
//  reached. BPC.mulDivUp already exists (Core:381) and is already used
//  (Core:1852).
//
//  RED BEFORE THE FIX: test_DustSwap_PaysAProtocolFee fails with treasuries
//  at exactly 0. The control test pins the normal path so the rounding change
//  cannot silently move a real fee.
//
//  forge test --match-contract FeeCannotRoundToZero -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract FeeCannotRoundToZeroTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool;

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    // Pinned constants (blind-constant law: this file must break if either
    // silently changes, because the whole threshold below is derived from them).
    uint256 constant PROTOCOL_FEE_BPS = BPC.PROTOCOL_FEE_BPS; // 28
    uint256 constant BPS              = BPC.BPS;              // 10_000

    // The largest input whose floor-divided fee is still zero:
    //   mulDiv(357, 28, 10_000) = floor(9_996 / 10_000) = 0
    //   mulDiv(358, 28, 10_000) = floor(10_024 / 10_000) = 1
    uint256 constant DUST_IN = 357;

    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0
    uint128 constant LIQ      = 1_000_000e18;
    uint24  constant POOL_FEE = 3000;
    uint256 constant NORMAL_IN = 10_000e18;

    bool zfo;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pool = new MockV3Pool(address(tokenA), address(tokenB), POOL_FEE);
        pool.setState(SQRT_P_1, LIQ);
        tokenB.mint(address(pool), 1_000_000e18);
        hub.seedPool(address(pool), BPC.KIND_V3, POOL_FEE, address(0), address(tokenA), address(tokenB));

        zfo = pool.token0() == address(tokenA);

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _route(uint256 amountIn) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool),
            hooks: address(0),
            kind: BPC.KIND_V3,
            fee: POOL_FEE,
            tickSpacing: 0,
            zeroForOne: zfo,
            stable: false,
            amountIn: amountIn,
            expectedOut: 0,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: amountIn,
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

    /// The treasuries are paid in tokenIn.
    function _treasuries() internal view returns (uint256) {
        return tokenA.balanceOf(T1) + tokenA.balanceOf(T2);
    }

    // ─── the arithmetic, stated plainly ──────────────────────────────────────

    function test_Arithmetic_FloorDivisionReachesZero() public pure {
        assertEq(BPC.mulDiv(DUST_IN, PROTOCOL_FEE_BPS, BPS), 0,
            "floor division yields a zero fee on a non-zero base");
        assertEq(BPC.mulDivUp(DUST_IN, PROTOCOL_FEE_BPS, BPS), 1,
            "rounding up makes the same base pay 1 wei");
        // The zero is not a single point: every base below the threshold hits it.
        assertEq(BPC.mulDiv(1, PROTOCOL_FEE_BPS, BPS), 0);
        assertEq(BPC.mulDiv(357, PROTOCOL_FEE_BPS, BPS), 0);
        assertEq(BPC.mulDiv(358, PROTOCOL_FEE_BPS, BPS), 1);
    }

    // ─── RED: the swap goes through and the protocol is paid nothing ─────────

    function test_DustSwap_PaysAProtocolFee() public {
        uint256 before = _treasuries();

        vm.prank(user);
        uint256 got = router.swapExactIn(
            _route(DUST_IN), DUST_IN, 1, user, block.timestamp + 1);

        assertGt(got, 0, "the swap delivered, so it is a real swap");

        // THE CLAIM: a swap that executes must pay the protocol. Before the
        // fix this is 0 — the fee rounded through zero and Router:601 returned
        // early instead of charging.
        assertGt(_treasuries() - before, 0,
            "an executed swap paid ZERO protocol fee: the fee rounded through zero");
    }

    /// The fix must not turn dust into a revert — that was the rejected design,
    /// because the wei threshold is blind to decimals and would refuse
    /// legitimate small trades on low-decimal tokens.
    function test_DustSwap_IsNotRefused() public {
        vm.prank(user);
        uint256 got = router.swapExactIn(
            _route(DUST_IN), DUST_IN, 1, user, block.timestamp + 1);
        assertGt(got, 0, "a dust swap must still execute, not revert");
    }

    // ─── the boundary the round-up itself creates ────────────────────────────

    /// An adversarial review predicted that rounding up creates a NEW refusal:
    /// solving ceil(a * 28 / 10_000) >= a has exactly one solution, a == 1, so
    /// a one-wei base now owes its whole self as fee and trips
    /// `if (feeH >= amountIn) revert RouterE(8)`.
    ///
    /// The arithmetic is correct, and measured here. What it does NOT cost is
    /// value: before the change a one-wei input took the `feeH == 0` early
    /// return, reached the pool, priced to zero output and reverted there
    /// instead. One wei reverted before and reverts now — the round-up changed
    /// the REASON, not the outcome. That is the whole price of the fix, and it
    /// is stated here rather than left to be discovered.
    function test_Boundary_OneWeiRevertsAtTheFeeGuardAndCostsNothing() public {
        // The arithmetic the review was right about.
        assertGe(BPC.mulDivUp(1, PROTOCOL_FEE_BPS, BPS), 1, "one wei owes a whole wei of fee");
        assertLt(BPC.mulDivUp(2, PROTOCOL_FEE_BPS, BPS), 2, "two wei does not");

        // After the change: refused by the fee guard.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8));
        router.swapExactIn(_route(1), 1, 1, user, block.timestamp + 1);

        // And it was already unusable regardless: two wei still prices to zero
        // output at this pool, so the refusal band is not something the fee
        // rounding invented.
        vm.prank(user);
        vm.expectRevert(bytes("MockV3Pool: zero out"));
        router.swapExactIn(_route(2), 2, 1, user, block.timestamp + 1);
    }

    // ─── control: the ordinary path may move by at most the rounding ─────────

    function test_Control_NormalSwapFeeUnchangedBeyondRounding() public {
        uint256 before = _treasuries();

        vm.prank(user);
        router.swapExactIn(
            _route(NORMAL_IN), NORMAL_IN, 1, user, block.timestamp + 1);

        uint256 paid = _treasuries() - before;
        uint256 floorFee = BPC.mulDiv(NORMAL_IN, PROTOCOL_FEE_BPS, BPS);

        // A round-up may add at most 1 wei, and on this input it adds nothing
        // (10_000e18 * 28 divides exactly). The normal path must not drift.
        assertGe(paid, floorFee, "the ordinary fee must never fall below nominal");
        assertLe(paid, floorFee + 1, "the ordinary fee must not exceed nominal by more than the rounding");
    }
}
