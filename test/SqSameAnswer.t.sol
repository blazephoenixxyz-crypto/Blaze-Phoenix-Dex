// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// SQ2 META-GUARD: ONE QUOTE CONTEXT AND ONE HOLDINGS READ PER CANDIDATE PER BUILD CHANGE NO
// ANSWER, TO THE BYTE.
//
// A hop quotes each candidate up to three times with the same pool, the same input token and the
// same decimals: the band's probe, the split's share and the full-size single. The Solver of
// cb1d7d9 built the Core's quote context (`QuoteCtx`, thirteen words, and `hub.v4PoolManager()`
// for a singleton book) at each of the three, and `_singleLeg` read the pool's tokenOut holdings
// again although the probe pass had read them into `balsOut`. The Solver builds the context
// once, in the probe pass, replays the band's `map` on it as on `cands` and `balsOut`, and hands
// the single the reading the probe pass took. A lone candidate (no probe pass) still reads its
// holdings itself, after its quote and only when its kind is judged by them, as before.
//
// `SolverRefCb1d7d9` is the Solver of cb1d7d9 (literal, renamed), linked to the live Core and
// Math, which this change does not touch. Both Solvers read the same Hub and the same state, and
// each call must come back with the same success and the same returndata bytes, cold and warm,
// with all the gas and at the door's budget (SOLVE_GAS). Rules that landed after cb1d7d9 are
// carried, never frozen anew: the floor's frame (4007, test/ref/Frame4007.sol, in `_same`) and,
// inside the reference, G52's "every leg pays for its place" (48ff261, marked `CARRY G52`),
// written from that rule with the reference's own MIN_SPLIT_IMPROVEMENT_PPM. Their mutants:
// [morf-SQ2-17] (the carry's threshold at 0), [morf-SQ2-18] (the frame's dust floor) and
// [morf-SQ2-19] (the frame's rate band collapsed to its top rate).
//
// RED BEFORE THE CHANGE (cb1d7d9): the two counting rows, `test_Sq_OneHoldingsReadPerCandidate`
// and `test_Sq_OneManagerReadPerSingletonCandidate` - the Solver of cb1d7d9 reads the holdings
// twice and the manager three times. The same-answer rows are green on both sides of the change
// by construction (that is the claim); their mutants are the ones that turn them red, listed in
// .github/scripts/mutants.py under [morf-SQ2-*].
//
// WHERE THE CLAIM STOPS: a token whose `balanceOf` is not a function of the state (one that
// answers by `gasleft()`) can give the probe pass and the single two different readings in the
// Solver of cb1d7d9; the Solver judges both by the one reading. No row here draws such a token.

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {SolverRefCb1d7d9} from "./morf/SolverRefCb1d7d9.sol";
import {Frame4007} from "./ref/Frame4007.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {HeavyBookPool} from "./CapacityWalkBudget.t.sol";

/// A token whose `balanceOf` refuses while it is sour. Everything else is a plain 18-decimal token.
contract SqMoodyToken {
    error Sour();
    string public name = "M";
    string public symbol = "M";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    bool public sour;
    mapping(address => uint256) internal bal;

    function mint(address to, uint256 amt) external { bal[to] += amt; totalSupply += amt; }
    function setSour(bool s) external { sour = s; }
    function balanceOf(address who) external view returns (uint256) {
        if (sour) revert Sour();
        return bal[who];
    }
}

