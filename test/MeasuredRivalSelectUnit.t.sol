// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title The measured rival, read on `BlazePhoenixMath.select` alone
/// @notice The band's upper edge drops a row on one hypothesis: it promises more than it pays.
///         `_measuredAbove` keeps the rows for which that hypothesis is false by construction: a
///         reserve-shaped pair attested at the source (`active`, or the curated tier) and a
///         singleton book with no hook. Every other row above the base is still judged by the
///         edge, and no row under the base is touched. These tests hand `select` the probe pass
///         directly (no Solver, no pool): the oracle is the table below, written from the rule.
/// @dev    Red at 6e5067b: the four `Stays` tests and the `stays` half of the fuzz (the edge
///         dropped every row above it, measured or not). The `Leaves` tests were green there
///         and pin what the fix must not widen.
///         Mutants (.github/scripts/mutants.py, "measured rival [MV-*]"):
///         MV-1 (the union is gone)            -> test_Stays_AnAttestedPairAboveTheBase
///         MV-2 (`>` reads `<`)                -> test_Leaves_AMeasuredRowUnderTheBase
///         MV-3 (a concentrated pool joins)    -> test_Leaves_AConcentratedPoolAboveTheBase
///         MV-5a (the attestation is not read) -> test_Leaves_AnUnvouchedPairAboveTheBase_WithAndWithoutAVoter
///         MV-5b (the hook is not read)        -> test_Leaves_AHookedBookAboveTheBase
///         MV-6a (the curve is not read)       -> test_Leaves_AStableCurvePairAboveTheBase
///         MV-6b (Camelot's name is not asked) -> test_Leaves_AStableCurvePairAboveTheBase
///         MV-6c (any answer reads as stable)  -> test_Stays_AVolatileCurvePairAboveTheBase
///         The two curve tests were red at 2e4d2df (a stable pair above the base stayed:
///         Camelot 0x5201f648 on Arbitrum, quoted x*y=k at 30 bps, reverted on its K).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMath, IHubMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, PoolInfo, MAX_LEGS_PER_HOP} from "../src/BlazePhoenixCore.sol";

/// The two reads `select` makes on the Hub. A pair's slot carries its tier; no test row has a
/// depth above 1 on a singleton book, so the PoolManager is never asked.
contract TierBook {
    mapping(bytes32 => uint256) public getSlot;
    function setTier(bytes32 key, uint8 tier) external { getSlot[key] = uint256(tier) << 40; }
    function v4PoolManager() external pure returns (address) { return address(0); }
}

/// A pair that states its curve under one of the two names pairs answer it by (the two names
/// `BlazePhoenixCore.statesStableCurve` asks): Solidly's `stable()` or Camelot's `stableSwap()`.
/// The word is an immutable, so the code can be etched.
contract CurveFlag {
    uint256 private immutable word;
    bool private immutable camelot;
    constructor(uint256 w, bool c) { word = w; camelot = c; }
    fallback() external {
        bytes4 sel = camelot ? bytes4(0x9e548b7f) : bytes4(0x22be3de1);
        if (msg.sig != sel) revert();
        uint256 w = word;
        assembly { mstore(0, w) return(0, 32) }
    }
}

