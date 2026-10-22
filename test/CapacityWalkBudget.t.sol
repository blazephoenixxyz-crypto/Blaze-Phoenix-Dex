// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  3073, the capacity walk on the chosen topology. A capacity-held concentrated
//  leg (cap < F <= holdings, MAX_CONC_DRAIN_BPS) ranks at its cap in every
//  topology, the direct one included: one basis for the judgement. When a held
//  candidate of the winning build could pay more than what that build chose, the
//  topology is built once more and its held candidates are ranked and promised
//  their own book's answer (Solver._capacity, WALK). Pinned:
//
//   - I2 on every hop: no concentrated leg is promised more than the pool holds
//     of tokenOut, also on a later hop, where the input is never cut. A book
//     that declares far more than it holds is held at the cap there too.
//   - SOLVE_GAS: a walk reads up to sixteen stretches cold (four storage words
//     per tick, as UniswapV3Pool.ticks reads them), so it runs on one topology
//     per solve. Honest V3 grids whose cap binds on every pair keep the margins
//     test/EntryBSolveBudget.t.sol sets for V4 books (SOLVE_GAS / 10 for one or
//     two bridges, / 5 for three), and the automatic door settles them, up to
//     three bridges with six books on every pair.
//   - The gain on a later hop: a held leg of a bridge route is promised its walk.
//   - One basis: a direct book is never ranked on its walk against a bridge
//     ranked at its cap; the bridge that leads keeps the lead and its walk.
//   - One hop: a held single beside an unheld rival or an unheld split, held
//     legs of a split, a held book the band leaves alone, and a held book the
//     funnel leaves out of a split the gate collapses are each settled by the walk.
//
//  forge test --match-path test/CapacityWalkBudget.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Route, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV3BookPool} from "./mocks/MockV3BookPool.sol";

/// A V3-shaped book whose ticks() reads four storage words per tick, as UniswapV3Pool's does.
contract HeavyBookPool is MockV3Pool {
    int24 public tickSpacing;
    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => uint256[4]) internal info;

    constructor(address a, address b, uint24 f, int24 ts) MockV3Pool(a, b, f) { tickSpacing = ts; }

    function setTick(int24 t, int128 n) external {
        int24 c = t / tickSpacing;
        tickBitmap[int16(c >> 8)] |= uint256(1) << (uint256(uint24(c)) & 0xff);
        info[t] = [uint256(uint128(n)) << 128 | 1, 7, 7, 7];
    }

    function ticks(int24 t)
        external view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        uint256[4] memory w = info[t];
        return (uint128(w[0]), int128(int256(w[0] >> 128)), w[1], w[2], int56(int256(w[3] & 1)), 0, 0, true);
    }
}

