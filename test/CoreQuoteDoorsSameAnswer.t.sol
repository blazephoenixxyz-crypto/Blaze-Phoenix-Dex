// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  CoreQuoteDoorsSameAnswer — ONE QUOTE BODY, THE SAME ANSWERS AS THE THREE DOORS
//
//  WHAT CHANGED IN src/. The Core had three public doors over one private body
//  (`_quoteArms`), each writing its own literal coordinates into the call:
//      universalQuote(c, a)            -> _quoteArms(c, a, type(uint256).max, false)
//      universalQuoteRank(c, a, bar)   -> _quoteArms(c, a, bar, false)
//      universalProbe(c, a)            -> _quoteArms(c, a, 0, true)
//  The compiler kept one specialised copy of the body per literal tuple. Now the
//  coordinates are data the caller passes: `universalQuote` is gone,
//  `universalQuoteRank(c, a, bar, wantFee)` and `universalProbe(c, a, bar, wantFee)`
//  hand them to the one body, and each caller in src/ passes the tuple its old
//  door wrote (Quoter: max, false. Solver ranking: bar, false. Solver probe: 0, true).
//
//  WHAT THIS FILE PROVES. For the same world and the same arguments, each new
//  call answers what the old door answered: same success flag, same returndata
//  byte for byte (so the same rounding and the same revert). The oracle is not
//  the code under test: it is src/BlazePhoenixCore.sol of cb1d7d9, frozen in
//  test/morf/CoreRefCb1d7d9.sol with only the library name changed.
//
//  THE WORLD. `HashWorld` stands in for the pool, both tokens, the V4 manager,
//  the hooks and the Hub. It answers ANY call with words derived from
//  (seed, its own address, the calldata), sometimes reverting, sometimes
//  answering nothing or too little. Both libraries read the same world, so
//  whatever it says is a fair question; `test_Witness_*` prove the questions
//  are not all trivial (every native kind reaches a live quote, the Solidly
//  probe reads a fee, calls revert on both sides).
//  A hash cannot build a V4 tick book, so the two V4 kinds get a real one
//  (`MockV4TickManager`): a deep position with one-tick dust in the swap's way.
//  Past sixteen stretches the promise stops short and `rank`/`hi` read the rest:
//  the one place `bar` is read.
//  LIMIT, written down: a kind-9 (Gate wrapper) context only walks the refusal
//  path here, because no hash can forge a CREATE2 wrapper identity. That arm is
//  one `gateQuote` call that reads neither `bar` nor `wantFee`.
//
//  THE CALL NOT MADE. `wantFee` on the quote door changes no answer (the fee it
//  would fetch is thrown away), so the comparison of answers is blind to it. The
//  two `test_*SolidlyFee*` tests count the read itself on a real Solidly pair:
//  none for a quote or a ranking, one for a probe, on each side.
//
//  THE WORD NOT COMPARED (MAT-02, 2026-11-10, merged 2026-11-12). The probe door's first
//  word is `mass` since MAT-02: the tokenOut side a book declares, the unit of the band's
//  vote. The frozen Core of cb1d7d9 answers the short side there (`depthWad`), a unit the
//  tree no longer has, so `_sameProbe` holds the probe door to the frozen one on its success
//  flag, its length and its other three words (rank, fee, err), byte for byte, and on the
//  whole revert data when both refuse. The first word is held where its unit is made:
//  test/Mat02BandVoteIsOneUnit.t.sol and test/HopMassIsTokenOutHeld.t.sol.
//
//  MUTANTS (.github/scripts/mutants.py, label morf-12; each run alone, each red here):
//    [a] universalProbe hands `false` for `wantFee`: the Solidly fee reads 0
//        -> test_TheProbeReadsTheSolidlyFeeOnce, testFuzz_universalProbe_SameAnswer,
//           test_Edges_*, test_Witness_EveryPoolKindReachesALiveQuote.
//    [b] universalProbe hands the top bar -> test_Witness_V4BookLeavesInputUnspent,
//        testFuzz_V4Book_ThreeDoorsSameAnswer.
//    [c] universalQuoteRank hands bar 0 -> test_V4Book_EachSideOfTheBarAnswersAsItDid,
//        testFuzz_V4Book_ThreeDoorsSameAnswer. It SURVIVED the first form of that
//        fuzz, which chose the bar by the top bits of a fuzzed word (see its comment).
//    [d] universalQuoteRank hands `true` for `wantFee` -> test_AQuoteDoesNotReadTheSolidlyFee
//        alone: every answer is the same.
//    [k] universalQuoteRank hands the top bar -> test_V4Book_EachSideOfTheBarAnswersAsItDid,
//        test_Witness_V4BookLeavesInputUnspent.
//    [m] the live Solidly arm pays 1 ppm less than the frozen one -> testFuzz_universalQuote_SameAnswer,
//        testFuzz_universalQuoteRank_SameAnswer and five more: the body drifting is seen at every door.
// =============================================================================
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {CoreRefCb1d7d9 as REF, QuoteCtx as RefCtx} from "./morf/CoreRefCb1d7d9.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @dev The three questions, as a caller asks them. Both sides answer this one ABI.
interface IQuoteDoors {
    function quote(QuoteCtx memory c, uint256 a) external view returns (uint256 out, uint256 depthWad);
    function rank(QuoteCtx memory c, uint256 a, uint256 bar)
        external view returns (uint256 out, uint256 depthWad, uint256 rnk, uint256 hi);
    function probe(QuoteCtx memory c, uint256 a)
        external view returns (uint256 depthWad, uint256 rnk, uint256 fee, uint256 err);
}

