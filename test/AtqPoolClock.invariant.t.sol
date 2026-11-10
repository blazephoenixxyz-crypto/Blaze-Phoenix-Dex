// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ATQ-inv (atq-1111): stateful campaign over the pool clock as the Hub's swap door writes it.
//
// The handler is the Hub's Router. Over three pools of one pair it sends anchored ticks, dust
// ticks (no anchor bit), zero legs and stranger calls, pauses the Hub and warps by zero, by
// seconds and by weeks. The row's two clock fields are decoded by hand (lastUpdateTs in bits
// [95:64], tau in bits [255:224]) and checked after every call against laws that do not
// depend on how the code computes them:
//
//   K1  lastUpdateTs never goes back, never passes the block's time, and is the block's time
//       after every counted tick; a tick on one pool never touches another pool's row
//   K2  a dust tick, a zero leg, a paused Hub and a stranger leave tau exactly where it was
//       (and the last three leave the whole row where it was)
//   K3  an anchored tick moves tau by 2^-3 of its distance to the interval it closes, where
//       the interval is at least the time since the pool's previous tick of any kind and at
//       most the time since its previous anchored tick; the first measured interval IS tau.
//       With no dust between two anchored ticks the two bounds meet and the law is exact.
//
// Mutants: [ATQ-inv-n] in .github/scripts/mutants.py.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {MockOriginFactory, Origin} from "./mocks/MockOriginFactory.sol";
import {MockPair} from "./DiscoveryRefreshMonoslot.t.sol";

