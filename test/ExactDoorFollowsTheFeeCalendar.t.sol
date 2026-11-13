// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The exact door follows the fee calendar (Base fork, USDC->DAI 10k at block 49800000,
//  2026-11-13). Red at db3c028: on a thin book whose route the calendar charges on the INPUT,
//  `previewPlanExact` promised the gross output less 28 bps while the Router, charging the
//  input and pricing what was left, delivered more - by the curve's bend over the fee (25.5 bps
//  on the Base DAI pool: test/fork/FidelityMatrix.t.sol, test_Matriz_DaiEPortaExata, which asks
//  1 bps; a few bps on the books here). Green once `Quoter._exact` applies the output deduction
//  only where `_fundedOut` read the calendar as output-charged, and takes `_fundedOut`'s figure,
//  the Router's own, everywhere else.
//
//  Offline twin of the fork row: the same door, the same Router, the same block, the venue a
//  concave mock; every row asserts EQUALITY (delivered == exactOut), not a tolerance.
//
//  Matrix. Decimals 6->18 (the fork's USDC->DAI), 18->6, 8->18, 24->6 (the price carries the
//  scale); a thin book (10 % of its input reserve) and a deep one; dust, the fee's rounding seam
//  (3571/3572 wei) and a fuzz up to a quarter of the reserve; kinds V3 and V2 (both concave; a
//  Gate leg is linear and pinned by test_GateF2_Quoter_PricesTheWrapperAsExecuted); one hop
//  charged on the input, one hop charged on the output (control), two hops charged at hop 1 and
//  at hop 0 (controls: the loop took the fee there before). Seams: door <-> Router in one block
//  (minOut = exactOut); door <-> `_fundedOut` through the min that pins them (mutant
//  [door-fee-3] of .github/scripts/mutants.py).
//
//  Mutants: [door-fee-1] the output deduction whatever the calendar says (the rule before
//  2026-11-13); [door-fee-2] the deduction on every route; [door-fee-3] `_fundedOut` answers no
//  bound for every calendar. Tripwire [door-fee-meta]: the fork row's 1 bps may not widen.
//
//  forge test --match-path test/ExactDoorFollowsTheFeeCalendar.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20Dec} from "./adapters/mocks/MockERC20Dec.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ExactDoorFollowsTheFeeCalendarTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address user = makeAddr("user");

    uint24  constant FEE  = 3_000;
    uint128 constant THIN = 1_000e18; // an order of a tenth of the reserve bends the curve by bps
    uint128 constant DEEP = 1e30;     // the step function's regime: the bend is under a wei

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2")
        );
        hub.setRoles(address(router), address(solver), address(this));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
    }

    // ─── fixtures ────────────────────────────────────────────────────────────

    /// A single-tick V3 book on `a` (`da` decimals) and `b` (`db` decimals) at one unit per unit,
    /// liquidity `liq`, holding a hundred times its virtual reserve of each side.
    function _book(address a, uint8 da, address b, uint8 db, uint128 liq) internal returns (MockV3Pool pool) {
        pool = new MockV3Pool(a, b, FEE);
        (uint8 d0, uint8 d1) = pool.token0() == a ? (da, db) : (db, da);
        uint256 sp = d1 >= d0
            ? _sqrt((10 ** uint256(d1 - d0)) << 192)
            : _sqrt((uint256(1) << 192) / (10 ** uint256(d0 - d1)));
        pool.setState(uint160(sp), liq);
        MockERC20Dec(a).mint(address(pool), 100 * _reserve(pool, a));
        MockERC20Dec(b).mint(address(pool), 100 * _reserve(pool, b));
        hub.seedPool(address(pool), BPC.KIND_V3, FEE, address(0), a, b);
    }

    /// Two fresh tokens and a book between them.
    function _v3(uint8 dIn, uint8 dOut, uint128 liq)
        internal returns (address tIn, address tOut, MockV3Pool pool)
    {
        tIn  = address(new MockERC20Dec(dIn));
        tOut = address(new MockERC20Dec(dOut));
        pool = _book(tIn, dIn, tOut, dOut, liq);
    }

    /// The book's virtual reserve of `t`: L / sqrtP for token0, L * sqrtP for token1.
    function _reserve(MockV3Pool pool, address t) internal view returns (uint256) {
        (uint160 sp, , , , , , ) = pool.slot0();
        uint256 liq = pool.liquidity();
        return pool.token0() == t ? BPC.mulDiv(liq, BPC.Q96, sp) : BPC.mulDiv(liq, sp, BPC.Q96);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) { z = y; y = (x / y + y) >> 1; }
    }

    function _leg(MockV3Pool pool, address tIn, uint256 amt) internal view returns (Leg memory l) {
        l.pool = address(pool);
        l.kind = BPC.KIND_V3;
        l.fee = FEE;
        l.zeroForOne = pool.token0() == tIn;
        l.amountIn = amt;
    }

    /// A hand-built two-hop route a -> b -> c, one V3 leg per hop (the door for such routes is
    /// `previewRouteExact`); the hops' figures are the plan's commitment, re-priced by the walk.
    function _twoHops(MockV3Pool p0, MockV3Pool p1, address a, address b, address c, uint256 amt)
        internal view returns (Route memory r)
    {
        r.hops = new Hop[](2);
        r.hops[0].tokenIn = a;
        r.hops[0].tokenOut = b;
        r.hops[0].amountIn = amt;
        r.hops[0].legs = new Leg[](1);
        r.hops[0].legs[0] = _leg(p0, a, amt);
        r.hops[1].tokenIn = b;
        r.hops[1].tokenOut = c;
        r.hops[1].amountIn = amt;
        r.hops[1].legs = new Leg[](1);
        r.hops[1].legs[0] = _leg(p1, b, amt);
    }

    /// Swaps `r` as the user, `minOut = exactOut`, in the block the door was asked in.
    function _execute(Route memory r, address tIn, address tOut, uint256 amt, uint256 minOut)
        internal returns (uint256 delivered)
    {
        MockERC20Dec(tIn).mint(user, amt);
        uint256 b0 = MockERC20Dec(tOut).balanceOf(user);
        vm.startPrank(user);
        MockERC20Dec(tIn).approve(address(router), amt);
        uint256 ret = router.swapExactIn(r, amt, minOut, user, block.timestamp + 1);
        vm.stopPrank();
        delivered = MockERC20Dec(tOut).balanceOf(user) - b0;
        assertEq(delivered, ret, "the Router's return is the recipient's delta");
    }

    /// The plan door: the Solver's plan re-priced by `_exact`, then executed at its own figure.
    function _settle(address tIn, address tOut, uint256 amt)
        internal returns (Route memory r, uint256 exactOut, uint256 delivered)
    {
        (r, exactOut) = quoter.previewPlanExact(tIn, tOut, amt);
        assertGt(exactOut, 0, "precondition: the door promised a fill");
        delivered = _execute(r, tIn, tOut, amt, exactOut);
    }

    /// The old rule's figure: the walk's gross output less the fee, rounded up.
    function _deduction(Route memory r) internal pure returns (uint256) {
        return r.totalOut - BPC.mulDivUp(r.totalOut, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    // ─── one hop charged on the input (no bridge): the door is the Router's figure ───

    /// The fork row's shape: 6 -> 18 decimals, a thin book, a tenth of its input reserve.
    function test_OneHop_InputCharged_ThinBook_6to18_DeliveredIsExactOut() public {
        (address tIn, address tOut, MockV3Pool pool) = _v3(6, 18, THIN);
        (Route memory r, uint256 exactOut, uint256 delivered) = _settle(tIn, tOut, _reserve(pool, tIn) / 10);
        assertEq(delivered, exactOut, "the exact door is what the Router delivers in the same block");
        assertGt(exactOut, _deduction(r), "the bend over the fee is visible on this book: the old deduction sat under the fill");
    }

    function test_OneHop_InputCharged_ThinBook_18to6_DeliveredIsExactOut() public {
        (address tIn, address tOut, MockV3Pool pool) = _v3(18, 6, THIN);
        (Route memory r, uint256 exactOut, uint256 delivered) = _settle(tIn, tOut, _reserve(pool, tIn) / 10);
        assertEq(delivered, exactOut, "18 -> 6: delivered == exactOut");
        assertGt(exactOut, _deduction(r), "18 -> 6: the bend is visible");
    }

    function test_OneHop_InputCharged_ThinBook_8to18_DeliveredIsExactOut() public {
        (address tIn, address tOut, MockV3Pool pool) = _v3(8, 18, THIN);
        (Route memory r, uint256 exactOut, uint256 delivered) = _settle(tIn, tOut, _reserve(pool, tIn) / 10);
        assertEq(delivered, exactOut, "8 -> 18: delivered == exactOut");
        assertGt(exactOut, _deduction(r), "8 -> 18: the bend is visible");
    }

    function test_OneHop_InputCharged_ThinBook_24to6_DeliveredIsExactOut() public {
        (address tIn, address tOut, MockV3Pool pool) = _v3(24, 6, THIN);
        (Route memory r, uint256 exactOut, uint256 delivered) = _settle(tIn, tOut, _reserve(pool, tIn) / 10);
        assertEq(delivered, exactOut, "24 -> 6: delivered == exactOut");
        assertGt(exactOut, _deduction(r), "24 -> 6: the bend is visible");
    }

    /// Dust on a deep book: the bend is under a wei, the fee's round-up is not; still equal.
    function test_OneHop_InputCharged_DeepBook_Dust_DeliveredIsExactOut() public {
        (address tIn, address tOut, ) = _v3(18, 18, DEEP);
        (, uint256 exactOut, uint256 delivered) = _settle(tIn, tOut, 1_000);
        assertEq(delivered, exactOut, "dust: delivered == exactOut");
    }

    /// The fee's rounding seam: 3571 wei pays 10 wei (9.9988 rounded up), 3572 pays 11.
    function test_OneHop_InputCharged_DeepBook_FeeRoundingSeam_DeliveredIsExactOut() public {
        (address tIn, address tOut, ) = _v3(18, 18, DEEP);
        (, uint256 exactLo, uint256 gotLo) = _settle(tIn, tOut, 3_571);
        assertEq(gotLo, exactLo, "3571 wei: delivered == exactOut");
        (, uint256 exactHi, uint256 gotHi) = _settle(tIn, tOut, 3_572);
        assertEq(gotHi, exactHi, "3572 wei: delivered == exactOut");
    }

    /// Any order up to a quarter of the thin book's input reserve.
    function testFuzz_OneHop_InputCharged_ThinBook_6to18_AnyOrder_DeliveredIsExactOut(uint256 seed) public {
        (address tIn, address tOut, MockV3Pool pool) = _v3(6, 18, THIN);
        uint256 amt = bound(seed, 1e6, _reserve(pool, tIn) / 4);
        (, uint256 exactOut, uint256 delivered) = _settle(tIn, tOut, amt);
        assertEq(delivered, exactOut, "fuzz: delivered == exactOut");
    }

    /// A reserve pair (x * y = k) is concave too, and priced by the model, not a dry-run.
    function test_OneHop_InputCharged_V2Pair_DeliveredIsExactOut() public {
        address a = address(new MockERC20Dec(18));
        address b = address(new MockERC20Dec(18));
        MockV2Pair pair = new MockV2Pair(a, b);
        MockERC20Dec(a).mint(address(pair), 1e24);
        MockERC20Dec(b).mint(address(pair), 1e24);
        pair.setReserves(uint112(1e24), uint112(1e24));
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), a, b);
        (Route memory r, uint256 exactOut, uint256 delivered) = _settle(a, b, 1e22);
        assertEq(delivered, exactOut, "V2: delivered == exactOut");
        assertGt(exactOut, _deduction(r), "V2: the bend is visible");
    }

    // ─── one hop charged on the output (a direct route into a bridge): the deduction ───

    function test_Control_OneHop_OutputCharged_IntoABridge_IsTheDeductionToTheWei() public {
        (address tIn, address tOut, MockV3Pool pool) = _v3(6, 18, THIN);
        hub.addBridge(tOut);
        (Route memory r, uint256 exactOut, uint256 delivered) = _settle(tIn, tOut, _reserve(pool, tIn) / 10);
        assertEq(exactOut, _deduction(r), "into a bridge: the scalar is the gross less the fee, rounded up");
        assertEq(delivered, exactOut, "into a bridge: delivered == exactOut");
    }

    // ─── two hops: the loop took the fee at the calendar's hop before; unchanged ───

    function test_Control_TwoHops_FeeAtHop1_ThroughABridge_DeliveredIsExactOut() public {
        address a = address(new MockERC20Dec(18));
        address b = address(new MockERC20Dec(18));
        address c = address(new MockERC20Dec(18));
        MockV3Pool p0 = _book(a, 18, b, 18, THIN);
        MockV3Pool p1 = _book(b, 18, c, 18, THIN);
        hub.addBridge(b);
        uint256 amt = _reserve(p0, a) / 10;
        (Route memory ex, uint256 exactOut) = quoter.previewRouteExact(_twoHops(p0, p1, a, b, c, amt), amt);
        assertGt(exactOut, 0, "precondition: the route door promised a fill");
        assertEq(_execute(ex, a, c, amt, exactOut), exactOut, "fee at hop 1: delivered == exactOut");
    }

    function test_Control_TwoHops_FeeAtHop0_BridgeInput_DeliveredIsExactOut() public {
        address a = address(new MockERC20Dec(18));
        address b = address(new MockERC20Dec(18));
        address c = address(new MockERC20Dec(18));
        MockV3Pool p0 = _book(a, 18, b, 18, THIN);
        MockV3Pool p1 = _book(b, 18, c, 18, THIN);
        hub.addBridge(a);
        uint256 amt = _reserve(p0, a) / 10;
        (Route memory ex, uint256 exactOut) = quoter.previewRouteExact(_twoHops(p0, p1, a, b, c, amt), amt);
        assertGt(exactOut, 0, "precondition: the route door promised a fill");
        assertEq(_execute(ex, a, c, amt, exactOut), exactOut, "fee at hop 0: delivered == exactOut");
    }
}