abstract contract SqFixture is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    SolverRefCb1d7d9 ref;
    MockV4TickManager mgr;
    address tA;
    address tB;
    address[] touched;
    address[] bridges;

    /// Mirrors `BlazePhoenixRouter.SOLVE_GAS`, the budget the automatic door hands a solve.
    uint256 constant SOLVE_GAS = 14_700_000;
    uint160 constant SP = uint160(1 << 96);   // price 1, tick 0
    uint128 constant L = 1_000e18;
    int24 constant TS = 60;

    function _deploy() internal {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        ref = new SolverRefCb1d7d9(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(this));
        address a = _token();
        address b = _token();
        (tA, tB) = a < b ? (a, b) : (b, a);
        touched.push(address(hub));
        touched.push(address(solver));
        touched.push(address(ref));
        touched.push(address(mgr));
        touched.push(address(BlazePhoenixMath));
        touched.push(address(BPC));
    }

    // ─── fixtures ────────────────────────────────────────────────────────────

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        touched.push(t);
    }

    /// A curated V2 row declaring `ra` of `a` and `rb` of `b` and holding `ha` and `hb` of them:
    /// an honest pair holds what it declares, a forged one holds less.
    function _v2Held(address a, address b, uint256 ra, uint256 rb, uint256 ha, uint256 hb, uint24 fee)
        internal returns (address)
    {
        MockV2Pair p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), ha);
        MockERC20(b).mint(address(p), hb);
        (uint256 r0, uint256 r1) = p.token0() == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, fee, address(0), a, b);
        touched.push(address(p));
        return address(p);
    }

    function _v2(address a, address b, uint256 ra, uint256 rb) internal returns (address) {
        return _v2Held(a, b, ra, rb, ra, rb, 30);
    }

    /// A curated Solidly row (volatile), reserve-shaped as V2 is and its own kind.
    function _solidly(address a, address b, uint256 ra, uint256 rb) internal returns (address) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        MockSolidlyPair p = new MockSolidlyPair(c0, c1, false);
        MockERC20(a).mint(address(p), ra);
        MockERC20(b).mint(address(p), rb);
        (uint256 r0, uint256 r1) = c0 == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_SOLIDLY, 30, address(0), c0, c1);
        touched.push(address(p));
        return address(p);
    }

    /// A V3 book the capacity clamp can bind (test/CapacityWalkBudget.t.sol's), twenty ticks on
    /// each side, holding `held` of each token.
    function _heavy(address a, address b, uint24 fee, uint128 liq, uint256 held) internal returns (address) {
        HeavyBookPool p = new HeavyBookPool(a, b, fee, TS);
        p.setState(SP, liq);
        for (int24 i = 1; i <= 20; ++i) {
            p.setTick(-i * TS, int128(liq / 1000));
            p.setTick(i * TS, -int128(liq / 1000));
        }
        MockERC20(a).mint(address(p), held);
        MockERC20(b).mint(address(p), held);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), a, b);
        touched.push(address(p));
        return address(p);
    }

    /// An Algebra book at price 1: concentrated at the pool as V3 is, and its own kind.
    function _algebra(address a, address b, uint128 liq, uint256 held) internal returns (address) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        MockAlgebraPool p = new MockAlgebraPool(c0, c1, 500);
        p.setState(SP, liq);
        MockERC20(a).mint(address(p), held);
        MockERC20(b).mint(address(p), held);
        hub.seedPool(address(p), BPC.KIND_ALGEBRA, 0, address(0), c0, c1);
        touched.push(address(p));
        return address(p);
    }

    /// A V4 book on (a, b), either order, at `tick`, liquidity `liq` over [lo, hi].
    function _v4On(address a, address b, uint24 fee, int24 ts, int24 tick, int24 lo, int24 hi, uint128 liq)
        internal returns (address pool)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        MockERC20(c0).mint(address(mgr), 1e30);
        MockERC20(c1).mint(address(mgr), 1e30);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, ts, address(0));
        mgr.initialize(pid, mgr.sqrtAt(tick), tick, fee);
        mgr.addPosition(pid, lo, hi, ts, liq);
        pool = address(uint160(uint256(pid)));
        hub.seedPool(pool, BPC.KIND_V4, fee, address(0), c0, c1);
    }

    function _bridge() internal returns (address b) {
        b = _token();
        bridges.push(b);
        hub.addBridge(b);
    }

    /// Word `i` of a call's arguments (`QuoteCtx` is static: `pool` is word 1 of a probe's).
    function _word(bytes memory data, uint256 i) internal pure returns (uint256 w) {
        assembly ("memory-safe") { w := mload(add(add(data, 0x24), shl(5, i))) }
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    // ─── the comparison ──────────────────────────────────────────────────────

    /// Both Solvers on the same call with the same gas: the same success and the same bytes.
    function _same(address a, address b, uint256 amt, uint256 g, bool cold)
        internal returns (bool ok, bytes memory out, uint256 gasNew, uint256 gasRef)
    {
        bytes memory q = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (a, b, amt));
        if (cold) _cool();
        uint256 g0 = gasleft();
        (bool okN, bytes memory rN) = address(solver).staticcall{gas: g}(q);
        gasNew = g0 - gasleft();
        if (cold) _cool();
        g0 = gasleft();
        (bool okR, bytes memory rR) = address(ref).staticcall{gas: g}(q);
        gasRef = g0 - gasleft();
        assertEq(okN, okR, "SQ2: one Solver answered and the other refused");
        // 4007: the floor is attested on the net output since 2026-11-11; the reference's is read
        // in that frame (test/ref/Frame4007.sol), every other field to the byte.
        if (okN) rR = Frame4007.carry(hub, rN, rR);
        assertEq(rN, rR, "SQ2: the Solver and the Solver of cb1d7d9 disagree");
        (ok, out) = (okN, rN);
    }

    /// Cold with all the gas, warm with all the gas, cold at the door's budget.
    function _sameEveryWay(address a, address b, uint256 amt) internal returns (bool ok, bytes memory out) {
        uint256 gN;
        uint256 gR;
        (ok, out, gN, gR) = _same(a, b, amt, gasleft(), true);
        _same(a, b, amt, gasleft(), false);
        _same(a, b, amt, SOLVE_GAS, true);
        emit log_named_uint("  gas new, cold", gN);
        emit log_named_uint("  gas cb1d7d9, cold", gR);
    }

    /// The comparison, and the route must exist: two refusals compare nothing.
    function _row(string memory name, address a, address b, uint256 amt) internal returns (RoutePlan memory plan) {
        emit log_named_string("row", name);
        (bool ok, bytes memory out) = _sameEveryWay(a, b, amt);
        assertTrue(ok, "precondition: the row has a route");
        plan = abi.decode(out, (RoutePlan));
        assertGt(plan.best.totalOut, 0, "precondition: the row's route promises something");
    }

    /// What one solve of `s` asked from inside its own frame: `holdings`, the `balanceOf(pool)`
    /// reads of `token`; `manager`, the `v4PoolManager()` reads of the Hub; `probes`, the band
    /// probes of `pool` (`Core.universalProbe`: one per build of a hop that lists it).
    function _asks(address s, address a, address b, uint256 amt, address token, address pool)
        internal returns (uint256 holdings, uint256 manager, uint256 probes)
    {
        bytes32 want = keccak256(abi.encodeWithSelector(0x70a08231, pool));
        _cool();
        vm.startStateDiffRecording();
        (bool ok, ) = s.staticcall(abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (a, b, amt)));
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        assertTrue(ok, "precondition: the row has a route");
        for (uint256 i; i < recs.length; ++i) {
            // A library call keeps the Solver's own caller, so its record is told by the callee.
            if (recs[i].kind == VmSafe.AccountAccessKind.DelegateCall) {
                if (recs[i].account == address(BPC) && bytes4(recs[i].data) == BPC.universalProbe.selector && _word(recs[i].data, 1) == uint256(uint160(pool))) ++probes;
                continue;
            }
            if (recs[i].kind != VmSafe.AccountAccessKind.StaticCall || recs[i].accessor != s) continue;
            if (recs[i].account == token && keccak256(recs[i].data) == want) ++holdings;
            if (recs[i].account == address(hub) && bytes4(recs[i].data) == bytes4(keccak256("v4PoolManager()"))) ++manager;
        }
    }
}

