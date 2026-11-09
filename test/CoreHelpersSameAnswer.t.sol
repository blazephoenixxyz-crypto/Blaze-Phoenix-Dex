// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  Five helpers of the Core left its dispatcher; this is the proof they still
//  say what they said.
//
//  `solidlyGetAmountOut`, `outSolidly`, `solidlyCurveOut`, `readDynamicFee` and
//  `impactV3FromOut` were doors of the library (`public`) up to cb1d7d9. No
//  contract in src/ ever called them through the dispatcher: the Core reaches
//  four of them with a jump, and the fifth (`outSolidly`) has no caller outside
//  the suite. As doors they cost the Core their five dispatcher rows and five
//  ABI wrappers, and the doors behind them 22 to 88 gas a call (measured). They
//  are `internal` now. A visibility word is not supposed to move an answer,
//  and "not supposed to" is the sentence this repository does not accept
//  unmeasured.
//
//  THE MEASUREMENT. `test/morf/CoreHelpersRef.sol` holds the five bodies as
//  cb1d7d9 wrote them, frozen. Two harnesses expose the same five signatures:
//  one over the live Core, one over the frozen copy. Every case sends the SAME
//  calldata to both by staticcall and compares the two outcomes whole - whether
//  the call returned, and every byte it returned or reverted with. So an equal
//  figure, an equal rounding direction and an equal refusal are one assertion,
//  and none of them is read through the code under test.
//
//  RANGES. Each fuzzed magnitude is drawn from four gauges - dust (0..3 wei),
//  a trade-sized figure, the top of the word (max - 0..3) and the word as
//  drawn - and each fee from the edges the code branches on (0, 1, 30, the V2
//  ceiling and one above it, BPS - 1, BPS) or raw. `test_Edges_...` then walks
//  the boundaries one wei either side, with no fuzzer between it and the edge.
//
//  VECTORS. The helpers ask a pool, its factory and its tokens. Here each of
//  those is an `Answerer`: per selector it reverts, answers one word, answers
//  31 bytes, answers two words, or answers a word that depends on every byte of
//  the calldata it was asked with (so a helper that asks with one wei more, or
//  the other token, is seen). A factory() that is zero, has no code, or is not
//  an address; a getFee of 0, 1, BPS - 1, BPS, BPS + 1; decimals from 0 to 255.
//
//  WHAT THIS DOES NOT SAY. That the curve is right - SolidlyReferenceQuote,
//  SolidlyStableDecimals and the n-version lane ask that. The reference shares
//  the live `outV2`, `mulDiv`, `outSolidlyStable` and token getters by design.
//
//  RED BEFORE GREEN. Green at cb1d7d9 (the two sides are then the same source)
//  and green after the visibility change: that is the claim. A differential that
//  cannot go red compares a program with itself, so each test has the mutant
//  that turns it red. Five are registered in .github/scripts/mutants.py
//  (morf-CBP2-E2..E6).
//
//  THE SIXTH IS NOT, AND WHY IS A FACT ABOUT THE CORE. `outSolidly` has no
//  caller in src/. As a door it was at least in the Core's runtime; internal,
//  it is compiled into no contract that ships - only into the harnesses that
//  call it. Flip its curve arm (`if (!stable)` to `if (stable)`) and
//  `testFuzz_outSolidly_SameAnswer` goes red, but no shipped artefact moves,
//  and the mutation guard discards a verdict on bytecode that did not change.
//  So that test guards the source the suite and the n-version probe read, not
//  a deployed byte. Whether `outSolidly` stays in the library is the owner's.
// =============================================================================
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {CoreHelpersRef as REF} from "./morf/CoreHelpersRef.sol";

interface IFiveHelpers {
    function solidlyGetAmountOut(address pool, uint256 amountIn, address tokenIn) external view returns (uint256);
    function outSolidly(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, bool stable) external pure returns (uint256);
    function solidlyCurveOut(
        address pool, uint256 ain, uint256 rIn, uint256 rOut, bool stable, uint256 cfgFee, address tokenIn
    ) external view returns (uint256);
    function readDynamicFee(address pool, bool stable, uint256 cfgFee) external view returns (uint256);
    function impactV3FromOut(uint256 out, uint256 amountIn, uint160 sqrtP, bool zeroForOne) external pure returns (uint256);
}

