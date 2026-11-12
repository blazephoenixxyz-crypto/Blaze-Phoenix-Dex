// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ATQ-inv (atq-1111): stateful campaign over the Gate's adapter lifecycle.
//
// The handler is the Gate admin. It proposes, accepts and clears adapters for three families,
// morphs the code of an adapter between propose and accept (and after accept), warps onto and
// around the timelock boundary, renounces control and pokes every door as a stranger. Each
// transition is checked against a ghost model, and after every call:
//
//   G1  adapterOf / pinOf / pendingOf / familiesUsed mirror the model for every family
//   G2  liveAdapter(f) is the accepted adapter while its codehash still equals the pin, and
//       the zero address otherwise (the codehash is read from the chain, not from the Gate)
//   G3  admin and controlRenounced mirror the model
//
// and every refusal carried the exact GateE code the model expects (1 admin, 2 control,
// 3 zero address, 6 dirty code, 7 timelock, 8 nothing pending, 9 code changed, 10 sealed).
//
// Mutants: [ATQ-inv-n] in .github/scripts/mutants.py.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixGate} from "../src/BlazePhoenixGate.sol";

contract AtqGateHandler is Test {
    address public constant STRANGER = address(0xBAD5EED);
    // PUSH1 1 PUSH1 0 MSTORE PUSH1 0x20 PUSH1 0 RETURN
    bytes internal constant CODE_X = hex"600160005260206000f3";
    // Same shape, but the pushed byte is 0xF4: banned as an opcode, legal as PUSH data.
    bytes internal constant CODE_Y = hex"60f460005260206000f3";
    // PUSH1 0 DELEGATECALL
    bytes internal constant CODE_DIRTY = hex"6000f4";

    BlazePhoenixGate public gate;
    address[5] public cand; // 0..2 clean (morphable), 3 dirty, 4 no code
    mapping(address => bool) internal isY;

    struct GF { address pAdapter; uint64 pEta; bytes32 pHash; address adapter; bytes32 pin; bool used; }
    mapping(uint8 => GF) internal g;
    bool public gRenounced;

    uint256 public nBad;
    string public bad;
    uint256 public accepts;
    uint256 public clears;
    uint256 public seals;
    uint256 public codeChanged;

    constructor(BlazePhoenixGate gate_) {
        gate = gate_;
        for (uint256 i; i < 5; ++i) cand[i] = address(uint160(0xC0DE00 + i));
        for (uint256 i; i < 3; ++i) vm.etch(cand[i], CODE_X);
        vm.etch(cand[3], CODE_DIRTY);
    }

    function _h(uint256 x) internal pure returns (uint256) { return uint256(keccak256(abi.encode(x))); }
    function _fail(string memory what) internal { if (nBad == 0) bad = what; ++nBad; }
    function _isE(bytes memory e, uint8 code) internal pure returns (bool) {
        return keccak256(e) == keccak256(abi.encodeWithSelector(BlazePhoenixGate.GateE.selector, code));
    }
    function _clean(address a) internal view returns (bool) { return a == cand[0] || a == cand[1] || a == cand[2]; }

    function ghost(uint8 f) external view returns (address, uint64, bytes32, address, bytes32, bool) {
        GF storage x = g[f];
        return (x.pAdapter, x.pEta, x.pHash, x.adapter, x.pin, x.used);
    }

    // ------------------------------------------------------------------ model transitions
    function _propose(uint8 f, address a) internal {
        (bool ok, bytes memory err) = address(gate).call(abi.encodeCall(gate.proposeAdapter, (f, a)));
        if (gRenounced && g[f].used) { if (ok || !_isE(err, 10)) _fail("propose on a sealed family did not refuse with GateE(10)"); ++seals; return; }
        if (!_clean(a)) { if (ok || !_isE(err, 6)) _fail("dirty or empty adapter did not refuse with GateE(6)"); return; }
        if (!ok) { _fail("clean proposal refused"); return; }
        g[f].pAdapter = a;
        g[f].pEta = uint64(block.timestamp + 48 hours);
        g[f].pHash = a.codehash;
    }

    function _accept(uint8 f) internal {
        (bool ok, bytes memory err) = address(gate).call(abi.encodeCall(gate.acceptAdapter, (f)));
        GF storage x = g[f];
        if (x.pAdapter == address(0)) { if (ok || !_isE(err, 8)) _fail("accept with nothing pending did not refuse with GateE(8)"); return; }
        if (block.timestamp < x.pEta) { if (ok || !_isE(err, 7)) _fail("accept inside the timelock did not refuse with GateE(7)"); return; }
        if (x.pAdapter.codehash != x.pHash) { if (ok || !_isE(err, 9)) _fail("accept of changed code did not refuse with GateE(9)"); ++codeChanged; return; }
        if (gRenounced && x.used) { if (ok || !_isE(err, 10)) _fail("accept on a sealed family did not refuse with GateE(10)"); ++seals; return; }
        if (!ok) { _fail("due accept refused"); return; }
        x.adapter = x.pAdapter;
        x.pin = x.pHash;
        x.used = true;
        x.pAdapter = address(0);
        x.pEta = 0;
        x.pHash = bytes32(0);
        ++accepts;
    }

    function _clear(uint8 f) internal {
        (bool ok, bytes memory err) = address(gate).call(abi.encodeCall(gate.clearAdapter, (f)));
        if (gRenounced) { if (ok || !_isE(err, 2)) _fail("clear open after renounce"); return; }
        if (!ok) { _fail("clear refused"); return; }
        GF storage x = g[f];
        x.adapter = address(0);
        x.pAdapter = address(0);
        x.pEta = 0;
        x.pHash = bytes32(0);
        ++clears;
    }

    function _renounce() internal {
        (bool ok,) = address(gate).call(abi.encodeCall(gate.renounceControl, ()));
        if (!ok) { _fail("renounce refused"); return; }
        gRenounced = true;
    }

    function _morph(address a) internal {
        isY[a] = !isY[a];
        vm.etch(a, isY[a] ? CODE_Y : CODE_X);
    }

    // ------------------------------------------------------------------ fuzzed actions
    function propose(uint256 fS, uint256 aS) external { _propose(uint8(_h(fS) % 3), cand[_h(aS) % 5]); }
    function accept(uint256 fS) external { _accept(uint8(_h(fS) % 3)); }
    function clear(uint256 fS) external { _clear(uint8(_h(fS) % 3)); }
    function renounce(uint256 s) external { if (_h(s) % 16 == 0) _renounce(); }
    function morph(uint256 s) external { if (_h(s) % 3 == 0) _morph(cand[(_h(s) >> 8) % 3]); }

    function warp(uint256 s) external {
        uint256 h = _h(s);
        uint256 t0 = block.timestamp;
        uint256 target = t0 + 1 + (h >> 8) % 30 hours;
        if (h % 4 < 2) {
            for (uint8 f; f < 3; ++f) {
                uint256 e = g[f].pEta;
                if (e > t0 + 1) { target = h % 4 == 0 ? e : e - 1; break; }
            }
        }
        vm.warp(target);
        vm.roll(block.number + 1);
    }

    function poke(uint256 s) external { _poke(_h(s) % 6); }

    function _poke(uint256 m) internal {
        bytes memory cd;
        uint8 want = 1;
        if (m == 0) cd = abi.encodeCall(gate.proposeAdapter, (0, cand[0]));
        else if (m == 1) cd = abi.encodeCall(gate.acceptAdapter, (0));
        else if (m == 2) cd = abi.encodeCall(gate.renounceControl, ());
        else if (m == 3) { cd = abi.encodeCall(gate.clearAdapter, (0)); want = 2; }
        else if (m == 4) { cd = abi.encodeCall(gate.setAdmin, (STRANGER)); want = 2; }
        else {
            // The admin itself: the zero address is refused, and after renounce the door is shut.
            (bool ok0, bytes memory err0) = address(gate).call(abi.encodeCall(gate.setAdmin, (address(0))));
            if (ok0 || !_isE(err0, gRenounced ? 2 : 3)) _fail("setAdmin(0) by the admin was not refused with the expected code");
            return;
        }
        vm.prank(STRANGER);
        (bool ok, bytes memory err) = address(gate).call(cd);
        if (ok || !_isE(err, want)) _fail("a stranger passed a Gate door");
    }

    // ------------------------------------------------------------------ scripted entry points
    function walkPropose(uint8 f, address a) external { _propose(f, a); }
    function walkAccept(uint8 f) external { _accept(f); }
    function walkClear(uint8 f) external { _clear(f); }
    function walkRenounce() external { _renounce(); }
    function walkMorph(address a) external { _morph(a); }
    function walkPoke(uint256 m) external { _poke(m); }
}

