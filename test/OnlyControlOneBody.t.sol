// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  THE ROUTER'S CONTROL GATE: ONE PREDICATE, NINE DOORS, THE ANSWER OF cb1d7d9.
//
//  `onlyControl` asks one question at nine doors (setAdmin, setTreasuries, setPermit2, setWeth,
//  setPaused, renounceControl, queueRescue, cancelRescue, executeRescue): is the caller the admin,
//  and is control still alive? At cb1d7d9 the modifier carried the predicate inline, so the
//  compiler laid one copy at each door. Moving it into one private function, the way the Hub's
//  `_auth` already works, costs the Router fewer bytes and must cost it nothing else.
//
//  This file is the equivalence, and it is green on both sides of that move:
//    - the frozen gate (test/morf/OnlyControlRefCb1d7d9.sol: the modifier of cb1d7d9, literally)
//      is given the Router's two seats and the same msg.sender; each door must open exactly when
//      the frozen gate opens, and refuse with the frozen gate's bytes;
//    - the same nine doors against literal expectations, with no reference in the oracle;
//    - a stateful campaign against a model that never reads the Router's seats.
//  A refusal is asserted by its exact bytes (selector and code), leaves no log and moves nothing.
//  The gate answers before the door's own refusals do.
//
//  Pins of behaviour that exists at cb1d7d9: green there, so the evidence is the mutants
//  (.github/scripts/mutants.py, [morf-R2-*]): the predicate without its renunciation arm, with
//  `==`, with `<`, with tx.origin, with the arm's polarity inverted, admitting the Router itself,
//  reading the treasury's seat, raising another code; the modifier without its body; and each
//  of the nine doors without the modifier.
// =============================================================================
import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {OnlyControlRefCb1d7d9} from "./morf/OnlyControlRefCb1d7d9.sol";

/// The nine doors and the fixture both contracts below stand on.
abstract contract OnlyControlDoors is Test {
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    address constant NEXT = address(0xAD31);   // the admin after a handover
    address constant STRANGER = address(0xBAD);
    address constant SEAT = address(0xA0A0);   // what an open door writes
    address constant SEAT2 = address(0xA0A1);
    address constant TO = address(0x7070);     // the rescue armed by _arm pays here
    uint256 constant DOORS = 9;
    uint256 constant T0 = 1_000_000;
    uint256 constant ARMED = T0 + 48 hours;    // Router: RESCUE_DELAY
    uint256 constant STRAY = 777e18;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tok;

    /// The Router with this contract as admin, and a stray balance for a rescue to move.
    function _deploy() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        tok = new MockERC20("S", "S");
        tok.mint(address(router), STRAY); // an accidental direct send
    }

    /// One rescue queued and past its timelock, so that all nine doors have a body that succeeds
    /// once the gate opens. It is the first door the live admin opens, so it is asserted, and each
    /// test calls it from its own body: a gate that refuses its admin fails the test that asked,
    /// not a fixture that every test shares.
    function _arm() internal {
        // Times are constants: via_ir may recompute `block.timestamp + x` after a vm.warp.
        vm.warp(T0);
        (bool ok,) = address(router).call(abi.encodeCall(router.queueRescue, (address(tok), TO)));
        assertTrue(ok, "the live admin arms the rescue");
        vm.warp(ARMED);
    }

    function _e(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    function _key(address to) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(tok), to));
    }

    /// Door `i` with arguments its body accepts.
    function _door(uint256 i) internal view returns (bytes memory) {
        if (i == 0) return abi.encodeCall(router.setAdmin, (SEAT));
        if (i == 1) return abi.encodeCall(router.setTreasuries, (SEAT, SEAT2));
        if (i == 2) return abi.encodeCall(router.setPermit2, (SEAT));
        if (i == 3) return abi.encodeCall(router.setWeth, (SEAT));
        if (i == 4) return abi.encodeCall(router.setPaused, (true));
        if (i == 5) return abi.encodeCall(router.renounceControl, ());
        if (i == 6) return abi.encodeCall(router.queueRescue, (address(tok), SEAT));
        if (i == 7) return abi.encodeCall(router.cancelRescue, (address(tok), TO));
        return abi.encodeCall(router.executeRescue, (address(tok), TO));
    }

    /// Everything a control door can write.
    function _state() internal view returns (bytes32) {
        return keccak256(abi.encode(
            router.admin(), router.treasury1(), router.treasury2(), router.permit2(), router.weth(),
            router.paused(), router.controlRenounced(),
            router.rescueEta(_key(TO)), router.rescueEta(_key(SEAT)),
            tok.balanceOf(address(router)), tok.balanceOf(TO)
        ));
    }
}