contract MeasuredRivalSelectUnitTest is Test {
    address internal constant T_IN  = address(0xA11CE);
    address internal constant T_OUT = address(0xB0B);
    uint256 internal constant FEE   = 3000;      // pips, every row; error bounds e = e_o = 0
    uint256 internal constant RATE  = 1e18;      // the base's rate
    uint256 internal constant HEAVY = 1e24;      // the base's vote
    uint256 internal constant LIGHT = 1e18;      // every other vote
    uint256 internal constant RIVAL = 2;         // the rival's row

    TierBook internal book;

    function setUp() public { book = new TierBook(); }

    function _row(uint256 k, uint8 kind, bool active, address hooks) private pure returns (PoolInfo memory) {
        return PoolInfo({active: active, stable: false, kind: kind, fee: uint24(FEE), tickSpacing: 60,
            token0: T_IN, token1: T_OUT, pool: address(uint160(0x1000 + k)), hooks: hooks});
    }

    /// Three rows: the base (the heavy vote), a light row at the base's rate, and the rival at
    /// `pct` percent of the base's rate. `vouched` is the attestation of all three pairs at
    /// once when `allUnvouched`, of the rival alone otherwise. Returns whether the rival is in
    /// the band `select` hands back.
    function _rivalStays(uint8 kind, bool active, uint8 tier, address hooks, uint256 pct, uint256 depth, bool allUnvouched)
        private returns (bool stays)
    {
        PoolInfo[] memory c = new PoolInfo[](3);
        c[0] = _row(0, BPC.KIND_V2, !allUnvouched, address(0));
        c[1] = _row(1, BPC.KIND_V2, !allUnvouched, address(0));
        c[RIVAL] = _row(RIVAL, kind, active, hooks);
        book.setTier(BPC.pairKey(c[0].pool, T_IN, T_OUT), allUnvouched ? 1 : 0);
        book.setTier(BPC.pairKey(c[1].pool, T_IN, T_OUT), allUnvouched ? 1 : 0);
        book.setTier(BPC.pairKey(c[RIVAL].pool, T_IN, T_OUT), tier);

        uint256[] memory rates  = new uint256[](3);
        uint256[] memory depths = new uint256[](3);
        uint256[] memory bals   = new uint256[](3);
        uint256[] memory fe     = new uint256[](3);
        (rates[0], rates[1], rates[RIVAL]) = (RATE, RATE, RATE * pct / 100);
        (depths[0], depths[1], depths[RIVAL]) = (HEAVY, LIGHT, depth);
        for (uint256 i; i < 3; i++) { bals[i] = depths[i]; fe[i] = FEE; }

        (uint256 nBand,,, uint256[] memory map,) =
            BlazePhoenixMath.select(rates, depths, bals, fe, c, T_IN, IHubMath(address(book)), MAX_LEGS_PER_HOP);
        // The base and its neighbour are in every band: the rival never moves the base (its
        // vote is a millionth of the base's at most).
        assertGe(nBand, 2, "the base and its neighbour are kept");
        assertLe(nBand, 3, "three rows at most");
        for (uint256 j; j < nBand; j++) if (map[j] == RIVAL) stays = true;
        assertEq(nBand, stays ? 3 : 2, "the band is the base, its neighbour and the rival or not");
    }

    // ------------------------------------------------------------------ measured: stays above

    function test_Stays_AnAttestedPairAboveTheBase() public {
        assertTrue(_rivalStays(BPC.KIND_V2, true, 1, address(0), 200, LIGHT, false), "factory-vouched pair at 2x");
        assertTrue(_rivalStays(BPC.KIND_SOLIDLY, true, 1, address(0), 200, LIGHT, false), "vouched Solidly pair at 2x");
    }

    function test_Stays_ACuratedPairAboveTheBase() public {
        assertTrue(_rivalStays(BPC.KIND_V2, false, 0, address(0), 200, LIGHT, false), "curated tier, no factory");
    }

    function test_Stays_AHooklessBookAboveTheBase() public {
        assertTrue(_rivalStays(BPC.KIND_V4, false, 1, address(0), 200, 0, false), "singleton book, no hook");
    }

    function test_Stays_AHooklessNativeBookAboveTheBase() public {
        assertTrue(_rivalStays(BPC.KIND_V4_NATIVE, false, 1, address(0), 200, 0, false), "native singleton book, no hook");
    }

    // ------------------------------------------------------------- not measured: the edge judges

    function test_Leaves_AConcentratedPoolAboveTheBase() public {
        assertFalse(_rivalStays(BPC.KIND_V3, true, 0, address(0), 200, LIGHT, false), "vouched and curated V3 at 2x");
        assertFalse(_rivalStays(BPC.KIND_ALGEBRA, true, 0, address(0), 200, LIGHT, false), "vouched and curated Algebra at 2x");
    }

    /// The attestation is read at the source. With a voter beside it the unvouched pair is
    /// muted; with no vouched row in the hop `_mutedVotes` clears its mask and every row votes.
    /// The rival is dropped in both: the mask's answer is not what keeps a row.
    function test_Leaves_AnUnvouchedPairAboveTheBase_WithAndWithoutAVoter() public {
        assertFalse(_rivalStays(BPC.KIND_V2, false, 1, address(0), 200, LIGHT, false), "unvouched pair, vouched voters");
        assertFalse(_rivalStays(BPC.KIND_V2, false, 1, address(0), 200, LIGHT, true), "unvouched pair, nobody vouched");
        assertFalse(_rivalStays(BPC.KIND_SOLIDLY, false, 2, address(0), 200, LIGHT, true), "unvouched Solidly pair, nobody vouched");
    }

    function test_Leaves_AHookedBookAboveTheBase() public {
        assertFalse(_rivalStays(BPC.KIND_V4, false, 1, address(0xBEEF), 200, 0, false), "hooked book at 2x");
        assertFalse(_rivalStays(BPC.KIND_V4_NATIVE, true, 0, address(0xBEEF), 200, 0, false), "hooked native book at 2x");
    }

    /// The lower edge is bonded by the base's mass and is not touched: measured or not, a row
    /// priced under it leaves.
    function test_Leaves_AMeasuredRowUnderTheBase() public {
        assertFalse(_rivalStays(BPC.KIND_V2, true, 0, address(0), 50, LIGHT, false), "vouched pair at half the base");
        assertFalse(_rivalStays(BPC.KIND_V4, false, 1, address(0), 50, 0, false), "hookless book at half the base");
    }

    // ------------------------------------------------------------------------------ the ranges

    /// Boundaries of the upper edge with every fee at 3000 pips and no error bound: a row is
    /// in the band while price * (1-f)^3 <= base price, about 0.9 % over the base. One percent
    /// over is past the edge, a half percent over is inside it.
    function test_Edge_TheRuleStartsWhereTheEdgeEnds() public {
        // inside the band: kept by the band itself, whatever the row is
        assertTrue(_rivalStays(BPC.KIND_V3, false, 1, address(0), 100, LIGHT, false), "unmeasured row at the base's rate");
        // past the edge by the first whole percent that is out: only the measured row stays
        assertTrue(_rivalStays(BPC.KIND_V2, true, 1, address(0), 101, LIGHT, false), "measured, 1 % over");
        assertFalse(_rivalStays(BPC.KIND_V3, true, 0, address(0), 101, LIGHT, false), "modelled, 1 % over");
        // far past it: the rule has no upper bound of its own
        assertTrue(_rivalStays(BPC.KIND_V2, true, 1, address(0), 1e12, LIGHT, false), "measured, 1e10 x");
        assertFalse(_rivalStays(BPC.KIND_V2, false, 1, address(0), 1e12, LIGHT, false), "unvouched, 1e10 x");
    }

    /// Any rate from 1 % over the base to 1e10 times it, any vote up to a millionth of the
    /// base's, every family: above the base a row stays exactly when it is measured.
    function testFuzz_AboveTheBase_ARowStaysExactlyWhenItIsMeasured(
        uint256 pct, uint256 depth, uint8 pick, bool active, uint8 tier, bool hooked, bool allUnvouched
    ) public {
        pct = bound(pct, 101, 1e12);
        uint8[6] memory kinds =
            [BPC.KIND_V2, BPC.KIND_SOLIDLY, BPC.KIND_V3, BPC.KIND_ALGEBRA, BPC.KIND_V4, BPC.KIND_V4_NATIVE];
        uint8 kind = kinds[pick % 6];
        bool book4 = kind == BPC.KIND_V4 || kind == BPC.KIND_V4_NATIVE;
        bool pair  = kind == BPC.KIND_V2 || kind == BPC.KIND_SOLIDLY;
        depth = book4 ? 0 : bound(depth, 0, LIGHT);
        tier = uint8(bound(tier, 0, 3));
        address hooks = hooked && book4 ? address(0xBEEF) : address(0);
        bool measured = pair ? (active || tier == 0) : (book4 && hooks == address(0));
        // Nobody vouched is a hop whose every row is muted: the rival is one of them, or it
        // would be the hop's only voter and the base itself.
        allUnvouched = allUnvouched && !book4 && !active && tier != 0;
        assertEq(_rivalStays(kind, active, tier, hooks, pct, depth, allUnvouched), measured, "stays iff measured");
    }

    /// Under the lower edge (1 % to 99 % of the base's rate) nothing stays, measured or not.
    function testFuzz_UnderTheBase_NoRowIsKeptByTheRule(uint256 pct, uint8 pick, bool active, uint8 tier) public {
        pct = bound(pct, 1, 99);
        uint8[4] memory kinds = [BPC.KIND_V2, BPC.KIND_SOLIDLY, BPC.KIND_V4, BPC.KIND_V4_NATIVE];
        uint8 kind = kinds[pick % 4];
        bool book4 = kind == BPC.KIND_V4 || kind == BPC.KIND_V4_NATIVE;
        assertFalse(_rivalStays(kind, active, uint8(bound(tier, 0, 3)), address(0), pct, book4 ? 0 : LIGHT, false), "under the edge");
    }

    // ------------------------------------------------------------- the curve the quote models

    /// The rival's pair states its curve (`word`, under Solidly's or Camelot's name).
    function _curve(uint256 word, bool camelot) private {
        vm.etch(address(uint160(0x1000 + RIVAL)), address(new CurveFlag(word, camelot)).code);
    }

    /// A reserves row is quoted on x*y=k (a V2 row) or asked of the pair; a pair that states a
    /// stable curve pays on another curve than the row's formula, so the hypothesis the rule
    /// rests on ("only the fee is modelled") is false and the edge judges it. Camelot's stable
    /// pair 0x5201f648 (Arbitrum, block 498000000) stated `stableSwap() = true`, did not answer
    /// `stable()`, was kept at 2.2x the base and reverted on its K. 1 % over is the first whole
    /// percent past the edge.
    function test_Leaves_AStableCurvePairAboveTheBase() public {
        _curve(1, true);
        assertFalse(_rivalStays(BPC.KIND_V2, true, 1, address(0), 220, LIGHT, false), "Camelot stable, vouched, 2.2x");
        assertFalse(_rivalStays(BPC.KIND_V2, false, 0, address(0), 101, LIGHT, false), "Camelot stable, curated, 1 % over");
        _curve(1, false);
        assertFalse(_rivalStays(BPC.KIND_SOLIDLY, true, 1, address(0), 220, LIGHT, false), "Solidly stable, vouched, 2.2x");
        assertFalse(_rivalStays(BPC.KIND_V2, true, 1, address(0), 1e12, LIGHT, false), "stable, vouched, 1e10 x");
    }

    /// The word is read, not the name: a pair that answers the curve question with 0 (volatile),
    /// or with a word that is not a bool, is the x*y=k pair the rule keeps.
    function test_Stays_AVolatileCurvePairAboveTheBase() public {
        _curve(0, true);
        assertTrue(_rivalStays(BPC.KIND_V2, true, 1, address(0), 220, LIGHT, false), "Camelot volatile, 2.2x");
        _curve(2, false);
        assertTrue(_rivalStays(BPC.KIND_V2, true, 1, address(0), 101, LIGHT, false), "a word above 1, 1 % over");
        _curve(0, false);
        assertTrue(_rivalStays(BPC.KIND_SOLIDLY, false, 0, address(0), 1e12, LIGHT, false), "Solidly volatile, curated, 1e10 x");
    }

    /// Any rate past the edge, either name, any word: an attested pair above the base stays
    /// exactly when it does not state a stable curve.
    function testFuzz_AboveTheBase_APairStaysExactlyWhenItsCurveIsTheRows(
        uint256 pct, uint256 word, bool camelot, bool solidly, bool active
    ) public {
        pct = bound(pct, 101, 1e12);
        word = bound(word, 0, 3);
        _curve(word, camelot);
        bool kept = _rivalStays(solidly ? BPC.KIND_SOLIDLY : BPC.KIND_V2, active, active ? 1 : 0, address(0), pct, LIGHT, false);
        assertEq(kept, word != 1, "stays iff not stable");
    }
}