contract AtqGateLifecycleInvariantTest is Test {
    BlazePhoenixGate internal gate;
    AtqGateHandler internal h;

    function setUp() public {
        gate = new BlazePhoenixGate(address(this));
        h = new AtqGateHandler(gate);
        gate.setAdmin(address(h));

        bytes4[] memory sels = new bytes4[](7);
        sels[0] = h.propose.selector;
        sels[1] = h.accept.selector;
        sels[2] = h.clear.selector;
        sels[3] = h.renounce.selector;
        sels[4] = h.morph.selector;
        sels[5] = h.warp.selector;
        sels[6] = h.poke.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function _checkAll() internal view {
        assertEq(h.nBad(), 0, h.bad());
        uint256 used;
        for (uint8 f; f < 3; ++f) {
            (address pA, uint64 pEta, bytes32 pHash, address a, bytes32 pin, bool u) = h.ghost(f);
            (address qA, uint64 qEta, bytes32 qHash) = gate.pendingOf(f);
            assertEq(qA, pA, "G1: pending adapter drift");
            assertEq(qEta, pEta, "G1: pending eta drift");
            assertEq(qHash, pHash, "G1: pending codehash drift");
            assertEq(gate.adapterOf(f), a, "G1: adapter drift");
            assertEq(gate.pinOf(f), pin, "G1: pin drift");
            assertEq(gate.liveAdapter(f), (a != address(0) && a.codehash == pin) ? a : address(0), "G2: live adapter");
            if (u) used |= uint256(1) << f;
        }
        assertEq(gate.familiesUsed(), used, "G1: familiesUsed drift");
        assertEq(gate.admin(), address(h), "G3: admin changed");
        assertEq(gate.controlRenounced(), h.gRenounced(), "G3: renounced drift");
    }

    function invariant_AtqGateLifecycleMirror() public view {
        _checkAll();
    }

    function test_AtqGateAdapter_TwoStepTimelockPinAndSeal() public {
        address k0 = h.cand(0);
        address k1 = h.cand(1);
        for (uint256 m; m < 6; ++m) h.walkPoke(m); // every door, control still live
        h.walkAccept(0); // nothing pending
        h.walkPropose(0, h.cand(3)); // dirty
        h.walkPropose(0, h.cand(4)); // no code
        h.walkPropose(0, k0);
        (, uint64 eta,) = gate.pendingOf(0);
        assertEq(eta, vm.getBlockTimestamp() + 48 hours, "eta is now + 48 h");
        h.walkAccept(0); // inside the timelock
        vm.warp(eta - 1);
        h.walkAccept(0);
        assertEq(gate.adapterOf(0), address(0), "nothing accepted one second before eta");
        vm.warp(eta);
        h.walkAccept(0);
        assertEq(gate.adapterOf(0), k0, "accepted at eta");
        assertEq(gate.liveAdapter(0), k0, "live while the code matches the pin");
        assertEq(gate.pinOf(0), k0.codehash, "pin is the proposed codehash");
        _checkAll();

        h.walkMorph(k0); // the adapter's code changes after acceptance
        assertEq(gate.liveAdapter(0), address(0), "an adapter whose code moved is not live");
        h.walkMorph(k0);
        assertEq(gate.liveAdapter(0), k0, "live again when the code is the pinned one");

        // The brake: one call drops the live adapter and whatever was pending; the family is
        // then wired again through the same two steps.
        h.walkPropose(0, k1);
        h.walkClear(0);
        assertEq(gate.adapterOf(0), address(0), "cleared at once");
        (address pend,,) = gate.pendingOf(0);
        assertEq(pend, address(0), "the pending proposal goes with it");
        assertEq(gate.liveAdapter(0), address(0), "a cleared family has no live adapter");
        h.walkPropose(0, k0);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        h.walkAccept(0);
        assertEq(gate.liveAdapter(0), k0, "wired again");
        _checkAll();

        h.walkPropose(1, k1);
        h.walkMorph(k1); // code changes between propose and accept
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        h.walkAccept(1);
        assertEq(gate.adapterOf(1), address(0), "changed code is not accepted");
        assertEq(h.codeChanged(), 1, "the code-changed refusal fired");
        h.walkClear(1);
        h.walkAccept(1); // cleared: nothing pending
        _checkAll();

        h.walkRenounce();
        h.walkClear(0);
        h.walkPropose(0, k1); // family 0 is used: sealed
        assertEq(h.seals(), 1, "the seal fired");
        h.walkPropose(2, k1); // an unused family can still be wired once
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        h.walkAccept(2);
        assertEq(gate.adapterOf(2), k1, "unused family wired after renounce");
        h.walkPropose(2, k0);
        assertEq(h.seals(), 2, "the family sealed itself on first use");
        for (uint256 m; m < 6; ++m) h.walkPoke(m); // every door again, control renounced
        assertEq(h.accepts(), 3, "three accepts");
        assertEq(h.clears(), 2, "two clears");
        _checkAll();
    }
}
