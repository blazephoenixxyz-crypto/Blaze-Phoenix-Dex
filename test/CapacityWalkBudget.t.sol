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
//     per solve, in a static self-call on what SOLVE_GAS leaves after the search.
//     Honest V3 grids whose cap binds on every pair keep the margins
//     test/EntryBSolveBudget.t.sol sets for V4 books (a tenth of the search's
//     12M for one or two bridges, a fifth for three), and the automatic door
//     settles them, up to three bridges with six books on every pair.
//   - Liveness and R1 with held legs: where the search fits its 12M, the solve
//     fits SOLVE_GAS with the walk's budget derived from it, and the solve the door runs
//     returns the plan quoted without a cap - on a held grid of three bridges
//     and six books, on one a bridge leads, on four books whose every read
//     burns its GAS_CAP, and on every budget across the threshold of a walk
//     that changes the plan (the plan or nothing, never the plan at the cap).
//   - The gain on a later hop: a held leg of a bridge route is promised its walk.
//   - One basis: a direct book is never ranked on its walk against a bridge
//     ranked at its cap; the bridge that leads keeps the lead and its walk.
//   - One hop: a held single beside an unheld rival or an unheld split, held
//     legs of a split, a held book the band leaves alone, and a held book the
//     funnel leaves out of a split the gate collapses, onto a book or onto a V2
//     pair whose promise no walk lowers, are each settled by the walk.
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
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

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

/// A V3-shaped book whose every book read burns all the gas it is given (GAS_CAP).
contract BurnBookPool is MockV3Pool {
    int24 public tickSpacing = 60;
    constructor(address a, address b, uint24 f) MockV3Pool(a, b, f) {}
    function _burn() internal view { uint256 x; while (gasleft() > 3_000) { x = uint256(keccak256(abi.encode(x))); } }
    function tickBitmap(int16) external view returns (uint256) { _burn(); return type(uint256).max; }
    function ticks(int24) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        _burn();
        return (1, 0, 0, 0, 0, 0, 0, true);
    }
}

/// A V3-shaped pool whose price and liquidity reads each burn `burn` gas first: the search's
/// cost, set by the test (C1, the derived walk budget under WALK_CAP).
contract SearchBurnPool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint160 internal sqrtPriceX96 = uint160(1 << 96);
    uint256 public burn;
    constructor(address a, address b, uint24 f) { (token0, token1) = a < b ? (a, b) : (b, a); fee = f; }
    function setBurn(uint256 b) external { burn = b; }
    function _burnSome() internal view { uint256 g = gasleft(); uint256 x; while (g - gasleft() < burn) { x = uint256(keccak256(abi.encode(x))); } }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        _burnSome();
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
    function liquidity() external view returns (uint128) { _burnSome(); return 1e9; }
}