/// @dev The live Core, asked the way src/ asks it (Quoter, Solver ranking, Solver probe).
contract LiveDoors {
    function quote(QuoteCtx memory c, uint256 a) external view returns (uint256 out, uint256 depthWad) {
        (out, depthWad, , ) = BPC.universalQuoteRank(c, a, type(uint256).max, false);
    }
    function rank(QuoteCtx memory c, uint256 a, uint256 bar)
        external view returns (uint256, uint256, uint256, uint256)
    {
        return BPC.universalQuoteRank(c, a, bar, false);
    }
    function probe(QuoteCtx memory c, uint256 a) external view returns (uint256, uint256, uint256, uint256) {
        return BPC.universalProbe(c, a, 0, true, a);
    }
}

/// @dev The Core of cb1d7d9, asked through the doors it had.
contract FrozenDoors {
    function quote(RefCtx memory c, uint256 a) external view returns (uint256, uint256) {
        return REF.universalQuote(c, a);
    }
    function rank(RefCtx memory c, uint256 a, uint256 bar)
        external view returns (uint256, uint256, uint256, uint256)
    {
        return REF.universalQuoteRank(c, a, bar);
    }
    function probe(RefCtx memory c, uint256 a) external view returns (uint256, uint256, uint256, uint256) {
        return REF.universalProbe(c, a);
    }
}

/// @dev Pool, token, manager, hooks and Hub in one. Every answer is a function of
///      (seed, this address, calldata), so a second reader gets the same words.
contract HashWorld {
    uint256 private seed;

    function dial(uint256 s) external {
        seed = s;
    }

    fallback() external {
        uint256 s = seed;
        bytes32 h = keccak256(abi.encodePacked(s, address(this), msg.data));
        uint256 m = uint256(h) & 0x1f;
        if (m == 0) {
            assembly { revert(0, 0) }
        }
        if (m == 1) {
            assembly { return(0, 0) }
        }
        // 1, 2, 3 or 7 words now and then (a short answer is a refusal for most reads), else 8.
        uint256 n = m == 2 ? 1 : m == 3 ? 2 : m == 4 ? 3 : m == 5 ? 7 : 8;
        bytes memory out = new bytes(n * 32);
        // An odd seed is a world whose pool holds what it claims: balanceOf answers a rich figure.
        bool rich = (s & 1) == 1 && msg.sig == 0x70a08231;
        for (uint256 i; i < n; ++i) {
            uint256 w = uint256(keccak256(abi.encode(h, i)));
            uint256 bits = [uint256(1), 6, 24, 64, 96, 112, 128, 160][(w >> 3) & 7];
            w = rich ? type(uint256).max >> 1 : w >> (256 - bits);
            assembly { mstore(add(add(out, 32), mul(i, 32)), w) }
        }
        assembly { return(add(out, 32), mload(out)) }
    }
}

