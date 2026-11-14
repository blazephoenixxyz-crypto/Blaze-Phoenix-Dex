// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The same-answer comparison of test/G52SameAnswer.t.sol and
//  test/MathBoundarySameAnswer.t.sol, on the venue shapes and ranges those two
//  files never seed.
//
//  Both files register KIND_V2, KIND_V3 and KIND_V4 rows over 18-decimal tokens.
//  A change to the Core's Solidly arm, to its Algebra arm or to its decimals
//  scaling therefore reaches no row of theirs, and the frozen reference
//  (test/ref/CoreRefCb1d7d9.sol) is never asked about it.
//
//  Matrix (range x vector x dimension):
//    - range: 0, 1, 2, 2^112 - 1, 2^112, 2^128, 2^255, 2^256 - 1, and one unit
//      of a 6-decimal and of an 18-decimal token;
//    - vector: Solidly volatile, Solidly stable, Algebra with a live fee, V2;
//      18/18 and 6/18 decimals; both directions;
//    - dimension: unit, one hop, both frozen Solvers (653b1dc and the 2026-10-27
//      pruning), at the door's budget.
//
//  Mutants, all on the LIVE Core (.github/scripts/mutants.py), each run alone
//  against the three files (2026-11-10):
//    - [morf-1j] a one-ppm cut of `out` in the KIND_SOLIDLY arm: red on the six
//      one-unit Solidly rows here (SolidlyVolatile, SolidlyStable,
//      SolidlySixEighteen, against both frozen Solvers); G52SameAnswer (14
//      cases) and MathBoundarySameAnswer (11 cases) stay green;
//    - [morf-1k] the Algebra live fee read as zero: red on the two
//      AlgebraLiveFee rows here; the two older files stay green;
//    - [morf-1a] the one-ppm cut of the V2 curve is G52SameAnswer's own mutant
//      (red on 11 of its 14 cases and on 7 of MathBoundarySameAnswer's 11); here
//      it is also red on the V2SixEighteen and ExtremesV2 rows, the 6/18
//      decimals and the extreme sizes those two files do not seed.
//  ExtremesSolidly compares sixteen refusals, so it pins that both sides refuse
//  and does not see a cut of the price.
//
//  The floor's frame (4007, 2026-11-11): the Solver attests `singleOutFloor` on the
//  output net of the input fees, where both frozen Solvers attested it on the gross
//  output. As in test/G52SameAnswer.t.sol, the reference's floor is read in that
//  frame (test/ref/Frame4007.sol, in `_same`); every other field is compared to the
//  byte. Here no token is a bridge, so every hop pays on its input and the net
//  output is the gross output scaled by (amountIn - ceil(amountIn * 28 / 10_000)) /
//  amountIn: on the volatile Solidly row (1e18 in, 1e24 a side) the live floor is
//  954339691683327390 wei where the frozen floor is 957019345851712184 wei; on the
//  one-wei V2 row the fee swallows the input and the live floor is 0. The frame carries the reference's rate, not
//  the live figure: a floor outside the band the reference's rate admits is still
//  reported as a disagreement.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {SolverRef653} from "./ref/SolverRef653.sol";
import {SolverRefPoda1027} from "./ref/SolverRefPoda1027.sol";
import {Frame4007} from "./ref/Frame4007.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";