contract AtqClockHandler is Test {
    address public constant TA = address(0xAAA1);
    address public constant TB = address(0xBBB2);
    address public constant STRANGER = address(0xBAD5EED);
    uint8 internal constant KIND_V3 = 1;
    uint256 internal constant DEPTH = 1_000_000e18;
    uint256 internal constant ANCHOR = 1 << 255; // the anchor bit of the depth word
    uint256 internal constant EMA_SHIFT = 3;

    BlazePhoenixHub public hub;
    address public admin;
    address[3] public pools;
    bytes32[3] public keys;

    struct Clock { bool seated; uint32 tsAny; uint32 tsAnchored; }
    mapping(uint256 => Clock) internal g;
    bool public gPaused;

    uint256 public nBad;
    string public bad;
    uint256 public seats;
    uint256 public anchoredTicks;
    uint256 public dustTicks;
    uint256 public zeroLegs;
    uint256 public pausedTicks;
    uint256 public exactTicks; // anchored ticks whose interval had one reading only

    constructor(BlazePhoenixHub hub_, address[3] memory pools_) {
        hub = hub_;
        admin = msg.sender;
        pools = pools_;
        for (uint256 i; i < 3; ++i) keys[i] = hub_.keyOf(pools_[i], TA, TB);
    }

    function _h(uint256 x) internal pure returns (uint256) { return uint256(keccak256(abi.encode(x))); }
    function _fail(string memory what) internal { if (nBad == 0) bad = what; ++nBad; }
    function _isE(bytes memory e, uint16 code) internal pure returns (bool) {
        return keccak256(e) == keccak256(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code));
    }
    function _ts(uint256 s) internal pure returns (uint32) { return uint32(s >> 64); }
    function _tau(uint256 s) internal pure returns (uint32) { return uint32(s >> 224); }
    function _step(uint32 tau, uint32 dt) internal pure returns (uint32) {
        if (tau == 0) return dt;
        return dt >= tau ? tau + ((dt - tau) >> EMA_SHIFT) : tau - ((tau - dt) >> EMA_SHIFT);
    }

    function tsOf(uint256 i) external view returns (uint32) { return _ts(hub.getSlot(keys[i])); }
    function tauOf(uint256 i) external view returns (uint32) { return _tau(hub.getSlot(keys[i])); }
    function ghost(uint256 i) external view returns (bool, uint32, uint32) {
        return (g[i].seated, g[i].tsAny, g[i].tsAnchored);
    }

    // ------------------------------------------------------------------ model transition
    function _tick(uint256 i, bool anchored, uint256 amtIn, bool asStranger) internal {
        uint256[3] memory s0;
        for (uint256 j; j < 3; ++j) s0[j] = hub.getSlot(keys[j]);
        bytes memory cd = abi.encodeCall(hub.recordSwap,
            (pools[i], KIND_V3, 500, address(0), TA, TB, amtIn, 1e18, anchored ? DEPTH | ANCHOR : DEPTH));
        if (asStranger) vm.prank(STRANGER);
        (bool ok, bytes memory err) = address(hub).call(cd);
        uint256 s1 = hub.getSlot(keys[i]);
        for (uint256 j; j < 3; ++j) {
            if (j != i && hub.getSlot(keys[j]) != s0[j]) _fail("a tick on one pool moved another pool's row");
        }
        if (asStranger) {
            if (ok || !_isE(err, 1)) _fail("a stranger ticked a pool");
            if (s1 != s0[i]) _fail("a refused stranger moved the row");
            return;
        }
        if (gPaused) {
            if (ok || !_isE(err, 2)) _fail("a paused Hub took a tick");
            if (s1 != s0[i]) _fail("a paused Hub moved the row");
            ++pausedTicks;
            return;
        }
        if (!ok) { _fail("the swap door reverted"); return; }
        if (amtIn == 0) {
            if (s1 != s0[i]) _fail("a zero leg moved the row");
            ++zeroLegs;
            return;
        }
        Clock storage c = g[i];
        uint32 nowTs = uint32(block.timestamp);
        if (_ts(s1) != nowTs) _fail("a counted tick did not stamp the row with the block's time");
        if (!c.seated) {
            if (s1 == 0) { _fail("a pool with room was not seated"); return; }
            if (_tau(s1) != 0) _fail("a registration measured a clock");
            c.seated = true;
            c.tsAny = nowTs;
            c.tsAnchored = nowTs;
            ++seats;
            return;
        }
        uint32 tau0 = _tau(s0[i]);
        uint32 tau1 = _tau(s1);
        if (!anchored) {
            if (tau1 != tau0) _fail("a dust tick moved the clock");
            c.tsAny = nowTs;
            ++dustTicks;
            return;
        }
        uint32 lo = _step(tau0, nowTs - c.tsAny);
        uint32 hi = _step(tau0, nowTs - c.tsAnchored);
        if (tau1 < lo || tau1 > hi) _fail("an anchored tick put the clock outside every reading of its interval");
        if (lo == hi) ++exactTicks;
        c.tsAny = nowTs;
        c.tsAnchored = nowTs;
        ++anchoredTicks;
    }

    function _pause(bool b) internal {
        vm.prank(admin);
        hub.setPaused(b);
        gPaused = b;
    }

    // ------------------------------------------------------------------ fuzzed actions
    function tick(uint256 s) external {
        uint256 h = _h(s);
        // one in eight a zero leg, three in eight dust, four in eight anchored
        uint256 m = (h >> 8) % 8;
        _tick(h % 3, m >= 4, m == 0 ? 0 : 1 + (h >> 16) % 1e24, false);
    }
    function poke(uint256 s) external { uint256 h = _h(s); _tick(h % 3, (h >> 8) % 2 == 0, 1e18, true); }
    function pause(uint256 s) external { _pause(_h(s) % 4 == 0); }
    function warp(uint256 s) external {
        uint256 h = _h(s);
        uint256 m = h % 4;
        // same block; one second; seconds to an hour; a day to a month
        uint256 d = m == 0 ? 0 : m == 1 ? 1 : m == 2 ? 2 + (h >> 8) % 3600 : 1 days + (h >> 8) % 29 days;
        vm.warp(block.timestamp + d);
        vm.roll(block.number + (d == 0 ? 0 : 1));
    }

    // ------------------------------------------------------------------ scripted entry points
    function walkTick(uint256 i, bool anchored, uint256 amtIn) external { _tick(i, anchored, amtIn, false); }
    function walkStranger(uint256 i) external { _tick(i, true, 1e18, true); }
    function walkPause(bool b) external { _pause(b); }
}