contract CapacityWalkBudgetTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    address user = address(0xBEEF);
    address t0;
    address t1;
    address[] touched;

    /// Mirrors `BlazePhoenixRouter.SOLVE_GAS`.
    uint256 constant SOLVE_GAS = 12_000_000;
    uint160 constant SP   = uint160(1 << 96);   // price 1, tick 0
    uint128 constant L    = 1_000e18;
    uint24  constant FEE  = 3_000;
    int24   constant TS   = 60;
    uint256 constant IN   = 200e18;             // F ~166e18 > cap 120e18, F <= HELD
    uint256 constant HELD = 400e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(0xC0FFEE));
        t0 = _token();
        t1 = _token();
        MockERC20(t0).mint(user, 1e30);
        vm.prank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
        touched.push(address(hub));
        touched.push(address(solver));
        touched.push(address(router));
    }

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        touched.push(t);
    }

    /// A book the cap binds, twenty initialized ticks on both sides of the price, so a walk
    /// in either direction runs its sixteen stretches.
    function _heavy(address a, address b, uint24 fee) internal {
        HeavyBookPool p = new HeavyBookPool(a, b, fee, TS);
        p.setState(SP, L);
        for (int24 i = 1; i <= 20; ++i) {
            p.setTick(-i * TS, int128(1e18));
            p.setTick(i * TS, -int128(1e18));
        }
        MockERC20(a).mint(address(p), HELD);
        MockERC20(b).mint(address(p), HELD);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), a, b);
        touched.push(address(p));
    }

    /// Every pair of tIn, tOut and `nBridges` bridges gets `perPair` heavy books.
    function _grid(uint256 nBridges, uint256 perPair) internal {
        uint24[6] memory fees = [uint24(3_000), 500, 10_000, 100, 2_500, 400];
        address[] memory b = new address[](nBridges);
        for (uint256 i; i < nBridges; ++i) { b[i] = _token(); hub.addBridge(b[i]); }
        for (uint256 k; k < perPair; ++k) {
            _heavy(t0, t1, fees[k]);
            for (uint256 i; i < nBridges; ++i) {
                _heavy(t0, b[i], fees[k]);
                _heavy(b[i], t1, fees[k]);
                for (uint256 j; j < i; ++j) _heavy(b[j], b[i], fees[k]);
            }
        }
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    /// The cold plan's gas, then the automatic door on the same state, which must settle.
    function _fits(string memory row, uint256 budget) internal {
        _cool();
        uint256 g0 = gasleft();
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, IN);
        uint256 used = g0 - gasleft();
        emit log_named_string("row", row);
        emit log_named_uint("  plan gas, cold", used);
        _i2(plan.best);
        assertLe(used, budget, "a plan over V3 books the cap binds uses more than its share of SOLVE_GAS");
        _cool();
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        (bool ok, ) = address(router).call{gas: 30_000_000}(
            abi.encodeCall(BlazePhoenixRouter.swapBestExactIn, (t0, t1, IN, 1, user, block.timestamp + 1))
        );
        assertTrue(ok, "the automatic door settles the plan inside SOLVE_GAS");
        assertGe(MockERC20(t1).balanceOf(user) - b1, plan.best.singleOutFloor, "it delivers at least the floor");
    }

    /// I2: a concentrated leg is never promised more than its pool holds of tokenOut.
    function _i2(Route memory r) internal view {
        for (uint256 h; h < r.hops.length; ++h) {
            for (uint256 l; l < r.hops[h].legs.length; ++l) {
                Leg memory g = r.hops[h].legs[l];
                assertLe(g.expectedOut, MockERC20(r.hops[h].tokenOut).balanceOf(g.pool), "a promise past the pool's holdings");
            }
        }
    }

    // ─── SOLVE_GAS with the cap binding on every pair ──────────────────

    function test_3073_WalkBudget_DirectThreeBooks_FitsATenth() public { _grid(0, 3); _fits("direct, 3 books", SOLVE_GAS / 10); }
    function test_3073_WalkBudget_TwoBridges_FitsATenth() public { _grid(2, 1); _fits("2 bridges, 1 book per pair", SOLVE_GAS / 10); }
    function test_3073_WalkBudget_ThreeBridges_FitsAFifth() public { _grid(3, 1); _fits("3 bridges, 1 book per pair", SOLVE_GAS / 5); }
    function test_3073_WalkBudget_ThreeBridgesThreeBooks_Settles() public { _grid(3, 3); _fits("3 bridges, 3 books per pair", SOLVE_GAS * 3 / 4); }
    function test_3073_WalkBudget_ThreeBridgesSixBooks_Settles() public { _grid(3, 6); _fits("3 bridges, 6 books per pair", SOLVE_GAS); }

    // ─── I2 on a later hop ─────────────────────────────────────────────

    /// The second hop's pool declares L = 1e6e18 and holds 50e18 of tOut: its single-tick
    /// quote and its walk both pass its holdings. It stays at the cap (15e18), so the honest
    /// direct pool (~90e18) wins and the automatic door settles.
    function test_3073_PhantomLaterHop_NoLegPromisesPastItsHoldings() public {
        address br = _token();
        hub.addBridge(br);
        _pool(t0, br, 1_000_000e18, 10_000_000e18);   // honest, deep first hop
        _pool(br, t1, 1_000_000e18, 50e18);           // phantom second hop
        _pool(t0, t1, 1_000e18, 1_000e18);            // honest direct rival
        uint256 amt = 100e18;
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _i2(plan.best);
        if (plan.hasFallback) _i2(plan.fallbackRoute);
        assertEq(plan.best.hops.length, 1, "the honest direct route wins");
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        (bool ok, ) = address(router).call(
            abi.encodeCall(BlazePhoenixRouter.swapBestExactIn, (t0, t1, amt, 1, user, block.timestamp + 1))
        );
        assertTrue(ok, "the automatic door settles");
        assertGe(MockERC20(t1).balanceOf(user) - b1, plan.best.singleOutFloor, "it delivers at least the floor");
    }

    /// The same second hop with no rival: the bridge route is the only one, so it is the chosen
    /// topology and its build asks the books. The second leg stays at the cap of what its pool
    /// holds: a book walked on the chosen route never lifts a leg whose quote passes its holdings.
    function test_3073_PhantomLaterHop_OnlyRoute_PromiseStaysAtTheCap() public {
        address br = _token();
        hub.addBridge(br);
        _pool(t0, br, 1_000_000e18, 10_000_000e18);
        HeavyBookPool ph = _pool(br, t1, 1_000_000e18, 50e18);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, 100e18);
        assertEq(plan.best.hops.length, 2, "precondition: the bridge route");
        Leg memory g = plan.best.hops[1].legs[0];
        assertEq(g.pool, address(ph), "precondition: the second hop's pool");
        assertGt(g.amountIn, 50e18, "precondition: the second hop quotes past the holdings");
        _i2(plan.best);
        assertEq(g.expectedOut, BPC.mulDiv(50e18, 3_000, BPC.BPS), "the leg is promised the cap of its holdings");
    }

    function _pool(address a, address b, uint128 liq, uint256 held) internal returns (HeavyBookPool p) {
        p = new HeavyBookPool(a, b, FEE, TS);
        p.setState(SP, liq);
        MockERC20(a).mint(address(p), held);
        MockERC20(b).mint(address(p), held);
        hub.seedPool(address(p), BPC.KIND_V3, FEE, address(0), a, b);
    }

    // ─── The gain on a later hop ───────────────────────────────────────

    /// No direct pool: the route is t0 -> br -> t1. The first hop is deep (the cap does not
    /// bind); the second is a flat book the cap binds (cap 120e18 < F <= 400e18). The chosen
    /// route's build asks that book: the second leg is promised its walk, above the cap.
    function test_3073_LaterHop_HeldLegIsPromisedItsBook() public {
        address br = _token();
        hub.addBridge(br);
        _pool(t0, br, 1_000_000e18, 10_000_000e18);
        MockV3BookPool p = new MockV3BookPool(br, t1, FEE, TS);
        p.setState(SP, L);
        MockERC20(br).mint(address(p), HELD);
        MockERC20(t1).mint(address(p), HELD);
        hub.seedPool(address(p), BPC.KIND_V3, FEE, address(0), br, t1);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, IN);
        assertEq(plan.best.hops.length, 2, "precondition: the bridge route");
        Leg memory g = plan.best.hops[1].legs[0];
        assertEq(g.pool, address(p), "precondition: the booked pool on the second hop");
        uint256 cap = BPC.mulDiv(HELD, 3_000, BPC.BPS);
        uint256 w = BPC.v4WalkOut(address(p), bytes32(0), g.amountIn, 0, 0, g.zeroForOne);
        assertGt(w, cap, "precondition: the book pays past the cap");
        assertEq(g.expectedOut, w, "the second leg's promise is its book's answer");
        assertEq(plan.best.totalOut, w, "and so is the route's");
        assertFalse(plan.hasFallback, "the rebuilt route is not its own fallback");
    }

    // ─── One basis across topologies ───────────────────────────────────

    /// A direct book the cap binds (cap 90e18 of 300e18 held) beside a bridge route whose
    /// second book the cap binds too (cap 94.8e18 of 316e18). Both rank at their caps, so the
    /// bridge leads, and its own build then asks its book. The order is settled on the bridge
    /// and delivers what the bridge pays: more than the direct book pays for the whole order,
    /// and at least the 109.711e18 the cap-only judgement (f91c6bd) delivered here.
    function test_3073_OneBasis_BridgeLeadsAndIsPromisedItsBook() public {
        address br = _token();
        hub.addBridge(br);
        MockV3BookPool h1 = new MockV3BookPool(t0, br, FEE, TS);
        h1.setState(SP, 1_000_000e18);
        MockERC20(t0).mint(address(h1), 10_000_000e18);
        MockERC20(br).mint(address(h1), 10_000_000e18);
        hub.seedPool(address(h1), BPC.KIND_V3, FEE, address(0), t0, br);
        MockV3BookPool b2 = new MockV3BookPool(br, t1, FEE, TS);
        b2.setState(SP, 1_415e18);
        MockERC20(br).mint(address(b2), 316e18);
        MockERC20(t1).mint(address(b2), 316e18);
        hub.seedPool(address(b2), BPC.KIND_V3, FEE, address(0), br, t1);
        MockV3BookPool d = new MockV3BookPool(t0, t1, FEE, TS);
        d.setState(SP, 609e18);
        MockERC20(t0).mint(address(d), 300e18);
        MockERC20(t1).mint(address(d), 300e18);
        hub.seedPool(address(d), BPC.KIND_V3, FEE, address(0), t0, t1);
        uint256 amt = 120e18;
        uint256 directPays = BPC.v4WalkOut(address(d), bytes32(0), amt, 0, 0, d.token0() == t0);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _i2(plan.best);
        assertEq(plan.best.hops.length, 2, "the bridge route leads");
        assertGt(plan.best.totalOut, BPC.mulDiv(316e18, 3_000, BPC.BPS), "its held leg is promised its book, above the cap");
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        (bool ok, ) = address(router).call(
            abi.encodeCall(BlazePhoenixRouter.swapBestExactIn, (t0, t1, amt, 1, user, block.timestamp + 1))
        );
        assertTrue(ok, "the automatic door settles");
        uint256 got = MockERC20(t1).balanceOf(user) - b1;
        assertGt(got, directPays, "it delivers more than the direct book pays");
        assertGe(got, 109_711_452_379_324_602_667, "and at least the cap-only judgement's delivery");
    }

    // ─── One hop: a held book against the rest of its hop ──────────────

    function _book(address a, address b, uint24 fee, uint128 liq, uint256 held) internal returns (MockV3BookPool p) {
        p = new MockV3BookPool(a, b, fee, TS);
        p.setState(SP, liq);
        MockERC20(a).mint(address(p), held);
        MockERC20(b).mint(address(p), held);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), a, b);
    }

    function _settles(uint256 amt, RoutePlan memory plan) internal returns (uint256 got) {
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        (bool ok, ) = address(router).call(
            abi.encodeCall(BlazePhoenixRouter.swapBestExactIn, (t0, t1, amt, 1, user, block.timestamp + 1))
        );
        assertTrue(ok, "the automatic door settles");
        got = MockERC20(t1).balanceOf(user) - b1;
        assertGe(got, plan.best.singleOutFloor, "it delivers at least the floor");
    }

    function _net(uint256 x) internal pure returns (uint256) {
        return x - BPC.mulDivUp(x, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function _log(RoutePlan memory plan) internal {
        emit log_named_uint("hops", plan.best.hops.length);
        emit log_named_uint("legs", plan.best.hops[0].legs.length);
        emit log_named_uint("totalOut", plan.best.totalOut);
        for (uint256 l; l < plan.best.hops[0].legs.length; ++l) {
            emit log_named_address("  pool", plan.best.hops[0].legs[l].pool);
            emit log_named_uint("  in", plan.best.hops[0].legs[l].amountIn);
            emit log_named_uint("  out", plan.best.hops[0].legs[l].expectedOut);
        }
    }

    /// A held single against an unheld rival on the same hop. `h` holds 150e18: the order
    /// (120e18) is inside its holdings and past its cap (45e18); its book pays ~119.6e18.
    /// `u` holds 1,000e18 and pays ~85.7e18, under its cap. At the cap `u` would take the
    /// hop; the build is settled by the walk, and the hop pays what `h`'s book pays.
    function test_3073_OneHop_HeldSingleOverAnUnheldRival() public {
        MockV3BookPool h = _book(t0, t1, FEE, 1_000_000e18, 150e18);
        MockV3BookPool u = _book(t0, t1, 500, 300e18, 1_000e18);
        uint256 amt = 120e18;
        uint256 hPays = BPC.v4WalkOut(address(h), bytes32(0), amt, 0, 0, h.token0() == t0);
        uint256 uPays = BPC.v4WalkOut(address(u), bytes32(0), amt, 0, 0, u.token0() == t0);
        emit log_named_uint("hPays", hPays);
        emit log_named_uint("uPays", uPays);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _log(plan);
        _i2(plan.best);
        assertGt(hPays, uPays, "precondition: the held book pays more than its rival");
        assertGt(uPays, BPC.mulDiv(150e18, 3_000, BPC.BPS), "precondition: the rival pays past the held book's cap");
        assertGe(plan.best.totalOut, hPays, "the hop is promised at least what the held book pays");
        assertGe(_settles(amt, plan), _net(hPays), "and delivers it, net of the protocol fee");
    }

    /// Two books each holding 100e18: the whole order (120e18) is past either one's holdings,
    /// so no single is held; half of it on each is inside them and past each cap (30e18).
    /// The split's legs are held at the cap; the walk promises each its book's answer.
    function test_3073_OneHop_SplitHeldAtTheCapIsPromisedItsBooks() public {
        _book(t0, t1, FEE, 1_000_000e18, 100e18);
        _book(t0, t1, 500, 1_000_000e18, 100e18);
        uint256 amt = 120e18;
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _log(plan);
        _i2(plan.best);
        assertGt(plan.best.hops[0].legs.length, 1, "precondition: the split");
        assertGt(plan.best.totalOut, 2 * BPC.mulDiv(100e18, 3_000, BPC.BPS), "the held legs are promised past their caps");
        assertGe(_settles(amt, plan), _net(plan.best.totalOut), "and the books pay it, net of the protocol fee");
    }

    /// A split whose legs the cap does not bind, beside a single the cap binds: `h` holds
    /// 300e18 (cap 90e18) and pays ~119.6e18 for the whole order. The split of `h` and `u`
    /// beats `h` at its cap; it does not beat what `h`'s book pays, and the walk settles that.
    function test_3073_OneHop_HeldSingleOverAnUnheldSplit() public {
        MockV3BookPool h = _book(t0, t1, FEE, 1_000_000e18, 300e18);
        _book(t0, t1, 500, 300e18, 1_000e18);
        uint256 amt = 120e18;
        uint256 hPays = BPC.v4WalkOut(address(h), bytes32(0), amt, 0, 0, h.token0() == t0);
        emit log_named_uint("hPays", hPays);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _log(plan);
        _i2(plan.best);
        assertGe(plan.best.totalOut, hPays, "the hop is promised at least what the held book pays");
        assertGe(_settles(amt, plan), _net(hPays), "and delivers it, net of the protocol fee");
    }

    /// A held book beside a pool priced at a quarter of it, which the band leaves out: the
    /// hop keeps one candidate, held at its cap (45e18 of 150e18), and the walk settles it.
    function test_3073_OneHop_BandKeepsOneHeldBook_PromiseIsItsBook() public {
        MockV3BookPool h = _book(t0, t1, FEE, 1_000_000e18, 150e18);
        MockV3BookPool off = new MockV3BookPool(t0, t1, 500, TS);
        off.setState(uint160(1 << 95), 1_000e18);
        MockERC20(t0).mint(address(off), 10e18);
        MockERC20(t1).mint(address(off), 10e18);
        hub.seedPool(address(off), BPC.KIND_V3, 500, address(0), t0, t1);
        uint256 amt = 120e18;
        uint256 hPays = BPC.v4WalkOut(address(h), bytes32(0), amt, 0, 0, h.token0() == t0);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _log(plan);
        _i2(plan.best);
        assertEq(plan.best.hops[0].legs.length, 1, "precondition: one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(h), "precondition: the held book");
        assertGt(hPays, BPC.mulDiv(150e18, 3_000, BPC.BPS), "precondition: its book pays past the cap");
        assertEq(plan.best.totalOut, hPays, "the hop is promised what the held book pays");
        assertGe(_settles(amt, plan), _net(hPays), "and delivers it, net of the protocol fee");
    }

    /// The split weighs by holdings: three books holding 4,000e18 at a 1% fee take most of the
    /// order, and the gate collapses it onto the 0.05% book. The 0.01% book holds 150e18, the
    /// least, so the funnel leaves it out of the split; the gate ranks it at its cap (45e18)
    /// though its book pays more than the collapsed single. The walk settles the hop on it.
    function test_3073_OneHop_CollapseBesideAHeldSingle_PromiseIsItsBook() public {
        _book(t0, t1, 10_000, 1_000_000e18, 4_000e18);
        _book(t0, t1, 10_000, 1_000_000e18, 4_001e18);
        _book(t0, t1, 10_000, 1_000_000e18, 4_002e18);
        MockV3BookPool u = _book(t0, t1, 500, 1_000_000e18, 400e18);
        MockV3BookPool h = _book(t0, t1, 100, 1_000_000e18, 150e18);
        uint256 amt = 120e18;
        uint256 hPays = BPC.v4WalkOut(address(h), bytes32(0), amt, 0, 0, h.token0() == t0);
        uint256 uPays = BPC.v4WalkOut(address(u), bytes32(0), amt, 0, 0, u.token0() == t0);
        emit log_named_uint("hPays", hPays);
        emit log_named_uint("uPays", uPays);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _log(plan);
        _i2(plan.best);
        assertGt(hPays, uPays, "precondition: the held book pays more than the collapsed single");
        assertEq(plan.best.hops[0].legs.length, 1, "the hop is one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(h), "on the held book");
        assertEq(plan.best.totalOut, hPays, "promised what its book pays");
        assertGe(_settles(amt, plan), _net(hPays), "and delivers it, net of the protocol fee");
    }
}