contract CoreQuoteDoorsSameAnswerTest is Test {
    address private live;
    address private frozen;
    HashWorld private pool;
    HashWorld private tIn;
    HashWorld private tOt;
    HashWorld private mgr;
    HashWorld private hooks;
    HashWorld private hub;
    address private b0;
    address private b1;

    uint8 private constant K_V2 = 0;
    uint8 private constant K_V3 = 1;
    uint8 private constant K_V4 = 4;
    uint8 private constant K_SOLIDLY = 5;
    uint8 private constant K_ALGEBRA = 6;
    uint8 private constant K_V4_NATIVE = 8;
    uint8 private constant K_EXTERNAL = 9;

    function setUp() public {
        live = address(new LiveDoors());
        frozen = address(new FrozenDoors());
        pool = new HashWorld();
        tIn = new HashWorld();
        tOt = new HashWorld();
        mgr = new HashWorld();
        hooks = new HashWorld();
        hub = new HashWorld();
        address x = address(new MockERC20("A", "A"));
        address y = address(new MockERC20("B", "B"));
        (b0, b1) = x < y ? (x, y) : (y, x);
    }

    // ---------------------------------------------------------------- world

    function _dial(uint256 seed) private {
        pool.dial(seed);
        tIn.dial(seed);
        tOt.dial(seed);
        mgr.dial(seed);
        hooks.dial(seed);
        hub.dial(seed);
    }

    function _kind(uint256 pick) private pure returns (uint8) {
        uint8[7] memory ks = [K_V2, K_V3, K_V4, K_SOLIDLY, K_ALGEBRA, K_V4_NATIVE, K_EXTERNAL];
        uint256 i = pick % 8;
        return i == 7 ? uint8(pick >> 8) : ks[i]; // one pick in eight is any byte: unknown kinds too
    }

    /// @dev A context over the world, its free fields drawn from `seed`.
    function _ctx(uint256 seed, uint8 kind) private view returns (QuoteCtx memory c) {
        uint256 r = uint256(keccak256(abi.encode(seed, "ctx")));
        c.kind = kind;
        c.pool = address(pool);
        c.zeroForOne = r & 1 == 1;
        c.fee = uint24(r >> 8) % (r & 2 == 2 ? 10_001 : type(uint24).max);
        c.tickSpacing = int24(int256((r >> 40) % 400)) - 100;
        c.stable = r & 4 == 4;
        c.tokenIn = address(tIn);
        c.tokenOther = address(tOt);
        c.hooks = r & 8 == 8 ? address(hooks) : address(0);
        c.v4Manager = address(mgr);
        c.hub = address(hub);
        c.decIn1 = r & 16 == 16 ? 0 : uint8(1 + (r >> 72) % 25);
        c.decOther1 = r & 32 == 32 ? 0 : uint8(1 + (r >> 80) % 25);
    }

    /// @dev Sizes from one wei to the whole word, log-uniform.
    function _size(uint256 seed, uint256 x) private pure returns (uint256) {
        return x >> (uint256(keccak256(abi.encode(seed, "size"))) % 256);
    }

    // ---------------------------------------------------------------- the comparison

    function _ask(address who, bytes memory cd) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = who.staticcall(cd);
    }

    /// @dev Same success, same bytes. Returns the live answer.
    function _same(bytes memory cd, string memory what) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = _ask(live, cd);
        (bool okF, bytes memory retF) = _ask(frozen, cd);
        assertEq(ok, okF, string.concat(what, ": one side reverted, the other answered"));
        assertEq(ret, retF, string.concat(what, ": the answers differ"));
    }

    /// @dev The probe door: same success, same bytes but the first word (see THE WORD NOT
    ///      COMPARED in the header). Returns the live answer.
    function _sameProbe(bytes memory cd, string memory what) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = _ask(live, cd);
        (bool okF, bytes memory retF) = _ask(frozen, cd);
        assertEq(ok, okF, string.concat(what, ": one side reverted, the other answered"));
        if (!ok || ret.length != 128 || retF.length != 128) {
            assertEq(ret, retF, string.concat(what, ": the answers differ"));
            return (ok, ret);
        }
        (, uint256 r1, uint256 f1, uint256 e1) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        (, uint256 r2, uint256 f2, uint256 e2) = abi.decode(retF, (uint256, uint256, uint256, uint256));
        assertEq(r1, r2, string.concat(what, ": the ranks differ"));
        assertEq(f1, f2, string.concat(what, ": the fees differ"));
        assertEq(e1, e2, string.concat(what, ": the error bounds differ"));
    }

    // ---------------------------------------------------------------- fuzz, one door each

    /// The Quoter's question: the old `universalQuote` against the one door at (max, false).
    function testFuzz_universalQuote_SameAnswer(uint256 seed, uint256 pick, uint256 amountIn) public {
        _dial(seed);
        _same(abi.encodeCall(IQuoteDoors.quote, (_ctx(seed, _kind(pick)), _size(seed, amountIn))), "universalQuote");
    }

    /// The Solver's ranking question: the caller's bar, no fee read.
    function testFuzz_universalQuoteRank_SameAnswer(uint256 seed, uint256 pick, uint256 amountIn, uint256 bar)
        public
    {
        _dial(seed);
        uint256 r = uint256(keccak256(abi.encode(seed, pick, bar))) & 7; // a hashed choice, as above
        bar = r > 1 ? _size(~seed, bar) : r == 0 ? 0 : type(uint256).max;
        _same(
            abi.encodeCall(IQuoteDoors.rank, (_ctx(seed, _kind(pick)), _size(seed, amountIn), bar)),
            "universalQuoteRank"
        );
    }

    /// The band's question: bar 0 and the fee the figure charged.
    function testFuzz_universalProbe_SameAnswer(uint256 seed, uint256 pick, uint256 amountIn) public {
        _dial(seed);
        _sameProbe(abi.encodeCall(IQuoteDoors.probe, (_ctx(seed, _kind(pick)), _size(seed, amountIn))), "universalProbe");
    }

    // ---------------------------------------------------------------- the fee read is the caller's word

    /// @dev A Solidly pair that holds its reserves and answers its own ask, as a quote context.
    function _solidlyCtx() private returns (QuoteCtx memory c) {
        MockSolidlyPair pair = new MockSolidlyPair(b0, b1, false);
        MockERC20(b0).mint(address(pair), 1_000_000e18);
        MockERC20(b1).mint(address(pair), 1_000_000e18);
        pair.setReserves(1_000_000e18, 1_000_000e18);
        c.kind = K_SOLIDLY;
        c.pool = address(pair);
        c.zeroForOne = true;
        c.fee = 30;
        c.tokenIn = b0;
        c.tokenOther = b1;
        c.decIn1 = 19;
        c.decOther1 = 19;
    }

    /// `wantFee` reaches the body as the caller said it, on both doors. A quote and a ranking
    /// do not read the pair's fee, now as before: the call not made is the property. The
    /// comparison of answers cannot see it, because the fee such a read fetches is thrown away.
    function test_AQuoteDoesNotReadTheSolidlyFee() public {
        QuoteCtx memory c = _solidlyCtx();
        vm.expectCall(c.pool, abi.encodeWithSignature("factory()"), 0);
        (, bytes memory ret) = _same(abi.encodeCall(IQuoteDoors.quote, (c, 1_000e18)), "solidly quote");
        (uint256 out,) = abi.decode(ret, (uint256, uint256));
        (, ret) = _same(abi.encodeCall(IQuoteDoors.rank, (c, 1_000e18, 0)), "solidly rank");
        (uint256 ranked,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        assertGt(out, 0, "the pair did not quote: a call not made proves nothing");
        assertEq(ranked, out, "the ranking and the quote read different asks");
    }

    /// The probe reads it, once on each side, and answers it in pips: the band is judged on
    /// the fee the figure charged.
    function test_TheProbeReadsTheSolidlyFeeOnce() public {
        QuoteCtx memory c = _solidlyCtx();
        vm.expectCall(c.pool, abi.encodeWithSignature("factory()"), 2);
        (, bytes memory ret) = _sameProbe(abi.encodeCall(IQuoteDoors.probe, (c, 1_000e18)), "solidly probe");
        (, uint256 rnk, uint256 fee,) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        assertGt(rnk, 0, "the pair did not answer the probe");
        assertEq(fee, 3000, "the probe did not answer the pair's fee");
    }

    // ---------------------------------------------------------------- a real V4 book

    /// @dev A fresh manager holding one deep position and `dust` one-tick positions of
    ///      liquidity 1 in the swap's way (0 to 40 of them: under and over the sixteen stretches).
    function _bookCtx(uint256 seed, uint8 kind) private returns (QuoteCtx memory c) {
        uint256 r = uint256(keccak256(abi.encode(seed, "book")));
        MockV4TickManager m = new MockV4TickManager();
        c.kind = kind;
        c.zeroForOne = r & 4 == 4;
        c.fee = [uint24(100), 500, 3000, 50_000][r & 3];
        c.tickSpacing = 1;
        (address c0, address c1) = kind == K_V4_NATIVE ? (address(0), b1) : (b0, b1);
        (c.tokenIn, c.tokenOther) = c.zeroForOne ? (c0, c1) : (c1, c0);
        c.v4Manager = address(m);
        c.decIn1 = 19;
        c.decOther1 = 19;
        bytes32 pid = BPC.computeV4PoolId(c0, c1, c.fee, 1, address(0));
        m.initialize(pid, BPC.sqrtPriceAtTick(0), 0, c.fee);
        m.addPosition(pid, -20_000, 20_000, 1, 1e24);
        int24 dust = int24(int256((r >> 8) % 41));
        for (int24 t; t < dust; ++t) {
            int24 lo = c.zeroForOne ? -1 - t : t;
            m.addPosition(pid, lo, lo + 1, 1, 1);
        }
    }

    /// The three doors over a fragmented V4 book, wrapped and native: one wei to 9e26, the bar at
    /// zero, at the top, and anywhere around the figure it is compared with. Every choice is a
    /// bit of a hash of the fuzzed words: the fuzzer's own words are mostly short, so their top
    /// bits are almost always zero and a choice read there is one choice.
    function testFuzz_V4Book_ThreeDoorsSameAnswer(uint256 seed, uint256 amountIn, uint256 bar) public {
        uint256 r = uint256(keccak256(abi.encode(seed, amountIn, bar)));
        QuoteCtx memory c = _bookCtx(seed, r & 1 == 0 ? K_V4 : K_V4_NATIVE);
        uint256 a = (1 + (r >> 8) % 9) * 10 ** ((r >> 16) % 27);
        uint256 pick = (r >> 32) & 3;
        bar = pick == 0 ? 0 : pick == 1 ? type(uint256).max : (r >> 40) % (2 * a + 1);
        _same(abi.encodeCall(IQuoteDoors.quote, (c, a)), "V4 book quote");
        _same(abi.encodeCall(IQuoteDoors.rank, (c, a, bar)), "V4 book rank");
        _sameProbe(abi.encodeCall(IQuoteDoors.probe, (c, a)), "V4 book probe");
    }

    /// The bar is read in one place: when the sixteenth stretch closes with input unspent, the
    /// ranking goes on only if the ceiling of what is left is above it. Both sides of that
    /// comparison, to the wei, and its two corners (0 walks on, the top never does).
    function test_V4Book_EachSideOfTheBarAnswersAsItDid() public {
        uint8[2] memory ks = [K_V4, K_V4_NATIVE];
        uint256 stopped;
        for (uint256 j; j < ks.length; ++j) {
            for (uint256 seed = 1; seed <= 10; ++seed) {
                QuoteCtx memory c = _bookCtx(seed, ks[j]);
                // One under the top is a bar no ceiling is above: `hi` is the ceiling itself.
                (, bytes memory ret) =
                    _same(abi.encodeCall(IQuoteDoors.rank, (c, 1e22, type(uint256).max - 1)), "bar: top - 1");
                (uint256 out,,, uint256 ceil) = abi.decode(ret, (uint256, uint256, uint256, uint256));
                if (ceil == out) continue; // the quote finished inside sixteen stretches: no bar read
                ++stopped;
                _same(abi.encodeCall(IQuoteDoors.rank, (c, 1e22, 0)), "bar: zero");
                _same(abi.encodeCall(IQuoteDoors.rank, (c, 1e22, ceil - 1)), "bar: one under the ceiling");
                (, ret) = _same(abi.encodeCall(IQuoteDoors.rank, (c, 1e22, ceil)), "bar: the ceiling");
                (,, uint256 rnk,) = abi.decode(ret, (uint256, uint256, uint256, uint256));
                assertEq(rnk, out, "a ceiling at the bar went on walking");
                (, ret) = _same(abi.encodeCall(IQuoteDoors.rank, (c, 1e22, type(uint256).max)), "bar: top");
                (,,, uint256 hiTop) = abi.decode(ret, (uint256, uint256, uint256, uint256));
                assertEq(hiTop, type(uint128).max, "the top bar did not answer the saturated ceiling");
            }
        }
        assertGt(stopped, 0, "no book left input unspent: the bar was never read");
    }

    // ---------------------------------------------------------------- boundaries

    /// Dust to the whole word, at the bar's three corners, on every kind and on unknown ones.
    function test_Edges_EverySizeAndBarCornerAnswersAsItDid() public {
        uint256[7] memory sizes =
            [uint256(0), 1, 2, 1e18, type(uint128).max, uint256(type(uint128).max) + 1, type(uint256).max];
        uint256[4] memory bars = [uint256(0), 1, type(uint256).max - 1, type(uint256).max];
        for (uint256 seed = 1; seed <= 12; ++seed) {
            _dial(seed);
            for (uint256 k; k < 11; ++k) {
                QuoteCtx memory c = _ctx(seed, uint8(k));
                for (uint256 i; i < sizes.length; ++i) {
                    _same(abi.encodeCall(IQuoteDoors.quote, (c, sizes[i])), "edge quote");
                    _sameProbe(abi.encodeCall(IQuoteDoors.probe, (c, sizes[i])), "edge probe");
                    for (uint256 b; b < bars.length; ++b) {
                        _same(abi.encodeCall(IQuoteDoors.rank, (c, sizes[i], bars[b])), "edge rank");
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- the questions are not trivial

    struct Seen {
        uint256 live;      // quotes with out > 0
        uint256 reverts;   // calls both sides refused by reverting
        uint256 feeRead;   // probes with 0 < fee < FEE_UNKNOWN
        uint256 ranked;    // rank != out (a V4 walk that left input unspent)
    }

    /// @dev Walks 400 hash worlds per pool kind and counts what the comparison actually saw. A
    ///      differential that only ever compared (0, 0) with (0, 0) would pass on anything.
    function test_Witness_EveryPoolKindReachesALiveQuote() public {
        uint8[4] memory ks = [K_V2, K_V3, K_SOLIDLY, K_ALGEBRA];
        uint256 allReverts;
        for (uint256 j; j < ks.length; ++j) {
            Seen memory s;
            for (uint256 seed = 1; seed <= 400; ++seed) {
                _dial(seed);
                _tally(s, _ctx(seed, ks[j]), _size(seed, 1e30));
            }
            _report(ks[j], s);
            assertGt(s.live, 0, "a kind never reached a live quote: the comparison is vacuous for it");
            if (ks[j] == K_SOLIDLY) assertGt(s.feeRead, 0, "no Solidly probe read a fee");
            allReverts += s.reverts;
        }
        assertGt(allReverts, 0, "no call reverted: the revert half of the comparison saw nothing");
    }

    /// @dev The same count over the V4 book, wrapped and native: the walk must leave input
    ///      unspent somewhere (rank != out), or `bar` was never read and its comparison is vacuous.
    function test_Witness_V4BookLeavesInputUnspent() public {
        uint8[2] memory ks = [K_V4, K_V4_NATIVE];
        for (uint256 j; j < ks.length; ++j) {
            Seen memory s;
            for (uint256 seed = 1; seed <= 20; ++seed) {
                _tally(s, _bookCtx(seed, ks[j]), 1e22);
            }
            _report(ks[j], s);
            assertGt(s.live, 0, "a V4 kind never reached a live quote");
            assertGt(s.ranked, 0, "no V4 walk left input unspent: the bar was never read");
            assertGt(s.feeRead, 0, "no V4 probe read a fee");
        }
    }

    function _report(uint8 kind, Seen memory s) private {
        emit log_named_uint(string.concat("kind ", vm.toString(kind), " live quotes"), s.live);
        emit log_named_uint("  reverts on both sides", s.reverts);
        emit log_named_uint("  probes with a fee read", s.feeRead);
        emit log_named_uint("  rank != out", s.ranked);
    }

    function _tally(Seen memory s, QuoteCtx memory c, uint256 a) private view {
        (bool ok, bytes memory ret) = _same(abi.encodeCall(IQuoteDoors.rank, (c, a, 0)), "witness rank");
        if (!ok) {
            ++s.reverts;
        } else {
            (uint256 out,, uint256 rnk,) = abi.decode(ret, (uint256, uint256, uint256, uint256));
            if (out > 0) ++s.live;
            if (rnk != out) ++s.ranked;
        }
        (ok, ret) = _sameProbe(abi.encodeCall(IQuoteDoors.probe, (c, a)), "witness probe");
        if (ok) {
            (,, uint256 fee,) = abi.decode(ret, (uint256, uint256, uint256, uint256));
            if (fee > 0 && fee < 0xFFFFFF) ++s.feeRead;
        }
    }
}
