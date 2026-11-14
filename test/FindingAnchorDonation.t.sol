// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

/// A raw-balance donation to a cheap pool must not move the anchor (T2). Since ROUTEQ the band's
/// lower edge reads the base's bound at the hop's size, so a pool priced under the base enters as
/// a leg once its price beats the base's own fill of the order: better execution, not capture.
/// What must hold is that no pool captures the anchor and the route never pays less than the
/// base alone. Three claims, each against an oracle written here by hand:
///   (i)   the anchor is the honest pool's price, with and without the donation. The anchor is
///         not read in public; its witness is derived from the band's edges. With two rows the
///         base is the one holding more of the vote, and the band's UPPER edge reads only the
///         probe-size bound. Attacker at half the price (below): were it the base, the honest
///         pool would sit 2x over it and leave the band, so `honest in legs` <=> honest base.
///         Attacker at twice the price (above): were it the base it would be its own band and
///         quote best, so `attacker not in legs` <=> honest base. An honest base reads only the
///         honest pool's state, which no donation touches: the same anchor to the wei as with
///         no attacker at all.
///   (ii)  totalOut >= the honest pool alone on what the route commits, the legs' input sum
///         (V2 formula, reserves read here). A leg that quotes 0 at its share is dropped and its
///         share is not reassigned (Solver._split); the Router sweeps it back to the payer. Every
///         row in the split quotes > 0 at the probe (m / 100, or m under 100 wei) and a V2 output
///         grows with its input, so a dropped share is under the probe: m - committed < probe.
///         Pre-existing (the same to the wei on 8c100b3): below, m = 3..8 wei commits m - 2 at
///         most and pays up to 2 wei under the honest pool alone on m; no gain for the attacker.
///   (iii) the user receives >= totalOut * (m - ceil(m * 28 / 1e4)) / m, the plan net of the
///         protocol fee on the input (each leg is concave); a fee on the output delivers
///         totalOut - ceil(totalOut * 28 / 1e4), never under it either.
/// Mutant: Core.hopMass18 reading the pair's raw tokenOut balance instead of its reserves (the
/// T2 finding, in the funnel: Solver._dropDust) turns
/// test_DonationPastTheDustShare_HonestRowKeepsItsSeat_plusMinusOneWei red. The vote reads
/// reserves through _quoteArms, so a donation under the funnel's 25 ppm share moves nothing.
contract FindingAnchorDonationTest is Test {
    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router;
    MockERC20 tokenA; MockERC20 tokenB; MockV2Pair honest; MockV2Pair attacker;
    address constant T1 = address(0xFEE1); address constant T2 = address(0xFEE2);
    address constant USER = address(0xBEEF);
    uint256 constant AMOUNT_IN = 1000e18;
    uint256 constant DEPTH = 1000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        tokenA = new MockERC20("A", "A"); tokenB = new MockERC20("B", "B");
        vm.prank(USER);
        tokenA.approve(address(router), type(uint256).max);
    }

    /// Honest pool 1:1 with `depth` a side; the attacker at half the price (depth A, depth/2 B)
    /// or twice it (depth/4 A, depth/2 B), less tokenOut than the honest pool either way. Each
    /// side held, each pool born in its own factory (rizki-3107), so both rows vote: the
    /// attacker's mass counts, the strongest adversary.
    function _market(uint256 depth, bool above) internal {
        honest = _pool(depth, depth);
        attacker = above ? _pool(depth / 4, depth / 2) : _pool(depth, depth / 2);
    }

    function _pool(uint256 rA, uint256 rB) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokenA), address(tokenB));
        (uint256 r0, uint256 r1) = p.token0() == address(tokenA) ? (rA, rB) : (rB, rA);
        p.setReserves(uint112(r0), uint112(r1));
        tokenA.mint(address(p), rA);
        tokenB.mint(address(p), rB);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        Origin.wire(hub, address(p), address(tokenA), address(tokenB), BPC.KIND_V2, 30);
    }

    function _has(RoutePlan memory plan, address pool) internal pure returns (bool) {
        if (plan.best.hops.length == 0) return false;
        Leg[] memory legs = plan.best.hops[0].legs;
        for (uint256 i; i < legs.length; ++i) if (legs[i].pool == pool) return true;
        return false;
    }

    /// (i): the witness that the base is the honest pool (see the header).
    function _baseIsHonest(RoutePlan memory plan, bool above) internal view returns (bool) {
        return above ? !_has(plan, address(attacker)) : _has(plan, address(honest));
    }

    /// The honest pool alone on the whole order: m * 997 * rOut / (rIn * 1000 + m * 997).
    function _honestAlone(uint256 m) internal view returns (uint256) {
        return _alone(honest, m);
    }

    /// One pool alone on x, Core.outV2 at 30 bps with the reserves read here (rank at a probe).
    function _alone(MockV2Pair p, uint256 x) internal view returns (uint256) {
        (uint112 r0, uint112 r1, ) = p.getReserves();
        (uint256 rIn, uint256 rOut) = p.token0() == address(tokenA) ? (r0, r1) : (r1, r0);
        return x * 997 * rOut / (rIn * 1000 + x * 997);
    }

    /// A pool's rank at the probe and its keep (1 - f)(1 - e) in WAD, by the producers' formulas
    /// on the reserves read here: e is Core.universalProbe's `err` (V2, 18 decimals): WAD for a
    /// dead row (rank 0), else (3 WAD + 2 probe) / rank + 1 + 3 WAD / n + ceil(min(probe, rank)
    /// WAD / depth), n the probe net of the fee and depth the short side, at most WAD; the keep
    /// is Math._keep's (1e6 - f) 1e12 (WAD - e) / WAD.
    function _keepAtProbe(MockV2Pair p, uint256 probe) internal view returns (uint256 rank, uint256 k) {
        rank = _alone(p, probe);
        (uint112 r0, uint112 r1, ) = p.getReserves();
        uint256 depth = r0 < r1 ? r0 : r1;
        uint256 n = probe * (1e6 - 3_000) / 1e6;
        uint256 low = probe < rank ? probe : rank;
        uint256 e = rank == 0 || n == 0 || low >= depth
            ? 1e18
            : (3e18 + 2 * probe) / rank + 1 + 3e18 / n + (low * 1e18 + depth - 1) / depth;
        if (e > 1e18) e = 1e18;
        k = (1e6 - 3_000) * 1e12 * (1e18 - e) / 1e18;
    }

    /// Where (i)'s witness is one: the honest row votes (rank > 0 at the probe, m / 100 or m) and
    /// the band's upper edge would drop the pricier row were the other the base. Math._inBand keeps
    /// row i iff p_i k_i k_b (1 - f_b) <= p_b; both fees are 30 bps, so the prices' ratio is the
    /// ranks' ratio at the one probe. No threshold: in dust the rounding terms widen the band
    /// past the 2x row (probe < ~19 wei), and at 1 wei the honest row quotes 0 and is dead.
    function _witness(uint256 m) internal view returns (bool) {
        uint256 probe = m / 100 == 0 ? m : m / 100;
        (uint256 rH, uint256 kH) = _keepAtProbe(honest, probe);
        (uint256 rA, uint256 kA) = _keepAtProbe(attacker, probe);
        if (rH == 0) return false;
        (uint256 hi, uint256 lo) = rA > rH ? (rA, rH) : (rH, rA);
        return hi * (kH * kA / 1e18 * (1e6 - 3_000) / 1e6) > lo * 1e18;
    }

    /// (i) where its witness holds. Elsewhere the anchor may be the attacker's, the same on
    /// 8c100b3 and before ROUTEQ: the route still pays at least the honest pool alone and, with
    /// the honest pool out of it, exactly what the attacker's pool pays alone.
    function _anchor(RoutePlan memory plan, uint256 m, bool above, bool witness, string memory why) internal view {
        if (witness) {
            assertTrue(_baseIsHonest(plan, above), why);
            return;
        }
        uint256 committed = _committed(plan);
        assertGe(plan.best.totalOut, _honestAlone(committed), "(ii) outside the witness, never under the honest pool alone");
        if (!_has(plan, address(honest))) {
            assertEq(plan.best.totalOut, _alone(attacker, committed), "outside the witness, without the honest pool: the attacker alone");
        }
    }

    /// What the route commits on its one hop: the legs' input sum (the Router's fee base).
    function _committed(RoutePlan memory plan) internal pure returns (uint256 s) {
        Leg[] memory legs = plan.best.hops[0].legs;
        for (uint256 i; i < legs.length; ++i) s += legs[i].amountIn;
    }

    /// Where the Router refuses the plan, RouterE(8), by its own formulas on the reserves read
    /// here. Hop 0 charges fee = ceil(c * 28 / 1e4) on the committed sum c (Router._chargeHopFee,
    /// the one reader of the fee) and scales each leg to floor(leg.amountIn * min(m - fee, c) / c)
    /// (Router._execute). Two refusals, both before a pair swaps and both pre-existing (the same
    /// lines on e01b503, main):
    ///   - the fee takes the order, fee >= m (Router._chargeHopFee): only m = 1 wei;
    ///   - a leg's net input quotes 0 by the V2 formula (Router._execPairAmt: outAmt == 0). A leg
    ///     scaled to 0 is skipped, not refused. At 1:1 this is 1 wei net (m = 2, fee 1): the
    ///     Solver, which does not read the fee, quotes 2 wei for 1; the Router has 1 wei for 0.
    /// Exact, not a dust threshold: c <= m (asserted before), so the Router's fee base min(m, c)
    /// is c. Every leg scaled to 0 would refuse too (totalReceived == 0), but that needs two legs
    /// of 1 wei at 1 wei net (m = 2), and the honest pool's 1 wei leg quotes 0, which the Solver
    /// drops (Solver._split): not reachable here.
    function _routerRefuses(RoutePlan memory plan, uint256 m) internal view returns (bool) {
        uint256 c = _committed(plan);
        uint256 fee = (c * 28 + 9_999) / 10_000;
        if (fee >= m) return true;
        uint256 net = m - fee < c ? m - fee : c;
        Leg[] memory legs = plan.best.hops[0].legs;
        for (uint256 i; i < legs.length; ++i) {
            uint256 x = legs[i].amountIn * net / c;
            if (x != 0 && _alone(MockV2Pair(legs[i].pool), x) == 0) return true;
        }
        return false;
    }

    /// (ii) and (iii) on one order.
    function _routeAndPay(RoutePlan memory plan, uint256 m) internal {
        uint256 committed = _committed(plan);
        assertLe(committed, m, "the route commits at most the order");
        assertLt(m - committed, m / 100 == 0 ? m : m / 100, "(ii) what no leg takes is under the probe");
        assertGe(plan.best.totalOut, _honestAlone(committed), "(ii) the route never pays less than the base alone");
        tokenA.mint(USER, m);
        if (_routerRefuses(plan, m)) {
            vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8));
            vm.prank(USER);
            router.swapExactIn(plan.best, m, 1, USER, block.timestamp + 1);
            assertEq(tokenA.balanceOf(USER), m, "refused: the order stays with the user");
            assertEq(tokenB.balanceOf(USER), 0, "refused: nothing delivered");
            emit log_named_uint("router_refuses_nothing_left_for_a_pool_to_pay_m", m);
            return;
        }
        uint256 before = tokenB.balanceOf(USER);
        vm.prank(USER);
        router.swapExactIn(plan.best, m, 1, USER, block.timestamp + 1);
        uint256 got = tokenB.balanceOf(USER) - before;
        uint256 promised = plan.best.totalOut * (m - (m * 28 + 9_999) / 10_000) / m;
        emit log_named_uint("delivered_minus_promised", got - (got < promised ? got : promised));
        assertGe(got, promised, "(iii) delivered >= promised, net of the protocol fee");
    }

    function test_WithoutDonation_AnchorStaysOnTheHonestPool() public {
        _market(DEPTH, false);
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMOUNT_IN);
        assertTrue(_baseIsHonest(plan, false), "(i) the honest pool is the base: it is in the route");
        // 1000e18 into 1000e18/1000e18 at 30 bps: 1000e18 * 997 * 1000e18 / (1000e18 * 1000 + 1000e18 * 997)
        // = 997e42 / 1997e21 = 499248873309964947421 (floor)
        assertEq(_honestAlone(AMOUNT_IN), 499248873309964947421, "oracle: V2 out, by hand");
        _routeAndPay(plan, AMOUNT_IN);
    }

    // T2: 2000e18 tokenOut donated to the attacker (twice the honest depth); the vote reads
    // reserves, so the honest pool stays the base and the route reads nothing the donation moved.
    function test_WithDonation_AnchorHolds_HonestPoolStaysInTheRoute() public {
        _market(DEPTH, false);
        RoutePlan memory clean = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMOUNT_IN);
        tokenB.mint(address(attacker), 2000e18);
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMOUNT_IN);
        assertTrue(_baseIsHonest(plan, false), "(i) donation must NOT flip the anchor");
        assertEq(plan.best.totalOut, clean.best.totalOut, "the donation changes nothing the route reads");
        emit log_named_uint("honest_totalOut", plan.best.totalOut);
        _routeAndPay(plan, AMOUNT_IN);
    }

    /// The funnel (Solver._dropDust) drops row j iff d_j 1e6 < 25 (D - d_j), d the row's
    /// hopMass18. The honest row holds 1000e18 of tokenOut, the attacker 500e18 and a donation x.
    /// Read from reserves, x moves nothing. Read from balances, the honest row would be dropped
    /// iff 1000e18 * 1e6 < 25 * (500e18 + x), i.e. x > 4e25 - 500e18 = 39_999_500e18: at that x
    /// it sits on the edge (1e27 = 25 * 4e25, kept), one wei more and the route is the attacker
    /// alone, 1000e18 * 997 * 500e18 / (1000e18 * 1000 + 1000e18 * 997) = 249624436654982473710,
    /// half the honest pool alone. Mutant ANCHOR is red at + 1 wei.
    function test_DonationPastTheDustShare_HonestRowKeepsItsSeat_plusMinusOneWei() public {
        _market(DEPTH, false);
        RoutePlan memory clean = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMOUNT_IN);
        assertEq(_alone(attacker, AMOUNT_IN), 249624436654982473710, "oracle: the attacker alone, by hand");
        uint256 edge = 39_999_500e18;
        tokenB.mint(address(attacker), edge);
        RoutePlan memory atEdge = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMOUNT_IN);
        assertTrue(_baseIsHonest(atEdge, false), "on the edge the honest row keeps its seat");
        assertEq(atEdge.best.totalOut, clean.best.totalOut, "on the edge the donation changes nothing");
        tokenB.mint(address(attacker), 1);
        RoutePlan memory past = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMOUNT_IN);
        assertTrue(_baseIsHonest(past, false), "one wei past the edge the honest row keeps its seat");
        assertEq(past.best.totalOut, clean.best.totalOut, "one wei past the edge the donation changes nothing");
        _routeAndPay(past, AMOUNT_IN);
    }

    /// Pre-registered 2026-11-13, before any run: runs = 1000; depth in [1e20, 1e28]; order m in
    /// {0, depth/2, depth, 10 depth} or uniform in [1, 10 depth]; attacker above or below;
    /// donation in [0, 4 depth]; (i) before and after the donation, (ii)-(iii) after. Run with
    /// the repo's seed and one seed from /dev/urandom; failures are recorded, not tuned away.
    /// The first runs failed on two refusals that are the Solver's, the same on 8c100b3 (before
    /// ROUTEQ-2) as on the fix, so the oracle asserts them instead of expecting a plan:
    ///   - m = 0 is refused with SolverE(4) (no order, no plan);
    ///   - "no route", SolverE(5), and only for an order no leg can take: past the impact
    ///     ceiling (MAX_ROUTE_IMPACT_BPS = 9_000; a V2 leg of input reserve R measures
    ///     ceil(x 1e4 / (R + x)) >= 9_000 iff 1_001 x > 8_999 R, and no leg takes more than m,
    ///     so it needs 1_001 m > 8_999 rMin, rMin the thinner input-side book: depth / 4 above,
    ///     depth below), or an order whose probe (m / 100, or m under 100 wei) no row quotes:
    ///     every row dead, nothing to route (Solver: a row lives iff its probe rank > 0). Each
    ///     one is logged.
    ///     Measured on 8c100b3: attacker above, m = 10 depth has no route at depth 1e20, 8.23e27
    ///     and 1e28; 6 depth routes. Below the bound a refusal is a failure.
    /// A later run failed (i) at args=[1e20, 174, 167, true, 10226]: m = 167 wei, probe 1 wei, where
    /// the honest pool quotes 0 and does not vote. (i) is asserted only where its witness is one
    /// (`_witness`, derived from the producers' formulas); elsewhere `_anchor` asserts what holds.
    /// Seed 0xb1a2ef00 failed (ii) at args=[10921, 64, 7, false, ~2^256]: m = 7 wei below, a leg
    /// dropped at its share and 2 wei left unrouted; (ii) now reads the committed sum (header).
    /// Seed 0xa2fa3a53edbbe778 failed (iii) at args=[2, 179, 1, true, 1717033926673775]: m = 1
    /// wei, whose fee is the whole order; `_routeAndPay` asserts the Router's refusal there.
    /// CI run 43502199738 (584e547) failed (iii) at args=[193130785639724, 4, 2, false, 1270]: m = 2
    /// wei, whose fee leaves 1 wei, which the pool pays nothing for; `_routerRefuses` derives both
    /// refusals from the Router's formulas on the reserves read here (pre-existing on e01b503).
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_NoPoolCapturesTheAnchor(uint256 depth, uint8 bucket, uint256 rawM, bool above, uint256 donation)
        public
    {
        _noPoolCapturesTheAnchor(depth, bucket, rawM, above, donation);
    }

    /// The fuzz's counterexample, pinned (pre-existing: the same to the wei on 8c100b3). Probe
    /// 167 / 100 = 1 wei: the honest pool quotes floor(0.997) = 0, a dead row; the attacker, the
    /// one live row, is the anchor and the sole leg, paying twice the honest pool. By hand:
    /// 167 * 997 * 5e19 / (2.5e19 * 1000 + 167 * 997) = 332; the honest pool 166.
    function test_DustOrder_HonestRowDeadAtOneWeiProbe_AttackerPaysMore() public {
        RoutePlan memory plan = _noPoolCapturesTheAnchor(1e20, 174, 167, true, 10226);
        assertFalse(_witness(167), "oracle: at a 1 wei probe the honest row is dead, no witness");
        assertEq(plan.best.hops[0].legs.length, 1, "one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(attacker), "the attacker, the one live row");
        assertEq(plan.best.totalOut, 332, "oracle: the attacker alone, V2 formula by hand");
        assertEq(_honestAlone(167), 166, "oracle: the honest pool alone, V2 formula by hand");
    }

    /// The second counterexample, pinned: m = 1 wei above, the attacker the one live row (the
    /// honest pool quotes floor(0.997) = 0 at a 1 wei probe), a plan of 1 wei for 1 wei whose
    /// fee, ceil(1 * 28 / 1e4) = 1, is the whole order: the Router refuses it, RouterE(8).
    function test_OneWeiOrder_TheFeeTakesTheOrder_RouterRefuses() public {
        RoutePlan memory plan = _noPoolCapturesTheAnchor(2, 179, 1, true, 1717033926673775);
        assertEq(plan.best.hops[0].legs.length, 1, "one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(attacker), "the attacker, the one live row");
        assertEq(plan.best.totalOut, 1, "oracle: depth 1e20 + 2, 997 * (depth / 2) / (depth / 4 * 1000 + 997) = 1");
        assertEq(tokenB.balanceOf(USER), 0, "refused: nothing delivered");
        assertEq(tokenA.balanceOf(USER), 1, "refused: the order stays with the user");
    }

    /// The third counterexample, pinned (CI run 43502199738 on 584e547; pre-existing, the same
    /// plan and the same refusal on e01b503): depth binds to 9999999900000193130785639725, m = 2
    /// wei below, probe 2 wei, where the honest pool quotes floor(1.994) = 1 and the attacker
    /// floor(0.997) = 0: the honest pool is the one live row, a plan of 2 wei for 1. The fee,
    /// ceil(2 * 28 / 1e4) = 1, is not the order (1 < 2), so the Router goes on with 1 wei, and
    /// 1 wei at 1:1 quotes floor(997 D / (1000 D + 997)) = 0: refused before the pair swaps,
    /// RouterE(8) (Router._execPairAmt, outAmt == 0), not the fee refusal of m = 1.
    /// Mutant: Router._chargeHopFee with mulDiv for mulDivUp charges no fee at 2 wei and the
    /// swap no longer ends in RouterE(8) (it ends in RouterE(15)): red.
    function test_TwoWeiOrder_TheFeeLeavesOneWei_WhichThePoolPaysNothingFor_RouterRefuses() public {
        RoutePlan memory plan = _noPoolCapturesTheAnchor(193130785639724, 4, 2, false, 1270);
        assertEq(plan.best.hops[0].legs.length, 1, "one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(honest), "the honest pool, the one live row");
        assertEq(plan.best.hops[0].legs[0].amountIn, 2, "the whole order committed");
        assertEq(plan.best.totalOut, 1, "oracle: 2 * 997 * D / (1000 D + 1994) = 1 at D = 9999999900000193130785639725");
        assertEq(_alone(honest, 1), 0, "oracle: 1 wei net of the fee pays nothing at 1:1");
        assertTrue(_routerRefuses(plan, 2), "oracle: the refusal is derived, not read from the Router");
        assertEq(tokenB.balanceOf(USER), 0, "refused: nothing delivered");
        assertEq(tokenA.balanceOf(USER), 2, "refused: the order stays with the user");
    }

    function _noPoolCapturesTheAnchor(uint256 depth, uint8 bucket, uint256 rawM, bool above, uint256 donation)
        internal returns (RoutePlan memory plan)
    {
        depth = bound(depth, 1e20, 1e28);
        uint256[5] memory ms = [uint256(0), depth / 2, depth, 10 * depth, bound(rawM, 1, 10 * depth)];
        uint256 m = ms[bucket % 5];
        donation = bound(donation, 0, 4 * depth);
        _market(depth, above);
        if (m == 0) {
            vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 4));
            solver.findBestRoutePlan(address(tokenA), address(tokenB), m);
            return plan;
        }
        uint256 rMin = above ? depth / 4 : depth;
        bool witness = _witness(m);   // reserves only: a donation does not move it
        (bool routed, RoutePlan memory clean) = _plan(m, rMin);
        if (routed) _anchor(clean, m, above, witness, "(i) without the donation the honest pool is the base");
        tokenB.mint(address(attacker), donation);
        (routed, plan) = _plan(m, rMin);
        if (!routed) return plan;
        _anchor(plan, m, above, witness, "(i) with the donation the honest pool is still the base");
        _routeAndPay(plan, m);
    }

    /// A plan, or "no route" where the Solver may answer it (see the fuzz's header): past the
    /// impact ceiling on the thinner book, or for an order whose probe no row quotes.
    function _plan(uint256 m, uint256 rMin) internal returns (bool routed, RoutePlan memory plan) {
        try solver.findBestRoutePlan(address(tokenA), address(tokenB), m) returns (RoutePlan memory p) {
            return (true, p);
        } catch (bytes memory err) {
            assertEq(
                err,
                abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, 5),
                "a live order is refused only as 'no route'"
            );
            uint256 probe = m / 100 == 0 ? m : m / 100;
            assertTrue(
                1_001 * m > 8_999 * rMin || (_alone(honest, probe) == 0 && _alone(attacker, probe) == 0),
                "no route for an order a leg can take"
            );
            emit log_named_uint("no_route_m_per_rMin_pct", m * 100 / rMin);
        }
    }
}