contract G52SameAnswerRangesTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    address ref653;
    address refPoda;

    /// Mirrors `BlazePhoenixCore.SOLVE_GAS`, the budget the automatic door hands a solve.
    uint256 constant SOLVE_GAS = 14_700_000;
    uint160 constant SP = uint160(1 << 96);   // price 1, tick 0

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        ref653 = address(new SolverRef653(address(hub), address(0)));
        refPoda = address(new SolverRefPoda1027(address(hub), address(0)));
        hub.setRoles(address(this), address(solver), address(this));
    }

    // ─── fixtures ────────────────────────────────────────────────────────────

    function _pair18() internal returns (address lo, address hi) {
        address a = address(new MockERC20("A", "A"));
        address b = address(new MockERC20("B", "B"));
        (lo, hi) = a < b ? (a, b) : (b, a);
    }

    /// One token of 6 decimals and one of 18, returned as (six, eighteen).
    function _pair6x18() internal returns (address six, address eighteen) {
        six = address(new PathologicalERC20("S", "S", 6));
        eighteen = address(new MockERC20("E", "E"));
    }

    function _mint(address t, address to, uint256 amt) internal {
        MockERC20(t).mint(to, amt);   // PathologicalERC20 answers the same selector
    }

    function _solidly(address a, address b, uint256 ra, uint256 rb, bool stable) internal returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        MockSolidlyPair p = new MockSolidlyPair(t0, t1, stable);
        _mint(a, address(p), ra);
        _mint(b, address(p), rb);
        (uint256 r0, uint256 r1) = t0 == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_SOLIDLY, 30, address(0), a, b);
        return address(p);
    }

    function _v2(address a, address b, uint256 ra, uint256 rb) internal returns (address) {
        MockV2Pair p = new MockV2Pair(a, b);
        _mint(a, address(p), ra);
        _mint(b, address(p), rb);
        (uint256 r0, uint256 r1) = p.token0() == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), a, b);
        return address(p);
    }

    function _algebra(address a, address b, uint16 dynFee, uint128 liq) internal returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        MockAlgebraPool p = new MockAlgebraPool(t0, t1, dynFee);
        p.setState(SP, liq);
        _mint(a, address(p), 1_000_000e18);
        _mint(b, address(p), 1_000_000e18);
        hub.seedPool(address(p), BPC.KIND_ALGEBRA, 0, address(0), a, b);
        return address(p);
    }

    // ─── the comparison ──────────────────────────────────────────────────────

    /// The live Solver and one frozen Solver on the same call with the same gas: the same
    /// success and the same bytes. `needRoute` refuses a comparison of two refusals.
    function _same(address refSolver, address a, address b, uint256 amt, bool needRoute) internal {
        bytes memory q = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (a, b, amt));
        (bool okN, bytes memory rN) = address(solver).staticcall{gas: SOLVE_GAS}(q);
        (bool okR, bytes memory rR) = refSolver.staticcall{gas: SOLVE_GAS}(q);
        emit log_named_uint("amountIn", amt);
        emit log_named_string("  live", okN ? "answered" : "refused");
        emit log_named_string("  frozen", okR ? "answered" : "refused");
        emit log_named_bytes32("  live bytes", keccak256(rN));
        emit log_named_bytes32("  frozen bytes", keccak256(rR));
        assertEq(okN, okR, "one Solver answered and the other refused");
        // 4007: the floor is attested on the net output since 2026-11-11; the reference's is read
        // in that frame (test/ref/Frame4007.sol), every other field to the byte.
        if (okN) rR = Frame4007.carry(hub, rN, rR);
        assertEq(keccak256(rN), keccak256(rR), "the live Solver and the frozen Solver disagree");
        if (needRoute) assertTrue(okN, "precondition: the row has a route");
    }

    function _extremes(address refSolver, address a, address b) internal {
        uint256[8] memory amts = [
            uint256(0), 1, 2, (uint256(1) << 112) - 1, uint256(1) << 112,
            uint256(1) << 128, uint256(1) << 255, type(uint256).max
        ];
        for (uint256 i; i < amts.length; ++i) {
            _same(refSolver, a, b, amts[i], false);
            _same(refSolver, b, a, amts[i], false);
        }
    }

    // ─── Solidly, volatile, 18/18 ────────────────────────────────────────────

    function _solidlyVolatile(address refSolver) internal {
        (address a, address b) = _pair18();
        _solidly(a, b, 1e24, 1e24, false);
        _same(refSolver, a, b, 1e18, true);
        _same(refSolver, b, a, 1e18, true);
    }
    function test_G52R_SolidlyVolatile_SameAs653() public { _solidlyVolatile(ref653); }
    function test_G52R_SolidlyVolatile_SameAsPruning1027() public { _solidlyVolatile(refPoda); }

    // ─── Solidly, stable, 18/18 ──────────────────────────────────────────────

    function _solidlyStable(address refSolver) internal {
        (address a, address b) = _pair18();
        _solidly(a, b, 1e24, 1e24, true);
        _same(refSolver, a, b, 1e18, true);
        _same(refSolver, b, a, 1e18, true);
    }
    function test_G52R_SolidlyStable_SameAs653() public { _solidlyStable(ref653); }
    function test_G52R_SolidlyStable_SameAsPruning1027() public { _solidlyStable(refPoda); }

    // ─── Solidly, volatile, 6/18 ─────────────────────────────────────────────

    function _solidlySixEighteen(address refSolver) internal {
        (address six, address eighteen) = _pair6x18();
        _solidly(six, eighteen, 1e12, 1e24, false);
        _same(refSolver, six, eighteen, 1e6, true);
        _same(refSolver, eighteen, six, 1e18, true);
    }
    function test_G52R_SolidlySixEighteen_SameAs653() public { _solidlySixEighteen(ref653); }
    function test_G52R_SolidlySixEighteen_SameAsPruning1027() public { _solidlySixEighteen(refPoda); }

    // ─── V2, 6/18 ────────────────────────────────────────────────────────────

    function _v2SixEighteen(address refSolver) internal {
        (address six, address eighteen) = _pair6x18();
        _v2(six, eighteen, 1e12, 1e24);
        _same(refSolver, six, eighteen, 1e6, true);
        _same(refSolver, eighteen, six, 1e18, true);
        _same(refSolver, six, eighteen, 1, false);
        _same(refSolver, eighteen, six, 1, false);
    }
    function test_G52R_V2SixEighteen_SameAs653() public { _v2SixEighteen(ref653); }
    function test_G52R_V2SixEighteen_SameAsPruning1027() public { _v2SixEighteen(refPoda); }

    // ─── Algebra, live fee, 18/18 ────────────────────────────────────────────

    function _algebraLiveFee(address refSolver) internal {
        (address a, address b) = _pair18();
        _algebra(a, b, 500, 1_000_000e18);
        _same(refSolver, a, b, 1e18, true);
        _same(refSolver, b, a, 1e18, true);
    }
    function test_G52R_AlgebraLiveFee_SameAs653() public { _algebraLiveFee(ref653); }
    function test_G52R_AlgebraLiveFee_SameAsPruning1027() public { _algebraLiveFee(refPoda); }

    // ─── the ends of the amount's domain ─────────────────────────────────────

    function _extremesV2(address refSolver) internal {
        (address a, address b) = _pair18();
        _v2(a, b, 1e24, 1e24);
        _extremes(refSolver, a, b);
    }
    function test_G52R_ExtremesV2_SameAs653() public { _extremesV2(ref653); }
    function test_G52R_ExtremesV2_SameAsPruning1027() public { _extremesV2(refPoda); }

    function _extremesSolidly(address refSolver) internal {
        (address a, address b) = _pair18();
        _solidly(a, b, 1e24, 1e24, false);
        _extremes(refSolver, a, b);
    }
    function test_G52R_ExtremesSolidly_SameAs653() public { _extremesSolidly(ref653); }
    function test_G52R_ExtremesSolidly_SameAsPruning1027() public { _extremesSolidly(refPoda); }
}
