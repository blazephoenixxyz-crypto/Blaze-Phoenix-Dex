// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// S2 follow-up: the gas a fragmented V4 book costs the planner when SEVERAL pools of the same
// hop are fragmented at once. Every V4 quote the sixteen-stretch walk leaves truncated is walked
// on to V4_WALK_DEEP_STEPS (256) when it is asked for a rank, and the held vote's third pass
// walks each cut vote with an unbounded input - 256 stretches per pool, every time. Each test
// measures `findBestRoutePlan` and `swapBestExactIn` with every touched account cooled first
// (`vm.cool`), so the figures are cold-storage figures, not the warm ones a test's own setup
// leaves behind. The swap figure also carries the mock pool manager's own execution, which is
// not a model of the PoolManager's cost; the plan figure is the one that measures the planner.
//
// Book: L = 1e24 over [-20,000, 20,000] at tickSpacing 1, one-wei positions on every tick of
// the order's path (600 of them, past the deep walk's reach). Order 1e22 crosses ~200 ticks.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract V4FragmentationGasTest is Test {
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
    int24   constant TS   = 1;
    uint128 constant L    = 1e24;
    uint256 constant DUST = 600;
    uint256 constant ORDER = 1e22;
    /// The plan must stay quotable in one ordinary `eth_call`.
    uint256 constant PLAN_GAS_CEILING = 30_000_000;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
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

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        MockERC20(t).mint(address(mgr), 1e30);
        touched.push(t);
    }

    function _fee(uint256 i) internal pure returns (uint24) {
        uint24[8] memory f = [uint24(100), 500, 3000, 10_000, 50, 250, 1000, 2000];
        return f[i];
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

    /// A thin V2 pair priced ~5.6% above the books: under the cut held votes it sets the band
    /// alone, under the uncut ones it falls out - so the held vote's deep third pass runs.
    function _thinRival() internal {
        MockV2Pair p = new MockV2Pair(t0, t1);
        fac.setPair(t0, t1, address(p));
        (uint112 r0, uint112 r1) = t0 < t1 ? (uint112(1e22), uint112(1.07e22)) : (uint112(1.07e22), uint112(1e22));
        MockERC20(p.token0()).mint(address(p), r0);
        MockERC20(p.token1()).mint(address(p), r1);
        p.setReserves(r0, r1);
        touched.push(address(p));
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    function _measure(string memory row, uint256 order) internal returns (uint256 gPlan, uint256 gSwap) {
        _cool();
        uint256 g0 = gasleft();
        solver.findBestRoutePlan(t0, t1, order);
        gPlan = g0 - gasleft();
        _cool();
        vm.prank(user);
        g0 = gasleft();
        router.swapBestExactIn(t0, t1, order, 1, user, block.timestamp + 1);
        gSwap = g0 - gasleft();
        emit log_named_string("row ", row);
        emit log_named_uint("  plan gas", gPlan);
        emit log_named_uint("  swap gas", gSwap);
        assertLt(gPlan, PLAN_GAS_CEILING, "a fragmented book pushed the plan past its gas ceiling");
    }

    // ---- the typical quote ------------------------------------------------------------------

    function test_Gas_Typical_OneCleanBook() public { _books(t0, t1, 1, 0); _measure("1 clean book", ORDER); }
    function test_Gas_Typical_FourCleanBooks() public { _books(t0, t1, 4, 0); _measure("4 clean books", ORDER); }

    // ---- k fragmented books on the one hop ---------------------------------------------------

    function test_Gas_Fragmented_1() public { _books(t0, t1, 1, DUST); _measure("1 fragmented", ORDER); }
    function test_Gas_Fragmented_2() public { _books(t0, t1, 2, DUST); _measure("2 fragmented", ORDER); }
    function test_Gas_Fragmented_3() public { _books(t0, t1, 3, DUST); _measure("3 fragmented", ORDER); }
    function test_Gas_Fragmented_4() public { _books(t0, t1, 4, DUST); _measure("4 fragmented", ORDER); }
    function test_Gas_Fragmented_8() public { _books(t0, t1, 8, DUST); _measure("8 fragmented", ORDER); }

    // ---- the same, with the held vote's deep third pass forced ------------------------------

    function test_Gas_HeldPass2_1() public { _books(t0, t1, 1, DUST); _thinRival(); _measure("1 fragmented + held pass 2", ORDER); }
    function test_Gas_HeldPass2_2() public { _books(t0, t1, 2, DUST); _thinRival(); _measure("2 fragmented + held pass 2", ORDER); }
    function test_Gas_HeldPass2_3() public { _books(t0, t1, 3, DUST); _thinRival(); _measure("3 fragmented + held pass 2", ORDER); }
    function test_Gas_HeldPass2_4() public { _books(t0, t1, 4, DUST); _thinRival(); _measure("4 fragmented + held pass 2", ORDER); }
    function test_Gas_HeldPass2_8() public { _books(t0, t1, 8, DUST); _thinRival(); _measure("8 fragmented + held pass 2", ORDER); }

    // ---- an order past the deep walk: every ranked quote walks all 256 stretches -----------

    function test_Gas_PastDeepWalk_4() public { _books(t0, t1, 4, DUST); _thinRival(); _measure("4 fragmented + pass 2, order 5e22", 5 * ORDER); }

    // ---- a bridge route fragmented on both hops, beside the fragmented direct hop -----------

    function test_Gas_Bridge_4x3hops() public {
        address br = _token();
        hub.addBridge(br);
        _books(t0, t1, 4, DUST);
        _books(t0, br, 4, DUST);
        _books(br, t1, 4, DUST);
        _measure("4 fragmented on direct, on t0->bridge and on bridge->t1", ORDER);
    }
}
