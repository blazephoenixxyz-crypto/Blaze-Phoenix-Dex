// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  EVERY CONFIG DOOR EMITS THE SEAT IT WROTE, AND A REFUSED DOOR EMITS NOTHING.
//
//  A mutable instrument without an event measures the wrong place: an indexer, a monitor or
//  the API learns of a treasury move, a pause, a rescue or a renounce only from the log. Until
//  this file no door of the Router (Cfg 0-4, PausedSet, ControlRenounced, RescueQueued,
//  RescueCancelled, Rescued), of the Gate
//  (AdminSet, ControlRenounced, Adapter*, WrapperCreated) or the Hub's Evicted had its log
//  pinned: deleting any of those emits left the suite green.
//
//  Each door: vm.expectEmit(true, true, true, true, emitter) with every field, then the state
//  the log names read back from storage (the log is the seat that was written, not a guess).
//  Each refusal: the exact selector and code, no log, and the state unchanged.
//
//  Mutants that turn this file red (.github/scripts/mutants.py, [morf-P3-*]): every door above
//  without its emit; Cfg(1,t1) -> Cfg(2,t1); RescueQueued eta -> 0; Rescued amt -> 0;
//  Gate:113 forgetting `controlRenounced`; the Router's renounce and cancel back on the
//  seat-shaped logs they had before NOMES-124 (Cfg(0, 0), RescueQueued(token, to, 0)). Pins of behaviour that exists at cb1d7d9: green
//  there, so the evidence is the mutants.
// =============================================================================
import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockGateVenue, MockGateRegistry, MockGateAdapter} from "./mocks/MockGateAdapters.sol";
import {MockV4ManagerNative} from "./RouterV4NativeEth.t.sol";