contract SqSameAnswerTest is SqFixture {
    function setUp() public { _deploy(); }

    // ─── the mechanism, counted (red at cb1d7d9) ─────────────────────────────

    /// Three reserve-shaped books in the band, split and then judged against their singles. The
    /// Solver of cb1d7d9 reads each pool's tokenOut holdings in the probe pass and again in the
    /// single; the Solver's single takes the probe pass's reading, so each build of the hop
    /// asks one time less. (The quotes and the route's assembly read the holdings as well, in
    /// both Solvers alike: the count is compared, not pinned.)
    function test_Sq_OneHoldingsReadPerCandidate() public {
        address[3] memory p = [_v2(tA, tB, 3e24, 3e24), _v2(tA, tB, 2e24, 2e24), _solidly(tA, tB, 1e24, 1e24)];
        RoutePlan memory plan = _row("three reserve books, one hop", tA, tB, 9e21);
        assertGe(plan.best.hops[0].legs.length, 2, "precondition: the hop splits, so every single is quoted");
        for (uint256 i; i < 3; ++i) {
            (uint256 was, , uint256 wasProbes) = _asks(address(ref), tA, tB, 9e21, tB, p[i]);
            (uint256 now_, , uint256 probes) = _asks(address(solver), tA, tB, 9e21, tB, p[i]);
            emit log_named_uint("  holdings reads, cb1d7d9", was);
            emit log_named_uint("  holdings reads, now", now_);
            emit log_named_uint("  probe passes", probes);
            assertGt(probes, 0, "precondition: the pool is probed");
            assertEq(wasProbes, probes, "precondition: both Solvers build the hop as often");
            assertEq(was - now_, probes, "SQ2: the single takes the probe pass's reading: one read less per build");
        }
    }

    /// A singleton book among reserve books: its context needs the manager's address, which the
    /// Solver of cb1d7d9 asked the Hub for at the probe, at the share and at the single.
    function test_Sq_OneManagerReadPerSingletonCandidate() public {
        _v2(tA, tB, 3e24, 3e24);
        _v2(tA, tB, 2e24, 2e24);
        address book = _v4On(tA, tB, 3000, 60, 0, -887220, 887220, 2e24);
        RoutePlan memory plan = _row("two reserve books and a singleton book", tA, tB, 9e21);
        assertGe(plan.best.hops[0].legs.length, 2, "precondition: the hop splits, so every single is quoted");
        (, uint256 was, uint256 wasProbes) = _asks(address(ref), tA, tB, 9e21, tB, book);
        (, uint256 now_, uint256 probes) = _asks(address(solver), tA, tB, 9e21, tB, book);
        emit log_named_uint("  manager reads, cb1d7d9", was);
        emit log_named_uint("  manager reads, now", now_);
        emit log_named_uint("  probe passes", probes);
        assertGt(probes, 0, "precondition: the book is probed");
        assertEq(wasProbes, probes, "precondition: both Solvers build the hop as often");
        assertEq(was - now_, 2 * probes, "SQ2: the singleton candidate's context is built once per build, not at three quotes");
    }

    // ─── fixed rows: the same bytes ──────────────────────────────────────────

    /// Every kind the band can hold at once, at different fees, both ways.
    function test_Sq_SameAnswer_EveryKindInOneHop() public {
        _v2(tA, tB, 3e24, 3e24);
        _v2Held(tA, tB, 2e24, 2e24, 2e24, 2e24, 5);
        _solidly(tA, tB, 1e24, 1e24);
        _heavy(tA, tB, 500, 1e24, 5e21);
        _algebra(tA, tB, 1e24, 5e21);
        _v4On(tA, tB, 3000, 60, 0, -887220, 887220, 2e24);
        _row("six kinds, tA -> tB", tA, tB, 9e21);
        _row("six kinds, tB -> tA", tB, tA, 4e22);
    }

    /// The first row of the list sits outside the band, so the band's `map` moves every kept
    /// book one seat down: a context or a holdings reading left at its old seat is another
    /// pool's. The kept books differ in kind, fee and holdings.
    function test_Sq_SameAnswer_BandMovesTheSeats() public {
        _v2Held(tA, tB, 9e24, 72e23, 1e18, 1e18, 30);          // 20% off, and holding almost nothing
        _v2Held(tA, tB, 3e24, 3e24, 3e24, 3e24, 5);
        _heavy(tA, tB, 3000, 1e24, 2e22);
        _v2(tA, tB, 2e24, 2e24);
        RoutePlan memory plan = _row("out-of-band row first, tA -> tB", tA, tB, 9e21);
        assertGe(plan.best.hops[0].legs.length, 2, "precondition: the kept books split");
        _row("out-of-band row first, tB -> tA", tB, tA, 9e21);
    }

    /// Two rows, one outside the band: the hop is the kept row's single (nKept == 1), quoted with
    /// the context and the holdings the probe pass took for it at its old seat.
    function test_Sq_SameAnswer_OneKeptRowIsASingle() public {
        _v2Held(tA, tB, 9e24, 72e23, 1e18, 1e18, 30);
        address kept = _heavy(tA, tB, 3000, 1e24, 2e22);
        RoutePlan memory plan = _row("one kept row", tA, tB, 9e21);
        assertEq(plan.best.hops[0].legs.length, 1, "precondition: a single");
        assertEq(plan.best.hops[0].legs[0].pool, kept, "precondition: the kept row is the heavy book");
    }

    /// A lone row of each kind: no probe pass ran, so the single reads the holdings itself.
    function test_Sq_SameAnswer_LoneRowOfEachKind() public {
        address[3] memory b = [_bridge(), _bridge(), _bridge()];
        _v2(tA, b[0], 3e24, 3e24);
        _heavy(b[0], b[1], 3000, 1e24, 2e22);
        _v4On(b[1], b[2], 3000, 60, 0, -887220, 887220, 2e24);
        _solidly(b[2], tB, 1e24, 1e24);
        _algebra(tA, tB, 1e24, 5e21);
        _row("lone V2", tA, b[0], 9e21);
        _row("lone V3, the cap binds", b[0], b[1], 9e21);
        _row("lone V4", b[1], b[2], 9e21);
        _row("lone Solidly", b[2], tB, 9e21);
        _row("lone Algebra", tA, tB, 9e21);
    }

    /// A reserve book whose promise for the whole order stands one wei under, at and one wei
    /// over what it holds of tokenOut: the single's refusal (`out > held`) reads the holdings
    /// the probe pass took, and falls on the same side of the edge as before.
    function test_Sq_SameAnswer_PromiseAtTheEdgeOfTheHoldings() public {
        uint256 amt = 9e21;
        uint256 rs = 3e24;
        uint256 out = amt * 997 * rs / (rs * 1000 + amt * 997);   // V2 at 30 bps, the whole order
        for (uint256 k; k < 3; ++k) {
            _deploy();
            _v2(tA, tB, 2e24, 2e24);
            _v2Held(tA, tB, rs, rs, rs, out + k - 1, 30);
            _row(k == 0 ? "holdings = promise - 1" : k == 1 ? "holdings = promise" : "holdings = promise + 1", tA, tB, amt);
        }
    }

    /// Two hops over a bridge, mixed kinds on both stages, and the direct pair beside it.
    function test_Sq_SameAnswer_TwoHopsMixedKinds() public {
        address x = _bridge();
        _v2(tA, x, 3e24, 3e24);
        _heavy(tA, x, 500, 1e24, 2e22);
        _v4On(tA, x, 3000, 60, 0, -887220, 887220, 2e24);
        _solidly(x, tB, 3e24, 3e24);
        _algebra(x, tB, 1e24, 2e22);
        _v2Held(x, tB, 2e24, 2e24, 2e24, 2e24, 5);
        _v2(tA, tB, 1e21, 1e21);
        _row("two hops, tA -> tB", tA, tB, 9e21);
        _row("two hops, tB -> tA", tB, tA, 9e21);
    }

    // ─── a hostile tokenOut: the refusals are the same ───────────────────────

    /// A lone concentrated book and an order of one wei: the quote is zero, so the holdings are
    /// never asked for, and a tokenOut whose `balanceOf` refuses changes nothing. Read before
    /// the quote, they would turn the Solver's own answer into the refusal of a failed read.
    /// (A reserve book cannot show this: its quote reads the holdings by itself.)
    function test_Sq_SameRefusal_LoneRowReadsHoldingsOnlyAfterAQuote() public {
        SqMoodyToken m = new SqMoodyToken();
        touched.push(address(m));
        _heavy(tA, address(m), 3000, 1e24, 2e22);
        m.setSour(true);
        (bool ok, bytes memory out, , ) = _same(tA, address(m), 1, gasleft(), true);
        assertFalse(ok, "precondition: one wei finds no route");
        assertEq(bytes4(out), BlazePhoenixSolver.SolverE.selector, "precondition: the Solver of cb1d7d9 refuses in its own words, so it never asked for the holdings");
        _same(tA, address(m), 1, SOLVE_GAS, false);
    }

    // ─── the coincidence the change leans on, pinned ─────────────────────────

    /// The probe pass leaves a singleton book's seat in `balsOut` at zero: unmeasured, not
    /// empty. The single may take its holdings from that seat only because no kind is both a
    /// singleton book and judged by its holdings. A kind that were both needs its own reading.
    function test_Sq_NoSingletonKindIsJudgedByItsHoldings() public pure {
        for (uint256 k; k < 256; ++k) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 kind = uint8(k);
            assertFalse(
                BPC.kindHasAny(kind, BPC.A_CONC_SING) && BPC.kindHasAny(kind, BPC.A_RESERVES | BPC.A_CONC_POOL),
                "a singleton kind judged by pool holdings: Solver._singleLeg must read them for it"
            );
        }
    }

    // ─── fuzz ────────────────────────────────────────────────────────────────

    function _w(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// A book on (a, b) drawn from `w`: its kind, its depth, its price (at the market or 20%
    /// off it), its fee, and for the reserve kinds whether it holds what it declares.
    function _book(address a, address b, uint256 w) internal {
        uint16[4] memory pct = [uint16(100), 100, 120, 80];
        uint24[4] memory fees = [uint24(30), 5, 100, 1];
        uint256 d = 1e21 * (1 + w % 1000);
        uint256 rb = d * pct[(w >> 16) % 4] / 100;
        uint256 kind = (w >> 24) % 6;
        if (kind == 0) _v2Held(a, b, d, rb, d, rb, fees[(w >> 32) % 4]);
        else if (kind == 1) _v2Held(a, b, d, rb, d / (1 + (w >> 40) % 2000), rb / (1 + (w >> 56) % 2000), 30);
        else if (kind == 2) _solidly(a, b, d, rb);
        else if (kind == 3) _heavy(a, b, [uint24(3000), 500, 10_000, 100][(w >> 32) % 4], uint128(d), 1e18 * (1 + (w >> 40) % 1e6));
        else if (kind == 4) _algebra(a, b, uint128(d), 1e18 * (1 + (w >> 40) % 1e6));
        else {
            uint256 t = (w >> 32) % 3;
            uint24 fee = [uint24(3000), 500, 100][t];
            int24 ts = [int24(60), 10, 1][t];   // the spacing the Hub recovers for the fee
            (address c0, address c1) = a < b ? (a, b) : (b, a);
            bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, ts, address(0));
            if (!_v4Seeded[pid]) {
                _v4Seeded[pid] = true;
                _v4On(a, b, fee, ts, 0, -887220, 887220, uint128(d));
            }
        }
    }

    mapping(bytes32 => bool) internal _v4Seeded;

    /// A one-wei order over five direct books and a bridge (the fuzz's seed 11933): the route pays
    /// one wei and nets to zero after the input fees, so the 4007 floor is zero. Red before the
    /// 4007 frame read the floor of an output of at most BPS wei on the net output (it kept the
    /// reference's gross floor, 1).
    function test_Sq_SameAnswer_OneWeiOrderNetsToAZeroFloor() public {
        testFuzz_Sq_SameAnswer(11933);
    }

    /// A two-wei order over three direct books (the fuzz's seed 116847): it nets to one wei, and
    /// every floor rate the reference's gross floor of two admits gives a 4007 floor of one.
    /// A 700-wei order paying 838 wei (the fuzz's seed 307163716377032989948697243942600083929): the
    /// reference's floor of 804 admits a band of floor rates, and on the net output they give the
    /// floors [801, 802], one wei wide; the Solver's 801 sits inside. Red with the band collapsed
    /// to its top rate (a single floor, 802).
    function test_Sq_SameAnswer_DustOrderFloorIsInsideTheRateBand() public {
        testFuzz_Sq_SameAnswer(307163716377032989948697243942600083929);
    }

    function test_Sq_SameAnswer_TwoWeiOrderNetsToAOneWeiFloor() public {
        testFuzz_Sq_SameAnswer(116847);
    }

    /// Up to six books on the direct pair and up to two bridges with up to three books on each
    /// stage, every kind, forged and honest holdings, from one wei to 9e27: both Solvers give
    /// the same bytes, both ways, cold and warm, with all the gas and at the door's budget.
    function testFuzz_Sq_SameAnswer(uint256 seed) public {
        uint256 nDirect = seed % 7;
        for (uint256 i; i < nDirect; ++i) _book(tA, tB, _w(seed, i));
        uint256 nb = (seed >> 8) % 3;
        for (uint256 i; i < nb; ++i) _bridge();
        for (uint256 i; i < nb; ++i) {
            uint256 nx = 1 + (_w(seed, 50 + i) % 3);
            for (uint256 k; k < nx; ++k) {
                _book(tA, bridges[i], _w(seed, 100 + 10 * i + k));
                _book(bridges[i], tB, _w(seed, 200 + 10 * i + k));
            }
            for (uint256 j; j < i; ++j) if (_w(seed, 300 + 10 * i + j) % 2 == 0) _book(bridges[j], bridges[i], _w(seed, 400 + 10 * i + j));
        }
        uint256 amt = (1 + (seed >> 16) % 9) * 10 ** ((seed >> 24) % 28);
        _sameEveryWay(tA, tB, amt);
        _sameEveryWay(tB, tA, amt);
    }

    /// The edge of the holdings, drawn: a forged reserve book whose holdings stand within a few
    /// wei of its promise for the whole order, beside an honest one.
    function testFuzz_Sq_SameAnswer_AroundTheHoldings(uint256 amt, uint256 rs, int256 off) public {
        amt = bound(amt, 1e6, 1e24);
        rs = bound(rs, 1e21, 1e27);
        off = bound(off, -3, 3);
        uint256 out = amt * 997 * rs / (rs * 1000 + amt * 997);
        uint256 held = off < 0 ? out - uint256(-off) : out + uint256(off);
        _v2(tA, tB, rs, rs);
        _v2Held(tA, tB, rs, rs, rs, held, 30);
        _sameEveryWay(tA, tB, amt);
    }
}

