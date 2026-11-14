// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE ONE FALLBACK OF THE ENCODE DOORS (#126; G7 ethereum C6, block 26,339,826).
//
//  The Solver ranks routes on what their venues promise and returns its runner-up beside its
//  leader (`RoutePlan.fallbackRoute`). When the leader's promise sits above what its venues pay
//  as the Router funds them, `_encode` refuses it and the doors used to return no bytes while
//  the runner-up settled. `Quoter._encodePlan` asks the runner-up the same question, once, on
//  its own floor and the caller's, and only when the leader cleared `_pack` and `_encode`
//  refused it. Never a third route, never a second solve.
//
//  Also pinned: a zero floor is never encoded (the Router refuses minOut 0 with a non-zero
//  input, RouterE(10); G7 ethereum shallow-3, one unit).
//
//  Harness: the Quoter is given a solver that returns a fixed plan, so the leader's and the
//  runner-up's floors are set by the test. Each route is one hop, one V3 leg, on its own pool.
//  Oracle: what each route delivers when the Router runs it (`_delivered`, a real swap under a
//  snapshot), not a Quoter figure. Mutants: QF-1 .. QF-6 in .github/scripts/mutants.py.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// @dev A solver that answers a fixed plan (set as ABI bytes: a nested struct cannot be stored).
contract FixedPlanSolver {
    bytes internal plan;
    function set(RoutePlan memory p) external { plan = abi.encode(p); }
    function findBestRoutePlan(address, address, uint256) external view returns (RoutePlan memory) {
        return abi.decode(plan, (RoutePlan));
    }
}

