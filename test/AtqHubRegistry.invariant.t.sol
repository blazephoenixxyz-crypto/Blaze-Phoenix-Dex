// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ATQ-inv (atq-1111): stateful campaign over the Hub's bridge registry and role set.
//
// The handler is the Hub admin and drives addBridge / removeBridge / setOperator / setPaused /
// renounceControl plus stranger and operator probes, against a ghost model (an ordered list of
// bridges, an operator set, paused, renounced). After every call:
//
//   B1  bridgeCount() == ghost length <= 3, bridge(i) == ghost[i], and every index past the
//       count reads the zero address (no stale tail)
//   B2  isBridgeToken(t) == isRoutableBridge(t) == (t in ghost) for every candidate
//   R   every refusal carried the exact HubE code the model expects (1 auth, 2 paused,
//       3 zero address, 4 index out of range, 7 cap)
//
// The operator probe is seedPool(address(0), ...): an operator passes the gate and stops at the
// zero-address check (HubE(3)), anyone else stops at the gate (HubE(1)); neither writes state.
//
// Mutants: [ATQ-inv-n] in .github/scripts/mutants.py.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract AtqHubHandler is Test {
    uint256 public constant CAP = 3;
    address public constant STRANGER = address(0xBAD5EED);

    BlazePhoenixHub public hub;
    address[6] public cand;
    address[2] public ops;

    address[] internal g;
    mapping(address => bool) public gOp;
    bool public gPaused;
    bool public gRenounced;

    uint256 public nBad;
    string public bad;
    uint256 public adds;
    uint256 public removes;
    uint256 public capHits;
    uint256 public probes;

    constructor(BlazePhoenixHub hub_) {
        hub = hub_;
        for (uint256 i; i < 6; ++i) cand[i] = address(uint160(0xB000 + i));
        ops = [address(0x0A01), address(0x0A02)];
        gOp[address(this)] = true;
    }

    function _h(uint256 x) internal pure returns (uint256) { return uint256(keccak256(abi.encode(x))); }
    function _fail(string memory what) internal { if (nBad == 0) bad = what; ++nBad; }
    function _isE(bytes memory e, uint16 code) internal pure returns (bool) {
        return keccak256(e) == keccak256(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code));
    }
    function gLen() external view returns (uint256) { return g.length; }
    function gAt(uint256 i) external view returns (address) { return g[i]; }
    function inGhost(address t) public view returns (bool) {
        for (uint256 i; i < g.length; ++i) if (g[i] == t) return true;
        return false;
    }

    // ------------------------------------------------------------------ model transitions
    function _add(address t) internal {
        (bool ok, bytes memory err) = address(hub).call(abi.encodeCall(hub.addBridge, (t)));
        if (t == address(0)) { if (ok || !_isE(err, 3)) _fail("zero bridge did not refuse with HubE(3)"); return; }
        if (inGhost(t)) { if (!ok) _fail("re-adding a bridge reverted"); return; }
        if (g.length >= CAP) { if (ok || !_isE(err, 7)) _fail("bridge cap did not refuse with HubE(7)"); ++capHits; return; }
        if (!ok) { _fail("addBridge refused under the cap"); return; }
        g.push(t);
        ++adds;
    }

    function _remove(uint8 idx) internal {
        (bool ok, bytes memory err) = address(hub).call(abi.encodeCall(hub.removeBridge, (idx)));
        if (gRenounced) { if (ok || !_isE(err, 1)) _fail("removeBridge open after renounce"); return; }
        if (idx >= g.length) { if (ok || !_isE(err, 4)) _fail("removeBridge out of range did not refuse with HubE(4)"); return; }
        if (!ok) { _fail("removeBridge refused"); return; }
        for (uint256 i = idx; i + 1 < g.length; ++i) g[i] = g[i + 1];
        g.pop();
        ++removes;
    }

    function _setOp(address who, bool on) internal {
        (bool ok, bytes memory err) = address(hub).call(abi.encodeCall(hub.setOperator, (who, on)));
        if (gRenounced) { if (ok || !_isE(err, 1)) _fail("setOperator open after renounce"); return; }
        if (!ok) { _fail("setOperator refused"); return; }
        gOp[who] = on;
    }

    function _pause(bool b) internal {
        (bool ok, bytes memory err) = address(hub).call(abi.encodeCall(hub.setPaused, (b)));
        if (gRenounced) { if (ok || !_isE(err, 1)) _fail("setPaused open after renounce"); return; }
        if (!ok) { _fail("setPaused refused"); return; }
        gPaused = b;
    }

    function _renounce() internal {
        (bool ok, bytes memory err) = address(hub).call(abi.encodeCall(hub.renounceControl, ()));
        if (gPaused) { if (ok || !_isE(err, 2)) _fail("renounced while paused"); return; }
        if (!ok) { _fail("renounce refused"); return; }
        gRenounced = true;
    }

    function _probe(address who) internal {
        vm.prank(who);
        (bool ok, bytes memory err) = address(hub).call(
            abi.encodeCall(hub.seedPool, (address(0), 0, 0, address(0), cand[0], cand[1])));
        if (ok || !_isE(err, gOp[who] ? 3 : 1)) _fail(gOp[who] ? "an operator was stopped at the gate" : "a non-operator passed the gate");
        ++probes;
    }

    // ------------------------------------------------------------------ fuzzed actions
    function addBridge(uint256 s) external { uint256 i = _h(s) % 7; _add(i == 6 ? address(0) : cand[i]); }
    function removeBridge(uint256 s) external { _remove(uint8(_h(s) % 5)); }
    function setOperator(uint256 s, bool on) external { _setOp(ops[_h(s) % 2], on); }
    function pause(uint256 s) external { _pause(_h(s) % 4 == 0); }
    function renounce(uint256 s) external { if (_h(s) % 16 == 0) _renounce(); }
    function probe(uint256 s) external { uint256 i = _h(s) % 4; _probe(i == 3 ? STRANGER : i == 2 ? address(this) : ops[i]); }

    function poke(uint256 s) external { _poke(_h(s) % 8, s % 2 == 0); }

    function _poke(uint256 m, bool asStranger) internal {
        bytes memory cd;
        if (m == 0) cd = abi.encodeCall(hub.addBridge, (cand[5]));
        else if (m == 1) cd = abi.encodeCall(hub.removeBridge, (0));
        else if (m == 2) cd = abi.encodeCall(hub.setOperator, (STRANGER, true));
        else if (m == 3) cd = abi.encodeCall(hub.setPaused, (true));
        else if (m == 4) cd = abi.encodeCall(hub.setRoles, (STRANGER, STRANGER, STRANGER));
        else if (m == 5) cd = abi.encodeCall(hub.renounceControl, ());
        else if (m == 6) cd = abi.encodeCall(hub.recordSwap, (cand[0], 0, 30, address(0), cand[0], cand[1], 1e18, 1e18, 0));
        else cd = abi.encodeCall(hub.initialize, (STRANGER, STRANGER));
        // A second initialize is refused for the admin as well as for a stranger.
        if (m != 7 || asStranger) vm.prank(STRANGER);
        (bool ok, bytes memory err) = address(hub).call(cd);
        if (ok || !_isE(err, 1)) _fail("a stranger passed a Hub role gate");
    }

    // ------------------------------------------------------------------ scripted entry points
    function walkAdd(address t) external { _add(t); }
    function walkRemove(uint8 idx) external { _remove(idx); }
    function walkSetOp(address who, bool on) external { _setOp(who, on); }
    function walkPause(bool b) external { _pause(b); }
    function walkRenounce() external { _renounce(); }
    function walkProbe(address who) external { _probe(who); }
    function walkPoke(uint256 m, bool asStranger) external { _poke(m, asStranger); }
}