/// The same claim over a state that moves: books are added, donated to and re-declared between
/// solves, and after every step both Solvers answer the same bytes.
contract SqSameAnswerInvariantTest is SqFixture {
    address[] v2s;
    uint256 public steps;

    function setUp() public {
        _deploy();
        _bridge();
        v2s.push(_v2(tA, tB, 3e24, 3e24));
        v2s.push(_v2(tA, tB, 2e24, 2e24));
        _heavy(tA, tB, 3000, 1e24, 2e22);
        v2s.push(_v2(tA, bridges[0], 3e24, 3e24));
        v2s.push(_v2(bridges[0], tB, 3e24, 3e24));
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = this.actAddBook.selector;
        sel[1] = this.actDonate.selector;
        sel[2] = this.actDeclare.selector;
        sel[3] = this.actAddHeavy.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
    }

    function _pair(uint256 w) internal view returns (address a, address b) {
        uint256 k = w % 3;
        (a, b) = k == 0 ? (tA, tB) : k == 1 ? (tA, bridges[0]) : (bridges[0], tB);
    }

    function actAddBook(uint256 w) external {
        (address a, address b) = _pair(w);
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        if (hub.getActivePools(c0, c1).length >= 8) return;
        uint256 d = 1e21 * (1 + (w >> 8) % 1000);
        v2s.push(_v2Held(a, b, d, d, d / (1 + (w >> 24) % 3), d / (1 + (w >> 32) % 3), (w >> 40) % 2 == 0 ? 30 : 5));
        ++steps;
    }

    function actAddHeavy(uint256 w) external {
        (address a, address b) = _pair(w);
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        if (hub.getActivePools(c0, c1).length >= 8) return;
        _heavy(a, b, [uint24(3000), 500, 10_000, 100][(w >> 8) % 4], uint128(1e21 * (1 + (w >> 16) % 1000)), 1e18 * (1 + (w >> 40) % 1e6));
        ++steps;
    }

    /// Anyone can send a pool tokens: its holdings move, its reserves do not.
    function actDonate(uint256 i, uint256 amt, bool side) external {
        MockV2Pair p = MockV2Pair(v2s[i % v2s.length]);
        MockERC20(side ? p.token0() : p.token1()).mint(address(p), bound(amt, 1, 1e24));
        ++steps;
    }

    /// The pool states other reserves than it holds.
    function actDeclare(uint256 i, uint256 r0, uint256 r1) external {
        MockV2Pair(v2s[i % v2s.length]).setReserves(uint112(bound(r0, 1e18, 1e27)), uint112(bound(r1, 1e18, 1e27)));
        ++steps;
    }

    function invariant_Sq_BothSolversAnswerTheSameBytes() public {
        _same(tA, tB, 9e21, gasleft(), true);
        _same(tB, tA, 3e19, gasleft(), false);
    }

    function afterInvariant() public view {
        assertGt(steps, 0, "precondition: the state moved, so the invariant held over more than the fixture");
    }
}
