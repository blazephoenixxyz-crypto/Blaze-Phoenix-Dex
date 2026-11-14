// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Solidly stable solver (Newton on k = x^3 y + x y^3) exits on the safe side,
//  and one output wei from it.
//
//    _solY(x, K, y0): Newton seeded at the output reserve, at most 64 steps; on
//    convergence (|step| <= 1) it climbs y by one wei while k(x, y) < K, at most
//    twice, and otherwise refuses the pool (out = 0), so K_post >= K_pre.
//
//  1. SAFE SIDE. For every pool of at least one normalised unit per side, the
//     output the solver quotes leaves k(X + A', Y - out * sOut) >= k(X, Y), with A'
//     the input net of the fee: the curve is never asked for more than it holds.
//     The same holds for an input side thinner than one normalised unit.
//  2. ONE WEI. When out > 0, one more output wei breaks the invariant: the solver
//     did not stop early.
//  3. CONVERGENCE. A pool where the exit reserve is far below the seed (here more
//     than 400 times) needs ~22 Newton steps; a skewed pool quoted by an 8-step
//     solver would read as unpriceable (out = 0).
//  4. SHAPE GUARDS. An input that swamps the pool fires the step-halving guard;
//     an input side thinner than one normalised unit drives the safe-side climb.
//     Both are registered in .github/scripts/assurance/guard_inventory.py.
//
//  The oracle `_k` is the same cubic in the same 512-bit arithmetic: what is under
//  test is the Newton exit, not the invariant formula.
//
//  forge test --match-path test/SolidlyNewtonLandsOnTheSafeSide.t.sol
// =============================================================================
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract NewtonSideProbe {
    function stable(uint256 a, uint256 rIn, uint256 rOut, uint256 fee, uint8 dIn, uint8 dOut)
        external pure returns (uint256)
    {
        return BPC.outSolidlyStable(a, rIn, rOut, fee, dIn, dOut);
    }
}