contract OnlyControlOneBodyTest is OnlyControlDoors {
    OnlyControlRefCb1d7d9 ref;

    function setUp() public {
        _deploy();
        ref = new OnlyControlRefCb1d7d9();
    }

    // ─── helpers ───

    /// `who` at door `i`: refused with exactly `err`, no log, nothing moved.
    function _refused(uint256 i, address who, bytes memory data, bytes memory err) internal {
        bytes32 seats = _state();
        vm.recordLogs();
        vm.prank(who);
        (bool ok, bytes memory ret) = address(router).call(data);
        assertFalse(ok, string.concat("door ", vm.toString(i), " refused"));
        assertEq(ret, err, string.concat("door ", vm.toString(i), ": the exact selector and code"));
        assertEq(vm.getRecordedLogs().length, 0, "a refused door logs nothing");
        assertEq(_state(), seats, "a refused door moves nothing");
    }

    function _allNineRefuse(address who) internal {
        for (uint256 i; i < DOORS; ++i) _refused(i, who, _door(i), _e(1));
    }

    /// Door `i` under `who`, undone afterwards: did it open, with which bytes, how many logs, and
    /// did anything move.
    function _knock(uint256 i, address who)
        internal returns (bool ok, bytes memory ret, uint256 logs, bool moved)
    {
        bytes memory data = _door(i);
        bytes32 seats = _state();
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(who);
        (ok, ret) = address(router).call(data);
        logs = vm.getRecordedLogs().length;
        moved = _state() != seats;
        vm.revertToStateAndDelete(snap);
    }

    /// The frozen gate of cb1d7d9 under the Router's two seats and the same caller.
    function _frozen(address who) internal returns (bool ok, bytes memory ret) {
        ref.mirror(router.admin(), router.controlRenounced());
        vm.prank(who);
        (ok, ret) = address(ref).call(abi.encodeCall(ref.door, ()));
    }

    /// All nine doors give `who` the frozen gate's verdict. Returns how many opened.
    function _sameVerdictAtNine(address who) internal returns (uint256 opened) {
        (bool refOk, bytes memory refRet) = _frozen(who);
        if (!refOk) assertEq(refRet, _e(1), "the frozen gate refuses with the Router's RouterE(1)");
        for (uint256 i; i < DOORS; ++i) {
            (bool ok, bytes memory ret, uint256 logs, bool moved) = _knock(i, who);
            string memory d = string.concat("door ", vm.toString(i));
            assertEq(ok, refOk, string.concat(d, " opens exactly when the frozen gate opens"));
            if (refOk) {
                assertGt(logs, 0, string.concat(d, ": an open door logs what it wrote"));
                assertTrue(moved, string.concat(d, ": an open door writes"));
                ++opened;
            } else {
                assertEq(ret, refRet, string.concat(d, ": refused with the frozen gate's bytes"));
                assertEq(logs, 0, string.concat(d, ": a refused door logs nothing"));
                assertFalse(moved, string.concat(d, ": a refused door moves nothing"));
            }
        }
    }

    function _callers() internal view returns (address[9] memory c) {
        c = [address(this), NEXT, STRANGER, T1, T2, address(router), address(hub), address(solver), address(0)];
    }

    // ─── R2-T1: nine doors, literal expectations (no reference in the oracle) ───

    /// Nobody but the live admin opens any of the nine doors, and after renounceControl nobody
    /// does. Every refusal is RouterE(1) by its exact bytes.
    function test_OnlyControl_NineDoorsRefuseByE1() public {
        _arm();
        // Control alive: a stranger, both treasuries (a seat with its own door, moveTreasury, and
        // no control), the Router itself, its Hub and Solver, and the zero address.
        address[9] memory c = _callers();
        for (uint256 k = 1; k < c.length; ++k) _allNineRefuse(c[k]);

        // The gate answers before the door's own refusals: a zero seat (3), a zero payee (3), a
        // pair never queued (14) and a renounce while paused (2) are all RouterE(1) to a stranger.
        _refused(0, STRANGER, abi.encodeCall(router.setAdmin, (address(0))), _e(1));
        _refused(1, STRANGER, abi.encodeCall(router.setTreasuries, (address(0), address(0))), _e(1));
        _refused(6, STRANGER, abi.encodeCall(router.queueRescue, (address(tok), address(0))), _e(1));
        _refused(8, STRANGER, abi.encodeCall(router.executeRescue, (address(tok), STRANGER)), _e(1));
        router.setPaused(true);
        _refused(5, STRANGER, abi.encodeCall(router.renounceControl, ()), _e(1));
        router.setPaused(false);

        // A handover: the seat moved, so the previous admin is a stranger at all nine.
        router.setAdmin(NEXT);
        _allNineRefuse(address(this));

        // Renounced by the admin of the day: the nine doors are shut for it, for the previous
        // admin and for everyone else, renounceControl itself included.
        vm.prank(NEXT);
        router.renounceControl();
        assertTrue(router.controlRenounced());
        for (uint256 k; k < c.length; ++k) _allNineRefuse(c[k]);
    }

    /// The other half: the live admin opens all nine, and each door writes what it says.
    function test_OnlyControl_NineDoorsOpenToTheLiveAdmin() public {
        _arm();
        uint256 snap = vm.snapshotState();
        for (uint256 pass; pass < 2; ++pass) {
            // Second pass: after a handover the new admin holds the nine doors.
            if (pass == 1) router.setAdmin(NEXT);
            address live = pass == 0 ? address(this) : NEXT;
            for (uint256 i; i < DOORS; ++i) {
                bytes memory data = _door(i);
                uint256 s = vm.snapshotState();
                vm.prank(live);
                (bool ok, bytes memory ret) = address(router).call(data);
                assertTrue(ok, string.concat("door ", vm.toString(i), " opens to the live admin"));
                assertEq(ret.length, 0);
                if (i == 0) assertEq(router.admin(), SEAT);
                if (i == 1) { assertEq(router.treasury1(), SEAT); assertEq(router.treasury2(), SEAT2); }
                if (i == 2) assertEq(router.permit2(), SEAT);
                if (i == 3) assertEq(router.weth(), SEAT);
                if (i == 4) assertTrue(router.paused());
                if (i == 5) assertTrue(router.controlRenounced());
                if (i == 6) assertEq(router.rescueEta(_key(SEAT)), ARMED + 48 hours);
                if (i == 7) assertEq(router.rescueEta(_key(TO)), 0);
                if (i == 8) assertEq(tok.balanceOf(TO), STRAY);
                vm.revertToStateAndDelete(s);
            }
        }
        vm.revertToStateAndDelete(snap);
        assertEq(router.admin(), address(this));
        assertEq(router.rescueEta(_key(TO)), ARMED, "the fixture's rescue is armed");
    }

    // ─── the equivalence: every door against the frozen gate of cb1d7d9 ───

    /// The four states of the two seats times nine callers times nine doors. The frozen gate opens
    /// for one caller in each live state and for none after renunciation; the count is literal.
    function test_OnlyControl_FrozenGateMatrix_OpensOnlyForTheLiveAdmin() public {
        _arm();
        address[9] memory c = _callers();
        uint256 opened;
        for (uint256 st; st < 4; ++st) {
            uint256 snap = vm.snapshotState();
            if ((st & 1) != 0) router.setAdmin(NEXT);
            address live = router.admin();
            bool renounced = (st & 2) != 0;
            if (renounced) { vm.prank(live); router.renounceControl(); }
            for (uint256 k; k < c.length; ++k) {
                uint256 n = _sameVerdictAtNine(c[k]);
                assertEq(n, (c[k] == live && !renounced) ? DOORS : 0, "who opens the nine doors");
                opened += n;
            }
            vm.revertToStateAndDelete(snap);
        }
        assertEq(opened, 2 * DOORS, "two live states, one admin each, nine doors");
    }

    /// Any caller, any of the four states: nine doors, the frozen gate's verdict and bytes. `cls`
    /// puts the live admin, the previous one and the Router among the callers, so the open arm is
    /// not left to a coincidence of addresses.
    function testFuzz_OnlyControl_EveryDoorGivesTheFrozenGatesVerdict(
        address who, uint8 cls, bool handover, bool renounce
    ) public {
        _arm();
        if (handover) router.setAdmin(NEXT);
        address live = router.admin();
        if (renounce) { vm.prank(live); router.renounceControl(); }
        cls = cls % 6;
        address caller = cls == 0 ? live
            : cls == 1 ? address(this)
            : cls == 2 ? NEXT
            : cls == 3 ? address(router)
            : who;
        uint256 opened = _sameVerdictAtNine(caller);
        assertEq(opened, (caller == live && !renounce) ? DOORS : 0, "who opens the nine doors");
    }

    /// Any address that is not the admin: nine refusals while control lives, and nine more, with
    /// the admin beside it, once it is renounced.
    function testFuzz_OnlyControl_NineDoorsRefuseByE1(address who) public {
        _arm();
        vm.assume(who != address(this));
        _allNineRefuse(who);
        router.renounceControl();
        _allNineRefuse(who);
        _allNineRefuse(address(this));
    }
}