/// @dev The five as the Core holds them today.
contract LiveFive is IFiveHelpers {
    function solidlyGetAmountOut(address pool, uint256 amountIn, address tokenIn) external view returns (uint256) {
        return BPC.solidlyGetAmountOut(pool, amountIn, tokenIn);
    }
    function outSolidly(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, bool stable) external pure returns (uint256) {
        return BPC.outSolidly(ain, rIn, rOut, fee, stable);
    }
    function solidlyCurveOut(
        address pool, uint256 ain, uint256 rIn, uint256 rOut, bool stable, uint256 cfgFee, address tokenIn
    ) external view returns (uint256) {
        return BPC.solidlyCurveOut(pool, ain, rIn, rOut, stable, cfgFee, tokenIn);
    }
    function readDynamicFee(address pool, bool stable, uint256 cfgFee) external view returns (uint256) {
        return BPC.readDynamicFee(pool, stable, cfgFee);
    }
    function impactV3FromOut(uint256 out, uint256 amountIn, uint160 sqrtP, bool zeroForOne) external pure returns (uint256) {
        return BPC.impactV3FromOut(out, amountIn, sqrtP, zeroForOne);
    }
}

/// @dev The five as cb1d7d9 wrote them.
contract FrozenFive is IFiveHelpers {
    function solidlyGetAmountOut(address pool, uint256 amountIn, address tokenIn) external view returns (uint256) {
        return REF.solidlyGetAmountOut(pool, amountIn, tokenIn);
    }
    function outSolidly(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, bool stable) external pure returns (uint256) {
        return REF.outSolidly(ain, rIn, rOut, fee, stable);
    }
    function solidlyCurveOut(
        address pool, uint256 ain, uint256 rIn, uint256 rOut, bool stable, uint256 cfgFee, address tokenIn
    ) external view returns (uint256) {
        return REF.solidlyCurveOut(pool, ain, rIn, rOut, stable, cfgFee, tokenIn);
    }
    function readDynamicFee(address pool, bool stable, uint256 cfgFee) external view returns (uint256) {
        return REF.readDynamicFee(pool, stable, cfgFee);
    }
    function impactV3FromOut(uint256 out, uint256 amountIn, uint160 sqrtP, bool zeroForOne) external pure returns (uint256) {
        return REF.impactV3FromOut(out, amountIn, sqrtP, zeroForOne);
    }
}

uint8 constant ABSENT = 0; // the selector reverts
uint8 constant WORD   = 1; // one word
uint8 constant SHORT  = 2; // 31 bytes: one short of a word
uint8 constant ECHO   = 3; // one word that depends on every byte of the calldata
uint8 constant LONG   = 4; // two words

/// @dev A pool, a factory or a token that answers each selector the way it was programmed to.
contract Answerer {
    struct Answer { uint8 mode; uint256 word; }
    mapping(bytes4 => Answer) internal answers;

    function program(bytes4 sel, uint8 mode, uint256 word) external {
        answers[sel] = Answer(mode, word);
    }

    fallback() external {
        Answer memory a = answers[msg.sig];
        if (a.mode == ABSENT) revert();
        uint256 w = a.mode == ECHO ? a.word ^ uint256(keccak256(msg.data)) : a.word;
        uint256 n = a.mode == SHORT ? 31 : a.mode == LONG ? 64 : 32;
        assembly {
            mstore(0x00, w)
            mstore(0x20, w)
            return(0x00, n)
        }
    }
}