contract QuoterEncodeFallsBackOnceTest is Test {
    uint256 constant AMT = 1e18;

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    FixedPlanSolver fixedSolver;
    MockERC20 tA;
    MockERC20 tB;
    MockV3Pool poolL; // the leader's venue: deep
    MockV3Pool poolR; // the runner-up's venue: shallower, pays less
    bytes routeTemplate;
    uint256 dL; // what the leader's route delivers through the Router
    uint256 dR; // what the runner-up's route delivers through the Router
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2"));
        fixedSolver = new FixedPlanSolver();
        quoter = new BlazePhoenixQuoter(address(hub), address(fixedSolver));
        poolL = new MockV3Pool(address(tA), address(tB), 100);
        poolL.setState(uint160(BPC.Q96), 1e30);
        tB.mint(address(poolL), 1e30);
        hub.seedPool(address(poolL), BPC.KIND_V3, 100, address(0), address(tA), address(tB));
        // The template: the real Solver's route over the leader's pool alone (the shape the
        // Router accepts), copied per route as ABI bytes.
        routeTemplate = abi.encode(solver.findBestRoutePlan(address(tA), address(tB), AMT).best);
        poolR = new MockV3Pool(address(tA), address(tB), 500);
        poolR.setState(uint160(BPC.Q96), 1e20);
        tB.mint(address(poolR), 1e30);
        hub.seedPool(address(poolR), BPC.KIND_V3, 500, address(0), address(tA), address(tB));
        dL = _delivered(_route(poolL, 1000, 1));
        dR = _delivered(_route(poolR, 1000, 1));
        require(dR > 0 && dR < dL, "premise: the runner-up's venue pays less than the leader's");
    }

    // ---------------------------------------------------------------- helpers

    /// A one-hop route on `pool`, promising `totalOut` (in thousandths of the input, the
    /// estimate) with its own floor `floor`.
    function _route(MockV3Pool pool, uint256 promisePermille, uint256 floor) internal view returns (Route memory r) {
        r = abi.decode(routeTemplate, (Route));
        r.hops[0].legs[0].pool = address(pool);
        r.hops[0].legs[0].fee = pool.fee();
        // At the input (1:1 price), above what either venue pays after its fee and impact, and
        // within the Router's per-leg floor (80% of the leg's promise, RouterE(5)).
        uint256 promised = AMT * promisePermille / 1000;
        r.totalOut = promised;
        r.singleOut = promised;
        r.hops[0].expectedOut = promised;
        r.hops[0].legs[0].expectedOut = promised;
        r.singleOutFloor = floor;
    }

    function _plan(Route memory best, Route memory fb, bool has) internal {
        fixedSolver.set(RoutePlan({best: best, fallbackRoute: fb, hasFallback: has}));
    }

    function _empty() internal pure returns (Route memory r) {}

    /// What the Router delivers for `r` (minOut 1), the oracle; the state is rolled back.
    function _delivered(Route memory r) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        tA.mint(address(this), AMT);
        tA.approve(address(router), AMT);
        out = router.swapExactIn(r, AMT, 1, recipient, block.timestamp + 1);
        vm.revertToState(snap);
    }

    function decodeCall(bytes calldata data)
        external pure returns (Route memory r, uint256 amountIn, uint256 minOut)
    {
        (r, amountIn, minOut, , ) = abi.decode(data[4:], (Route, uint256, uint256, address, uint256));
    }

    function _submit(bytes memory data) internal returns (bool ok, bytes memory ret, uint256 out) {
        tA.mint(address(this), AMT);
        tA.approve(address(router), AMT);
        (ok, ret) = address(router).call(data);
        if (ok) out = abi.decode(ret, (uint256));
    }

    function _encode(uint256 userMinOut, uint256 deadline)
        internal returns (BlazePhoenixQuoter.Preview memory pv, bytes memory data)
    {
        (pv, data) = quoter.previewAndEncodeWithMinOut(address(tA), address(tB), AMT, userMinOut, recipient, deadline);
    }

    function _poolOf(Route memory r) internal pure returns (address) { return r.hops[0].legs[0].pool; }

    // ---------------------------------------------------------------- the leader settles

    /// The leader settles at its own floor, to the wei: the bytes are the leader's and the
    /// runner-up's venue is not asked.
    function test_LeaderExactlyAtItsFloor_BytesCarryTheLeader_RunnerUpNotAsked() public {
        _plan(_route(poolL, 1000, dL), _route(poolR, 1000, dR), true);
        vm.expectCall(address(poolR), "", 0);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encode(0, block.timestamp + 1);
        assertTrue(pv.canExecute, "the leader settles at its floor");
        (Route memory r, , uint256 minOut) = this.decodeCall(data);
        assertEq(_poolOf(r), address(poolL), "the bytes carry the leader");
        assertEq(minOut, dL, "at its own floor");
        (bool ok, , uint256 out) = _submit(data);
        assertTrue(ok, "the bytes settle");
        assertGe(out, minOut, "at the floor they carry");
    }

    // ---------------------------------------------------------------- the fallback

    /// The leader's venue pays one wei under its floor; the runner-up settles at its own: the
    /// bytes carry the runner-up, at the runner-up's floor, and the Router settles them.
    function test_LeaderOneWeiUnderItsFloor_RunnerUpSettles_BytesCarryTheRunnerUp() public {
        _plan(_route(poolL, 1000, dL + 1), _route(poolR, 1000, dR), true);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encode(0, block.timestamp + 1);
        assertTrue(pv.canExecute, "the runner-up settles");
        assertEq(_poolOf(pv.route), address(poolR), "the preview is the runner-up's, as the bytes");
        (Route memory r, , uint256 minOut) = this.decodeCall(data);
        assertEq(_poolOf(r), address(poolR), "the bytes carry the runner-up");
        assertEq(minOut, dR, "at the runner-up's own floor, not the leader's");
        assertEq(minOut, pv.effectiveMinOut, "the floor the preview names");
        (bool ok, bytes memory ret, uint256 out) = _submit(data);
        assertTrue(ok, string.concat("bytes the Router refuses: ", vm.toString(ret)));
        assertEq(out, dR, "the runner-up's delivery");
    }

    /// Both venues pay one wei under their floors: no bytes, the preview stays the leader's,
    /// one solve, and each venue is dry-run once (two routes measured, no third).
    function test_BothOneWeiUnderTheirFloors_NoBytes_OneSolve_TheLeaderIsReported() public {
        _plan(_route(poolL, 1000, dL + 1), _route(poolR, 1000, dR + 1), true);
        vm.expectCall(address(fixedSolver), abi.encodeCall(FixedPlanSolver.findBestRoutePlan, (address(tA), address(tB), AMT)), 1);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encode(0, block.timestamp + 1);
        assertFalse(pv.canExecute, "neither settles");
        assertEq(data.length, 0, "no bytes");
        assertEq(_poolOf(pv.route), address(poolL), "the preview reports the leader");
        assertEq(pv.effectiveMinOut, dL + 1, "at the leader's floor");
    }

    /// The caller's floor holds for the runner-up too: its own floor is low, the caller's is
    /// one wei above what it pays. No bytes.
    function test_RunnerUpUnderTheCallersFloor_NoBytes() public {
        _plan(_route(poolL, 1000, dL + 1), _route(poolR, 1000, dR / 2), true);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encode(dR + 1, block.timestamp + 1);
        assertFalse(pv.canExecute, "the runner-up pays under the caller's floor");
        assertEq(data.length, 0, "no bytes");
        // Control: at the caller's floor the runner-up meets, it is encoded.
        (pv, data) = _encode(dR, block.timestamp + 1);
        assertTrue(pv.canExecute, "control: the runner-up meets the caller's floor");
        assertEq(pv.effectiveMinOut, dR, "control: the caller's floor is the one carried");
    }

    /// A deadline behind the block refuses both routes; the preview stays the leader's.
    function test_DeadlineBehind_NoBytes_TheLeaderIsReported() public {
        vm.warp(1000);
        _plan(_route(poolL, 1000, dL), _route(poolR, 1000, dR), true);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encode(0, block.timestamp - 1);
        assertFalse(pv.canExecute, "a deadline behind the block");
        assertEq(data.length, 0, "no bytes");
        assertEq(_poolOf(pv.route), address(poolL), "the leader is reported");
    }

    /// No runner-up: the leader refused, nothing else is packed.
    function test_NoRunnerUp_LeaderUnderItsFloor_NoBytes() public {
        _plan(_route(poolL, 1000, dL + 1), _empty(), false);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encode(0, block.timestamp + 1);
        assertFalse(pv.canExecute, "the leader does not settle");
        assertEq(data.length, 0, "no bytes");
        assertEq(_poolOf(pv.route), address(poolL), "the leader is reported");
    }

    /// The leader refused by the preview's own gate (the caller's floor above its estimate) is
    /// not a measured refusal: the runner-up, which would settle at that floor, is not asked.
    function test_LeaderRefusedByThePreviewGate_RunnerUpNotAsked() public {
        Route memory lead = _route(poolL, 1000, 1);
        lead.totalOut = dR / 2; lead.singleOut = dR / 2;
        lead.hops[0].expectedOut = dR / 2; lead.hops[0].legs[0].expectedOut = dR / 2;
        _plan(lead, _route(poolR, 1000, 1), true);
        uint256 userMin = dR * 3 / 4;
        vm.expectCall(address(poolR), "", 0);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encode(userMin, block.timestamp + 1);
        assertFalse(pv.canExecute, "the leader's estimate is under the caller's floor");
        assertEq(data.length, 0, "no bytes");
        assertEq(_poolOf(pv.route), address(poolL), "the leader is reported");
    }

    /// Fuzz around both floors, +-2 wei, and the caller's: bytes exist only where the route
    /// they carry is the leader or the runner-up, the leader only if it settles, the runner-up
    /// only if the leader does not, and the Router settles them at the floor they carry.
    function testFuzz_BytesNeverCarryARouteUnderItsOwnFloor(uint8 offL, uint8 offR, uint256 userSeed) public {
        uint256 fL = dL + bound(offL, 0, 4) - 2;
        uint256 fR = dR + bound(offR, 0, 4) - 2;
        uint256 userMin = bound(userSeed, 0, dR + 2);
        _plan(_route(poolL, 1000, fL), _route(poolR, 1000, fR), true);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encode(userMin, block.timestamp + 1);
        bool leaderSettles = dL >= (fL > userMin ? fL : userMin);
        bool runnerSettles = dR >= (fR > userMin ? fR : userMin);
        if (leaderSettles) {
            assertEq(_poolOf(pv.route), address(poolL), "a settling leader is kept");
        } else if (runnerSettles) {
            assertEq(_poolOf(pv.route), address(poolR), "a refused leader yields to a settling runner-up");
        }
        assertEq(data.length != 0, leaderSettles || runnerSettles, "bytes iff one of the two settles");
        assertEq(pv.canExecute, data.length != 0, "canExecute names the bytes");
        if (data.length == 0) return;
        (, , uint256 minOut) = this.decodeCall(data);
        (bool ok, bytes memory ret, uint256 out) = _submit(data);
        assertTrue(ok, string.concat("bytes the Router refuses: ", vm.toString(ret)));
        assertGe(out, minOut, "settled under the floor they carry");
    }

    // ---------------------------------------------------------------- a zero floor

    /// A route whose floor is zero (a one-unit input the fee takes whole) is never encoded:
    /// the Router refuses minOut 0 with a non-zero input (RouterE(10)).
    function test_ZeroFloor_NoRunnerUp_NoBytes() public {
        Route memory lead = _route(poolL, 1000, 0);
        _plan(lead, _empty(), false);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) =
            quoter.previewAndEncode(address(tA), address(tB), AMT, recipient, block.timestamp + 1);
        assertEq(pv.effectiveMinOut, 0, "premise: the floor is zero");
        assertFalse(pv.canExecute, "a zero floor is not executable");
        assertEq(data.length, 0, "no bytes");
        // Control: the Router refuses the same call with minOut 0.
        tA.mint(address(this), AMT);
        tA.approve(address(router), AMT);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(10)));
        router.swapExactIn(lead, AMT, 0, recipient, block.timestamp + 1);
    }

    /// A zero-floor leader yields to a runner-up with a floor of its own that settles.
    function test_ZeroFloorLeader_RunnerUpWithItsOwnFloorSettles() public {
        _plan(_route(poolL, 1000, 0), _route(poolR, 1000, dR), true);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) =
            quoter.previewAndEncode(address(tA), address(tB), AMT, recipient, block.timestamp + 1);
        assertTrue(pv.canExecute, "the runner-up settles");
        (Route memory r, , uint256 minOut) = this.decodeCall(data);
        assertEq(_poolOf(r), address(poolR), "the bytes carry the runner-up");
        assertEq(minOut, dR, "with a non-zero floor");
        (bool ok, , ) = _submit(data);
        assertTrue(ok, "the bytes settle");
    }

    // ---------------------------------------------------------------- gas

    /// The fallback branch: the leader refused by `_encode`, the runner-up packed and measured.
    function test_Gas_PreviewAndEncode_FallbackBranch() public {
        _plan(_route(poolL, 1000, dL + 1), _route(poolR, 1000, dR), true);
        quoter.previewAndEncodeWithMinOut(address(tA), address(tB), AMT, 0, recipient, block.timestamp + 1);
        vm.snapshotGasLastCall("QuoterEncodeFallsBackOnce", "PreviewAndEncode_FallbackBranch");
    }

    /// The normal branch on the same harness: the leader settles.
    function test_Gas_PreviewAndEncode_LeaderSettles() public {
        _plan(_route(poolL, 1000, dL), _route(poolR, 1000, dR), true);
        quoter.previewAndEncodeWithMinOut(address(tA), address(tB), AMT, 0, recipient, block.timestamp + 1);
        vm.snapshotGasLastCall("QuoterEncodeFallsBackOnce", "PreviewAndEncode_LeaderSettles");
    }
}