/// The campaign's hands. It keeps its own two seats (who a door that opened last gave the admin
/// seat to, and whether renounceControl ever opened) and never reads the Router's.
contract OnlyControlHandler is Test {
    BlazePhoenixRouter immutable router;
    address immutable tok;
    bytes32 immutable e1;

    address[] actors;
    address public modelAdmin;
    bool public modelRenounced;
    uint256 clock;

    uint256 public opened;
    uint256 public refused;
    uint256 public wrong;

    constructor(BlazePhoenixRouter router_, address tok_, address admin_, address[] memory actors_, uint256 now_) {
        router = router_;
        tok = tok_;
        modelAdmin = admin_;
        actors = actors_;
        clock = now_;
        e1 = keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1)));
    }

    /// One knock: half of them by the model's admin, the rest by any actor.
    function knock(uint256 actorSeed, uint256 doorSeed, uint256 argSeed, bool flag) external {
        address who = (actorSeed & 1) == 0 ? modelAdmin : actors[(actorSeed >> 1) % actors.length];
        address arg = actors[argSeed % actors.length];
        uint256 d = doorSeed % 9;
        bytes memory data =
            d == 0 ? abi.encodeCall(router.setAdmin, (arg))
            : d == 1 ? abi.encodeCall(router.setTreasuries, (arg, arg))
            : d == 2 ? abi.encodeCall(router.setPermit2, (arg))
            : d == 3 ? abi.encodeCall(router.setWeth, (arg))
            : d == 4 ? abi.encodeCall(router.setPaused, (flag))
            : d == 5 ? abi.encodeCall(router.renounceControl, ())
            : d == 6 ? abi.encodeCall(router.queueRescue, (tok, arg))
            : d == 7 ? abi.encodeCall(router.cancelRescue, (tok, arg))
            : abi.encodeCall(router.executeRescue, (tok, arg));
        bool live = who == modelAdmin && !modelRenounced;
        vm.prank(who);
        (bool ok, bytes memory ret) = address(router).call(data);
        bool gateRefused = !ok && keccak256(ret) == e1;
        if (live) {
            // The gate never refuses the live admin. A door's own refusal (paused, timelock) is
            // another code and is neither an opening nor a fault.
            if (gateRefused) ++wrong;
            if (ok) {
                ++opened;
                if (d == 0) modelAdmin = arg;
                if (d == 5) modelRenounced = true;
            }
        } else {
            if (gateRefused) ++refused; else ++wrong;
        }
    }

    /// Time passes, so a queued rescue can come due.
    function wait(uint256 dt) external {
        clock += bound(dt, 1 hours, 72 hours);
        vm.warp(clock);
    }
}

