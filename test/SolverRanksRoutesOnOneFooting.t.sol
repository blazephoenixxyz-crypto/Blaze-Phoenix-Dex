// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE RANK PUTS A DIRECT ROUTE AND A BRIDGE ROUTE ON THE SAME SIDE OF THE FEE.
//
// Every route pays the protocol fee once (`BPC.feeCalendar`): a direct route on its one hop
// (its input, or its output when it lands on a bridge), a bridge route on the first hop that
// opens on a bridge. The Solver picks between topologies on `totalOut` (`_considera`). While
// every planner's `totalOut` stands on the same side of that fee, the order of the ranks is
// the order of the deliveries. The day one planner promises net of the fee and another still
// promises gross, the net one carries a handicap of the whole fee: wherever it wins by less
// than the fee, the Solver hands the user the route that delivers less.
//
// GREEN at 9c98147 (fix-1102 on gas52-main), where every planner promises gross. It goes RED
// when `_planViaBridges` alone takes the fee off its fee hop (mutants "the bridge planner alone
// plans net of the fee"), which is what a fix of the fee hop's plan does if it stops there.
//
// The oracle is not the Solver's own number: each topology is executed in a world where it is
// the only one on offer, and the delivery is the user's balance delta. The world that offers
// both must then deliver the larger of the two.
//
// Fixture: every pool 100M deep at 30 bps; the direct pool pays 0.9955 per unit, so the bridge
// route delivers more below ~150k (by 15 bps at dust, 5 bps at 100k) and the direct route
// delivers more above it. Both sides of that crossover are checked, never the crossover.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract SolverRanksRoutesOnOneFootingTest is Test {
    struct World { BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router; }
    /// One pair of tokens in three worlds: both topologies, the direct pool alone, the bridge
    /// pools alone. The pools are the same contracts in every world that lists them.
    struct Scene { World both; World direct; World bridge; MockERC20 tIn; MockERC20 tOut; }
    struct Seen { uint256 direct; uint256 bridge; uint256 both; uint256 hops; }

    uint256 constant DEPTH = 100_000_000e18;
    uint256 constant DIRECT_OUT = 99_550_000e18;

    MockERC20 A; MockERC20 B; MockERC20 C; MockERC20 E;
    address user = address(0xBEEF);
    Scene plain;   // A -> E against A -> B -> E: neither end is a bridge

    function setUp() public {
        A = new MockERC20("A", "A"); B = new MockERC20("B", "B");
        C = new MockERC20("C", "C"); E = new MockERC20("E", "E");
        A.mint(user, 1_000_000_000e18);
        B.mint(user, 1_000_000_000e18);
        plain = _scene(A, B, E);
    }

    function _world() private returns (World memory w) {
        w.hub = new BlazePhoenixHub(address(this));
        w.hub.initialize(address(this), address(0));
        w.solver = new BlazePhoenixSolver(address(w.hub), address(0));
        w.router = new BlazePhoenixRouter(address(w.hub), address(w.solver), address(this), address(0xFEE1), address(0xFEE2));
        w.hub.setRoles(address(w.router), address(w.solver), address(this));
        w.hub.addBridge(address(B));
        w.hub.addBridge(address(C));
        vm.startPrank(user);
        A.approve(address(w.router), type(uint256).max);
        B.approve(address(w.router), type(uint256).max);
        vm.stopPrank();
    }

    function _pool(MockERC20 tA, MockERC20 tB, uint256 rA, uint256 rB) private returns (address) {
        MockV2Pair p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), rA);
        tB.mint(address(p), rB);
        if (p.token0() == address(tA)) p.setReserves(uint112(rA), uint112(rB));
        else p.setReserves(uint112(rB), uint112(rA));
        return address(p);
    }

    function _list(World memory w, address pool, MockERC20 tA, MockERC20 tB) private {
        w.hub.seedPool(pool, BPC.KIND_V2, 30, address(0), address(tA), address(tB));
    }

    function _scene(MockERC20 tIn, MockERC20 via, MockERC20 tOut) private returns (Scene memory s) {
        address d = _pool(tIn, tOut, DEPTH, DIRECT_OUT);
        address h0 = _pool(tIn, via, DEPTH, DEPTH);
        address h1 = _pool(via, tOut, DEPTH, DEPTH);
        s.both = _world(); s.direct = _world(); s.bridge = _world();
        _list(s.both, d, tIn, tOut); _list(s.direct, d, tIn, tOut);
        _list(s.both, h0, tIn, via); _list(s.bridge, h0, tIn, via);
        _list(s.both, h1, via, tOut); _list(s.bridge, h1, via, tOut);
        s.tIn = tIn; s.tOut = tOut;
    }

    /// Solves and executes in one world, then puts the state back. Returns the delivery (the
    /// user's balance delta) and the hop count of the route the Solver ranked first.
    function _deliver(World memory w, Scene memory s, uint256 amt) private returns (uint256 got, uint256 hops) {
        uint256 snap = vm.snapshotState();
        Route memory r = w.solver.findBestRoutePlan(address(s.tIn), address(s.tOut), amt).best;
        hops = r.hops.length;
        uint256 before = s.tOut.balanceOf(user);
        vm.prank(user);
        w.router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        got = s.tOut.balanceOf(user) - before;
        vm.revertToState(snap);
    }

    function _measure(Scene memory s, uint256 amt) private returns (Seen memory m) {
        uint256 h;
        (m.direct, h) = _deliver(s.direct, s, amt);
        assertEq(h, 1, "premise: the direct world offers one hop");
        (m.bridge, h) = _deliver(s.bridge, s, amt);
        assertEq(h, 2, "premise: the bridge world offers two hops");
        (m.both, m.hops) = _deliver(s.both, s, amt);
        emit log_named_uint("amountIn", amt);
        emit log_named_uint("  direct alone delivers", m.direct);
        emit log_named_uint("  bridge alone delivers", m.bridge);
        emit log_named_uint("  both on offer delivers", m.both);
        emit log_named_uint("  hops of the route ranked first", m.hops);
    }

    /// Below the crossover the bridge route delivers more, and it is the one ranked first.
    function _bridgeWins(Scene memory s, uint256 amt) private {
        Seen memory m = _measure(s, amt);
        assertGt(m.bridge, m.direct, "premise: the bridge route delivers more at this size");
        assertEq(m.both, m.bridge, "the route ranked first delivers the most");
        assertEq(m.hops, 2, "the route ranked first is the bridge route");
    }

    /// Above the crossover the direct route delivers more, and it is the one ranked first.
    function _directWins(Scene memory s, uint256 amt) private {
        Seen memory m = _measure(s, amt);
        assertGt(m.direct, m.bridge, "premise: the direct route delivers more at this size");
        assertEq(m.both, m.direct, "the route ranked first delivers the most");
        assertEq(m.hops, 1, "the route ranked first is the direct route");
    }

    // Neither end is a bridge: the direct route pays on its input, the bridge route on hop 1.
    function test_Plain_RankFollowsDelivery_AcrossSizes() public {
        uint256[5] memory small = [uint256(1e12), 1e18, 1_000e18, 50_000e18, 100_000e18];
        for (uint256 i; i < small.length; ++i) _bridgeWins(plain, small[i]);
        uint256[2] memory large = [uint256(1_000_000e18), 10_000_000e18];
        for (uint256 i; i < large.length; ++i) _directWins(plain, large[i]);
    }

    function testFuzz_Plain_RankFollowsDelivery_WhereTheBridgeDeliversMore(uint256 amt) public {
        _bridgeWins(plain, bound(amt, 1e9, 100_000e18));
    }

    /// One wei either side of a step of the fee's rounding (`mulDivUp(x, 28, 10_000)`).
    function test_Plain_RankFollowsDelivery_PlusMinusOneWei() public {
        for (uint256 d; d < 3; ++d) _bridgeWins(plain, 5_000e18 + d - 1);
    }

    // The direct route lands on a bridge and pays on its OUTPUT; the bridge route on hop 1.
    function test_DirectIntoABridge_RankFollowsDelivery() public {
        Scene memory s = _scene(A, B, C);
        _bridgeWins(s, 1e18);
        _bridgeWins(s, 50_000e18);
        _directWins(s, 1_000_000e18);
    }

    // CONTROL: the input is a bridge, so both topologies pay on hop 0 and no hop after it pays
    // again. A planner that takes a fee off hop 1 of every bridge route breaks this one too.
    function test_Control_BridgeInput_RankFollowsDelivery() public {
        Scene memory s = _scene(B, C, E);
        _bridgeWins(s, 1e18);
        _bridgeWins(s, 50_000e18);
        _directWins(s, 1_000_000e18);
    }
}