contract CapacityWalkBudgetTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    address user = address(0xBEEF);
    address t0;
    address t1;
    address[] touched;

    /// Mirrors `BlazePhoenixCore.SOLVE_GAS`: the search's budget at the automatic door, and the
    /// solve's whole budget the walk's is derived from.
    uint256 constant SOLVE_GAS = 14_700_000;
    /// Mirrors `BlazePhoenixSolver.ENTRY`: the dispatch's gas before the solve reads `g0`,
    /// rounded up; a solve that enters on less than SOLVE_GAS - ENTRY and walks stops.
    uint256 constant ENTRY = 1_200;
    /// The search's share, on which the rows below were sized: SOLVE_GAS grew by the walk's
    /// budget only, so a row's bound does not grow with it.
    uint256 constant SEARCH_GAS = 12_000_000;
    uint160 constant SP   = uint160(1 << 96);   // price 1, tick 0
    uint128 constant L    = 1_000e18;
    uint24  constant FEE  = 3_000;
    int24   constant TS   = 60;
    uint256 constant IN   = 200e18;             // F ~166e18 > cap 120e18, F <= HELD
    uint256 constant HELD = 400e18;
    uint256 constant UNHELD = 1_000e18;         // cap 300e18 >= F: no cap binds, even on one book

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
    function _heavy(address a, address b, uint24 fee, uint128 liq, uint256 holdings) internal {
        HeavyBookPool p = new HeavyBookPool(a, b, fee, TS);
        p.setState(SP, liq);
        for (int24 i = 1; i <= 20; ++i) {
            p.setTick(-i * TS, int128(liq / 1000));
            p.setTick(i * TS, -int128(liq / 1000));
        }
        MockERC20(a).mint(address(p), holdings);
        MockERC20(b).mint(address(p), holdings);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), a, b);
        touched.push(address(p));
    }

    /// Every pair of tIn, tOut and `nBridges` bridges gets `perPair` heavy books.
    function _grid(uint256 nBridges, uint256 perPair) internal { _grid(nBridges, perPair, HELD, L); }

    /// The same grid, every book holding `holdings` of each token, the direct books declaring `dLiq`.
    function _grid(uint256 nBridges, uint256 perPair, uint256 holdings, uint128 dLiq) internal {
        uint24[6] memory fees = [uint24(3_000), 500, 10_000, 100, 2_500, 400];
        address[] memory b = new address[](nBridges);
        for (uint256 i; i < nBridges; ++i) { b[i] = _token(); hub.addBridge(b[i]); }
        for (uint256 k; k < perPair; ++k) {
            _heavy(t0, t1, fees[k], dLiq, holdings);
            for (uint256 i; i < nBridges; ++i) {
                _heavy(t0, b[i], fees[k], L, holdings);
                _heavy(b[i], t1, fees[k], L, holdings);
                for (uint256 j; j < i; ++j) _heavy(b[j], b[i], fees[k], L, holdings);
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

    function test_3073_WalkBudget_DirectThreeBooks_FitsATenth() public { _grid(0, 3); _fits("direct, 3 books", SEARCH_GAS / 10); }
    function test_3073_WalkBudget_TwoBridges_FitsATenth() public { _grid(2, 1); _fits("2 bridges, 1 book per pair", SEARCH_GAS / 10); }
    function test_3073_WalkBudget_ThreeBridges_FitsAFifth() public { _grid(3, 1); _fits("3 bridges, 1 book per pair", SEARCH_GAS / 5); }
    function test_3073_WalkBudget_ThreeBridgesThreeBooks_Settles() public { _grid(3, 3); _fits("3 bridges, 3 books per pair", SEARCH_GAS * 3 / 4); }
    /// No build of this grid is held: the search alone, inside the search's share. Since DEX-01
    /// the plan's concentrated legs are walked by `Core.v3PaysOnBudget` on V3_PAY_READS reads for
    /// the whole route, inside the same share (that the reads are the route's is
    /// `test_3073_WalkBudget_HostileBooks_OneWalkForTheWholePlan`).
    function test_3073_WalkBudget_ThreeBridgesSixBooks_Settles() public { _grid(3, 6); _fits("3 bridges, 6 books per pair", SEARCH_GAS); }

    /// The walk runs on one topology per solve, the winner's, never per ranked candidate. The
    /// grid of `ThreeBridges_FitsAFifth` (one book per pair, every book the same shape): the
    /// direct book leads, held at its cap with its input whole, so the cap binds on the first
    /// hop of every bridge too, and none of those books, ranked at the cap and beaten, has a
    /// tick read. A count of reads, not a ceiling: a share of SOLVE_GAS stops telling the two
    /// apart once the search itself costs less (mutant [716]: every ranked candidate walks its
    /// held legs, sixteen tick reads on the first hop of a bridge).
    ///
    /// The leader is walked, and that half is a count too. Its walk stops short of the cap here,
    /// so the plan is the one built at the cap with or without it, and only the reads tell:
    /// nineteen on the leader's book, three by `_paysWhatItWalks` (the leader answers for what
    /// its book pays) and the sixteen stretches of the rebuild (mutant [722h]: a leader held at
    /// its cap is not rebuilt, three reads).
    function test_3073_WalkBudget_ThreeBridges_OnlyTheLeaderIsWalked() public {
        _heavy(t0, t1, FEE, L, HELD);
        address direct = touched[touched.length - 1];
        address[3] memory br;
        address[3] memory firstHop;
        for (uint256 i; i < 3; ++i) {
            br[i] = _token();
            hub.addBridge(br[i]);
            _heavy(t0, br[i], FEE, L, HELD);
            firstHop[i] = touched[touched.length - 1];
            _heavy(br[i], t1, FEE, L, HELD);
            for (uint256 j; j < i; ++j) _heavy(br[j], br[i], FEE, L, HELD);
        }
        for (uint256 i; i < 3; ++i) vm.expectCall(firstHop[i], abi.encodeWithSelector(HeavyBookPool.ticks.selector), 0);
        vm.expectCall(direct, abi.encodeWithSelector(HeavyBookPool.ticks.selector), 19);
        _cool();
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, IN);
        assertEq(plan.best.hops.length, 1, "precondition: the direct book leads");
        assertEq(plan.best.hops[0].legs.length, 1, "precondition: one direct book, one leg");
        Leg memory g = plan.best.hops[0].legs[0];
        assertEq(g.pool, direct, "precondition: the direct book leads");
        assertEq(g.amountIn, IN, "precondition: the book holds its quote, so the input is whole");
        assertEq(g.expectedOut, BPC.mulDiv(HELD, 3_000, BPC.BPS), "precondition: the cap binds on a book of this shape");
    }

    /// The direct grid of `DirectThreeBooks_FitsATenth`, by count. Each book alone would be held
    /// at its cap on the whole order, and is ranked there without a read of its book; the three
    /// split the order and no leg of the winner is left at its cap. `_paysWhatItWalks` spends the
    /// route's reads on its first leg, three on that book, and a walk the reads cut on a book
    /// that thins answers below `f` (G3): the promise fell, so the winner's topology is rebuilt
    /// once (N1), without the book that fell, and each of the other two is ranked alone on the
    /// whole order on its walk, sixteen stretches (`_capacity`, WALK). The book that fell is not
    /// read again, and the rebuild does not lead (two books pay less than three): the plan built
    /// at the cap stands. A count of reads, not a ceiling: a book walked while it is ranked
    /// (mutants [716], [716l], [724] on their second rows), a winner rebuilt as held as well
    /// (mutant [723] on its third row) and a book that fell walked by the rebuild (mutant
    /// [g3-5] = [n1-3]) each read more. Red at 10a2ac4 with the count before G3 (0, 0, 3), when
    /// a cut walk answered `f` and no promise fell on this grid.
    function test_3073_WalkBudget_DirectThreeBooks_AFallenPromiseRebuildsWithoutItsBook() public {
        uint256 n0 = touched.length;
        _grid(0, 3);
        bytes memory ticks = abi.encodeWithSelector(HeavyBookPool.ticks.selector);
        vm.expectCall(touched[n0], ticks, 16);
        vm.expectCall(touched[n0 + 1], ticks, 16);
        vm.expectCall(touched[n0 + 2], ticks, 3);
        _cool();
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, IN);
        assertEq(plan.best.hops.length, 1, "precondition: the direct books lead");
        Leg[] memory legs = plan.best.hops[0].legs;
        assertEq(legs.length, 3, "precondition: the three books split the order");
        assertEq(legs[0].pool, touched[n0 + 2], "precondition: the route's reads are spent on its first leg");
        uint256 cap = BPC.mulDiv(HELD, 3_000, BPC.BPS);
        for (uint256 l; l < 3; ++l) assertLt(legs[l].expectedOut, cap, "precondition: no leg of the winner is left at its cap");
    }

    /// The grid of `ThreeBridgesThreeBooks_Settles`, by count: the three direct books split the
    /// order, the first leg is the book of 3_000. A count of reads, not a ceiling: on this grid
    /// the share of SOLVE_GAS passes with a candidate walked while it is ranked (mutant [716l])
    /// and with the rebuild walking every topology (mutant [723t]), and the count does not.
    function test_3073_WalkBudget_ThreeBridgesThreeBooks_OnlyTheWinningTopologyIsRead() public {
        _onlyTheWinningTopologyIsRead(3, 0, 3);
    }

    /// The grid of `ThreeBridgesSixBooks_Settles`, by count: five of the six direct books split
    /// the order, the first leg is the book of 100. A count of reads, not a ceiling: on this grid
    /// the search's budget passes with the winner rebuilt with WALK on every solve (mutant
    /// [723]), and the count does not.
    function test_3073_WalkBudget_ThreeBridgesSixBooks_OnlyTheWinningTopologyIsRead() public {
        _onlyTheWinningTopologyIsRead(6, 3, 5);
    }

    /// `_grid(3, perPair)`: the direct books lead and split the order, so the walk is the direct
    /// topology's alone. `_paysWhatItWalks` spends the route's reads on the first leg, three on
    /// its book (the direct book of the `lead`-th fee); the promise falls, and the rebuild (N1)
    /// ranks each other direct book alone on the whole order on its walk, sixteen stretches. No
    /// book of a bridge has a tick read, by the search or by the rebuild.
    function _onlyTheWinningTopologyIsRead(uint256 perPair, uint256 lead, uint256 nLegs) internal {
        uint256 n0 = touched.length;
        _grid(3, perPair);
        bytes memory ticks = abi.encodeWithSelector(HeavyBookPool.ticks.selector);
        // After n0: the three bridges, then ten books for each fee, the direct book first.
        for (uint256 k; k < perPair; ++k) {
            vm.expectCall(touched[n0 + 3 + 10 * k], ticks, k == lead ? 3 : 16);
            for (uint256 b = 1; b < 10; ++b) vm.expectCall(touched[n0 + 3 + 10 * k + b], ticks, 0);
        }
        _cool();
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, IN);
        assertEq(plan.best.hops.length, 1, "precondition: the direct books lead");
        Leg[] memory legs = plan.best.hops[0].legs;
        assertEq(legs.length, nLegs, "precondition: the direct books split the order");
        assertEq(legs[0].pool, touched[n0 + 3 + 10 * lead], "precondition: the route's reads are spent on its first leg");
        uint256 cap = BPC.mulDiv(HELD, 3_000, BPC.BPS);
        for (uint256 l; l < nLegs; ++l) assertLt(legs[l].expectedOut, cap, "precondition: no leg of the winner is left at its cap");
    }

    // ─── Held legs: the door settles the plan quoted, the walk on its own budget ──

    /// Entry A (the uncapped solve), then the solve at the door's budget, which must return
    /// that same plan (R1), then the door itself, which must settle it.
    function _settlesAsQuoted(string memory row) internal returns (RoutePlan memory plan) {
        _cool();
        uint256 g0 = gasleft();
        plan = solver.findBestRoutePlan(t0, t1, IN);
        uint256 used = g0 - gasleft();
        emit log_named_string("row", row);
        emit log_named_uint("  plan gas, cold", used);
        emit log_named_uint("  totalOut", plan.best.totalOut);
        _i2(plan.best);
        _cool();
        RoutePlan memory atTheDoor = solver.findBestRoutePlan{gas: SOLVE_GAS}(t0, t1, IN);
        assertEq(keccak256(abi.encode(atTheDoor)), keccak256(abi.encode(plan)), "the door's budget chose another plan");
        _cool();
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        (bool ok, ) = address(router).call{gas: 16_000_000}(
            abi.encodeCall(BlazePhoenixRouter.swapBestExactIn, (t0, t1, IN, 1, user, block.timestamp + 1))
        );
        assertTrue(ok, "the automatic door settles the plan inside SOLVE_GAS");
        uint256 got = MockERC20(t1).balanceOf(user) - b1;
        emit log_named_uint("  delivered", got);
        assertGe(got, plan.best.singleOutFloor, "it delivers at least the floor");
    }

    /// Held 100e18 on every book (cap 30e18; a quarter of the order quotes ~47e18): the
    /// direct split leads held, and its rebuild runs past what the search left of 12M.
    function test_3073_WalkBudget_HeldThreeBridgesSixBooks_SettlesAsQuoted() public {
        _grid(3, 6, 100e18, L);
        _settlesAsQuoted("held 100e18, 3 bridges, 6 books per pair");
    }

    /// The same grid with thin direct books (100e18): a bridge route leads held, and its
    /// rebuild walks more books than the walk's budget holds.
    function test_3073_WalkBudget_HeldBridgeLeadsSixBooks_SettlesAsQuoted() public {
        _grid(3, 6, 100e18, 100e18);
        _settlesAsQuoted("held 100e18, a bridge leads, 3 bridges, 6 books per pair");
    }

    /// Four held books whose every read burns its whole GAS_CAP: the cost of a walk is the
    /// venue's choice. The walk runs out of its own budget and the plan at the cap stands -
    /// also in the uncapped solve, where the caller's gas would carry the whole walk.
    function test_3073_WalkBudget_FourHostileHeldBooks_SettlesAsQuoted() public {
        for (uint256 k; k < 4; ++k) {
            BurnBookPool p = new BurnBookPool(t0, t1, uint24(500 + k * 1000));
            p.setState(SP, L);
            MockERC20(t0).mint(address(p), 60e18);
            MockERC20(t1).mint(address(p), 60e18);
            hub.seedPool(address(p), BPC.KIND_V3, uint24(500 + k * 1000), address(0), t0, t1);
            touched.push(address(p));
        }
        RoutePlan memory plan = _settlesAsQuoted("4 held books, every read burns its GAS_CAP");
        Leg[] memory legs = plan.best.hops[0].legs;
        assertEq(legs.length, 4, "precondition: every hostile book is a leg");
        uint256 cap = BPC.mulDiv(60e18, 3_000, BPC.BPS);
        Leg memory l0 = legs[0];
        assertGt(BPC.v4WalkOut(l0.pool, bytes32(0), l0.amountIn, 0, 0, l0.zeroForOne), cap, "precondition: a whole walk pays past the cap");
        for (uint256 i; i < legs.length; ++i) assertEq(legs[i].expectedOut, cap, "the walk's own budget, not the caller's gas, keeps the cap");
    }

    /// C1 (c1-126), with the walk's budget derived from SOLVE_GAS: one to four held books whose
    /// every read burns its whole GAS_CAP. Whether their rebuild finishes is the state's
    /// business, never the caller's: the plan is the same at the automatic door's gas, at twice
    /// it, at 30M and uncapped, and the solve never stops for it - a walk that does not finish
    /// leaves the plan at the cap (mutants [739] [740] [740r]).
    function test_C1_HostileHeldBooks_ThePlanIsTheSameAtEveryGas() public {
        uint256 cap = BPC.mulDiv(60e18, 3_000, BPC.BPS);
        uint256[3] memory gs = [SOLVE_GAS * 2, 30_000_000, SOLVE_GAS];
        for (uint256 k; k < 4; ++k) {
            BurnBookPool p = new BurnBookPool(t0, t1, uint24(500 + k * 1000));
            p.setState(SP, L);
            MockERC20(t0).mint(address(p), 60e18);
            MockERC20(t1).mint(address(p), 60e18);
            hub.seedPool(address(p), BPC.KIND_V3, uint24(500 + k * 1000), address(0), t0, t1);
            touched.push(address(p));
            _cool();
            RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, IN);
            assertEq(plan.best.hops[0].legs.length, k + 1, "precondition: every hostile book is a leg");
            for (uint256 j; j < gs.length; ++j) {
                _cool();
                RoutePlan memory at = solver.findBestRoutePlan{gas: gs[j]}(t0, t1, IN);
                assertEq(keccak256(abi.encode(at)), keccak256(abi.encode(plan)), "the caller's gas chose another plan");
            }
            emit log_named_uint("hostile books", k + 1);
            emit log_named_uint("  first leg promised", plan.best.hops[0].legs[0].expectedOut);
        }
        Leg[] memory legs = solver.findBestRoutePlan(t0, t1, IN).best.hops[0].legs;
        for (uint256 i; i < legs.length; ++i) assertEq(legs[i].expectedOut, cap, "four books: the walk does not finish and the cap stands");
    }

    /// C1 (c1-126) where the search is long: the walk's budget, (SOLVE_GAS - ENTRY - s - 20,000)
    /// * 63 / 64 for a search that spent s, falls under WALK_CAP once s passes ~6.55M. One held
    /// book whose every book read burns its GAS_CAP leads direct; bridge pools whose price and
    /// liquidity reads burn `burn` gas each lengthen the search, never the rebuild of the direct
    /// topology. A bisection on `burn` finds the longest search after which the walk still
    /// finishes - so there the derived budget, under WALK_CAP, decides the plan - and on both
    /// sides of it the plan is the same at the automatic door's gas and at 30M: the budget is
    /// handed whole, its 1/64 off, whatever the caller brought (mutant [n1-5]).
    function test_C1_LongSearch_TheDerivedWalkBudgetIsTheSameAtEveryGas() public {
        uint256 cap = BPC.mulDiv(HELD, 3_000, BPC.BPS);
        BurnBookPool d = new BurnBookPool(t0, t1, 500);
        d.setState(SP, 10 * L);   // a short walk: a few stretches
        MockERC20(t0).mint(address(d), HELD);
        MockERC20(t1).mint(address(d), HELD);
        hub.seedPool(address(d), BPC.KIND_V3, 500, address(0), t0, t1);
        SearchBurnPool[] memory ps = new SearchBurnPool[](48);
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            address b = _token();
            hub.addBridge(b);
            for (uint256 k; k < 8; ++k) {
                for (uint256 e; e < 2; ++e) {
                    SearchBurnPool q = new SearchBurnPool(e == 0 ? t0 : b, e == 0 ? b : t1, uint24(100 + k));
                    hub.seedPool(address(q), BPC.KIND_V3, uint24(100 + k), address(0), q.token0(), q.token1());
                    ps[n++] = q;
                }
            }
        }
        uint256 lo;          // the walk finishes after this search
        uint256 hi = 90_000; // and not after this one
        assertTrue(_walks(ps, lo, cap), "premise: on a short search the walk finishes");
        assertFalse(_walks(ps, hi, cap), "premise: on the longest search the walk does not finish");
        while (hi - lo > 1) {
            uint256 m = (lo + hi) / 2;
            if (_walks(ps, m, cap)) lo = m; else hi = m;
        }
        emit log_named_uint("burn per read, the last walk that finishes", lo);
        for (uint256 j; j < 2; ++j) {
            _setBurn(ps, j == 0 ? lo : hi);
            uint256 g0 = gasleft();
            RoutePlan memory atThirty = solver.findBestRoutePlan{gas: 30_000_000}(t0, t1, IN);
            emit log_named_uint("  solve gas at 30M", g0 - gasleft());
            RoutePlan memory atTheDoor = solver.findBestRoutePlan{gas: SOLVE_GAS}(t0, t1, IN);
            assertEq(atThirty.best.hops.length, 1, "premise: the direct book leads");
            assertEq(keccak256(abi.encode(atTheDoor)), keccak256(abi.encode(atThirty)), "the caller's gas chose another plan");
            emit log_named_uint("  first leg promised", atThirty.best.hops[0].legs[0].expectedOut);
        }
    }

    function _setBurn(SearchBurnPool[] memory ps, uint256 b) internal {
        for (uint256 i; i < ps.length; ++i) ps[i].setBurn(b);
    }

    /// Whether, with every bridge pool's read burning `b`, the walk finishes at 30M: the
    /// plan at the cap stands when it does not, and a solve that stops does not walk.
    function _walks(SearchBurnPool[] memory ps, uint256 b, uint256 cap) internal returns (bool) {
        _setBurn(ps, b);
        try solver.findBestRoutePlan{gas: 30_000_000}(t0, t1, IN) returns (RoutePlan memory p) {
            return p.best.hops[0].legs[0].expectedOut > cap;
        } catch { return false; }
    }

    function _burnBook(uint256 k) internal {
        BurnBookPool p = new BurnBookPool(t0, t1, uint24(500 + k * 1000));
        p.setState(SP, L);
        MockERC20(t0).mint(address(p), UNHELD);
        MockERC20(t1).mint(address(p), UNHELD);
        hub.seedPool(address(p), BPC.KIND_V3, uint24(500 + k * 1000), address(0), t0, t1);
        touched.push(address(p));
    }

    function _coldPlan() internal returns (uint256 used, RoutePlan memory plan) {
        _cool();
        uint256 g0 = gasleft();
        plan = solver.findBestRoutePlan(t0, t1, IN);
        used = g0 - gasleft();
    }

    /// The walk's V3_PAY_READS reads are the plan's, not each leg's. Books whose every read burns
    /// its whole GAS_CAP, each holding UNHELD, so no cap binds and the search walks none of them:
    /// the only book reads of the plan are its promise's. Three more such books then cost the
    /// plan less than the one walk the budget allows, V3_PAY_READS * GAS_CAP. Relative, not a
    /// ceiling: both plans are measured cold on the same build (mutant [1006]: twelve reads for
    /// each leg walk every book).
    function test_3073_WalkBudget_HostileBooks_OneWalkForTheWholePlan() public {
        _burnBook(0);
        (uint256 g1, RoutePlan memory one) = _coldPlan();
        for (uint256 k = 1; k < 4; ++k) _burnBook(k);
        (uint256 g4, RoutePlan memory four) = _coldPlan();
        emit log_named_uint("plan gas, cold, 1 hostile book", g1);
        emit log_named_uint("plan gas, cold, 4 hostile books", g4);
        assertEq(one.best.hops[0].legs.length, 1, "precondition: one book, one leg");
        assertEq(four.best.hops[0].legs.length, 4, "precondition: every hostile book is a leg");
        uint256 cap = BPC.mulDiv(UNHELD, 3_000, BPC.BPS);
        assertLe(one.best.hops[0].legs[0].expectedOut, cap, "precondition: no cap binds");
        for (uint256 i; i < 4; ++i) assertLe(four.best.hops[0].legs[i].expectedOut, cap, "precondition: no cap binds");
        assertLt(g4, g1 + BPC.V3_PAY_READS * BPC.GAS_CAP, "each leg of the plan walked on reads of its own");
    }

    /// T3 on a walk that changes the plan (four books holding 100e18 each: a cap of 30e18 per
    /// leg, and each book pays more): on every budget from the uncapped cost up past SOLVE_GAS,
    /// a capped solve returns the uncapped plan or stops with empty revert data, never the plan
    /// at the cap - also where the gas left would finish a walk this short but the solve
    /// entered on less than SOLVE_GAS less ENTRY.
    function test_3073_HeldWalk_CappedSolveIsTheQuoteOrNothing() public {
        _grid(0, 4, 100e18, L);
        RoutePlan memory ref = solver.findBestRoutePlan(t0, t1, IN);   // warm: the capped calls' cost
        assertGt(ref.best.totalOut, 4 * 30e18, "the walk does not change the plan");
        uint256 g0 = gasleft();
        solver.findBestRoutePlan(t0, t1, IN);
        uint256 cost = g0 - gasleft();
        bytes32 h = keccak256(abi.encode(ref));
        uint256 done;
        uint256 stopped;
        // The threshold sits at SOLVE_GAS less ENTRY plus the dispatch, far past `cost`.
        uint256 step = (SOLVE_GAS + 100_000 - cost) / 60;
        for (uint256 g = cost; g <= SOLVE_GAS + 100_000; g += step) {
            try solver.findBestRoutePlan{gas: g}(t0, t1, IN) returns (RoutePlan memory p) {
                assertEq(keccak256(abi.encode(p)), h, "a capped solve returned another plan");
                ++done;
            } catch (bytes memory e) {
                assertEq(e.length, 0, "a capped solve failed with something other than out-of-gas");
                ++stopped;
            }
        }
        emit log_named_uint("uncapped cost, warm", cost);
        assertGt(done, 0, "no budget in the range completes");
        assertGt(stopped, 0, "every budget in the range completes");
    }

    /// N2 (reports/plano-1026/onda5/X6) and C1 (F2), at the threshold itself: a solve that walks
    /// derives the walk's budget from SOLVE_GAS less ENTRY, and stops when it entered on less.
    /// Completion is monotone in the gas - below the least that completes, every stop is out of
    /// gas or that check - so a bisection finds the least. It sits at or under SOLVE_GAS (the
    /// automatic door hands exactly that: ENTRY at least the dispatch's gas) and within ENTRY of
    /// it (ENTRY no larger than the dispatch needs, rounded); there the uncapped plan returns,
    /// and one gas less the solve stops with empty revert data.
    function test_3073_HeldWalk_AtTheThreshold_TheWholeBudgetOrNothing() public {
        _grid(0, 4, 100e18, L);
        RoutePlan memory ref = solver.findBestRoutePlan(t0, t1, IN);   // warm, as every call below
        assertGt(ref.best.totalOut, 4 * 30e18, "premise: the walk changes the plan");
        bytes32 h = keccak256(abi.encode(ref));
        uint256 g0 = gasleft();
        solver.findBestRoutePlan(t0, t1, IN);
        uint256 lo = g0 - gasleft() - 1;   // less than the solve spends: it cannot complete
        uint256 hi = SOLVE_GAS + 100_000;
        solver.findBestRoutePlan{gas: hi}(t0, t1, IN);
        while (hi - lo > 1) {
            uint256 g = (lo + hi) / 2;
            try solver.findBestRoutePlan{gas: g}(t0, t1, IN) returns (RoutePlan memory) { hi = g; }
            catch (bytes memory e) {
                assertEq(e.length, 0, "a capped solve failed with something other than out-of-gas");
                lo = g;
            }
        }
        emit log_named_uint("least gas that completes, warm", hi);
        emit log_named_int("its distance to SOLVE_GAS", int256(hi) - int256(SOLVE_GAS));
        assertLe(hi, SOLVE_GAS, "the automatic door's budget does not reach the walk (ENTRY too small)");
        assertGt(hi + ENTRY, SOLVE_GAS + ENTRY / 2, "the threshold sits far under SOLVE_GAS (ENTRY too large)");
        try solver.findBestRoutePlan{gas: hi - 1}(t0, t1, IN) returns (RoutePlan memory) {
            revert("a solve short of the walk's whole budget returned a plan");
        } catch (bytes memory e) {
            assertEq(e.length, 0, "a solve short of the walk's whole budget failed with data");
        }
        RoutePlan memory p = solver.findBestRoutePlan{gas: hi}(t0, t1, IN);
        assertEq(keccak256(abi.encode(p)), h, "the least gas that completes returned another plan");
    }

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

    function _pool(address a, address b, uint128 liq, uint256 holdings) internal returns (HeavyBookPool p) {
        p = new HeavyBookPool(a, b, FEE, TS);
        p.setState(SP, liq);
        MockERC20(a).mint(address(p), holdings);
        MockERC20(b).mint(address(p), holdings);
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
        // The runner-up read at the cap rides along with the rebuilt leader.
        assertTrue(plan.hasFallback, "the direct route is the fallback");
        assertEq(plan.fallbackRoute.hops.length, 1, "the fallback is the direct route");
        assertEq(plan.fallbackRoute.hops[0].legs[0].pool, address(d), "on the direct book");
        assertEq(plan.fallbackRoute.hops[0].legs[0].expectedOut, BPC.mulDiv(300e18, 3_000, BPC.BPS), "read at its cap");
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

    function _book(address a, address b, uint24 fee, uint128 liq, uint256 holdings) internal returns (MockV3BookPool p) {
        p = new MockV3BookPool(a, b, fee, TS);
        p.setState(SP, liq);
        MockERC20(a).mint(address(p), holdings);
        MockERC20(b).mint(address(p), holdings);
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

    /// The same collapse onto a V2 pair (reserves 50,000e18, 0.3%) in place of the 0.05%
    /// book. No walk lowers a pair's promise, so the build goes back to the walk only on the
    /// mark the collapse leaves. The pair pays ~119.35e18 for the order and leads at the
    /// held book's cap (45e18); the held book pays ~119.97e18, and the walk settles it.
    function test_3073_OneHop_CollapseOntoAV2Pair_PromiseIsTheHeldBook() public {
        _book(t0, t1, 10_000, 1_000_000e18, 4_000e18);
        _book(t0, t1, 10_000, 1_000_000e18, 4_001e18);
        _book(t0, t1, 10_000, 1_000_000e18, 4_002e18);
        uint112 r = 50_000e18;
        MockV2Pair u = new MockV2Pair(t0, t1);
        MockERC20(t0).mint(address(u), r);
        MockERC20(t1).mint(address(u), r);
        u.setReserves(r, r);
        hub.seedPool(address(u), BPC.KIND_V2, 30, address(0), t0, t1);
        MockV3BookPool h = _book(t0, t1, 100, 1_000_000e18, 150e18);
        uint256 amt = 120e18;
        uint256 hPays = BPC.v4WalkOut(address(h), bytes32(0), amt, 0, 0, h.token0() == t0);
        // Uniswap V2's getAmountOut at 0.3%, written out: the oracle is not the code under test.
        uint256 uPays = amt * 997 * r / (uint256(r) * 1000 + amt * 997);
        emit log_named_uint("hPays", hPays);
        emit log_named_uint("uPays", uPays);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _log(plan);
        _i2(plan.best);
        assertGt(hPays, uPays, "precondition: the held book pays more than the pair");
        assertGt(uPays, BPC.mulDiv(150e18, 3_000, BPC.BPS), "precondition: the pair pays past the held book's cap");
        assertEq(plan.best.hops[0].legs.length, 1, "the hop is one leg");
        assertEq(plan.best.hops[0].legs[0].pool, address(h), "on the held book");
        assertEq(plan.best.totalOut, hPays, "promised what its book pays");
        assertGe(_settles(amt, plan), _net(hPays), "and delivers it, net of the protocol fee");
    }

    // ─── The held mark survives what follows it ────────────────────────

    /// No direct pool: t0 -> br -> t1. The FIRST hop is the held book (cap 45e18 of 150e18;
    /// it pays ~119.6e18 for the 120e18 order), the second a deep book the cap does not bind.
    /// The mark the first stage leaves is not cleared by the unheld stage after it: the route
    /// is rebuilt with the walk and its first leg is promised its book.
    function test_3073_FirstHopHeld_LaterUnheldStageKeepsTheMark() public {
        address br = _token();
        hub.addBridge(br);
        MockV3BookPool h = _book(t0, br, FEE, 1_000_000e18, 150e18);
        _pool(br, t1, 1_000_000e18, 10_000_000e18);
        uint256 amt = 120e18;
        uint256 hPays = BPC.v4WalkOut(address(h), bytes32(0), amt, 0, 0, h.token0() == t0);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _i2(plan.best);
        assertEq(plan.best.hops.length, 2, "precondition: the bridge route");
        Leg memory g = plan.best.hops[0].legs[0];
        assertEq(g.pool, address(h), "precondition: the held book on the first hop");
        assertGt(hPays, BPC.mulDiv(150e18, 3_000, BPC.BPS), "precondition: its book pays past the cap");
        assertEq(g.expectedOut, hPays, "the first leg is promised its book, not its cap");
        assertGt(plan.best.totalOut, BPC.mulDiv(150e18, 3_000, BPC.BPS), "and the route carries it");
        _settles(amt, plan);
    }

    /// A split of a held book seated FIRST and an unheld one seated LAST. `h` holds 50e18
    /// (weight 50, share ~24e18, cap 15e18); `s` holds 1,000,000e18 but its book is thin
    /// (L 200e18, weight 200): the deepest weight, seated last, nowhere near its cap. The split
    /// beats every single (`h` alone is past its holdings). The unheld last leg does not clear
    /// the mark of the held one: the build is walked, and `h` is promised its book.
    function test_3073_SplitHeldFirstLeg_UnheldLastLegKeepsTheMark() public {
        MockV3BookPool h = _book(t0, t1, 100, 1_000_000e18, 50e18);
        _book(t0, t1, 500, 200e18, 1_000_000e18);
        uint256 amt = 120e18;
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _log(plan);
        _i2(plan.best);
        assertEq(plan.best.hops[0].legs.length, 2, "precondition: the split is kept");
        Leg memory g = plan.best.hops[0].legs[0];
        assertEq(g.pool, address(h), "precondition: the held book is seated first");
        assertGt(BPC.mulDiv(g.amountIn, 9_990, BPC.BPS), BPC.mulDiv(50e18, 3_000, BPC.BPS), "precondition: its share is past its cap");
        uint256 hPays = BPC.v4WalkOut(address(h), bytes32(0), g.amountIn, 0, 0, g.zeroForOne);
        assertEq(g.expectedOut, hPays, "the held leg is promised its book, not its cap");
        assertGe(_settles(amt, plan), _net(plan.best.totalOut), "and the books pay it, net of the protocol fee");
    }

    /// The gate collapses a split onto a single only by 25 ppm, and only at the cap. `h`
    /// holds 1.469e18 at 0.01% (weight 37 of 10,037, share ~0.4424e18 past its 0.4407e18
    /// cap); `s` holds 397e18 at 1%
    /// (its whole-order quote 118.8e18 stays under its 119.1e18 cap). Ranked at the cap, the
    /// split does not earn its second leg and collapses onto `s`; the held leg it drops keeps
    /// the build's mark, so the build is walked, and with `h` promised its book the split
    /// beats `s` alone by more than the gate asks.
    function test_3073_CollapseOffAHeldSplit_KeepsTheMark() public {
        MockV3BookPool h = _book(t0, t1, 100, 1e30, 1.469e18);
        MockV3BookPool s = _book(t0, t1, 10_000, 1e30, 397e18);
        uint256 amt = 120e18;
        uint256 sPays = BPC.v4WalkOut(address(s), bytes32(0), amt, 0, 0, s.token0() == t0);
        RoutePlan memory plan = solver.findBestRoutePlan(t0, t1, amt);
        _log(plan);
        _i2(plan.best);
        assertLe(sPays, BPC.mulDiv(397e18, 3_000, BPC.BPS), "precondition: the single is not held");
        assertEq(plan.best.hops[0].legs.length, 2, "the walked build keeps the split");
        assertEq(plan.best.hops[0].legs[0].pool, address(h), "with the held book seated first");
        assertGt(plan.best.hops[0].legs[0].expectedOut, BPC.mulDiv(1.469e18, 3_000, BPC.BPS), "promised past its cap");
        assertGt(plan.best.totalOut, BPC.mulDiv(sPays, 1_000_025, 1_000_000), "and the split beats the single by the gate");
        assertGe(_settles(amt, plan), _net(sPays), "it settles");
    }
}
