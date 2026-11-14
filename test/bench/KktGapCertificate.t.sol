// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE SPLIT'S DISTANCE FROM THE OPTIMUM, CERTIFIED FROM QUOTES (B9).
//
//  The Solver splits a hop in proportion to depth (psi), not by solving the KKT conditions.
//  For concave legs the gap to the optimum has a certificate that needs only quotes:
//      F* - F(a) <= A * ( max_i f_i'(a_i) - min_{i active} f_i'(a_i) )                 (*)
//  [derived: for concave f_i and any feasible a, F* - F(a) <= sum_i f_i'(a_i)(a*_i - a_i)
//   <= A * (max f' - min_{active} f'), since sum (a*_i - a_i) = 0 and a*_i - a_i < 0 only on
//   active legs]. f' is not read: a finite difference of the leg's own quotes bounds it
//   from the right side (concavity): (f(a) - f(a - d)) / d >= f'(a) for the max,
//   (f(a + d) - f(a)) / d <= f'(a) for the min; an inactive leg's f'(0) is at most its spot.
//
//  Universes are V2 (concave), generated from the pre-registered seed of
//  docs/prereg/kkt-1114.tsv. F* is found by bisection on the multiplier lambda of the KKT
//  equation, with the closed form a_i(lambda) = (sqrt(gamma R_o R_i / lambda) - R_i) / gamma,
//  so the optimum is not the code under test. Asserted per cell:
//    (a) F*_est - F <= (*) + n                  the certificate holds (n wei: integer quotes);
//    (b) one price, one fee: (*) <= BOUND_PPM   at one price and one fee the depth split IS
//        the KKT point (the marginals are equal iff a_i is proportional to R_i), so the
//        certificate is small; the bound is the pre-registered number.
//  Every cell is printed as a ledger line (docs/assurance/kkt-gap.tsv). V3/V4 legs are not
//  concave across a tick whose liquidity rises, and two hops couple through the bridge
//  amount: there the gap is a record, never an assertion (CONJECTURE, FABLE-DESENHO-124 F2.e).
//
//  Mutants: Math `_weights` psi -> 1 (equal split): red on (b). Solver `_onTrial` `>=` -> `>`.
//  Src 0: a benchmark with a certificate, not a guard on a fix.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, Leg, RoutePlan} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";

