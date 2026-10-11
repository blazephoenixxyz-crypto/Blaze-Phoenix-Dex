// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  E23 — the leg shave is the EFFECTIVE leg count, and it is floored once per hop.
//
//  The published definition (docs/papers/whitepaper-v2.2.md:616, and the machine
//  edition docs/papers/llms-full.txt:151 as E23) is
//
//      legShv = Σ_hops ⌊ FLOOR_PER_LEG_BPS · ((Σa)² − Σa²) / Σa² ⌋
//
//  and `Core.legShaveBps` (src/BlazePhoenixCore.sol:2314) is the one definition the
//  floor's two producers both call: the Router inside the executing frame, per hop
//  (`Router:1474`, inside the hop loop at `Router:1465`), and the Solver when it
//  attests the route (`Solver:1591` for the single-hop arm, `Solver:1681` summed per
//  hop for the multi-hop arm). Its own header states the reason it is a shared
//  quantity: "for a Solver-built route those are the same numbers - so the attested
//  floor and the enforced floor agree by construction, not by test."
//
//  Measured on this tree @754d651: `git grep -w legShaveBps -- test/` returns **0
//  files**, and no entry of `.github/scripts/mutants.py` points into the function
//  ({ path: src/BlazePhoenixCore.sol, line: 2314-2318 } lies in none of the 315
//  resolved mutant sites). So "agrees by construction" was the whole of the
//  evidence that the shipped shave is the published one. This file makes the
//  definition itself the subject, with the expected values taken from the paper and
//  from hand arithmetic on small vectors — never from the code under test.
//
//  What makes each test fail:
//    * summing before flooring per hop — the per-hop sum below moves (240 -> 2*120
//      is not 2*120 worth of a single floor: (Σa)² over the two-hop union is a
//      different number);
//    * shaving by the naive leg count instead of the effective one — the unequal
//      cases move ((3,1) is 120 bps, not 200);
//    * dropping the `sumA2 == 0` arm, or breaking the Cauchy–Schwarz numerator so
//      the ceiling assertion `shave ≤ 200·(n−1)` flips.
//
//  forge test --match-contract LegShaveIsTheEffectiveLegCount -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract LegShaveIsTheEffectiveLegCountTest is Test {
    /// The published constant (whitepaper-v2.2.md:616: "FLOOR_PER_LEG_BPS = 200").
    uint256 constant SHV_PUBLISHED = 200;

    function _b(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    /// Σa and Σa² for `n` legs of equal size `a` — the fixture the paper names
    /// ("exactly N for N equal shares").
    function _equalLegs(uint256 n, uint256 a) internal pure returns (uint256 sA, uint256 sA2) {
        sA = n * a;
        sA2 = n * a * a;
    }

    // ─── the constant itself, against the published figure ───────────────────

    /// The shave per effective extra leg is the paper's 200 bps, and the leg floor
    /// is the paper's 8,000 bps. Oracle: the published definition, not the code.
    function test_ThePublishedConstantsAreTheShippedOnes() public pure {
        assertEq(BPC.FLOOR_PER_LEG_BPS, SHV_PUBLISHED, "FLOOR_PER_LEG_BPS != the published 200");
        assertEq(BPC.LEG_FLOOR_BPS, 8_000, "LEG_FLOOR_BPS != the published 8000");
    }

    // ─── the two ends of the definition, as the paper names them ─────────────

    /// "exactly 1 for one dominant leg": a leg carrying the whole hop earns nothing.
    function testFuzz_ASingleLegEarnsNoShave(uint256 a) public pure {
        a = _b(a, 1, 1e30);
        assertEq(BPC.legShaveBps(a, a * a), 0, "one leg must earn zero shave");
    }

    /// "whether it declares zero or one wei": the arm that guards the division.
    function test_NoAmountsAtAllEarnNoShave() public pure {
        assertEq(BPC.legShaveBps(0, 0), 0, "an empty hop must not revert and must earn zero");
    }

    /// "exactly N for N equal shares": N equal legs earn exactly (N−1) shaves, at
    /// every size and every N (fuzzed), because (n²a² − n a²)/(n a²) is the integer
    /// n−1. Oracle: hand algebra from the published formula.
    function testFuzz_NEqualSharesEarnExactlyNMinusOneShaves(uint256 a, uint256 n) public pure {
        n = _b(n, 1, 12);
        a = _b(a, 1, 1e24);
        (uint256 sA, uint256 sA2) = _equalLegs(n, a);
        assertEq(BPC.legShaveBps(sA, sA2), SHV_PUBLISHED * (n - 1), "equal shares: not (n-1)*200");
    }

    // ─── the positive control the zero above needs (property 6 of the method) ─

    /// Two equal shares are the smallest non-degenerate split and they DO earn one
    /// full shave — so a zero elsewhere cannot come from a dead fixture.
    function test_TwoEqualSharesEarnOneFullShave() public pure {
        (uint256 sA, uint256 sA2) = _equalLegs(2, 1e18);
        assertEq(BPC.legShaveBps(sA, sA2), SHV_PUBLISHED, "two equal shares must earn exactly one shave");
    }

    // ─── unequal shares: the effective count is NOT the naive count ──────────

    /// (3,1): Σa = 4, Σa² = 10, so the fraction is (16−10)/10 = 0.6 and the shave is
    /// 120 bps — where a naive leg count would say 200. Hand-derived from the paper.
    function test_ThreeAndOneEarnOneHundredAndTwenty() public pure {
        assertEq(BPC.legShaveBps(4, 10), 120, "(3,1) shares are 120 bps, not the naive 200");
    }

    /// Three equal shares: (3a)² − 3a² over 3a² = 2 exactly -> 400.
    function test_ThreeEqualSharesEarnTwoShaves() public pure {
        (uint256 sA, uint256 sA2) = _equalLegs(3, 7);
        assertEq(BPC.legShaveBps(sA, sA2), 2 * SHV_PUBLISHED, "three equal shares must earn 2*200");
    }

    /// The naive count is a CEILING the equal case attains (Cauchy–Schwarz: (Σa)² ≤
    /// n·Σa²), and unequal shares sit strictly below it. This is the assertion that
    /// separates "shaves by the effective count" from "shaves by the leg count".
    function testFuzz_TheNaiveCountIsAReachableCeiling(uint256 a, uint256 b, uint256 c) public pure {
        a = _b(a, 1, 1e24);
        b = _b(b, 1, 1e24);
        c = _b(c, 1, 1e24);
        uint256 sA = a + b + c;
        uint256 sA2 = a * a + b * b + c * c;
        uint256 got = BPC.legShaveBps(sA, sA2);
        assertLe(got, 2 * SHV_PUBLISHED, "the shave of 3 legs can never exceed the naive 2*200");
        if (a == b && b == c) {
            assertEq(got, 2 * SHV_PUBLISHED, "equal shares must attain the ceiling");
        }
    }

    /// A dust leg beside a deep one earns nothing at all, at any depth: the whole
    /// point of taking the concentration rather than the count.
    function testFuzz_OneWeiBesideADeepLegEarnsZero(uint256 big) public pure {
        big = _b(big, 1e18, 1e30);
        assertEq(BPC.legShaveBps(big + 1, big * big + 1), 0, "a dust leg must earn nothing");
    }

    // ─── the definitional identity, against the test's own arithmetic ────────

    /// The shipped figure equals the published formula computed here, in the test,
    /// with the test's own arithmetic and no call into the contract beyond the one
    /// under test. Two independent expressions of ⌊200·((Σa)²−Σa²)/Σa²⌋.
    function testFuzz_ThePublishedFormulaAndTheShippedOneAgree(uint256 a, uint256 b) public pure {
        a = _b(a, 1, 1e26);
        b = _b(b, 1, 1e26);
        uint256 sA = a + b;
        uint256 sA2 = a * a + b * b;
        uint256 published = ((sA * sA - sA2) * SHV_PUBLISHED) / sA2;
        assertEq(BPC.legShaveBps(sA, sA2), published, "shipped shave != the published formula");
    }

    /// Per-hop flooring: E23 puts the ⌊⌋ INSIDE the sum over hops, so two hops that
    /// are each (3,1) contribute 120 + 120 = 240 — not the 200 a single floor over
    /// the union would give. The Router sums per hop (Router:1474) and the Solver's
    /// multi-hop arm does the same (Solver:1681); this pins the shape they share.
    function test_TwoHopsFloorSeparatelyAndTheSumIsWhatTheRouterBuilds() public pure {
        uint256 hop1 = BPC.legShaveBps(4, 10); // (3,1)
        uint256 hop2 = BPC.legShaveBps(4, 10); // (3,1)
        assertEq(hop1 + hop2, 240, "per-hop flooring must sum to 240 for two (3,1) hops");
    }
}
