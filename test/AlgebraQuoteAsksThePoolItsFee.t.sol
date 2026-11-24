// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ALGEBRA-QUOTE-ASKS-THE-POOL-ITS-FEE
//
//  RED at 6387350. `quoteV3Fee` never asked an Algebra-shaped pool for fee():
//  it priced word 2 of globalState(). On Algebra Integral that word is
//  `lastFee`, which a dynamic-fee plugin leaves stale; the swap pays what the
//  plugin answers and pool.fee() asks that same plugin. Measured on a fork in
//  test/fork/AlgebraQuotePricesTheFeeTheSwapPays.t.sol; this file holds the
//  same law with no RPC.
//
//  The law, one producer (`quoteV3Fee`), two consumers (the ranking quote and
//  the leg floor):
//    fee() answers inside its budget, not 0   -> that answer
//    fee() absent, reverting, 0, or over CL_FEE_TRUST -> the row key if it is
//                                                not 0, else word 2
//    the frame cannot fund the read          -> empty revert, never the word
//
//  The quote oracle is DIFFERENTIAL, not the code under test: a pool whose
//  word 2 is stale must quote exactly what a twin quotes whose word 2 and
//  fee() agree on the live fee, and strictly apart from a twin that agrees on
//  the stale one.
//
//  LIMIT, stated and not closed here: a fee() that reverts falls back to word
//  2, which on Integral is the optimistic direction whenever the plugin would
//  have charged more. The pool's own swap reverts with that same plugin, so
//  the quote prices a leg that cannot execute; it is not a wrong promise kept.
//
//  Red under (mutants.py): "hydrex-1124 D1" (Algebra is not asked) on every
//  test that names a stale word; DEX-17 [884] (the row key first) on
//  test_ACallerKeyNeverOutranksThePoolAnswer.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx, Leg} from "../src/BlazePhoenixCore.sol";

/// @dev Algebra Integral shape: no slot0(), globalState() of six words, and a fee() that asks
///      the plugin. `mode`: 0 answers `live`; 1 reverts, as fee() does when the plugin does;
///      2 spends the budget it was handed and then answers, a failure swallowed inside.
contract IntegralPoolMock {
    uint160 internal immutable price;
    uint16 internal immutable lastFee;
    uint16 internal immutable live;
    uint8 internal immutable mode;
    uint128 public immutable liquidity;
    address public immutable token0;
    address public immutable token1;

    constructor(uint160 p, uint16 word, uint16 l, uint8 m, uint128 liq, address a, address b) {
        price = p; lastFee = word; live = l; mode = m; liquidity = liq; token0 = a; token1 = b;
    }

    /// @dev pluginConfig 0xD5 carries the DYNAMIC_FEE bit (0x80), as the measured pools do.
    function globalState() external view returns (uint160, int24, uint16, uint8, uint16, bool) {
        return (price, 0, lastFee, 0xD5, 0, true);
    }

    function fee() external view returns (uint16) {
        if (mode == 1) revert("plugin");
        if (mode == 2) { while (gasleft() > 2_000) {} }
        return live;
    }
}

/// @dev Algebra 1.9 shape (Camelot): globalState() of eight words with a fee per direction, and
///      no fee() selector at all.
contract LegacyPoolMock {
    uint160 internal immutable price;
    uint16 internal immutable feeWord;
    uint128 public immutable liquidity;
    address public immutable token0;
    address public immutable token1;

    constructor(uint160 p, uint16 word, uint128 liq, address a, address b) {
        price = p; feeWord = word; liquidity = liq; token0 = a; token1 = b;
    }

    function globalState() external view returns (uint160, int24, uint16, uint16, uint16, uint8, uint8, bool) {
        return (price, 0, feeWord, feeWord, 0, 0, 0, true);
    }
}