contract KktGapCertificate is Test {
    // docs/prereg/kkt-1114.tsv
    bytes32 internal constant TAG = "kkt-1114";
    uint256 internal constant FEE_BPS = 30;
    // Fixed from the first run (11-14): the largest certificate in universe 0 is 3_014 ppm,
    // at 1 ppm of depth where one leg takes the order (the idle pools' marginal is the fee
    // away); from 100 ppm up it is <= 114 ppm. The prereg's 10_000 was a placeholder.
    uint256 internal constant BOUND_PPM = 3_500;

    MockERC20 A;
    MockERC20 B;
    address[] pools;
    uint256[] rIn;
    uint256[] rOut;

    function setUp() public {
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
    }

    function test_GapIsWithinTheCertificate() public {
        console2.log("ledger\tuniverse\tn\tsize_ppm\tlegs\tF\tF_star\tgap_ppm\tbound_ppm\tasserted");
        uint256[6] memory sizePpm = [uint256(1), 100, 1_000, 10_000, 50_000, 200_000];
        uint256[3] memory ns = [uint256(2), 3, 5];
        for (uint256 u; u < 2; ++u) {
            for (uint256 j; j < 3; ++j) {
                BlazePhoenixSolver s = _universe(u, ns[j]);
                uint256 depth;
                for (uint256 i; i < ns[j]; ++i) depth += rIn[i];
                for (uint256 k; k < 6; ++k) _cell(s, u, ns[j], sizePpm[k], depth * sizePpm[k] / 1e6);
            }
        }
    }

    // ---- one cell ----------------------------------------------------------------------

    function _cell(BlazePhoenixSolver s, uint256 u, uint256 n, uint256 sizePpm, uint256 amt) private {
        RoutePlan memory plan = s.findBestRoutePlan(address(A), address(B), amt);
        assertEq(plan.best.hops.length, 1, "one pair, one hop");
        Leg[] memory legs = plan.best.hops[0].legs;
        uint256[] memory a = new uint256[](n);
        uint256 sumA;
        for (uint256 l; l < legs.length; ++l) {
            uint256 i = _idx(legs[l].pool);
            a[i] += legs[l].amountIn;
            sumA += legs[l].amountIn;
        }
        assertEq(sumA, amt, "the legs spend the input");
        uint256 F;
        for (uint256 i; i < n; ++i) F += _f(i, a[i]);
        uint256 cert = _certificate(a, amt);
        uint256 fStar = _optimum(amt);
        uint256 gap = fStar > F ? fStar - F : 0;
        uint256 boundPpm = F == 0 ? 0 : cert * 1e6 / F;
        console2.log(string.concat(
            "ledger\t", u == 0 ? "v2-one-price-one-fee" : "v2-band-prices", "\t", vm.toString(n), "\t",
            vm.toString(sizePpm), "\t", vm.toString(legs.length), "\t", vm.toString(F), "\t", vm.toString(fStar), "\t",
            vm.toString(F == 0 ? 0 : gap * 1e6 / F), "\t", vm.toString(boundPpm), "\ty"
        ));
        assertLe(fStar, F + cert + n, "(a) the gap to the optimum is within the certificate");
        if (u == 0) assertLe(boundPpm, BOUND_PPM, "(b) one price, one fee: the depth split is the KKT point");
    }

    // ---- the universe ------------------------------------------------------------------

    /// u = 0: one price for every pool; u = 1: each pool within +-4 % of it (inside the band).
    function _universe(uint256 u, uint256 n) private returns (BlazePhoenixSolver solver) {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        delete pools;
        delete rIn;
        delete rOut;
        uint256 price = 100 + uint256(keccak256(abi.encode(TAG, u, n, "price"))) % 9_901; // thousandths
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(TAG, u, n, i)));
            uint256 ra = 1e24 * (1 + r % 16);
            uint256 dev = u == 0 ? 10_000 : 9_600 + (r >> 128) % 801;
            uint256 rb = ra * price / 1000 * dev / 10_000;
            MockV2Pair p = new MockV2Pair(address(A), address(B));
            A.mint(address(p), ra);
            B.mint(address(p), rb);
            bool aIs0 = address(A) < address(B);
            p.setReserves(uint112(aIs0 ? ra : rb), uint112(aIs0 ? rb : ra));
            hub.seedPool(address(p), BPC.KIND_V2, uint24(FEE_BPS), address(0), address(A), address(B));
            pools.push(address(p));
            rIn.push(ra);
            rOut.push(rb);
        }
    }

    function _idx(address p) private view returns (uint256 i) {
        for (; i < pools.length; ++i) if (pools[i] == p) return i;
        revert("leg on a pool outside the universe");
    }

    // ---- the oracle: the V2 closed form, not the Core ----------------------------------

    function _f(uint256 i, uint256 a) private view returns (uint256) {
        uint256 ae = a * (10_000 - FEE_BPS);
        return ae * rOut[i] / (rIn[i] * 10_000 + ae);
    }

    /// (*) from quotes: d = max(1, A / 1e6); +1 / -1 wei on each difference so the
    /// integer quotes keep the majorant above and the minorant below.
    function _certificate(uint256[] memory a, uint256 amt) private view returns (uint256) {
        uint256 d = amt / 1e6 == 0 ? 1 : amt / 1e6;
        uint256 hi;
        uint256 lo = type(uint256).max;
        for (uint256 i; i < a.length; ++i) {
            uint256 spot = (rOut[i] * 1e18 + rIn[i] - 1) / rIn[i];
            if (a[i] == 0) {
                if (spot > hi) hi = spot;
                continue;
            }
            uint256 up = a[i] >= d ? ((_f(i, a[i]) - _f(i, a[i] - d) + 1) * 1e18 + d - 1) / d : spot;
            uint256 dn = _f(i, a[i] + d) - _f(i, a[i]);
            uint256 down = dn == 0 ? 0 : (dn - 1) * 1e18 / d;
            if (up > hi) hi = up;
            if (down < lo) lo = down;
        }
        return hi > lo ? (amt * (hi - lo) + 1e18 - 1) / 1e18 : 0;
    }

    /// F* by bisection on lambda (WAD marginal): the largest lambda whose allocation covers
    /// the input; the excess comes off the largest leg. A lower estimate of the true optimum.
    function _optimum(uint256 amt) private view returns (uint256 best) {
        uint256 lo = 1;
        uint256 hi;
        for (uint256 i; i < rIn.length; ++i) {
            uint256 m = rOut[i] * 1e18 / rIn[i] + 1;
            if (m > hi) hi = m;
        }
        for (uint256 it; it < 200 && lo + 1 < hi; ++it) {
            uint256 mid = (lo + hi) / 2;
            if (_sumAt(mid) >= amt) lo = mid;
            else hi = mid;
        }
        uint256 n = rIn.length;
        uint256[] memory x = new uint256[](n);
        uint256 sum;
        uint256 top;
        for (uint256 i; i < n; ++i) {
            x[i] = _aAt(i, lo);
            sum += x[i];
            if (x[i] > x[top]) top = i;
        }
        if (sum > amt) x[top] -= sum - amt;
        else x[top] += amt - sum;
        for (uint256 i; i < n; ++i) best += _f(i, x[i]);
    }

    function _sumAt(uint256 lambda) private view returns (uint256 s) {
        for (uint256 i; i < rIn.length; ++i) s += _aAt(i, lambda);
    }

    /// a_i(lambda) = (sqrt(gamma R_o R_i / lambda) - R_i) / gamma, clamped at 0.
    function _aAt(uint256 i, uint256 lambda) private view returns (uint256) {
        uint256 sq = _sqrt(rOut[i] * rIn[i] * (10_000 - FEE_BPS) * 1e14 / lambda);
        return sq > rIn[i] ? (sq - rIn[i]) * 10_000 / (10_000 - FEE_BPS) : 0;
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