contract AtqPoolClockInvariantTest is Test {
    BlazePhoenixHub internal hub;
    AtqClockHandler internal h;
    uint256 internal constant T0 = 1_000_000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        MockOriginFactory origin = Origin.tiers(hub, 1, 3);
        address[3] memory pools;
        for (uint256 i; i < 3; ++i) {
            pools[i] = address(new MockPair(address(0xAAA1), address(0xBBB2)));
            origin.list(pools[i], address(0xAAA1), address(0xBBB2), uint24(i + 1), false);
        }
        h = new AtqClockHandler(hub, pools);
        hub.setRoles(address(h), address(h), address(h));
        vm.warp(T0);

        bytes4[] memory sels = new bytes4[](4);
        sels[0] = h.tick.selector;
        sels[1] = h.poke.selector;
        sels[2] = h.pause.selector;
        sels[3] = h.warp.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function _checkAll() internal view {
        assertEq(h.nBad(), 0, h.bad());
        for (uint256 i; i < 3; ++i) {
            (bool seated, uint32 tsAny,) = h.ghost(i);
            uint256 s = hub.getSlot(h.keys(i));
            assertEq(s != 0, seated, "K1: a row exists exactly when the pool was seated");
            assertEq(h.tsOf(i), tsAny, "K1: the stamp is the time of the pool's last counted tick");
            assertLe(h.tsOf(i), vm.getBlockTimestamp(), "K1: the stamp is ahead of the block");
        }
    }

    function invariant_AtqPoolClockLaws() public view {
        _checkAll();
    }

    function test_AtqClock_WalkSeatAnchoredDustZeroPausedStranger() public {
        for (uint256 i; i < 3; ++i) h.walkTick(i, true, 1e18); // registration closes no interval
        assertEq(h.seats(), 3, "three pools seated");
        assertEq(h.tauOf(0), 0, "a registration measures no clock");
        _checkAll();

        vm.warp(T0 + 100);
        h.walkTick(0, true, 1e18);
        assertEq(h.tauOf(0), 100, "the first anchored interval is tau");
        h.walkTick(0, false, 1e18); // dust, same block
        h.walkTick(0, true, 0); // zero leg
        assertEq(h.tauOf(0), 100, "dust and a zero leg moved no clock");
        assertEq(h.tsOf(1), T0, "pool 1 was not touched");
        assertEq(h.tauOf(1), 0, "pool 1's clock is its own");
        _checkAll();

        vm.warp(T0 + 900);
        h.walkTick(0, true, 1e18); // dt = 800 on tau = 100: 100 + (700 >> 3)
        assertEq(h.tauOf(0), 187, "a longer interval pulls tau up by an eighth of the distance");
        h.walkPause(true);
        h.walkTick(0, true, 1e18);
        h.walkPause(false);
        h.walkStranger(0);
        assertEq(h.tsOf(0), T0 + 900, "neither a paused Hub nor a stranger stamped the row");

        vm.warp(T0 + 910);
        h.walkTick(0, true, 1e18); // dt = 10 on tau = 187: 187 - (177 >> 3)
        assertEq(h.tauOf(0), 165, "a shorter interval pulls tau down by an eighth of the distance");
        h.walkTick(2, true, 1e18); // first interval of pool 2, 910 s after it was seated
        assertEq(h.tauOf(2), 910, "pool 2 measures its own first interval");

        assertEq(h.anchoredTicks(), 4, "anchored ticks");
        assertEq(h.exactTicks(), 4, "every one of them had a single reading of its interval");
        assertEq(h.dustTicks(), 1, "dust ticks");
        assertEq(h.zeroLegs(), 1, "zero legs");
        assertEq(h.pausedTicks(), 1, "paused ticks");
        _checkAll();
    }
}
