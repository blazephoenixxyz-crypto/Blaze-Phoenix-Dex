// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// D10 META-GUARD: THE MOVE TO `BlazePhoenixMath` CHANGES NO ANSWER, TO THE WEI.
//
// The hop's arithmetic (median, band, compaction, weights, funnel cut, seat of the remainder)
// left the Solver for a linked library the Solver delegatecalls once per hop. The library works
// on its own ABI copy of the arrays and answers with the permutation it applied; the Solver
// replays it on its own arrays. A replay that drifts, two arguments of the same type passed in
// the wrong order, an early exit taken at another point, or a boundary that costs a walk its
// budget would each change an answer without any other test having a reason to look.
//
// So the answer is compared whole. `SolverRef59ecf3f` is the Solver of 59ecf3f, literally (the
// code before the move); both Solvers read the same Hub and the same state, and each call must
// come back with the same success and the same returndata bytes. The fixed rows are the shapes
// the moved code decides on (an outlier against the band, a funnel cut over more candidates
// than legs, concentrated books voting with what they hold, bridge stages whose second pass
// reads the permuted list, capacity-held grids whose walk runs on its own budget, refusals);
// the fuzz row draws pools, prices, depths, bridges and amounts. Every comparison also runs at
// the door's budget (SOLVE_GAS), where the boundary's gas could change a walk's outcome.
//
// The rows also log the cold gas of both Solvers on the same state: the boundary's overhead is
// measured here, not estimated.

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {SolverRef59ecf3f} from "./ref/SolverRef59ecf3f.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {HeavyBookPool, BurnBookPool} from "./CapacityWalkBudget.t.sol";

contract MathBoundarySameAnswerTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    SolverRef59ecf3f ref;
    MockV4TickManager mgr;
    address tA;
    address tB;
    address[] touched;

    /// Mirrors `BlazePhoenixRouter.SOLVE_GAS`, the budget the automatic door hands a solve.
    uint256 constant SOLVE_GAS = 14_700_000;
    uint160 constant SP = uint160(1 << 96);   // price 1, tick 0
    uint128 constant L = 1_000e18;
    int24 constant TS = 60;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        ref = new SolverRef59ecf3f(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(this));
        address a = _token();
        address b = _token();
        (tA, tB) = a < b ? (a, b) : (b, a);
        MockERC20(tA).mint(address(mgr), 1e30);
        MockERC20(tB).mint(address(mgr), 1e30);
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

    /// A curated V2 row holding `ra` of `a` and `rb` of `b`.
    function _v2(address a, address b, uint256 ra, uint256 rb) internal returns (address) {
        MockV2Pair p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), ra);
        MockERC20(b).mint(address(p), rb);
        (uint256 r0, uint256 r1) = p.token0() == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), a, b);
        touched.push(address(p));
        return address(p);
    }

    /// The same pool found by discovery (its factory is admitted) and then traded once through
    /// the swap door, as test/BandBaseBreakdownPoint.t.sol wires its pools.
    function _v2Found(address a, address b, uint256 ra, uint256 rb) internal returns (address) {
        MockV2Pair p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), ra);
        MockERC20(b).mint(address(p), rb);
        (uint256 r0, uint256 r1) = p.token0() == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        touched.push(address(Origin.wire(hub, address(p), a, b, BPC.KIND_V2, 30)));
        hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0), a, b, 1e18, 1e18, ra < rb ? ra : rb);
        touched.push(address(p));
        return address(p);
    }

    /// A V4 book on (tA, tB) at `tick`, liquidity `liq` over [lo, hi].
    function _v4(uint24 fee, int24 ts, int24 tick, int24 lo, int24 hi, uint128 liq) internal {
        bytes32 pid = BPC.computeV4PoolId(tA, tB, fee, ts, address(0));
        mgr.initialize(pid, mgr.sqrtAt(tick), tick, fee);
        mgr.addPosition(pid, lo, hi, ts, liq);
        hub.seedPool(address(uint160(uint256(pid))), BPC.KIND_V4, fee, address(0), tA, tB);
    }

    /// A V3 book the cap binds (test/CapacityWalkBudget.t.sol's), twenty ticks on each side.
    function _heavy(address a, address b, uint24 fee, uint128 liq, uint256 held) internal {
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
    }

    /// test/CapacityWalkBudget.t.sol's grid: every pair of tA, tB and `nBridges` bridges gets
    /// `perPair` heavy books holding `held`, the direct books declaring `dLiq`.
    function _grid(uint256 nBridges, uint256 perPair, uint256 held, uint128 dLiq) internal {
        uint24[6] memory fees = [uint24(3_000), 500, 10_000, 100, 2_500, 400];
        address[] memory b = new address[](nBridges);
        for (uint256 i; i < nBridges; ++i) { b[i] = _token(); hub.addBridge(b[i]); }
        for (uint256 k; k < perPair; ++k) {
            _heavy(tA, tB, fees[k], dLiq, held);
            for (uint256 i; i < nBridges; ++i) {
                _heavy(tA, b[i], fees[k], L, held);
                _heavy(b[i], tB, fees[k], L, held);
                for (uint256 j; j < i; ++j) _heavy(b[j], b[i], fees[k], L, held);
            }
        }
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    // ─── the comparison ──────────────────────────────────────────────────────

    /// Both Solvers on the same call, cold, with the same gas: the same success and the same
    /// bytes. Returns how many times the new one delegatecalled `select`, and both gas figures.
    function _same(address a, address b, uint256 amt, uint256 g)
        internal returns (bool ok, uint256 selects, uint256 gasNew, uint256 gasRef)
    {
        bytes memory q = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (a, b, amt));
        _cool();
        vm.startStateDiffRecording();
        uint256 g0 = gasleft();
        (bool okN, bytes memory rN) = address(solver).staticcall{gas: g}(q);
        gasNew = g0 - gasleft();
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        _cool();
        g0 = gasleft();
        (bool okR, bytes memory rR) = address(ref).staticcall{gas: g}(q);
        gasRef = g0 - gasleft();
        assertEq(okN, okR, "D10: one Solver answered and the other refused");
        assertEq(rN, rR, "D10: the Solver with the library and the Solver of 59ecf3f disagree");
        ok = okN;
        for (uint256 i; i < recs.length; ++i) {
            if (recs[i].kind != VmSafe.AccountAccessKind.DelegateCall) continue;
            if (recs[i].account != address(BlazePhoenixMath)) continue;
            assertEq(bytes4(recs[i].data), BlazePhoenixMath.select.selector, "the Solver enters the library only through select");
            ++selects;
        }
    }

    /// The comparison with all the gas, then at the door's budget; the first must find a route.
    function _row(string memory name, address a, address b, uint256 amt) internal {
        (bool ok, uint256 selects, uint256 gN, uint256 gR) = _same(a, b, amt, gasleft());
        assertTrue(ok, "precondition: the row has a route, so the comparison is not of two refusals");
        assertGt(selects, 0, "precondition: the row reaches the library");
        emit log_named_string("row", name);
        emit log_named_uint("  amountIn", amt);
        emit log_named_uint("  select calls", selects);
        emit log_named_uint("  gas new, cold", gN);
        emit log_named_uint("  gas 59ecf3f, cold", gR);
        emit log_named_int("  boundary overhead", int256(gN) - int256(gR));
        (ok, , gN, ) = _same(a, b, amt, SOLVE_GAS);
        emit log_named_string("  at SOLVE_GAS", ok ? "both answered, same bytes" : "both refused, same bytes");
    }

    // ─── fixed rows ──────────────────────────────────────────────────────────

    /// Three honest books and one deep book far from their rate, below it, above it, short of
    /// half the mass and past it (test/BandBaseBreakdownPoint.t.sol's shapes).
    function test_D10_SameAnswer_BandAgainstAnOutlier() public {
        for (uint256 i; i < 3; ++i) _v2Found(tA, tB, 400_000e18, 400_000e18);
        _row("3 honest books", tA, tB, 300_000e18);
        _v2Found(tA, tB, 600_000e18, 300_000e18);
        _row("an outlier below the rate", tA, tB, 300_000e18);
        _v2Found(tA, tB, 300_000e18, 600_000e18);
        _row("and one above", tA, tB, 300_000e18);
        _v2Found(tA, tB, 1_150_000e18, 2_300_000e18);
        _row("and one short of half the mass", tA, tB, 300_000e18);
        _v2Found(tA, tB, 5_000_000e18, 2_500_000e18);
        _row("and one past half the mass", tA, tB, 300_000e18);
        _row("the other way", tB, tA, 300_000e18);
    }

    /// Nine curated books, some in the band and some out, against a budget of four legs:
    /// the funnel cut and the seat of the remainder decide, at sizes from dust to the depth.
    function test_D10_SameAnswer_FunnelCutAndSeat() public {
        uint16[9] memory pct = [uint16(100), 100, 101, 99, 103, 97, 108, 90, 100];
        for (uint256 i; i < 9; ++i) {
            uint256 d = (i + 1) * 50_000e18;
            _v2(tA, tB, d, d * pct[i] / 100);
        }
        _row("9 books, dust", tA, tB, 1e18);
        _row("9 books, 1k", tA, tB, 1_000e18);
        _row("9 books, 100k", tA, tB, 100_000e18);
        _row("9 books, 1M", tA, tB, 1_000_000e18);
        _row("9 books, 1M, the other way", tB, tA, 1_000_000e18);
    }

    /// Discovered rows beside curated ones: the band's vote reads which rows are vouched.
    function test_D10_SameAnswer_CuratedBesideDiscovered() public {
        _v2(tA, tB, 400_000e18, 400_000e18);
        _v2(tA, tB, 300_000e18, 303_000e18);
        _v2Found(tA, tB, 2_000_000e18, 1_000_000e18);
        _v2Found(tA, tB, 500_000e18, 495_000e18);
        _row("2 curated, 2 discovered", tA, tB, 100_000e18);
        _row("the other way", tB, tA, 100_000e18);
    }

    /// Concentrated books vote with what they hold (test/V4MedianMassIsHeld.t.sol's shapes),
    /// beside a V2 book.
    function test_D10_SameAnswer_V4BooksVoteWithWhatTheyHold() public {
        _v4(3000, 60, 0, -887220, 887220, 1e24);
        _v4(100, 1, 584, 580, 588, 3e24);
        _row("a wide book and a narrow range", tA, tB, 1e21);
        _v4(500, 10, 0, -887220, 887220, 2e23);
        _v2(tA, tB, 1_000e18, 1_000e18);
        _row("and a second wide book and a V2 book", tA, tB, 1e21);
        _row("the other way", tB, tA, 1e21);
        _v4(10_000, 200, 584, -200, 1200, 2e28);
        _row("and a funded range", tA, tB, 1e21);
    }

    /// Direct books, one bridge with two books a side and a second bridge: a stage's second
    /// pass reads the list its first pass permuted.
    function test_D10_SameAnswer_BridgeStages() public {
        address x = _token();
        address y = _token();
        hub.addBridge(x);
        hub.addBridge(y);
        for (uint256 i; i < 3; ++i) _v2(tA, tB, 20_000e18 * (i + 1), 20_000e18 * (i + 1));
        for (uint256 i; i < 2; ++i) {
            _v2(tA, x, 300_000e18 * (i + 1), 300_000e18 * (i + 1));
            _v2(x, tB, 300_000e18 * (i + 1), 301_000e18 * (i + 1));
            _v2(tA, y, 100_000e18, 100_000e18 + i * 1_000e18);
            _v2(x, y, 200_000e18, 200_000e18);
            _v2(y, tB, 100_000e18, 100_000e18);
        }
        _row("3 direct, 2 bridges", tA, tB, 1_000e18);
        _row("3 direct, 2 bridges, large", tA, tB, 200_000e18);
        _row("the other way", tB, tA, 200_000e18);
    }

    /// Four held books, each paying more than its cap: the walk changes the plan.
    function test_D10_SameAnswer_HeldWalkChangesThePlan() public {
        _grid(0, 4, 100e18, L);
        _row("4 held books", tA, tB, 200e18);
    }

    /// The heaviest grid of test/CapacityWalkBudget.t.sol: the direct split leads held, and its
    /// rebuild runs past what the search left of the door's budget.
    function test_D10_SameAnswer_HeldGridThreeBridgesSixBooks() public {
        _grid(3, 6, 100e18, L);
        _row("held, 3 bridges, 6 books per pair", tA, tB, 200e18);
    }

    /// The same grid with thin direct books: a bridge route leads held, and its rebuild walks
    /// more books than the walk's budget holds.
    function test_D10_SameAnswer_HeldGridBridgeLeads() public {
        _grid(3, 6, 100e18, 100e18);
        _row("held, a bridge leads", tA, tB, 200e18);
    }

    /// Four held books whose every read burns its whole GAS_CAP.
    function test_D10_SameAnswer_HostileHeldBooks() public {
        for (uint256 k; k < 4; ++k) {
            BurnBookPool p = new BurnBookPool(tA, tB, uint24(500 + k * 1000));
            p.setState(SP, L);
            MockERC20(tA).mint(address(p), 60e18);
            MockERC20(tB).mint(address(p), 60e18);
            hub.seedPool(address(p), BPC.KIND_V3, uint24(500 + k * 1000), address(0), tA, tB);
            touched.push(address(p));
        }
        _row("4 hostile held books", tA, tB, 200e18);
    }

    /// The refusals are the same refusals: no venue, degenerate inputs.
    function test_D10_SameAnswer_Refusals() public {
        (bool ok, , , ) = _same(tA, tB, 1e18, gasleft());
        assertFalse(ok, "precondition: no venue, no route");
        (ok, , , ) = _same(tA, tA, 1e18, gasleft());
        assertFalse(ok, "precondition: a self-hop is refused");
        (ok, , , ) = _same(tA, tB, 0, gasleft());
        assertFalse(ok, "precondition: a zero amount is refused");
        _v2(tA, tB, 1_000e18, 1_000e18);
        uint256 selects;
        (ok, selects, , ) = _same(tA, tB, 1e18, gasleft());
        assertTrue(ok, "precondition: one book is a route");
        assertEq(selects, 0, "a lone candidate is quoted without the library");
    }

    // ─── fuzz ────────────────────────────────────────────────────────────────

    /// A V2 book of depth 1e21..1e24 at one of ten rates around 1 (some inside the band, some
    /// outside), curated or discovered.
    function _v2Rand(address a, address b, uint256 w) internal {
        uint16[10] memory pct = [uint16(100), 100, 101, 99, 103, 97, 106, 94, 120, 80];
        uint256 d = 1e21 * (1 + w % 1000);
        uint256 rb = d * pct[(w >> 16) % 10] / 100;
        if ((w >> 32) % 4 == 0) _v2Found(a, b, d, rb);
        else _v2(a, b, d, rb);
    }

    function _w(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// Pools, rates, depths, bridges, concentrated books and amounts drawn from one seed: both
    /// Solvers give the same bytes, both ways, with all the gas and at the door's budget.
    function testFuzz_D10_SameAnswer(uint256 seed) public {
        uint256 nDirect = 1 + seed % 9;
        for (uint256 i; i < nDirect; ++i) _v2Rand(tA, tB, _w(seed, i));
        if ((seed >> 8) & 1 == 1) {
            address x = _token();
            hub.addBridge(x);
            uint256 nx = 1 + (seed >> 9) % 3;
            for (uint256 i; i < nx; ++i) {
                _v2Rand(tA, x, _w(seed, 100 + i));
                _v2Rand(x, tB, _w(seed, 200 + i));
            }
        }
        if ((seed >> 12) & 1 == 1) _v4(3000, 60, 0, -887220, 887220, uint128(1e22 * (1 + _w(seed, 300) % 1000)));
        if ((seed >> 13) & 1 == 1) {
            int24 t = int24(int256(_w(seed, 301) % 1201)) - 600;
            _v4(100, 1, t, t - 4, t + 4, uint128(1e22 * (1 + _w(seed, 302) % 10_000)));
        }
        uint256 amt = (1 + (seed >> 16) % 9) * 10 ** (15 + (seed >> 24) % 10);
        (bool ok, uint256 selects, , ) = _same(tA, tB, amt, gasleft());
        if (ok && nDirect > 1) assertGt(selects, 0, "precondition: a pair with several books reaches the library");
        _same(tA, tB, amt, SOLVE_GAS);
        _same(tB, tA, amt, gasleft());
        _same(tB, tA, amt, SOLVE_GAS);
    }
}