contract OnlyControlOneBodyInvariant is OnlyControlDoors {
    OnlyControlHandler handler;

    function setUp() public {
        _deploy();
        _arm();
        address[] memory actors = new address[](6);
        actors[0] = address(this);
        actors[1] = NEXT;
        actors[2] = STRANGER;
        actors[3] = T1;
        actors[4] = address(router);
        actors[5] = TO;
        handler = new OnlyControlHandler(router, address(tok), address(this), actors, ARMED);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = handler.knock.selector;
        sels[1] = handler.wait.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// Through any sequence of handovers, pauses, rescues and a renunciation, a control door
    /// opens only to the model's live admin and refuses everyone else with RouterE(1); and the
    /// two seats the gate reads are the model's.
    function invariant_OnlyControl_ADoorOpensOnlyToTheModelsLiveAdmin() public view {
        assertEq(handler.wrong(), 0, "a door disagreed with the model");
        assertEq(router.admin(), handler.modelAdmin(), "the admin seat is the model's");
        assertEq(router.controlRenounced(), handler.modelRenounced(), "the renunciation is the model's");
    }

    /// Vacuity guard: the campaign both opened doors and had doors refuse.
    function afterInvariant() public view {
        assertGt(handler.opened(), 0, "the campaign opened a door");
        assertGt(handler.refused(), 0, "the campaign was refused at a door");
    }
}
