// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// 4660, follow-up: the funnel now walks every singleton book whose declared side is under the
// bar, so organic dust (books whose current tick holds a few wei) is read where it used to be
// dropped unread. This pins what that costs on the widest search the Solver runs: the direct
// pair and three bridges, seven routed pairs, every pair full (MAX_SLOTS 16) with one-wei books.
//
//   ORG       a V2 incumbent and fifteen one-wei books on every pair; no held leader, no rebuild.
//   ORG-HELD  a capacity-held V3 book and fifteen one-wei books on every pair: the leader is held,
//             so the solve asks for the rebuild (`_walkOnItsOwnBudget`), which stops with empty
//             revert data when the search leaves it less than 20,000 of SOLVE_B.
//   ADV       the worst the tree before 4660 (2c8cbbe) already reached: on every pair a book
//             declaring far over the incumbent puts the incumbent's row in the bracket, which
//             walked every book. Same walk count per pair as ORG, so the same order of gas.
//
// Each row measures the solve at depth 2 on exactly SOLVE_GAS (as `Router.swapBestExactIn`
// forwards it) and runs the automatic door, which must settle. `isolate = true`: every
// top-level call is its own transaction, so every read here is cold.
// Mutant: walk the books once per row under the bar instead of once per hop (drop the `break`
// after `_heldBooks` in `Solver._dropDust`): ORG no longer fits its share.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {HeavyBookPool} from "./CapacityWalkBudget.t.sol";

/// Calls the solve one frame down with an exact gas limit, as the Router does, and reports
/// whether it returned and what it spent there.
contract SolveProbe {
    function solve(address s, address a, address b, uint256 amt, uint256 g)
        external view returns (bool ok, uint256 used)
    {
        bytes memory cd = abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (a, b, amt));
        uint256 g0 = gasleft();
        assembly ("memory-safe") { ok := staticcall(g, s, add(cd, 0x20), mload(cd), 0, 0) }
        used = g0 - gasleft();
    }
}

