// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3TickPool} from "../mocks/MockV3TickPool.sol";

/// @notice THE JUDGE'S GAS LEDGER (4746): what a solve costs when the route ceiling
///         (`MAX_ROUTE_IMPACT_BPS`) re-judges a route on its concentrated legs' own books
///         (Solver._judgedOnTheBook), at most JUDGE_READS (12) a hop and JUDGE_SOLVE_READS (24)
///         a solve frame, on mock pools.
///
/// The worlds are the ones test/CapacityWalkBudget.t.sol builds for the judge (the same fixture,
/// deployed in the same order, and the same books), where the judge's behaviour is asserted:
/// test_JudgeCannotStarveTheSolve and the refusals of (c) at SOLVE_GAS live there. This ledger
/// records the figures only, one group named after its test (snapshots/<test>.json). With
/// FORGE_SNAPSHOT_CHECK=true a run fails on any difference from the committed numbers, in either
/// direction; a number moves only with a re-emitted snapshot.
///
/// Each figure is one low-level call of findBestRoutePlan, uncapped and cold (every account the
/// world deployed is cooled first), so a refusal is measured too. Under isolate (asserted in
/// `setUp`) the call is its own transaction.
///
/// ROWS:
///   a   admitted, 1 hop, a deep current range: the judge never runs;
///   b1  refused by the model on an honest book the judge confirms, 1 hop;
///   b2  the same over one bridge, 2 hops;
///   c   the worst case: four topologies of stair books whose every read burns JBURN, every walk
///       running out of reads (24 judged reads in the frame), refused;
///   starve  four topologies of deep books whose every read burns JBURN, the direct route
///       admitted by its book (test_JudgeCannotStarveTheSolve's world).
/// Mutant M-JUDGE-6g in .github/scripts/mutants.py (the hop ignores what the frame spent): every
/// first hop of (c) is handed 12 reads, the frame reads past 24, and row c moves.
contract JudgeCeilingGasTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    address user = address(0xBEEF);
    address t0;
    address t1;
    address[] touched;

    uint24  constant FEE  = 3_000;
    int24   constant TS   = 60;
    uint128 constant JCUR  = 1e18;     // the thin range [0, 60) the price sits in
    uint128 constant JDEEP = 1e22;     // the book past its edge, over 6,000 ticks
    uint256 constant JORD  = 1e19;     // the model reads >= 9,000 bps on JCUR; the book pays ~1:1
    uint256 constant JBURN = 90_000;   // under GAS_CAP (100,000) less the read's own work: it answers
    uint256 constant JCAP  = 9_000;    // Mirrors `BlazePhoenixSolver.MAX_ROUTE_IMPACT_BPS`
    string  constant JGAS  = "test_Gas_JudgeCeiling_RefusedAndAdmitted";

    /// test/CapacityWalkBudget.t.sol's setUp, in its order, so every address is the same.
    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the figures need isolate: each top-level call is its own transaction");
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

    function test_Gas_JudgeCeiling_RefusedAndAdmitted() public {
        uint256 s = vm.snapshotState();
        // (a) admitted, 1 hop, deep current range.
        _jBook(t0, t1, 1e25, 1e25, 0);
        (uint256 g, bool ok) = _solveGas(t0, t1, 10_000e18);
        assertTrue(ok, "premise: (a) is admitted");
        vm.snapshotValue(JGAS, "a_admitted_1hop_deep", g);
        vm.revertToState(s);
        // (b1) refused, 1 hop: a shallow book past the edge, 1e17 over 46,080 ticks.
        _shallowBook(t0, t1);
        (g, ok) = _solveGas(t0, t1, 2e18);
        assertFalse(ok, "premise: (b1) is refused");
        vm.snapshotValue(JGAS, "b1_refused_1hop_honest", g);
        vm.revertToState(s);
        // (b2) refused, 2 hops over one bridge.
        {
            address m = _token();
            hub.addBridge(m);
            _shallowBook(t0, m);
            _shallowBook(m, t1);
            (g, ok) = _solveGas(t0, t1, 8e17);
            assertFalse(ok, "premise: (b2) is refused");
            vm.snapshotValue(JGAS, "b2_refused_2hops_honest", g);
        }
        vm.revertToState(s);
        // (c) refused, four topologies, stair books, every read burning JBURN.
        _fourTopologies(1e18, 20);
        (g, ok) = _solveGas(t0, t1, JORD);
        assertFalse(ok, "premise: (c) is refused");
        vm.snapshotValue(JGAS, "c_refused_4topologies_burn", g);
        vm.revertToState(s);
        // starve: four topologies, deep books, every read burning JBURN; the leader is admitted.
        _fourTopologies(JDEEP, 0);
        (g, ok) = _solveGas(t0, t1, JORD);
        assertTrue(ok, "premise: the leader the books pay keeps a route");
        vm.snapshotValue(JGAS, "starve_solve_4topologies_burn", g);
    }

    // ─── the worlds (test/CapacityWalkBudget.t.sol's, unchanged) ─────────────

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        touched.push(t);
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    /// A V3 book, the price one tick inside [0, 60) on the side an order of `a` moves toward;
    /// `deep` over 6,000 ticks past that edge (`stairs` == 0), or `stairs` adjacent 60-tick
    /// positions of `deep` each, every tick initialized, so a walk runs out of reads first.
    function _jBook(address a, address b, uint128 cur, uint128 deep, uint256 stairs) internal returns (MockV3TickPool q) {
        q = _jBook(a, b, cur, deep, stairs, FEE);
    }

    function _jBook(address a, address b, uint128 cur, uint128 deep, uint256 stairs, uint24 fee)
        internal returns (MockV3TickPool q)
    {
        q = new MockV3TickPool(a, b, fee, TS);
        bool z = a < b;
        q.initialize(z ? int24(1) : int24(59));
        q.addPosition(0, 60, cur);
        if (stairs == 0) {
            if (z) q.addPosition(-6000, 0, deep);
            else q.addPosition(60, 6060, deep);
        }
        for (uint256 k; k < stairs; ++k) {
            int24 st = int24(int256(k)) * 60;
            if (z) q.addPosition(-st - 60, -st, deep);
            else q.addPosition(60 + st, 120 + st, deep);
        }
        MockERC20(a).mint(address(q), 1e26);
        MockERC20(b).mint(address(q), 1e26);
        hub.seedPool(address(q), BPC.KIND_V3, fee, address(0), a, b);
        touched.push(address(q));
    }

    /// A book the judge confirms: 1e17 at the price, 1e17 past its edge over 46,080 ticks.
    function _shallowBook(address a, address b) internal returns (MockV3TickPool q) {
        q = new MockV3TickPool(a, b, FEE, TS);
        bool z = a < b;
        q.initialize(z ? int24(1) : int24(59));
        q.addPosition(0, 60, 1e17);
        if (z) q.addPosition(-46080, 0, 1e17);
        else q.addPosition(60, 46140, 1e17);
        MockERC20(a).mint(address(q), 1e26);
        MockERC20(b).mint(address(q), 1e26);
        hub.seedPool(address(q), BPC.KIND_V3, FEE, address(0), a, b);
        touched.push(address(q));
    }

    /// The single-range model's impact for `amt` of `a` on `q` (the figure the ceiling reads).
    function _modelBps(MockV3TickPool q, address a, uint256 amt) internal view returns (uint256) {
        bool z = a == q.token0();
        (uint160 sp, , , , , , ) = q.slot0();
        return BPC.impactV3FromOut(BPC.outV3(amt, sp, q.liquidity(), q.fee(), z, 0), amt, sp, z);
    }

    /// Direct t0 -> t1 and three bridges, every hop one book of `deep` past a thin range
    /// (`stairs` as `_jBook`), each read burning JBURN; the third bridge's books at fee 500.
    function _fourTopologies(uint128 deep, uint256 stairs) internal {
        MockV3TickPool[7] memory ps;
        ps[0] = _jBook(t0, t1, JCUR, deep, stairs);
        for (uint256 i; i < 3; ++i) {
            address b = _token();
            hub.addBridge(b);
            uint24 f = i == 2 ? 500 : FEE;
            ps[1 + 2 * i] = _jBook(t0, b, JCUR, deep, stairs, f);
            ps[2 + 2 * i] = _jBook(b, t1, JCUR, deep, stairs, f);
        }
        // Premise: the model refuses every route at its first hop, on JORD.
        for (uint256 i; i < 7; ++i) {
            if (i == 0 || i % 2 == 1) assertGe(_modelBps(ps[i], t0, JORD), JCAP, "premise: the model refuses every first hop");
            ps[i].burnOnRead(JBURN);
        }
    }

    /// The solve's gas, uncapped and cold, by a low-level call (so a refusal is measured too).
    function _solveGas(address a, address b, uint256 amt) internal returns (uint256 used, bool ok) {
        bytes memory cd = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (a, b, amt));
        _cool();
        uint256 g0 = gasleft();
        (ok, ) = address(solver).call(cd);
        used = g0 - gasleft();
    }
}
