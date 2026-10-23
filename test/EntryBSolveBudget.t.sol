// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  R1 - THE SOLVE INSIDE ENTRY B HAS A FIXED GAS BUDGET, AND IT FAILS CLOSED
//
//  Entry B (`Router.swapBestExactIn`) runs `Solver.findBestRoutePlan` inside the
//  transaction. Entry A runs the same view through `eth_call` and sends the plan
//  as calldata. The solve's cost is not bounded by anything the caller chooses:
//  every V4 pool fragmented by one-wei positions costs at least one deep walk of
//  the order (~8.6k gas per stretch, cold), and how many pools on the plan's
//  reach are fragmented is the attacker's choice (`modifyLiquidity` and `claimV4`
//  are permissionless). No optimisation of the solve can bound that; a fixed
//  budget that reverts can.
//
//  `SOLVE_GAS` caps the gas the Router forwards to the solve. An over-budget solve
//  reverts with RouterE(17) early, inside the per-transaction gas cap (EIP-7825,
//  2^24), instead of running out of gas in the whole transaction. Every other
//  revert of the Solver passes through unchanged.
//
//  The property: entry B executes exactly the plan entry A quotes for the same
//  state, or it reverts. Never a different plan.
//
//    T1  test_EntryB_OverBudgetRevertsCleanUnderTheTxCap      red before the cap
//    T2  testFuzz_EntryB_EqualsEntryA_UnderBudget
//    T3  testFuzz_SolveGasCapNeverDegradesThePlan_*           a capped solve returns
//        the uncapped plan or nothing
//    T4  test_EntryB_HonestPlansFitWithMargin_*               honest plans use at most
//        a tenth of the budget (three bridges: a fifth), and entry B settles them
//    T5  test_Dust* / test_OneWeiDust*                        dust in the order's path
//        is liquidity the user consumes; one-wei dust costs at most rounding; dust
//        beyond the order's reach is never touched
//    M   test_Measure_DustTickMintVsWalk                      gas of minting a dust
//        tick in the mock against the gas of walking it (log only)
//
//  Fixture: the books of the V4 fragmentation gas study, on MockV4TickManager. The
//  mock stores ticks and the bitmap at the singleton's offsets; it does not model the
//  PoolManager's position, fee-growth or settlement accounting, and its swap looks for
//  the next initialized tick one tick at a time rather than one bitmap word at a time,
//  so EXECUTION gas here is not the network's. The equality
//  checks therefore settle with the test's whole gas; only T1, where nothing executes,
//  runs under the per-transaction cap.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract EntryBSolveBudgetTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV2Factory fac;
    address t0;
    address t1;
    address user     = address(0xBEEF);
    address attacker = address(0xBAD);
    address[] touched;

    uint8   constant MODE_ASK = 0;
    int24   constant TS    = 1;
    uint128 constant L     = 1e24;
    uint256 constant DUST  = 600;
    uint256 constant ORDER = 1e22;

    /// Mirrors `BlazePhoenixRouter.SOLVE_GAS`: the search's 12M plus the capacity walk's own budget
    ///      (the walk that settles a leg held by `MAX_CONC_DRAIN_BPS`).
    uint256 constant SOLVE_GAS = 14_700_000;
    /// The search's share, on which T4's margins were set: SOLVE_GAS grew by the walk's budget
    /// only, so a share of it does not grow with it.
    uint256 constant SEARCH_GAS = 12_000_000;
    /// EIP-7825 per-transaction gas cap (2^24).
    uint256 constant TX_CAP = 16_777_216;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(0xC0FFEE));
        t0 = _token();
        t1 = _token();
        MockERC20(t0).mint(user, 100 * ORDER);
        vm.prank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
        fac = new MockV2Factory();
        hub.addFactory(address(fac), BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));
        touched.push(address(mgr));
        touched.push(address(hub));
        touched.push(address(solver));
        touched.push(address(router));
        touched.push(address(fac));
    }

    // ---- fixture ----------------------------------------------------------------------------

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        MockERC20(t).mint(address(mgr), 1e30);
        touched.push(t);
    }

    function _fee(uint256 i) internal pure returns (uint24) {
        uint24[8] memory f = [uint24(100), 500, 3000, 10_000, 50, 250, 1000, 2000];
        return f[i];
    }

    function _pid(address a, address b, uint24 fee) internal pure returns (bytes32) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return BPC.computeV4PoolId(c0, c1, fee, TS, address(0));
    }

    /// One honest V4 book for `a -> b`, with `dust` one-wei positions on the ticks the order walks.
    function _book(address a, address b, uint24 fee, uint256 dust) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, TS, address(0));
        mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, fee);
        mgr.addPosition(pid, -20_000, 20_000, TS, L);
        int24 d = int24(uint24(dust));
        vm.startPrank(attacker);
        if (a == c0) { for (int24 t = -d; t < 0; ++t) mgr.addPosition(pid, t, t + 1, TS, 1); }
        else         { for (int24 t = 0;  t < d; ++t) mgr.addPosition(pid, t, t + 1, TS, 1); }
        vm.stopPrank();
        hub.addV4(c0, c1, fee, TS, address(0));
    }

    function _books(address a, address b, uint256 k, uint256 dust) internal {
        for (uint256 i; i < k; ++i) _book(a, b, _fee(i), dust);
    }

    /// A thin V2 pair priced ~5.6% above the books: it forces the held vote's deep pass.
    function _thinRival() internal {
        MockV2Pair p = new MockV2Pair(t0, t1);
        fac.setPair(t0, t1, address(p));
        (uint112 r0, uint112 r1) = t0 < t1 ? (uint112(1e22), uint112(1.07e22)) : (uint112(1.07e22), uint112(1e22));
        MockERC20(p.token0()).mint(address(p), r0);
        MockERC20(p.token1()).mint(address(p), r1);
        p.setReserves(r0, r1);
        touched.push(address(p));
    }

    /// The direct hop and both hops through one bridge, four fragmented books on each.
    function _bridge4x3() internal {
        address br = _token();
        hub.addBridge(br);
        _books(t0, t1, 4, DUST);
        _books(t0, br, 4, DUST);
        _books(br, t1, 4, DUST);
    }

    /// `n` bridges, one book of `dust` on every pair among t0, t1 and the bridges.
    function _bridges(uint256 n, uint256 dust) internal {
        address[] memory b = new address[](n);
        for (uint256 i; i < n; ++i) { b[i] = _token(); hub.addBridge(b[i]); }
        _book(t0, t1, _fee(0), dust);
        for (uint256 i; i < n; ++i) {
            _book(t0, b[i], _fee(0), dust);
            _book(b[i], t1, _fee(0), dust);
            for (uint256 j; j < i; ++j) _book(b[j], b[i], _fee(0), dust);
        }
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    function _err(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// Entry B with an explicit gas limit. The calldata is built before the prank.
    function _entryB(uint256 order, uint256 gasLimit) internal returns (bool ok, bytes memory ret, uint256 used) {
        bytes memory cd = abi.encodeCall(
            BlazePhoenixRouter.swapBestExactIn, (t0, t1, order, 1, user, block.timestamp + 1)
        );
        vm.prank(user);
        uint256 g0 = gasleft();
        (ok, ret) = address(router).call{gas: gasLimit}(cd);
        used = g0 - gasleft();
    }

    function _deliveredB(uint256 order) internal returns (uint256 got) {
        uint256 b1 = MockERC20(t1).balanceOf(user);
        (bool ok, bytes memory ret, ) = _entryB(order, gasleft());
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        got = MockERC20(t1).balanceOf(user) - b1;
    }

    /// Entry A: the plan quoted off-chain, sent as calldata through `swapExactIn`.
    function _deliveredA(Route memory route, uint256 order) internal returns (uint256 got) {
        uint256 b1 = MockERC20(t1).balanceOf(user);
        uint256 dl = block.timestamp + 1;
        vm.prank(user);
        router.swapExactIn(route, order, 1, user, dl);
        got = MockERC20(t1).balanceOf(user) - b1;
    }

    /// Settle the same state through entry B and through entry A; both must deliver alike.
    function _bEqualsA(uint256 order) internal returns (uint256 gotB) {
        RoutePlan memory p = solver.findBestRoutePlan(t0, t1, order);
        uint256 snap = vm.snapshotState();
        gotB = _deliveredB(order);
        vm.revertToState(snap);
        uint256 gotA = _deliveredA(p.best, order);
        assertEq(gotB, gotA, "entry B delivered something entry A's plan does not");
    }

    /// The whole property: entry B settles entry A's plan, or reverts RouterE(17).
    function _bEqualsAOrStops(uint256 order) internal {
        RoutePlan memory p = solver.findBestRoutePlan(t0, t1, order);
        uint256 snap = vm.snapshotState();
        uint256 b1 = MockERC20(t1).balanceOf(user);
        (bool ok, bytes memory ret, ) = _entryB(order, gasleft());
        if (!ok) {
            assertEq(ret, _err(17), "entry B failed with something other than the budget stop");
            return;
        }
        uint256 gotB = MockERC20(t1).balanceOf(user) - b1;
        vm.revertToState(snap);
        assertEq(gotB, _deliveredA(p.best, order), "entry B delivered something entry A's plan does not");
    }

    // ---- T1: over budget, the transaction stops early and clean ----------------------------

    function test_EntryB_OverBudgetRevertsCleanUnderTheTxCap() public {
        _bridge4x3();
        uint256 in0 = MockERC20(t0).balanceOf(user);
        uint256 out0 = MockERC20(t1).balanceOf(user);
        _cool();
        (bool ok, bytes memory ret, uint256 used) = _entryB(ORDER, TX_CAP - 30_000);
        emit log_named_uint("entry B gas used, over budget", used);
        assertFalse(ok, "an over-budget solve settled");
        assertEq(ret, _err(17), "an over-budget solve must revert RouterE(17)");
        assertLt(used, SOLVE_GAS + 300_000, "the over-budget revert spent past the solve budget");
        assertEq(MockERC20(t0).balanceOf(user), in0, "input moved");
        assertEq(MockERC20(t1).balanceOf(user), out0, "output moved");
        // Non-vacuity: this book really is over budget for the uncapped solve (entry A).
        uint256 g0 = gasleft();
        solver.findBestRoutePlan(t0, t1, ORDER);
        uint256 plan = g0 - gasleft();
        emit log_named_uint("entry A plan gas, warm", plan);
        assertGt(plan, SOLVE_GAS, "the fixture is not over budget");
    }

    /// A Solver revert that is not out-of-gas reaches the caller unchanged.
    function test_EntryB_SolverRevertPassesThroughIntact() public {
        // No venue at all: the Solver refuses with its own error.
        (bool ok, bytes memory ret, ) = _entryB(ORDER, TX_CAP - 30_000);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)), "the Solver's own revert was rewritten");
    }

    // ---- T2: under budget, entry B is entry A ----------------------------------------------

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_EntryB_EqualsEntryA_UnderBudget(uint256 order, uint8 k, bool rival) public {
        order = bound(order, 1e18, 2e22);
        k = uint8(bound(k, 1, rival ? 2 : 3));
        _books(t0, t1, k, DUST);
        _book(t0, t1, _fee(4), 0);
        if (rival) _thinRival();
        _bEqualsAOrStops(order);
    }

    // ---- T3: a capped solve returns the uncapped plan or nothing ----------------------------

    function _planFixture() internal returns (bytes32 h, uint256 cost) {
        _books(t0, t1, 2, DUST);
        _book(t0, t1, _fee(4), 0);
        _thinRival();
        solver.findBestRoutePlan(t0, t1, ORDER); // warm, so the measured cost is the capped call's
        uint256 g0 = gasleft();
        RoutePlan memory ref = solver.findBestRoutePlan(t0, t1, ORDER);
        cost = g0 - gasleft();
        h = keccak256(abi.encode(ref));
    }

    function _capped(uint256 g, bytes32 h) internal view returns (bool done) {
        try solver.findBestRoutePlan{gas: g}(t0, t1, ORDER) returns (RoutePlan memory p) {
            assertEq(keccak256(abi.encode(p)), h, "a capped solve returned a different plan");
            done = true;
        } catch (bytes memory e) {
            assertEq(e.length, 0, "a capped solve failed with something other than out-of-gas");
        }
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_SolveGasCapNeverDegradesThePlan_NearTheThreshold(uint256 g) public {
        (bytes32 h, uint256 cost) = _planFixture();
        g = bound(g, cost - 200_000, cost + 50_000);
        _capped(g, h);
        // Non-vacuity: the range holds both outcomes.
        assertTrue(_capped(cost + 50_000, h), "the top of the range does not complete");
        assertFalse(_capped(cost - 200_000, h), "the bottom of the range completes");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_SolveGasCapNeverDegradesThePlan_AnyBudget(uint256 g) public {
        (bytes32 h, uint256 cost) = _planFixture();
        g = bound(g, 0, cost + 50_000);
        _capped(g, h);
    }

    // ---- T4: honest plans fit with margin, and entry B settles them -----------------------

    function _fits(string memory row, uint256 share) internal {
        _cool();
        uint256 g0 = gasleft();
        solver.findBestRoutePlan(t0, t1, ORDER);
        uint256 plan = g0 - gasleft();
        emit log_named_string("row", row);
        emit log_named_uint("  plan gas, cold", plan);
        assertLe(plan, SEARCH_GAS / share, "an honest plan uses more than its share of the search's budget");
        _bEqualsA(ORDER);
    }

    function test_EntryB_HonestPlansFitWithMargin_OneCleanBook() public { _books(t0, t1, 1, 0); _fits("1 clean book", 10); }
    function test_EntryB_HonestPlansFitWithMargin_FourCleanBooks() public { _books(t0, t1, 4, 0); _fits("4 clean books", 10); }
    function test_EntryB_HonestPlansFitWithMargin_TwoCleanBridges() public { _bridges(2, 0); _fits("2 bridges, 1 clean book per pair", 10); }
    // Three bridges measured 1,654,241 gas cold: a tenth does not hold, a fifth does.
    function test_EntryB_HonestPlansFitWithMargin_ThreeCleanBridges() public { _bridges(3, 0); _fits("3 bridges, 1 clean book per pair", 5); }

    // ---- T5: dust is liquidity; inside the order's path it pays the user -------------------

    uint128 constant DUST_LIQ = 1e18; // a millionth of the book

    function _dustBook(int24 lo, int24 hi, uint128 liq) internal returns (uint256 clean, uint256 dusty) {
        _book(t0, t1, _fee(0), 0);
        bytes32 pid = _pid(t0, t1, _fee(0));
        uint256 snap = vm.snapshotState();
        clean = _bEqualsA(ORDER);
        vm.revertToState(snap);
        vm.startPrank(attacker);
        for (int24 t = lo; t < hi; ++t) mgr.addPosition(pid, t, t + 1, TS, liq);
        vm.stopPrank();
        dusty = _bEqualsA(ORDER);
        emit log_named_uint("delivered, clean book", clean);
        emit log_named_uint("delivered, with dust ", dusty);
    }

    /// The order's path from tick 0: zeroForOne walks down, oneForZero walks up.
    function _path(int24 a, int24 b) internal view returns (int24 lo, int24 hi) {
        (lo, hi) = t0 < t1 ? (-b, -a) : (a, b);
    }

    function test_DustInsideTheOrderPathPaysTheUser() public {
        // ORDER crosses ~200 ticks; the dust sits on the first 150, at prices better than
        // the order's last one.
        (int24 lo, int24 hi) = _path(0, 150);
        (uint256 clean, uint256 dusty) = _dustBook(lo, hi, DUST_LIQ);
        assertGt(dusty, clean, "liquidity on the order's path was not consumed in the user's favour");
    }

    /// One-wei positions add no depth worth a wei, but each one splits a swap step in
    /// two, and every step rounds against the swapper (MockV4TickManager.specSwap): the
    /// input to the target up twice and the fee on it up once (3 wei of input), the
    /// output down at most twice (2 wei). At a price within 2 % of one that is under 6 wei
    /// of output per extra step, and 150 positions add 151 boundaries. So the user may
    /// lose rounding, and nothing more.
    function test_OneWeiDustInsideTheOrderPathCostsTheUserAtMostRounding() public {
        (int24 lo, int24 hi) = _path(0, 150);
        (uint256 clean, uint256 dusty) = _dustBook(lo, hi, 1);
        emit log_named_uint("rounding lost to one-wei dust, wei", clean > dusty ? clean - dusty : 0);
        assertGe(dusty + 6 * 151, clean, "one-wei dust on the path cost the user more than rounding");
    }

    function test_DustBeyondTheOrderReachIsIgnored() public {
        // Ticks 600..800 away: prices worse than any the order reaches.
        (int24 lo, int24 hi) = _path(600, 800);
        (uint256 clean, uint256 dusty) = _dustBook(lo, hi, DUST_LIQ);
        assertEq(dusty, clean, "liquidity beyond the order's reach changed what the user got");
    }

    // ---- M: what a dust tick costs to mint (in the mock) and to walk -----------------------

    function test_Measure_DustTickMintVsWalk() public {
        bool z = t0 < t1;
        // A clean book each; dust on 50 and on 150 ticks of the order's path.
        _book(t0, t1, _fee(0), 0);
        _book(t0, t1, _fee(1), 0);
        bytes32 p50 = _pid(t0, t1, _fee(0));
        bytes32 p150 = _pid(t0, t1, _fee(1));
        (int24 lo50, int24 hi50) = _path(0, 50);
        (int24 lo150, int24 hi150) = _path(0, 150);

        // Mint: one isolated dust position on untouched ticks (two new ticks), cold, in a
        // third book so the walks below do not see it.
        _book(t0, t1, _fee(2), 0);
        (int24 ilo, ) = _path(5000, 5001);
        bytes32 pIso = _pid(t0, t1, _fee(2));
        _cool();
        vm.prank(attacker);
        uint256 g0 = gasleft();
        mgr.addPosition(pIso, ilo, ilo + 1, TS, 1);
        emit log_named_uint("mint, one isolated dust position (2 new ticks), cold", g0 - gasleft());

        // Mint: a run of consecutive dust positions, cold; per position = one new tick.
        _cool();
        vm.startPrank(attacker);
        g0 = gasleft();
        for (int24 t = lo150; t < hi150; ++t) mgr.addPosition(p150, t, t + 1, TS, 1);
        uint256 run = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("mint, 150 consecutive dust positions, cold, total", run);
        emit log_named_uint("mint, per consecutive dust position", run / 150);
        vm.startPrank(attacker);
        for (int24 t = lo50; t < hi50; ++t) mgr.addPosition(p50, t, t + 1, TS, 1);
        vm.stopPrank();

        // Walk: the deep walk of the order (bar 0) over 50 and over 150 dust ticks, cold.
        _cool();
        g0 = gasleft();
        BPC.v4WalkRank(address(mgr), p50, ORDER, _fee(0), TS, z, 0);
        uint256 w50 = g0 - gasleft();
        _cool();
        g0 = gasleft();
        BPC.v4WalkRank(address(mgr), p150, ORDER, _fee(1), TS, z, 0);
        uint256 w150 = g0 - gasleft();
        emit log_named_uint("walk, order over 50 dust ticks, cold", w50);
        emit log_named_uint("walk, order over 150 dust ticks, cold", w150);
        emit log_named_uint("walk, per dust tick (marginal), cold", (w150 - w50) / 100);
        // Warm, the same two walks.
        g0 = gasleft();
        BPC.v4WalkRank(address(mgr), p50, ORDER, _fee(0), TS, z, 0);
        w50 = g0 - gasleft();
        g0 = gasleft();
        BPC.v4WalkRank(address(mgr), p150, ORDER, _fee(1), TS, z, 0);
        w150 = g0 - gasleft();
        emit log_named_uint("walk, per dust tick (marginal), warm", (w150 - w50) / 100);
        assertGt(w150, w50);
    }
}