contract AlgebraQuoteAsksThePoolItsFeeTest is Test {
    address constant TOKEN_A = address(0xA11CE);
    address constant TOKEN_B = address(0xB0B);

    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint128 constant LIQ = 1e21;
    uint256 constant AMOUNT_IN = 1e18;

    // The measured Hydrex pair of numbers: word 2 = 500 on a pool that charges 15000, and on
    // one that charges 50.
    uint16 constant STALE = 500;
    uint16 constant ABOVE = 15_000;
    uint16 constant BELOW = 50;

    function _integral(uint16 word, uint16 live, uint8 mode) internal returns (address) {
        return address(new IntegralPoolMock(SQRT_1_1, word, live, mode, LIQ, TOKEN_A, TOKEN_B));
    }

    /// @dev The twin: word 2 and fee() agree, so every version of the producer prices it alike.
    function _agreeing(uint16 f) internal returns (address) { return _integral(f, f, 0); }

    /// @dev External so a test can choose the gas of the frame the producer runs in.
    function priced(address pool, uint24 key) external view returns (uint24) {
        (, uint24 word, bool dyn) = BPC.v3StateAndDynFee(pool);
        return BPC.quoteV3Fee(pool, key, word, dyn);
    }

    function _rank(address pool) internal view returns (uint256 out) {
        QuoteCtx memory c;
        c.pool = pool;
        c.kind = BPC.KIND_ALGEBRA;
        c.tokenIn = TOKEN_A;
        c.tokenOther = TOKEN_B;
        c.fee = 0; // the Hub forces the 0 sentinel on every Algebra row
        c.zeroForOne = true;
        (out,,,) = BPC.universalQuoteRank(c, AMOUNT_IN, type(uint256).max, false);
    }

    /// @dev The Router's own call for a leg, made from here (`Leg` is calldata there).
    function legQuote(Leg calldata leg, uint256 amt) external view returns (uint256 q, uint256 imp) {
        (q, imp,) = BPC.legQuoteImpact(leg, TOKEN_A, TOKEN_B, amt);
    }

    function _leg(address pool) internal pure returns (Leg memory leg) {
        leg.pool = pool;
        leg.kind = BPC.KIND_ALGEBRA;
        leg.zeroForOne = true;
        leg.fee = 100; // calldata's fee: a lie the producer must not read
    }

    function _assertQuotesAs(address pool, uint16 feeCharged, uint16 feeNotCharged) internal {
        uint256 q = _rank(pool);
        assertGt(q, 0, "precondition: the pool quotes");
        assertEq(q, _rank(_agreeing(feeCharged)), "quoted as the twin that charges the live fee");
        assertTrue(q != _rank(_agreeing(feeNotCharged)), "and apart from the twin at the other fee");
    }

    // ------------------------------------------------------------------ the pool answers

    /// The defect: the plugin charges 30x the stale word and the quote priced the word.
    function test_AFeeAboveTheStaleWordIsTheFeePriced() public {
        address p = _integral(STALE, ABOVE, 0);
        assertEq(this.priced(p, 0), ABOVE, "the fee priced is the pool's answer");
        _assertQuotesAs(p, ABOVE, STALE);
        assertLt(_rank(p), _rank(_agreeing(STALE)), "a dearer pool quotes below the stale price");
    }

    /// The other direction of the same defect: the pool charges less and was under-ranked.
    function test_AFeeBelowTheStaleWordIsTheFeePriced() public {
        address p = _integral(STALE, BELOW, 0);
        assertEq(this.priced(p, 0), BELOW, "the fee priced is the pool's answer");
        _assertQuotesAs(p, BELOW, STALE);
        assertGt(_rank(p), _rank(_agreeing(STALE)), "a cheaper pool quotes above the stale price");
    }

    /// Lying caller: a row key cannot outrank a pool that answers, Algebra included.
    function test_ACallerKeyNeverOutranksThePoolAnswer() public {
        address p = _integral(STALE, ABOVE, 0);
        assertEq(this.priced(p, 100), ABOVE, "the pool before the key");
        assertEq(this.priced(p, 0xFFFFFE), ABOVE, "at any key");
    }

    /// The second consumer reads the same producer: the leg floor's quote and impact.
    function test_TheLegFloorReadsTheSameFee() public {
        (uint256 q, uint256 imp) = this.legQuote(_leg(_integral(STALE, ABOVE, 0)), AMOUNT_IN);
        (uint256 qLive, uint256 impLive) = this.legQuote(_leg(_agreeing(ABOVE)), AMOUNT_IN);
        (uint256 qStale,) = this.legQuote(_leg(_agreeing(STALE)), AMOUNT_IN);
        assertGt(q, 0, "precondition: the leg quotes");
        assertEq(q, qLive, "the leg is quoted at the live fee");
        assertEq(imp, impLive, "and its impact with it");
        assertLt(q, qStale, "below the stale price");
    }

    /// Every (word, answer) pair, both consumers: the answer wins, 0 hands over to the word.
    function testFuzz_TheAnswerWinsAndZeroHandsOverToTheWord(uint16 word, uint16 live) public {
        address p = _integral(word, live, 0);
        uint16 want = live != 0 ? live : word;
        assertEq(this.priced(p, 0), want, "fee priced");
        address twin = _agreeing(want);
        assertEq(_rank(p), _rank(twin), "ranking quote");
        (uint256 q,) = this.legQuote(_leg(p), AMOUNT_IN);
        (uint256 qTwin,) = this.legQuote(_leg(twin), AMOUNT_IN);
        assertEq(q, qTwin, "leg quote");
    }

    // ------------------------------------------------------------ the pool does not answer

    /// Algebra 1.9 has no fee(): word 2 answers, as before.
    function test_APoolWithNoFeeGetterKeepsItsWord() public {
        address p = address(new LegacyPoolMock(SQRT_1_1, 100, LIQ, TOKEN_A, TOKEN_B));
        assertEq(this.priced(p, 0), 100, "word 2 is the fee priced");
        _assertQuotesAs(p, 100, STALE);
    }

    /// A measured 0% on a pool with no fee() is still a fee, not a refusal.
    function test_AZeroWordOnAPoolWithNoFeeGetterStaysQuotable() public {
        address p = address(new LegacyPoolMock(SQRT_1_1, 0, LIQ, TOKEN_A, TOKEN_B));
        assertEq(this.priced(p, 0), 0, "0 is the fee priced, not 0xFFFFFF");
        assertGt(_rank(p), _rank(_agreeing(1)), "and it quotes above a 0.0001% twin");
    }

    /// fee() reverts when the plugin does: word 2 answers. The limit in the header.
    function test_AFeeGetterThatRevertsHandsOverToTheWord() public {
        address p = _integral(STALE, ABOVE, 1);
        assertEq(this.priced(p, 0), STALE, "word 2 is the fee priced");
        _assertQuotesAs(p, STALE, ABOVE);
    }

    /// Hostile pool: a fee() that spends CL_FEE_TRUST or more is not believed, whatever it says.
    function test_AFeeGetterThatSpendsItsBudgetIsNotBelieved() public {
        address p = _integral(STALE, 1, 2); // it would claim 0.0001%
        assertEq(this.priced(p, 0), STALE, "the costly answer is not taken; word 2 is");
    }

    /// The key still answers for a pool whose fee() does not, ahead of the word.
    function test_TheKeyAnswersBeforeTheWordWhenThePoolDoesNot() public {
        address p = address(new LegacyPoolMock(SQRT_1_1, 100, LIQ, TOKEN_A, TOKEN_B));
        assertEq(this.priced(p, 3000), 3000, "the key, then the word");
    }

    // ------------------------------------------------------------------- the read's budget

    /// The sender's gas never chooses the fee: over every frame size the producer reverts
    /// empty or prices the pool's answer. It never prices the stale word.
    function test_AStarvedFrameRevertsEmptyAndNeverPricesTheWord() public {
        address p = _integral(STALE, ABOVE, 0);
        bool sawRevert;
        bool sawFee;
        for (uint256 g = 100_000; g <= 300_000; g += 1_000) {
            vm.cool(p);
            (bool ok, bytes memory r) = address(this).call{gas: g}(abi.encodeCall(this.priced, (p, 0)));
            if (!ok) {
                assertEq(r.length, 0, "the refusal is the empty revert");
                sawRevert = true;
                continue;
            }
            assertEq(abi.decode(r, (uint24)), ABOVE, "a starved frame priced the stale word");
            sawFee = true;
        }
        assertTrue(sawRevert && sawFee, "both outcomes must be reached");
    }
}