contract AtqHubRegistryInvariantTest is Test {
    BlazePhoenixHub internal hub;
    AtqHubHandler internal h;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        h = new AtqHubHandler(hub);
        hub.initialize(address(h), address(0));

        bytes4[] memory sels = new bytes4[](7);
        sels[0] = h.addBridge.selector;
        sels[1] = h.removeBridge.selector;
        sels[2] = h.setOperator.selector;
        sels[3] = h.pause.selector;
        sels[4] = h.renounce.selector;
        sels[5] = h.probe.selector;
        sels[6] = h.poke.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function _checkAll() internal view {
        assertEq(h.nBad(), 0, h.bad());
        uint256 n = h.gLen();
        assertLe(n, 3, "B1: more bridges than the cap");
        assertEq(hub.bridgeCount(), n, "B1: bridgeCount drift");
        for (uint8 i; i < 3; ++i) {
            assertEq(hub.bridge(i), i < n ? h.gAt(i) : address(0), "B1: bridge order or stale tail");
        }
        for (uint256 i; i < 6; ++i) {
            address t = h.cand(i);
            bool m = h.inGhost(t);
            assertEq(hub.isBridgeToken(t), m, "B2: isBridgeToken drift");
            assertEq(hub.isRoutableBridge(t), m, "B2: isRoutableBridge drift");
        }
    }

    function invariant_AtqHubRegistryMirror() public view {
        _checkAll();
    }

    function test_AtqHubBridges_CapOrderAndRemoval() public {
        address c0 = h.cand(0);
        address c1 = h.cand(1);
        address c2 = h.cand(2);
        address c3 = h.cand(3);
        h.walkAdd(address(0));
        h.walkAdd(c0);
        h.walkAdd(c1);
        h.walkAdd(c2);
        _checkAll();
        h.walkAdd(c3); // cap
        h.walkAdd(c1); // already a bridge: no-op
        assertEq(h.capHits(), 1, "the cap was hit once");
        assertEq(hub.bridgeCount(), 3, "three bridges");
        _checkAll();

        h.walkRemove(0);
        assertEq(hub.bridge(0), c1, "order kept after removing the head");
        assertEq(hub.bridge(1), c2, "order kept after removing the head");
        assertEq(hub.bridge(2), address(0), "tail cleared");
        assertFalse(hub.isBridgeToken(c0), "removed bridge is no bridge");
        assertFalse(hub.isRoutableBridge(c0), "removed bridge is not routable");
        _checkAll();

        h.walkAdd(c3);
        assertEq(hub.bridge(2), c3, "freed slot reused");
        h.walkRemove(1);
        assertEq(hub.bridge(1), c3, "order kept after removing the middle");
        assertFalse(hub.isBridgeToken(c2), "removed bridge is no bridge");
        h.walkRemove(2); // out of range
        h.walkRemove(1);
        h.walkRemove(0);
        assertEq(hub.bridgeCount(), 0, "registry emptied");
        assertEq(h.adds(), 4, "adds");
        assertEq(h.removes(), 4, "removes");
        _checkAll();
    }

    function test_AtqHubRoles_OperatorRevocationAndStrangers() public {
        address op = h.ops(0);
        h.walkProbe(op); // not an operator yet
        h.walkSetOp(op, true);
        h.walkProbe(op);
        h.walkSetOp(op, false);
        h.walkProbe(op); // revoked
        h.walkProbe(address(h)); // the admin is an operator
        h.walkProbe(h.STRANGER());
        for (uint256 m; m < 8; ++m) h.walkPoke(m, true);
        h.walkPoke(7, false); // the admin cannot initialize twice either

        h.walkAdd(h.cand(0));
        h.walkPause(true);
        h.walkRenounce(); // refused while paused
        h.walkPause(false);
        h.walkRenounce();
        h.walkRemove(0); // control is gone: the registry only grows
        h.walkSetOp(op, true);
        h.walkPause(true);
        h.walkAdd(h.cand(1)); // curator power survives the renounce
        h.walkProbe(op);
        assertEq(hub.bridgeCount(), 2, "curator added after renounce, nothing was removed");
        assertEq(h.probes(), 6, "probes ran");
        _checkAll();
    }
}
