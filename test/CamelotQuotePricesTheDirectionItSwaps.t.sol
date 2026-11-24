// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// An Algebra 1.9 pool (Camelot shape) keeps one fee per direction in globalState():
//   word 2 = feeZto (token0 -> token1), word 3 = feeOtz (token1 -> token0).
// It has no fee() getter, so the quote falls back to the word. A swap one-for-zero pays
// feeOtz; the quote must price the word of the direction it swaps, never word 2 for both.
//
// Source: Camelot's verified pool (Arbitrum 0xB1026b8e7276e7AC75410F1fcbbe21796e8f7526,
// Sourcify full match) contracts/base/PoolState.sol:8-12 (struct GlobalState: price, tick,
// feeZto, feeOtz, timepointIndex, ...) and contracts/AlgebraPool.sol:739
// (`cache.fee = zeroToOne ? globalState.feeZto : globalState.feeOtz`).
//
// Ranges: fees far apart (100 vs 3000), adjacent (+-1), equal (control), fuzzed pair.
// Vectors: pool with a direction-split fee; the leg's calldata fee is a lie the producer must
// not read; seven- and six-word answers (Algebra v1, Integral) whose word 3 is not a fee.
// Dimensions: unit (rank door, leg door), fuzz. The Solver door is in FloorParityAlgebraLeg.t.sol.
// Red before 70295f7's successor: the producer read word 2 for both directions
// (BlazePhoenixCore.v3StateAndDynFee, `f := and(mload(add(m, 0x40)), 0xffffff)`).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx, Leg} from "../src/BlazePhoenixCore.sol";

/// @dev Algebra 1.9 shape: eight-word globalState() with a fee per direction, no fee().
contract CamelotDirectionalPoolMock {
    uint160 internal immutable price;
    uint16 internal immutable feeZto;
    uint16 internal immutable feeOtz;
    uint128 public immutable liquidity;
    address public immutable token0;
    address public immutable token1;

    constructor(uint160 p, uint16 zto, uint16 otz, uint128 liq, address a, address b) {
        price = p; feeZto = zto; feeOtz = otz; liquidity = liq; token0 = a; token1 = b;
    }

    function globalState() external view returns (uint160, int24, uint16, uint16, uint16, uint8, uint8, bool) {
        return (price, 0, feeZto, feeOtz, 0, 0, 0, true);
    }
}

/// @dev Algebra v1 shape: seven words, word 3 = timepointIndex (not a fee), no fee().
contract AlgebraV1SevenWordPoolMock {
    uint160 internal immutable price;
    uint16 internal immutable fee;
    uint16 internal immutable timepointIndex;

    constructor(uint160 p, uint16 f, uint16 idx) { price = p; fee = f; timepointIndex = idx; }

    function liquidity() external pure returns (uint128) { return 1e21; }

    function globalState() external view returns (uint160, int24, uint16, uint16, uint8, uint8, bool) {
        return (price, 0, fee, timepointIndex, 0, 0, true);
    }
}

/// @dev Integral shape without fee(): six words, word 3 = pluginConfig (not a fee).
contract IntegralSixWordPoolMock {
    uint160 internal immutable price;
    uint16 internal immutable lastFee;
    uint8 internal immutable pluginConfig;

    constructor(uint160 p, uint16 f, uint8 cfg) { price = p; lastFee = f; pluginConfig = cfg; }

    function liquidity() external pure returns (uint128) { return 1e21; }

    function globalState() external view returns (uint160, int24, uint16, uint8, uint16, bool) {
        return (price, 0, lastFee, pluginConfig, 0, true);
    }
}