contract ConfigDoorEventsArePinnedTest is Test {
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    address constant NEW = address(0xA0A0);
    address constant STRANGER = address(0xBAD);
    address constant TO = address(0x7070);
    address constant TOK_A = address(0xA11A);
    address constant TOK_B = address(0xB22B);
    uint24 constant GKEY = uint24(uint256(1) << 16 | 1);
    uint256 constant MAX_SLOTS = 16; // Hub:87
    uint256 constant T0 = 1_000_000;
    // ERC-7201 root of the Hub's storage (Hub: "blazephoenix.hub.v1"); field 6 = poolOf.
    bytes32 constant HUB_SLOT =
        keccak256(abi.encode(uint256(keccak256("blazephoenix.hub.v1")) - 1)) & ~bytes32(uint256(0xff));

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    BlazePhoenixGate gate;

    function setUp() public {
        MockV4ManagerNative mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        gate = new BlazePhoenixGate(address(this));
    }

    // ─── helpers ───

    function _rE(uint16 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, c);
    }

    function _gE(uint8 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixGate.GateE.selector, c);
    }

    /// The call reverts with exactly `err` and leaves no log.
    function _refused(address target, address who, bytes memory data, bytes memory err) internal {
        vm.recordLogs();
        vm.prank(who);
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, "the door refused");
        assertEq(ret, err, "refused with the expected selector and code");
        assertEq(vm.getRecordedLogs().length, 0, "a refused door logs nothing");
    }

    function _routerSeats() internal view returns (bytes32) {
        return keccak256(abi.encode(
            router.admin(), router.treasury1(), router.treasury2(), router.permit2(), router.weth(),
            router.paused(), router.controlRenounced()
        ));
    }

    function _rescueKey(address token, address to) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, to));
    }

    /// Every onlyControl door of the Router, called by `who`: RouterE(1), no log, no seat moved.
    function _routerControlRefuses(address who) internal {
        address tok = address(0x7011);
        bytes32 seats = _routerSeats();
        _refused(address(router), who, abi.encodeCall(router.setAdmin, (NEW)), _rE(1));
        _refused(address(router), who, abi.encodeCall(router.setTreasuries, (NEW, NEW)), _rE(1));
        _refused(address(router), who, abi.encodeCall(router.setPermit2, (NEW)), _rE(1));
        _refused(address(router), who, abi.encodeCall(router.setWeth, (NEW)), _rE(1));
        _refused(address(router), who, abi.encodeCall(router.setPaused, (true)), _rE(1));
        _refused(address(router), who, abi.encodeCall(router.renounceControl, ()), _rE(1));
        _refused(address(router), who, abi.encodeCall(router.queueRescue, (tok, TO)), _rE(1));
        _refused(address(router), who, abi.encodeCall(router.cancelRescue, (tok, TO)), _rE(1));
        _refused(address(router), who, abi.encodeCall(router.executeRescue, (tok, TO)), _rE(1));
        assertEq(_routerSeats(), seats, "no seat moved");
        assertEq(router.rescueEta(_rescueKey(tok, TO)), 0, "no rescue queued");
    }

    // ─── Router: Cfg 0-4 and PausedSet ───

    function test_RouterCfg0_SetAdminEmitsTheSeatItWrote() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(0, NEW);
        router.setAdmin(NEW);
        assertEq(router.admin(), NEW);
        // The same value again is a write again, and says so.
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(0, NEW);
        vm.prank(NEW);
        router.setAdmin(NEW);
        _refused(address(router), NEW, abi.encodeCall(router.setAdmin, (address(0))), _rE(3));
        assertEq(router.admin(), NEW);
    }

    function test_RouterCfg1Cfg2_SetTreasuriesEmitsBothSeatsInOrder() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(1, TOK_A);
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(2, TOK_B);
        router.setTreasuries(TOK_A, TOK_B);
        assertEq(router.treasury1(), TOK_A);
        assertEq(router.treasury2(), TOK_B);
        // One address in both seats: two writes, two logs.
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(1, NEW);
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(2, NEW);
        router.setTreasuries(NEW, NEW);
        bytes32 seats = _routerSeats();
        _refused(address(router), address(this), abi.encodeCall(router.setTreasuries, (address(0), TOK_B)), _rE(3));
        _refused(address(router), address(this), abi.encodeCall(router.setTreasuries, (TOK_A, address(0))), _rE(3));
        assertEq(_routerSeats(), seats);
    }

    /// A treasury moves its own seat, also after renounce; one address in both seats moves t1.
    function test_RouterCfg1Cfg2_MoveTreasuryEmitsTheMoversSeat() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(1, TOK_A);
        vm.prank(T1);
        router.moveTreasury(TOK_A);
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(2, TOK_B);
        vm.prank(T2);
        router.moveTreasury(TOK_B);
        assertEq(router.treasury1(), TOK_A);
        assertEq(router.treasury2(), TOK_B);

        router.renounceControl();
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(2, NEW);
        vm.prank(TOK_B);
        router.moveTreasury(NEW);
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(1, NEW);
        vm.prank(TOK_A);
        router.moveTreasury(NEW);
        // Both seats now NEW: the mover's first seat is t1, and only t1 moves.
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Cfg(1, TO);
        vm.prank(NEW);
        router.moveTreasury(TO);
        assertEq(router.treasury1(), TO);
        assertEq(router.treasury2(), NEW);

        bytes32 seats = _routerSeats();
        _refused(address(router), STRANGER, abi.encodeCall(router.moveTreasury, (STRANGER)), _rE(1));
        _refused(address(router), TO, abi.encodeCall(router.moveTreasury, (address(0))), _rE(3));
        assertEq(_routerSeats(), seats);
    }

    function test_RouterCfg3Cfg4_Permit2AndWethEmitTheAddress() public {
        address[2] memory vals = [NEW, address(0)];
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(true, true, true, true, address(router));
            emit BlazePhoenixRouter.Cfg(3, vals[i]);
            router.setPermit2(vals[i]);
            assertEq(router.permit2(), vals[i]);
            vm.expectEmit(true, true, true, true, address(router));
            emit BlazePhoenixRouter.Cfg(4, vals[i]);
            router.setWeth(vals[i]);
            assertEq(router.weth(), vals[i]);
        }
    }

    function test_RouterPausedSet_EmitsBothDirections() public {
        bool[3] memory vals = [true, true, false];
        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(true, true, true, true, address(router));
            emit BlazePhoenixRouter.PausedSet(vals[i]);
            router.setPaused(vals[i]);
            assertEq(router.paused(), vals[i]);
        }
    }

    // ─── Router: renounce and refusals ───

    function test_RouterRenounce_EmitsControlRenounced_ThenEveryControlDoorRefuses() public {
        router.setPaused(true);
        _refused(address(router), address(this), abi.encodeCall(router.renounceControl, ()), _rE(2));
        assertFalse(router.controlRenounced());
        router.setPaused(false);

        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.ControlRenounced();
        router.renounceControl();
        assertTrue(router.controlRenounced());
        assertEq(router.admin(), address(this), "renounce kills control, it does not rewrite the seat");
        _routerControlRefuses(address(this));
    }

    function test_RouterControlDoors_RefuseAStranger() public {
        _routerControlRefuses(STRANGER);
    }

    // ─── Router: a renounce and a cancel log no seat they did not write (NOMES-124 L2-07, L2-08) ───

    /// @notice An indexer that follows `Cfg(0, x)` as the admin seat must not read a renounce as
    ///         `admin = address(0)`: renouncing leaves the seat as it was. The renounce's ONLY log
    ///         is `ControlRenounced()`, and no `Cfg` is among the logs at all.
    ///         Red at c7beefb (the renounce emitted `Cfg(0, address(0))`).
    function test_RouterRenounce_LogsNoAdminSeat() public {
        vm.recordLogs();
        router.renounceControl();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "a renounce writes one log");
        assertEq(logs[0].emitter, address(router));
        assertEq(logs[0].topics.length, 1, "ControlRenounced() carries no field");
        assertEq(logs[0].topics[0], BlazePhoenixRouter.ControlRenounced.selector, "the renounce's own event");
        assertTrue(logs[0].topics[0] != BlazePhoenixRouter.Cfg.selector, "no Cfg: the admin seat was not written");
        assertEq(router.admin(), address(this), "the seat an indexer would read is still the admin");
    }

    /// @notice An indexer that counts `RescueQueued` as a pending rescue must not count a cancel:
    ///         the cancel's ONLY log is `RescueCancelled(token, to)`, both fields indexed, and no
    ///         `RescueQueued` is among the logs. Red at c7beefb (the cancel emitted
    ///         `RescueQueued(token, to, 0)`).
    function test_RouterCancelRescue_LogsNoQueuedRescue() public {
        PathologicalERC20 tok = new PathologicalERC20("S", "S", 18);
        router.queueRescue(address(tok), TO);
        vm.recordLogs();
        router.cancelRescue(address(tok), TO);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "a cancel writes one log");
        assertEq(logs[0].emitter, address(router));
        assertEq(logs[0].topics.length, 3, "token and to, indexed");
        assertEq(logs[0].topics[0], BlazePhoenixRouter.RescueCancelled.selector, "the cancel's own event");
        assertTrue(logs[0].topics[0] != BlazePhoenixRouter.RescueQueued.selector, "no RescueQueued: nothing is queued");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(tok)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(TO))));
        assertEq(logs[0].data.length, 0, "no eta field");
        assertEq(router.rescueEta(_rescueKey(address(tok), TO)), 0);
    }

    // ─── Router: rescue ───

    function test_RouterRescue_LogsTheStoredEtaAndTheMovedAmount() public {
        PathologicalERC20 tok = new PathologicalERC20("S", "S", 18);
        tok.mint(address(router), 777e18); // an accidental direct send
        bytes32 k = _rescueKey(address(tok), TO);
        _refused(address(router), address(this), abi.encodeCall(router.queueRescue, (address(tok), address(0))), _rE(3));

        // Times are constants and block.timestamp is never read here: via_ir treats TIMESTAMP as
        // fixed within the frame and may recompute `block.timestamp + x` after a vm.warp.
        vm.warp(T0);
        uint256 eta = T0 + 48 hours;
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.RescueQueued(address(tok), TO, eta);
        router.queueRescue(address(tok), TO);
        assertEq(router.rescueEta(k), eta, "the logged eta is the stored eta");

        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.RescueCancelled(address(tok), TO);
        router.cancelRescue(address(tok), TO);
        assertEq(router.rescueEta(k), 0, "a cancel deletes the eta it logs as cancelled");
        _refused(address(router), address(this), abi.encodeCall(router.executeRescue, (address(tok), TO)), _rE(14));

        vm.warp(T0 + 1 days);
        router.queueRescue(address(tok), TO);
        eta = T0 + 1 days + 48 hours;
        assertEq(router.rescueEta(k), eta, "a re-queue restarts the 48h");
        vm.warp(eta - 1);
        _refused(address(router), address(this), abi.encodeCall(router.executeRescue, (address(tok), TO)), _rE(14));
        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(router));
        emit BlazePhoenixRouter.Rescued(address(tok), TO, 777e18);
        router.executeRescue(address(tok), TO);
        assertEq(tok.balanceOf(TO), 777e18, "the logged amount is what arrived");
        assertEq(router.rescueEta(k), 0);
    }

    // ─── Gate ───

    function _adapter(MockGateRegistry reg) internal returns (MockGateAdapter a) {
        a = new MockGateAdapter(gate, reg);
        gate.proposeAdapter(1, address(a));
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(1);
    }

    function test_GateAdminSetAndControlRenounced_ThenControlDoorsRefuse() public {
        vm.expectEmit(true, true, true, true, address(gate));
        emit BlazePhoenixGate.AdminSet(NEW);
        gate.setAdmin(NEW);
        assertEq(gate.admin(), NEW);
        vm.prank(NEW);
        gate.setAdmin(address(this));
        _refused(address(gate), address(this), abi.encodeCall(gate.setAdmin, (address(0))), _gE(3));
        _refused(address(gate), STRANGER, abi.encodeCall(gate.setAdmin, (STRANGER)), _gE(2));

        MockGateAdapter a = _adapter(new MockGateRegistry());
        vm.expectEmit(true, true, true, true, address(gate));
        emit BlazePhoenixGate.ControlRenounced();
        gate.renounceControl();
        assertTrue(gate.controlRenounced());

        // Control died with the renounce; the admin seat and the live adapter stay as they were.
        _refused(address(gate), address(this), abi.encodeCall(gate.setAdmin, (NEW)), _gE(2));
        _refused(address(gate), address(this), abi.encodeCall(gate.clearAdapter, (1)), _gE(2));
        assertEq(gate.admin(), address(this));
        assertEq(gate.adapterOf(1), address(a));
        assertEq(gate.liveAdapter(1), address(a));
    }

    function test_GateAdapterAndWrapperDoorsLogWhatTheyStore() public {
        MockGateRegistry reg = new MockGateRegistry();
        MockGateAdapter a = new MockGateAdapter(gate, reg);
        vm.warp(T0);
        uint256 eta = T0 + 48 hours;
        vm.expectEmit(true, true, true, true, address(gate));
        emit BlazePhoenixGate.AdapterProposed(1, address(a), address(a).codehash, eta);
        gate.proposeAdapter(1, address(a));
        (address pa, uint64 peta, bytes32 pch) = gate.pendingOf(1);
        assertEq(pa, address(a));
        assertEq(uint256(peta), eta, "the logged eta is the stored eta");
        assertEq(pch, address(a).codehash);

        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(gate));
        emit BlazePhoenixGate.AdapterAccepted(1, address(a), address(a).codehash);
        gate.acceptAdapter(1);
        assertEq(gate.adapterOf(1), address(a));
        assertEq(gate.pinOf(1), address(a).codehash, "the logged codehash is the stored pin");

        PathologicalERC20 x = new PathologicalERC20("X", "X", 18);
        PathologicalERC20 y = new PathologicalERC20("Y", "Y", 18);
        (address t0, address t1) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        MockGateVenue gv = new MockGateVenue(address(x), address(y));
        reg.add(address(gv));
        bytes32 initHash = keccak256(type(BlazePhoenixGateWrapper).creationCode);
        assertEq(initHash, gate.WRAPPER_INIT_HASH(), "premise: the init hash the Hub pins");
        address w = vm.computeCreate2Address(keccak256(abi.encode(t0, t1, GKEY)), initHash, address(gate));
        vm.expectEmit(true, true, true, true, address(gate));
        emit BlazePhoenixGate.WrapperCreated(w, t0, t1, GKEY, address(gv));
        address got = gate.create(address(y), address(x), GKEY, abi.encode(address(gv)));
        assertEq(got, w, "the logged wrapper is the one deployed");
        assertTrue(gate.isWrapper(w));
        assertGt(w.code.length, 0);

        vm.expectEmit(true, true, true, true, address(gate));
        emit BlazePhoenixGate.AdapterCleared(1);
        gate.clearAdapter(1);
        assertEq(gate.adapterOf(1), address(0));
        assertEq(gate.liveAdapter(1), address(0));
    }

    // ─── Hub: Evicted ───

    function _poolOf(bytes32 key) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(hub), keccak256(abi.encode(key, uint256(HUB_SLOT) + 6))))));
    }

    /// A full pair evicts its weakest incumbent (a tie evicts the first seeded): the log names
    /// the key and the pool whose seat the Hub cleared.
    function test_HubEvicted_NamesTheSeatItCleared() public {
        for (uint256 i; i < MAX_SLOTS; ++i) {
            hub.seedPool(address(uint160(0xC000 + i)), BPC.KIND_V2, 30, address(0), TOK_A, TOK_B);
        }
        address victim = address(0xC000);
        bytes32 key = keccak256(abi.encodePacked(victim, TOK_A, TOK_B));
        assertEq(_poolOf(key), victim, "premise: the poolOf slot is read where the Hub writes it");
        vm.expectEmit(true, true, true, true, address(hub));
        emit BlazePhoenixHub.Evicted(key, victim);
        hub.seedPool(address(uint160(0xC000 + MAX_SLOTS)), BPC.KIND_V2, 30, address(0), TOK_A, TOK_B);
        assertEq(_poolOf(key), address(0), "the logged seat is the one cleared");
    }
}