contract CoreHelpersSameAnswerTest is Test {
    bytes4 constant TOTAL_FEE_ASK = 0x0ea099c1; // getAmountOutWithTotalFee(uint256,address), as the Core writes it
    bytes4 constant PLAIN_ASK     = 0xf140a35a; // getAmountOut(uint256,address), as the Core writes it
    bytes4 constant FACTORY  = bytes4(keccak256("factory()"));
    bytes4 constant GET_FEE  = bytes4(keccak256("getFee(address,bool)"));
    bytes4 constant TOKEN0   = bytes4(keccak256("token0()"));
    bytes4 constant TOKEN1   = bytes4(keccak256("token1()"));
    bytes4 constant DECIMALS = bytes4(keccak256("decimals()"));

    IFiveHelpers live;
    IFiveHelpers frozen;
    Answerer pool;
    Answerer fac;
    Answerer t0;
    Answerer t1;

    function setUp() public {
        live = new LiveFive();
        frozen = new FrozenFive();
        pool = new Answerer();
        fac = new Answerer();
        t0 = new Answerer();
        t1 = new Answerer();
    }

    // ─── the one assertion ───────────────────────────────────────────────────

    /// The same calldata to both; the outcomes compared whole. Returns the live outcome so an
    /// edge case can also say that what was compared was an answer and not two empty refusals.
    function _same(bytes memory cd, string memory what) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(live).staticcall(cd);
        (bool okF, bytes memory retF) = address(frozen).staticcall(cd);
        assertEq(ok, okF, string.concat(what, ": one of the two refuses what the other answers"));
        assertEq(ret, retF, string.concat(what, ": the live helper and the frozen one disagree"));
    }

    function _word(bytes memory cd, string memory what) private view returns (uint256) {
        (bool ok, bytes memory ret) = _same(cd, what);
        assertTrue(ok && ret.length == 32, string.concat(what, ": the edge case was meant to be answered, and was refused"));
        return abi.decode(ret, (uint256));
    }

    // ─── gauges ──────────────────────────────────────────────────────────────

    /// One magnitude for a fuzzed word: dust, the top of the domain, the word as drawn, or
    /// (five draws in eight) a trade-sized figure.
    function _gauge(uint256 x, uint256 pick) private pure returns (uint256) {
        pick %= 8;
        if (pick == 0) return x % 4;
        if (pick == 1) return type(uint256).max - (x % 4);
        if (pick == 2) return x;
        return bound(x, 1e6, 1e30);
    }

    /// A fee at one of the edges the helpers branch on, or as drawn.
    function _fee(uint256 x, uint256 pick) private pure returns (uint256) {
        pick %= 8;
        if (pick == 0) return 0;
        if (pick == 1) return 1;
        if (pick == 2) return 30;
        if (pick == 3) return BPC.V2_FEE_CEILING_BPS;
        if (pick == 4) return uint256(BPC.V2_FEE_CEILING_BPS) + 1;
        if (pick == 5) return BPC.BPS - 1;
        if (pick == 6) return BPC.BPS;
        return x;
    }

    // ─── worlds ──────────────────────────────────────────────────────────────

    /// What the pool says its factory is, and what that factory says the fee is.
    function _programFee(uint256 seed) private {
        uint256 shape = seed % 8;
        uint256 origin = shape == 0 ? 0                                      // address(0)
            : shape == 1 ? uint256(uint160(address(fac))) | (1 << 160)      // a word that is not an address
            : shape == 2 ? uint256(uint160(address(0xBEEF)))                // an address with no code behind it
            : uint256(uint160(address(fac)));
        pool.program(FACTORY, shape == 3 ? ABSENT : shape == 4 ? SHORT : shape == 5 ? LONG : WORD, origin);
        uint256 f = (seed >> 8) % 8;
        uint256 fee = f == 0 ? 0 : f == 1 ? 1 : f == 2 ? BPC.BPS - 1 : f == 3 ? BPC.BPS : f == 4 ? BPC.BPS + 1
            : f == 5 ? seed >> 32 : bound(seed >> 32, 1, BPC.BPS - 1);
        uint256 m = (seed >> 16) % 8;
        fac.program(GET_FEE, m == 0 ? ABSENT : m == 1 ? SHORT : m == 2 ? ECHO : m == 3 ? LONG : WORD, fee);
    }

    function _decimals(uint256 s) private pure returns (uint256) {
        s %= 8;
        return s == 0 ? 0 : s == 1 ? 8 : s == 2 ? 24 : s == 3 ? 77 : s == 4 ? 78 : s == 5 ? 255 : s == 6 ? 6 : 18;
    }

    function _decimalsMode(uint256 s) private pure returns (uint8) {
        s %= 16;
        return s == 0 ? ABSENT : s == 1 ? SHORT : s == 2 ? LONG : WORD;
    }

    /// What the pool says its two tokens are, and what each says its decimals are.
    function _programTokens(uint256 seed) private {
        pool.program(TOKEN0, seed % 16 == 0 ? ABSENT : WORD, uint256(uint160(address(t0))));
        pool.program(TOKEN1, (seed >> 4) % 16 == 0 ? ABSENT : WORD, uint256(uint160(address(t1))));
        t0.program(DECIMALS, _decimalsMode(seed >> 8), _decimals(seed >> 16));
        t1.program(DECIMALS, _decimalsMode(seed >> 24), _decimals(seed >> 32));
    }

    // ─── fuzz: one differential per helper ───────────────────────────────────

    function testFuzz_outSolidly_SameAnswer(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, bool stable, uint256 picks
    ) public view {
        ain = _gauge(ain, picks);
        rIn = _gauge(rIn, picks >> 3);
        rOut = _gauge(rOut, picks >> 6);
        fee = _fee(fee, picks >> 9);
        _same(abi.encodeCall(IFiveHelpers.outSolidly, (ain, rIn, rOut, fee, stable)), "outSolidly");
    }

    function testFuzz_impactV3FromOut_SameAnswer(
        uint256 out, uint256 amountIn, uint160 sqrtP, bool zeroForOne, uint256 picks
    ) public view {
        if (picks % 4 == 0) {
            out = _gauge(out, picks >> 2);
            amountIn = _gauge(amountIn, picks >> 5);
        } else {
            // A figure near what the price pays, so the ratio lands inside (0, BPS] and one step
            // over it: the arm a random word almost never reaches.
            amountIn = bound(amountIn, 1, 1e30);
            sqrtP = uint160(bound(sqrtP, 1 << 64, 1 << 128));
            uint256 fair = zeroForOne
                ? BPC.mulDiv(BPC.mulDiv(amountIn, sqrtP, BPC.Q96), sqrtP, BPC.Q96)
                : BPC.mulDiv(BPC.mulDiv(amountIn, BPC.Q96, sqrtP), BPC.Q96, sqrtP);
            out = BPC.mulDiv(fair, bound(out, 0, BPC.BPS + 1), BPC.BPS);
        }
        _same(abi.encodeCall(IFiveHelpers.impactV3FromOut, (out, amountIn, sqrtP, zeroForOne)), "impactV3FromOut");
    }

    function testFuzz_readDynamicFee_SameAnswer(uint256 seed, bool stable, uint256 cfgFee) public {
        _programFee(seed);
        cfgFee = _fee(cfgFee, seed >> 24);
        _same(abi.encodeCall(IFiveHelpers.readDynamicFee, (address(pool), stable, cfgFee)), "readDynamicFee");
    }

    function testFuzz_solidlyGetAmountOut_SameAnswer(uint256 seed, uint256 amountIn, address tokenIn, uint256 word) public {
        pool.program(TOTAL_FEE_ASK, uint8(seed % 5), word);
        pool.program(PLAIN_ASK, uint8((seed >> 8) % 5), ~word);
        _same(abi.encodeCall(IFiveHelpers.solidlyGetAmountOut, (address(pool), amountIn, tokenIn)), "solidlyGetAmountOut");
    }

    function testFuzz_solidlyCurveOut_SameAnswer(
        uint256 seed, uint256 ain, uint256 rIn, uint256 rOut, bool stable, uint256 cfgFee, uint256 picks
    ) public {
        _programFee(seed);
        _programTokens(seed >> 64);
        ain = _gauge(ain, picks);
        rIn = _gauge(rIn, picks >> 3);
        rOut = _gauge(rOut, picks >> 6);
        cfgFee = _fee(cfgFee, picks >> 9);
        uint256 who = (picks >> 12) % 4;
        address tokenIn = who == 0 ? address(t1) : who == 1 ? address(0xC0FFEE) : address(t0);
        _same(
            abi.encodeCall(IFiveHelpers.solidlyCurveOut, (address(pool), ain, rIn, rOut, stable, cfgFee, tokenIn)),
            "solidlyCurveOut"
        );
    }

    // ─── edges: one wei either side of every boundary, no fuzzer in between ──

    function test_Edges_EveryHelperAtItsBoundariesAnswersAsItDid() public {
        _edgesOutSolidly();
        _edgesImpact();
        _edgesFee();
        _edgesAsk();
        _edgesCurve();
    }

    /// Every magnitude at 0, 1, 2, a unit and the top two words; every fee edge; both curves.
    function _edgesOutSolidly() private view {
        uint256[6] memory mags = [uint256(0), 1, 2, 1e18, type(uint256).max - 1, type(uint256).max];
        uint256[5] memory fees = [uint256(0), 1, BPC.BPS - 1, BPC.BPS, BPC.BPS + 1];
        for (uint256 a; a < 6; ++a) for (uint256 b; b < 6; ++b) for (uint256 c; c < 6; ++c) for (uint256 f; f < 5; ++f) {
            _same(abi.encodeCall(IFiveHelpers.outSolidly, (mags[a], mags[b], mags[c], fees[f], false)), "outSolidly edge, volatile");
            _same(abi.encodeCall(IFiveHelpers.outSolidly, (mags[a], mags[b], mags[c], fees[f], true)), "outSolidly edge, stable");
        }
        // What was compared is an answer: a unit into a balanced thousand pays under a unit on both
        // curves, and the stable curve at 5 bps pays more than the volatile one at 30.
        uint256 v = _word(abi.encodeCall(IFiveHelpers.outSolidly, (1e18, 1_000e18, 1_000e18, 30, false)), "outSolidly, volatile");
        uint256 s = _word(abi.encodeCall(IFiveHelpers.outSolidly, (1e18, 1_000e18, 1_000e18, 5, true)), "outSolidly, stable");
        assertTrue(v > 0 && v < s && s < 1e18, "outSolidly: the balanced-pool case answered nothing a curve would");
    }

    /// Every zero arm, the price at and around 1.0, the top of each word; both directions.
    function _edgesImpact() private view {
        uint160[6] memory prices = [uint160(0), 1, uint160(BPC.Q96 - 1), uint160(BPC.Q96), uint160(BPC.Q96 + 1), type(uint160).max];
        uint256[5] memory amts = [uint256(0), 1, 2, 1e18, type(uint256).max];
        for (uint256 a; a < 5; ++a) for (uint256 b; b < 5; ++b) for (uint256 p; p < 6; ++p) {
            _same(abi.encodeCall(IFiveHelpers.impactV3FromOut, (amts[a], amts[b], prices[p], true)), "impactV3FromOut edge, zeroForOne");
            _same(abi.encodeCall(IFiveHelpers.impactV3FromOut, (amts[a], amts[b], prices[p], false)), "impactV3FromOut edge, oneForZero");
        }
        // At price 1.0 (sqrtP = Q96) half a unit out per unit in is exactly 5 000 bps of the price,
        // in either direction: out * Q96 / in = 2^95 with no remainder. One wei less out and the
        // ratio rounds DOWN to 4 999, so the impact rounds UP to 5 001 - against the caller. A full
        // unit out is no impact at all.
        uint160 one = uint160(BPC.Q96);
        assertEq(_word(abi.encodeCall(IFiveHelpers.impactV3FromOut, (0.5e18, 1e18, one, true)), "impact, half"), 5_000);
        assertEq(_word(abi.encodeCall(IFiveHelpers.impactV3FromOut, (0.5e18, 1e18, one, false)), "impact, half"), 5_000);
        assertEq(_word(abi.encodeCall(IFiveHelpers.impactV3FromOut, (0.5e18 - 1, 1e18, one, true)), "impact, a wei under half"), 5_001);
        assertEq(_word(abi.encodeCall(IFiveHelpers.impactV3FromOut, (1e18, 1e18, one, true)), "impact, par"), 0);
    }

    /// The factory's fee is taken strictly inside (0, BPS); at either end the declared fee stands,
    /// and the declared fee stands only inside (0, ceiling], else 30.
    function _edgesFee() private {
        uint256 ceil = BPC.V2_FEE_CEILING_BPS;
        pool.program(FACTORY, WORD, uint256(uint160(address(fac))));
        uint256[5] memory asked = [uint256(0), 1, BPC.BPS - 1, BPC.BPS, BPC.BPS + 1];
        uint256[5] memory cfgs = [uint256(0), 1, ceil, ceil + 1, BPC.BPS];
        for (uint256 i; i < 5; ++i) for (uint256 j; j < 5; ++j) {
            fac.program(GET_FEE, WORD, asked[i]);
            uint256 declared = (cfgs[j] == 0 || cfgs[j] > ceil) ? 30 : cfgs[j];
            uint256 want = (asked[i] > 0 && asked[i] < BPC.BPS) ? asked[i] : declared;
            assertEq(_word(abi.encodeCall(IFiveHelpers.readDynamicFee, (address(pool), false, cfgs[j])), "readDynamicFee edge"), want,
                "readDynamicFee: the fee at a boundary is not the one the rule names");
            _same(abi.encodeCall(IFiveHelpers.readDynamicFee, (address(pool), true, cfgs[j])), "readDynamicFee edge, stable");
        }
    }

    /// The total-fee ask wins; the plain ask answers only when that one fails; neither is 0.
    function _edgesAsk() private {
        bytes memory cd = abi.encodeCall(IFiveHelpers.solidlyGetAmountOut, (address(pool), 1e18, address(t0)));
        pool.program(TOTAL_FEE_ASK, WORD, 777);
        pool.program(PLAIN_ASK, WORD, 555);
        assertEq(_word(cd, "ask, both selectors"), 777);
        pool.program(TOTAL_FEE_ASK, SHORT, 777);
        assertEq(_word(cd, "ask, plain selector only"), 555);
        pool.program(PLAIN_ASK, ABSENT, 555);
        assertEq(_word(cd, "ask, neither selector"), 0);
    }

    /// A stable pair of an 18- and a 6-decimal token, balanced at a thousand each. A unit of either
    /// pays just under a unit of the other, in the OTHER token's scale: the decimals are read from
    /// the pool's own tokens, so the two directions differ by twelve digits.
    function _edgesCurve() private {
        pool.program(FACTORY, WORD, uint256(uint160(address(fac))));
        fac.program(GET_FEE, WORD, 5);
        pool.program(TOKEN0, WORD, uint256(uint160(address(t0))));
        pool.program(TOKEN1, WORD, uint256(uint160(address(t1))));
        t0.program(DECIMALS, WORD, 18);
        t1.program(DECIMALS, WORD, 6);
        uint256 into6 = _word(abi.encodeCall(IFiveHelpers.solidlyCurveOut,
            (address(pool), 1e18, 1_000e18, 1_000e6, true, 0, address(t0))), "curve, 18 into 6");
        uint256 into18 = _word(abi.encodeCall(IFiveHelpers.solidlyCurveOut,
            (address(pool), 1e6, 1_000e6, 1_000e18, true, 0, address(t1))), "curve, 6 into 18");
        assertTrue(into6 > 0.99e6 && into6 < 1e6, "solidlyCurveOut: a unit of the 18-decimal token did not pay just under a unit of the 6-decimal one");
        assertTrue(into18 > 0.99e18 && into18 < 1e18, "solidlyCurveOut: a unit of the 6-decimal token did not pay just under a unit of the 18-decimal one");
        _same(abi.encodeCall(IFiveHelpers.solidlyCurveOut, (address(pool), 1e18, 1_000e18, 1_000e6, false, 0, address(t0))), "curve, volatile");
    }
}