contract FunnelDustOnEveryHopSolveBudgetTest is Test {
    int24   internal constant TS = 60;
    uint256 internal constant SOLVE_GAS = 14_700_000; // BPC.SOLVE_GAS
    uint256 internal constant ENTRY = 1_200;          // Solver.ENTRY
    uint256 internal constant PAIR = 100_000e18;
    uint256 internal constant AMT = 1_000e18;
    uint256 internal constant IN = 200e18;            // CapacityWalkBudget: F > cap, F <= HELD
    uint256 internal constant HELD = 400e18;
    uint128 internal constant L = 1_000e18;
    uint160 internal constant SP = uint160(1 << 96);

    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    MockV4TickManager internal mgr;
    SolveProbe internal probe;
    address internal t0;
    address internal t1;
    address[3] internal br;
    address internal user = address(0xD05);

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(0xC0FFEE));
        probe = new SolveProbe();
        t0 = _token();
        t1 = _token();
        for (uint256 i; i < 3; ++i) { br[i] = _token(); hub.addBridge(br[i]); }
        MockERC20(t0).mint(user, 1e27);
        vm.prank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
    }

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        MockERC20(t).mint(address(mgr), 1e30);
    }

    /// The seven pairs the search routes: the direct one, then into and out of each bridge.
    function _pairs() internal view returns (address[2][7] memory p) {
        p[0] = [t0, t1];
        for (uint256 i; i < 3; ++i) { p[1 + 2 * i] = [t0, br[i]]; p[2 + 2 * i] = [br[i], t1]; }
    }

    /// A hookless V4 book at tick 1: `liqNow` on its current tick [0, 60), `liqDeep` on [-6000, 0).
    function _book(address a, address b, uint24 fee, uint128 liqNow, uint128 liqDeep) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(1), 1, fee);
        if (liqNow != 0) mgr.addPosition(pid, 0, 60, TS, liqNow);
        if (liqDeep != 0) mgr.addPosition(pid, -6000, 0, TS, liqDeep);
        hub.addV4(c0, c1, fee, TS, address(0));
    }

    function _v2(address a, address b) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        MockV2Pair p = new MockV2Pair(c0, c1);
        MockERC20(c0).mint(address(p), PAIR);
        MockERC20(c1).mint(address(p), PAIR);
        p.setReserves(uint112(PAIR), uint112(PAIR));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), c0, c1);
    }

    /// CapacityWalkBudget's held book: the cap binds on IN, twenty ticks either side.
    function _heavy(address a, address b) internal {
        HeavyBookPool p = new HeavyBookPool(a, b, 3_000, TS);
        p.setState(SP, L);
        for (int24 i = 1; i <= 20; ++i) {
            p.setTick(-i * TS, int128(L / 1000));
            p.setTick(i * TS, -int128(L / 1000));
        }
        MockERC20(a).mint(address(p), HELD);
        MockERC20(b).mint(address(p), HELD);
        hub.seedPool(address(p), BPC.KIND_V3, 3_000, address(0), a, b);
    }

    /// `n` one-wei books on the pair, fees 101, 201, ... (none collides with 3000).
    function _dust(address a, address b, uint256 n) internal {
        for (uint256 k; k < n; ++k) _book(a, b, uint24(101 + 100 * k), 1, 1);
    }

    /// A sparse thin book: sixteen one-wei positions [-15360k, 60 * (256k - 1)), k = 1..16, so the
    /// current tick holds 16 wei and a walk either way crosses an initialized tick in a new bitmap
    /// word on every stretch: two cold reads a stretch, the most a stretch of `_v4Walk` reads.
    function _sparse(address a, address b, uint24 fee) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(1), 1, fee);
        for (int24 k = 1; k <= 16; ++k) mgr.addPosition(pid, -15_360 * k, 60 * (256 * k - 1), TS, 1);
        hub.addV4(c0, c1, fee, TS, address(0));
    }

    function _sparseDust(address a, address b, uint256 n) internal {
        for (uint256 k; k < n; ++k) _sparse(a, b, uint24(101 + 100 * k));
    }

    /// The solve at depth 2 on SOLVE_GAS, the rebuild detector, then the door.
    function _row(string memory name, uint256 amt) internal returns (uint256 used, bool rebuilt) {
        bool ok;
        (ok, used) = probe.solve(address(solver), t0, t1, amt, SOLVE_GAS);
        (bool okUnder, uint256 search) = probe.solve(address(solver), t0, t1, amt, SOLVE_GAS - ENTRY - 5_000);
        rebuilt = !okUnder;
        if (rebuilt) emit log_named_uint("  search gas before the rebuild check", search);
        emit log_named_string("row", name);
        emit log_named_uint("  solve gas at depth 2 on SOLVE_GAS", used);
        emit log_named_uint("  rebuild asked (1 = yes)", rebuilt ? 1 : 0);
        assertTrue(ok, "the solve does not fit SOLVE_GAS");
        uint256 b1 = MockERC20(t1).balanceOf(user);
        vm.prank(user);
        (bool door, bytes memory ret) = address(router).call{gas: 30_000_000}(
            abi.encodeCall(BlazePhoenixRouter.swapBestExactIn, (t0, t1, amt, 1, user, block.timestamp + 1))
        );
        emit log_named_bytes("  door revert data", ret.length <= 68 && !door ? ret : bytes(""));
        assertTrue(door, "the automatic door does not settle");
        assertGt(MockERC20(t1).balanceOf(user), b1, "the door delivered nothing");
    }

    function test_Gas_OrganicDustOnEveryHop_ThreeBridges_DoorSettles() public {
        address[2][7] memory p = _pairs();
        for (uint256 i; i < 7; ++i) { _v2(p[i][0], p[i][1]); _dust(p[i][0], p[i][1], 15); }
        (uint256 used, ) = _row("ORG: 7 pairs x (V2 + 15 one-wei books)", AMT);
        assertLt(used + 20_000, SOLVE_GAS - ENTRY, "organic dust on every hop leaves the rebuild less than its splice");
    }

    function test_Gas_OrganicDustOnEveryHop_HeldLeader_DoorSettles() public {
        address[2][7] memory p = _pairs();
        for (uint256 i; i < 7; ++i) { _heavy(p[i][0], p[i][1]); _dust(p[i][0], p[i][1], 15); }
        (uint256 used, bool rebuilt) = _row("ORG-HELD: 7 pairs x (held V3 + 15 one-wei books)", IN);
        assertTrue(rebuilt, "fixture: the leader is not held, the rebuild is not asked");
        assertLt(used, SOLVE_GAS, "unreachable: asserted by _row");
    }

    /// The heaviest organic pair: the V2 incumbent, a held V3 book and fourteen one-wei books.
    function test_Gas_OrganicDustOnEveryHop_PairHeldAndDust_DoorSettles() public {
        address[2][7] memory p = _pairs();
        for (uint256 i; i < 7; ++i) { _v2(p[i][0], p[i][1]); _heavy(p[i][0], p[i][1]); _dust(p[i][0], p[i][1], 14); }
        _row("ORG-V2-HELD: 7 pairs x (V2 + held V3 + 14 one-wei books)", IN);
    }

    function test_Gas_BracketOnEveryHop_ThreeBridges_DoorSettles() public {
        address[2][7] memory p = _pairs();
        for (uint256 i; i < 7; ++i) {
            _v2(p[i][0], p[i][1]);
            _book(p[i][0], p[i][1], 3_000, 1e28, 0);
            _dust(p[i][0], p[i][1], 14);
        }
        _row("ADV: 7 pairs x (V2 + bracket book + 14 one-wei books)", AMT);
    }

    function test_Gas_SparseDustOnEveryHop_ThreeBridges_DoorSettles() public {
        address[2][7] memory p = _pairs();
        for (uint256 i; i < 7; ++i) { _v2(p[i][0], p[i][1]); _sparseDust(p[i][0], p[i][1], 15); }
        _row("ORG-SPARSE: 7 pairs x (V2 + 15 sparse thin books)", AMT);
    }

    function test_Gas_SparseDustOnEveryHop_HeldLeader_DoorSettles() public {
        address[2][7] memory p = _pairs();
        for (uint256 i; i < 7; ++i) { _heavy(p[i][0], p[i][1]); _sparseDust(p[i][0], p[i][1], 15); }
        _row("ORG-SPARSE-HELD: 7 pairs x (held V3 + 15 sparse thin books)", IN);
    }

    function test_Gas_SparseBracketOnEveryHop_ThreeBridges_DoorSettles() public {
        address[2][7] memory p = _pairs();
        for (uint256 i; i < 7; ++i) {
            _v2(p[i][0], p[i][1]);
            _book(p[i][0], p[i][1], 3_000, 1e28, 0);
            _sparseDust(p[i][0], p[i][1], 14);
        }
        _row("ADV-SPARSE: 7 pairs x (V2 + bracket book + 14 sparse thin books)", AMT);
    }


    // TYPICAL (4660 E1, the owner's criterion): a deep V2 incumbent and `n` one-wei books on
    // every pair, n = 0..3, the shape most solves meet. E1 - main over n = 1..3 is the funnel's
    // tax on an ordinary solve.
    function _typical(uint256 n, string memory name) internal {
        address[2][7] memory p = _pairs();
        for (uint256 i; i < 7; ++i) { _v2(p[i][0], p[i][1]); if (n != 0) _dust(p[i][0], p[i][1], n); }
        _row(name, AMT);
    }

    function test_Gas_Typical_NoBooks_DoorSettles() public { _typical(0, "TYP0: 7 pairs x V2"); }
    function test_Gas_Typical_OneWeiBook_DoorSettles() public { _typical(1, "TYP1: 7 pairs x (V2 + 1 one-wei book)"); }
    function test_Gas_Typical_TwoOneWeiBooks_DoorSettles() public { _typical(2, "TYP2: 7 pairs x (V2 + 2 one-wei books)"); }
    function test_Gas_Typical_ThreeOneWeiBooks_DoorSettles() public { _typical(3, "TYP3: 7 pairs x (V2 + 3 one-wei books)"); }
}