contract CamelotQuotePricesTheDirectionItSwapsTest is Test {
    address constant TOKEN0 = address(0xA11CE);
    address constant TOKEN1 = address(0xB0B);

    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint128 constant LIQ = 1e21;
    uint256 constant AMOUNT_IN = 1e18;

    uint16 constant ZTO = 100;
    uint16 constant OTZ = 3_000;

    function _pool(uint16 zto, uint16 otz) internal returns (address) {
        return address(new CamelotDirectionalPoolMock(SQRT_1_1, zto, otz, LIQ, TOKEN0, TOKEN1));
    }

    /// @dev The twin: both words equal, so the direction cannot change the fee it prices.
    function _twin(uint16 f) internal returns (address) { return _pool(f, f); }

    function _rank(address pool, bool zeroForOne) internal view returns (uint256 out) {
        QuoteCtx memory c;
        c.pool = pool;
        c.kind = BPC.KIND_ALGEBRA;
        c.tokenIn = zeroForOne ? TOKEN0 : TOKEN1;
        c.tokenOther = zeroForOne ? TOKEN1 : TOKEN0;
        c.fee = 0; // the Hub forces the 0 sentinel on every Algebra row
        c.zeroForOne = zeroForOne;
        (out,,,) = BPC.universalQuoteRank(c, AMOUNT_IN, type(uint256).max, false);
    }

    /// @dev The Router's own call for a leg, made from here (`Leg` is calldata there).
    function legQuote(Leg calldata leg, address tIn, address tOut, uint256 amt) external view returns (uint256 q) {
        (q,,) = BPC.legQuoteImpact(leg, tIn, tOut, amt);
    }

    function _legQuote(address pool, bool zeroForOne) internal view returns (uint256) {
        Leg memory leg;
        leg.pool = pool;
        leg.kind = BPC.KIND_ALGEBRA;
        leg.zeroForOne = zeroForOne;
        leg.fee = 100; // calldata's fee: a lie the producer must not read
        return zeroForOne
            ? this.legQuote(leg, TOKEN0, TOKEN1, AMOUNT_IN)
            : this.legQuote(leg, TOKEN1, TOKEN0, AMOUNT_IN);
    }

    function _assertRankAs(address pool, bool zeroForOne, uint16 charged, uint16 notCharged) internal {
        uint256 q = _rank(pool, zeroForOne);
        assertGt(q, 0, "precondition: the pool quotes");
        assertEq(q, _rank(_twin(charged), zeroForOne), "quoted as the twin at the fee this direction pays");
        assertTrue(q != _rank(_twin(notCharged), zeroForOne), "and apart from the twin at the other direction's fee");
    }

    // ------------------------------------------------------------------ control (green today)

    /// zero-for-one pays word 2: the word read today. Green before and after the fix.
    function test_ZeroForOnePricesFeeZto() public {
        _assertRankAs(_pool(ZTO, OTZ), true, ZTO, OTZ);
    }

    /// Equal words: the direction cannot matter.
    function test_EqualWordsPriceAlikeBothWays() public {
        address p = _pool(OTZ, OTZ);
        assertEq(_rank(p, false), _rank(_twin(OTZ), false), "one-for-zero");
        assertEq(_rank(p, true), _rank(_twin(OTZ), true), "zero-for-one");
    }

    // ------------------------------------------------------------------ the defect (red today)

    /// one-for-zero pays word 3 (feeOtz, 30x word 2 here); the quote priced word 2.
    function test_OneForZeroPricesFeeOtz() public {
        _assertRankAs(_pool(ZTO, OTZ), false, OTZ, ZTO);
    }

    /// The cheaper direction the other way round: the quote promised less than it pays.
    function test_OneForZeroPricesFeeOtzWhenItIsTheLowerFee() public {
        _assertRankAs(_pool(OTZ, ZTO), false, ZTO, OTZ);
    }

    /// +-1 pip apart still prices the right word.
    function test_OneForZeroPricesFeeOtzOnePipApart() public {
        _assertRankAs(_pool(OTZ, OTZ + 1), false, OTZ + 1, OTZ);
    }

    /// The leg door (Router's per-leg floor) reads the same word as the rank door.
    function test_TheLegDoorPricesFeeOtzOneForZero() public {
        address p = _pool(ZTO, OTZ);
        uint256 q = _legQuote(p, false);
        assertGt(q, 0, "precondition: the leg quotes");
        assertEq(q, _legQuote(_twin(OTZ), false), "leg quoted at the fee one-for-zero pays");
    }

    // ------------------------------------------------------------------ the identity (size of the answer)

    /// Algebra v1 answers seven words; word 3 is timepointIndex. Both directions keep word 2.
    function test_SevenWordAnswerKeepsWord2OneForZero() public {
        address p = address(new AlgebraV1SevenWordPoolMock(SQRT_1_1, OTZ, ZTO));
        assertGt(_rank(p, false), 0, "precondition: the pool quotes");
        assertEq(_rank(p, false), _rank(_twin(OTZ), false), "one-for-zero priced at word 2, not timepointIndex");
        assertEq(_rank(p, true), _rank(_twin(OTZ), true), "zero-for-one priced at word 2");
    }

    /// Integral without fee() answers six words; word 3 is pluginConfig. Both directions keep word 2.
    function test_SixWordAnswerKeepsWord2OneForZero() public {
        address p = address(new IntegralSixWordPoolMock(SQRT_1_1, OTZ, 0xC1));
        assertGt(_rank(p, false), 0, "precondition: the pool quotes");
        assertEq(_rank(p, false), _rank(_twin(OTZ), false), "one-for-zero priced at word 2, not pluginConfig");
        assertEq(_rank(p, true), _rank(_twin(OTZ), true), "zero-for-one priced at word 2");
    }

    /// Any distinct pair: one-for-zero is quoted as the twin at feeOtz.
    function testFuzz_OneForZeroIsQuotedAtFeeOtz(uint16 zto, uint16 otz) public {
        zto = uint16(bound(zto, 1, 60_000));
        otz = uint16(bound(otz, 1, 60_000));
        vm.assume(zto != otz);
        address p = _pool(zto, otz);
        uint256 q = _rank(p, false);
        vm.assume(q > 0);
        assertEq(q, _rank(_twin(otz), false), "one-for-zero priced at feeOtz");
    }
}