contract SolidlyNewtonLandsOnTheSafeSideTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant CAP = 3.4e38;
    NewtonSideProbe internal p;

    function setUp() public { p = new NewtonSideProbe(); }

    function _k(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 a = BPC.mulDiv(x, y, WAD);
        uint256 b = BPC.mulDiv(x, x, WAD) + BPC.mulDiv(y, y, WAD);
        return BPC.mulDiv(a, b, WAD);
    }

    function _dec(uint8 s) internal pure returns (uint8) {
        uint8 m = s % 3;
        return m == 0 ? 0 : (m == 1 ? 6 : 18);
    }

    /// log-spread value in [lo, hi]: a uniform draw shifted right by up to 71 bits
    function _spread(uint256 seed, uint256 lo, uint256 hi) internal pure returns (uint256 v) {
        v = (seed >> 8) % (hi - lo + 1) + lo;
        v >>= uint8(seed) % 72;
        if (v < lo) v = lo;
    }

    struct Case { uint256 X; uint256 Y; uint256 Anet; uint256 sOut; uint256 out; }

    function _case(uint256 sx, uint256 sy, uint256 sa, uint16 fee, uint8 dInS, uint8 dOutS)
        internal view returns (Case memory c)
    {
        c = _case(sx, sy, sa, fee, dInS, dOutS, false);
    }

    function _case(uint256 sx, uint256 sy, uint256 sa, uint16 fee, uint8 dInS, uint8 dOutS, bool thin)
        internal view returns (Case memory c)
    {
        uint8 dIn = _dec(dInS);
        uint8 dOut = _dec(dOutS);
        uint256 sIn = 10 ** (18 - dIn);
        c.sOut = 10 ** (18 - dOut);
        uint256 f = uint256(fee) % BPS;
        // at least one normalised unit per side, at most the solver's own cap;
        // `thin`: an input side of one raw unit up to one normalised unit
        uint256 rIn = thin ? _spread(sx, sIn, WAD) / sIn : _spread(sx, WAD, CAP) / sIn;
        uint256 rOut = _spread(sy, thin ? c.sOut : WAD, CAP) / c.sOut;
        uint256 a = _spread(sa, 1, thin ? rIn * 100 : CAP / sIn);
        c.X = rIn * sIn;
        c.Y = rOut * c.sOut;
        c.Anet = (a * sIn * (BPS - f)) / BPS;
        c.out = p.stable(a, rIn, rOut, f, dIn, dOut);
    }

    function testFuzz_ExitIsOnTheSafeSide(uint256 sx, uint256 sy, uint256 sa, uint16 fee, uint8 dIn, uint8 dOut)
        public view
    {
        Case memory c = _case(sx, sy, sa, fee, dIn, dOut);
        if (c.out == 0) return; // a refused pool leaves the reserves where they are
        assertLt(c.out * c.sOut, c.Y, "the quote empties the output reserve");
        assertGe(_k(c.X + c.Anet, c.Y - c.out * c.sOut), _k(c.X, c.Y),
            "the quoted exit leaves k below the pre-trade invariant (unsafe side)");
    }

    function testFuzz_ExitIsWithinOneWei(uint256 sx, uint256 sy, uint256 sa, uint16 fee, uint8 dIn, uint8 dOut)
        public view
    {
        Case memory c = _case(sx, sy, sa, fee, dIn, dOut);
        if (c.out == 0) return;
        uint256 more = (c.out + 1) * c.sOut;
        if (more > c.Y) return; // one more wei would empty the side: trivially out of reach
        assertLt(_k(c.X + c.Anet, c.Y - more), _k(c.X, c.Y),
            "one more output wei still keeps the invariant: the solver stopped early");
    }

    function _assertExact(uint256 X, uint256 Y, uint256 A) internal view returns (uint256 out) {
        out = p.stable(A, X, Y, 0, 18, 18);
        assertGt(out, 0, "a priceable stable pool read as unpriceable (solver did not converge)");
        uint256 K = _k(X, Y);
        assertGe(_k(X + A, Y - out), K, "exit on the unsafe side");
        assertLt(_k(X + A, Y - out - 1), K, "exit more than one wei early");
    }

    /// The exit reserve is ~1/464 of the seed: ~22 Newton steps from Y.
    function test_SkewedPoolConverges() public view {
        uint256 out = _assertExact(1e18, 1e32, 1e26);
        assertGt(out, 1e32 - 1e32 / 400, "the exit reserve is not far below the seed");
    }

    /// A small trade on a deep output side: the step uses the derivative x(x^2 + 3y^2);
    /// a derivative that undercounts the y^2 term overshoots and never settles.
    function test_ShallowTradeOnADeepSideConverges() public view {
        _assertExact(30545263552104624128, 96734432524203579195296579584, 119956366142611);
    }

    /// An input a trillion times the pool: the first downward step from the seed would pass
    /// zero, so the solver halves it (`if (dy >= y) dy = y / 2`) and converges in two steps.
    /// The guard fires here; its mutant `dy = y` changes no exit in the sampled domain
    /// (registered as equivalent), so this pins the firing, not the choice of step.
    function test_InputThatSwampsThePoolHalvesTheStep() public view {
        uint256 out = _assertExact(1e18, 1e18, 1e30);
        assertEq(out, 1e18 - 1, "a swamping input drains all but one wei of the output side");
    }

    /// An input side below one normalised unit, where k(x, y) rises in y by steps of
    /// floor(x y) rather than by every wei: the exit lands on the safe side, one wei from it.
    function test_ThinInputSideExitsOnTheSafeSide() public view {
        _assertExact(1344847930647679, 66054715354194477056, 344694);
    }

    function testFuzz_ThinInputSideExitsOnTheSafeSide(
        uint256 sx, uint256 sy, uint256 sa, uint16 fee, uint8 dIn, uint8 dOut
    ) public view {
        Case memory c = _case(sx, sy, sa, fee, dIn, dOut, true);
        if (c.out == 0) return; // a refused pool leaves the reserves where they are
        assertLt(c.out * c.sOut, c.Y, "the quote empties the output reserve");
        assertGe(_k(c.X + c.Anet, c.Y - c.out * c.sOut), _k(c.X, c.Y),
            "the quoted exit leaves k below the pre-trade invariant (unsafe side)");
    }
}
