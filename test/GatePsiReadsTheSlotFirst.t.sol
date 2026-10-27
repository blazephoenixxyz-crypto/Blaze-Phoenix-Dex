// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  LAZY GATE PSI (gas-h1-1026): Core.gatePsi reads the wrapper's own vitalSlot
//  before it asks the Gate. Red at 59ecf3f: gatePsi called vitalOf for every
//  wrapper.
//
//  Gate.vitalOf scores psi = vitality * 2^bucket, its vitality Core.vitality of
//  the wrapper's vitalSlot at block.timestamp. That vitality is 0 for a wrapper
//  never swapped (an empty slot, lastUpdateTs 0) and for one dead by decay (past
//  the 32-step horizon, its slot not empty): psi 0 at every depth bucket. The
//  depth read vitalOf pays before that product (the adapter's quote under
//  GATE_QUOTE_GAS, the venue, two balanceOf, two decimals) moves nothing, and
//  gatePsi now answers that 0 itself, by the same Core.vitality at the same
//  timestamp.
//
//  The properties, one test (and one mutant in mutants.py) per guard:
//    1. a slot of vitality 0 (empty, or dead by decay) never reaches the Gate; a
//       live one reaches it once, the floor one second before the horizon too;
//    2. the answer is the Gate's, bit for bit: vitality 0, 1, more, the floor,
//       both sides of the 32-step horizon, slots no swap writes, every depth
//       bucket 0..15, and any slot (fuzz);
//    3. a slot gatePsi cannot read (no code, a revert, an answer shorter than a
//       word) asks the Gate as before, and the read is capped at GAS_CAP;
//    4. gas: an empty slot skips the whole depth read.
//
//  Oracle: psi by hand per row (vitality from the count and the age, times
//  2^bucket of a depth word chosen per decade), and gatePsi as it stood at
//  59ecf3f (GatePsiAt59ecf3f below, its whole body); never the shortcut.
//
//  Cheatcodes: vm.warp (time is the route: the adapter timelock and the decay),
//  vm.expectCall (the call not made is the property), vm.cool (each gas reading
//  starts from cold accounts), vm.store (slots no swap writes: a count of
//  2^32 - 1, a count never stamped, a stamp in the future, any word; each read
//  back through the getter before use).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {
    MockGateVenue, MockGateRegistry, MockGateAdapter, MockGateHostileAdapter
} from "./mocks/MockGateAdapters.sol";

/// gatePsi as it stood at 59ecf3f, whole: a public library function whose body is
/// Core._gateVital's psi (which H1 does not touch), reached by a DELEGATECALL as the Solver
/// reaches gatePsi. The other side of every differential here.
library GatePsiAt59ecf3f {
    function gatePsi(address gate, address w) public view returns (uint256 p) {
        (, p) = BPC._gateVital(gate, w);
    }
}

/// Gas of one psi read, as the EVM accounts it inside this frame.
contract GatePsiGasProbe {
    function lazy(address g, address w) external view returns (uint256 used, uint256 p) {
        uint256 g0 = gasleft();
        p = BPC.gatePsi(g, w);
        used = g0 - gasleft();
    }

    function eager(address g, address w) external view returns (uint256 used, uint256 p) {
        uint256 g0 = gasleft();
        p = GatePsiAt59ecf3f.gatePsi(g, w);
        used = g0 - gasleft();
    }
}

/// A Gate stand-in: every vitalOf reads (1, 1e18, 7). Psi 7 is what gatePsi relays when it asks.
contract GatePsiStubGate {
    function vitalOf(address) external pure returns (uint256, uint256, uint256) {
        return (1, 1e18, 7);
    }
}

/// A pool whose vitalSlot read fails: 0 reverts, 1 answers 16 bytes, 2 burns every unit of gas.
contract GatePsiUnreadable {
    uint8 internal immutable how;

    constructor(uint8 h) {
        how = h;
    }

    fallback() external {
        if (how == 0) revert();
        if (how == 1) {
            assembly { return(0, 16) }
        }
        while (true) {}
    }
}

contract GatePsiReadsTheSlotFirstTest is Test {
    uint8 constant FAM = 1;
    uint24 constant KEY = uint24(uint256(FAM) << 16 | 1);
    uint8 constant HFAM = 2;
    uint24 constant HKEY = uint24(uint256(HFAM) << 16 | 1);
    /// 2e30 a side: the shorter side caps no word up to 1e30, so a word of 10^(15 + b) reads
    /// bucket b for every b in 0..15 (Core.depthBucket: floor(log10(word / 1e15)), capped at 15).
    uint256 constant HELD = 2e30;
    /// One material swap: 4e25 in, 3.988e25 out (the venue pays 99.7 %), both above
    /// HELD >> 16 = 3.0517578125e25.
    uint256 constant MATERIAL = 4e25;
    /// Core.VITALITY_DECAY_STEP_SECONDS, by hand.
    uint256 constant STEP = 24_576;
    uint256 constant T0 = 1_800_000_000;
    /// lastUpdateTs, bits [95:64] of the slot layout.
    uint256 constant LAST_TS = uint256(type(uint32).max) << 64;

    BlazePhoenixGate gate;
    MockGateRegistry reg;
    MockGateVenue venue;
    MockGateAdapter adapter;
    MockGateHostileAdapter hostile;
    MockERC20 t0;
    MockERC20 t1;
    GatePsiGasProbe probe;

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        gate = new BlazePhoenixGate(address(this));
        reg = new MockGateRegistry();
        venue = new MockGateVenue(address(t0), address(t1));
        reg.add(address(venue));
        t0.mint(address(venue), HELD);
        t1.mint(address(venue), HELD);
        venue.sync();
        adapter = new MockGateAdapter(gate, reg);
        hostile = new MockGateHostileAdapter(gate, reg);
        probe = new GatePsiGasProbe();
    }

    // ─── helpers ───

    function _accept(uint8 f, address a) internal {
        gate.proposeAdapter(f, a);
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(f);
    }

    function _wrapper() internal returns (BlazePhoenixGateWrapper w) {
        _accept(FAM, address(adapter));
        w = BlazePhoenixGateWrapper(gate.create(address(t1), address(t0), KEY, abi.encode(address(venue))));
    }

    /// A wrapper whose adapter, once created, burns every unit of gas its quote is given.
    function _burningWrapper() internal returns (address w) {
        _accept(HFAM, address(hostile));
        w = gate.create(address(t0), address(t1), HKEY, abi.encode(address(venue)));
        hostile.setMode(hostile.BURN());
    }

    /// One material swap of token0 through the wrapper, paid by this contract's callback.
    function _swap(BlazePhoenixGateWrapper w) internal {
        t0.mint(address(this), MATERIAL);
        w.swap(address(this), true, int256(MATERIAL), 0, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(msg.sender);
        if (a0 > 0) MockERC20(w.token0()).transfer(msg.sender, uint256(a0));
        else if (a1 > 0) MockERC20(w.token1()).transfer(msg.sender, uint256(a1));
    }

    /// vm.store into the wrapper's slot 0, read back through vitalSlot(): a store that missed the
    /// slot the getter reads would leave every row below reading the empty word.
    function _store(BlazePhoenixGateWrapper w, uint256 s) internal {
        vm.store(address(w), bytes32(0), bytes32(s));
        assertEq(w.vitalSlot(), s, "setup: the store wrote the slot vitalSlot() reads");
    }

    /// Psi of `w` at every depth bucket 0..15, by hand (v << b) and from both readers.
    function _allBuckets(address w, uint256 v, string memory row) internal {
        for (uint256 b; b < 16; ++b) {
            adapter.setDeclaredDepth(10 ** (15 + b));
            assertEq(GatePsiAt59ecf3f.gatePsi(address(gate), w), v << b, string.concat(row, ": the Gate's psi"));
            assertEq(BPC.gatePsi(address(gate), w), v << b, string.concat(row, ": gatePsi"));
        }
    }

    /// Every account a psi read touches, cold again: each gas reading pays its own first access.
    function _cool(address w) internal {
        vm.cool(w);
        vm.cool(address(gate));
        vm.cool(address(adapter));
        vm.cool(address(hostile));
        vm.cool(address(venue));
        vm.cool(address(reg));
        vm.cool(address(t0));
        vm.cool(address(t1));
    }

    // ─── 1. a slot of vitality 0 (empty, or dead by decay) never reaches the Gate ───

    /// Quantity: the calls gatePsi makes for a wrapper never swapped: none to the Gate. Its slot
    /// is empty, so vitalOf would answer psi 0 at any depth (lastUpdateTs 0: vitality 0), and
    /// gatePsi answers that 0 alone. RED at 59ecf3f: gatePsi called vitalOf for every wrapper.
    function test_GatePsi_AnUnusedWrapperNeverReachesTheGate() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setDeclaredDepth(1e30);
        assertEq(w.vitalSlot(), 0, "setup: never swapped, the slot is empty");
        vm.expectCall(address(gate), abi.encodeCall(BlazePhoenixGate.vitalOf, (address(w))), 0);
        assertEq(BPC.gatePsi(address(gate), address(w)), 0, "psi 0, as vitalOf answers");
    }

    /// The neighbour, same instrument: after one material swap the wrapper reaches the Gate
    /// exactly once, and gatePsi relays its psi, vitality 1 at bucket 15 (depth 1e30): 2^15.
    function test_GatePsi_AUsedWrapperAsksTheGateOnce() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setDeclaredDepth(1e30);
        _swap(w);
        vm.expectCall(address(gate), abi.encodeCall(BlazePhoenixGate.vitalOf, (address(w))), 1);
        assertEq(BPC.gatePsi(address(gate), address(w)), 1 << 15, "1 * 2^15");
    }

    /// Quantity: the calls gatePsi makes for a wrapper dead by decay: none to the Gate. One
    /// material swap at T0, then 32 steps: past the horizon its slot is not empty but decodes
    /// vitality 0, so vitalOf would answer psi 0 at any depth, and gatePsi answers that 0 alone.
    /// RED at 59ecf3f (vitalOf for every wrapper) and with an empty-slot test alone ([836]).
    function test_GatePsi_ADeadWrapperNeverReachesTheGate() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setDeclaredDepth(1e30);
        vm.warp(T0);
        _swap(w);
        vm.warp(T0 + 32 * STEP);
        assertTrue(w.vitalSlot() != 0, "setup: the dead slot is not empty");
        vm.expectCall(address(gate), abi.encodeCall(BlazePhoenixGate.vitalOf, (address(w))), 0);
        assertEq(BPC.gatePsi(address(gate), address(w)), 0, "psi 0, as vitalOf answers");
    }

    /// The neighbour at the horizon, same instrument: one second before it (31 steps) the count
    /// has decayed away but the slot is live, its vitality floored to 1, so gatePsi asks the Gate
    /// once and relays 1 * 2^15. A shortcut whose clock runs even one second ahead of the Gate's
    /// calls this slot dead ([837]).
    function test_GatePsi_AWrapperAtTheFloorAsksTheGateOnce() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setDeclaredDepth(1e30);
        vm.warp(T0);
        _swap(w);
        vm.warp(T0 + 32 * STEP - 1);
        vm.expectCall(address(gate), abi.encodeCall(BlazePhoenixGate.vitalOf, (address(w))), 1);
        assertEq(BPC.gatePsi(address(gate), address(w)), 1 << 15, "the floor: 1 * 2^15");
    }

    // ─── 2. the Gate's psi, bit for bit ───

    /// Quantity: psi along a wrapper's life, at every bucket 0..15, by hand and from gatePsi at
    /// 59ecf3f. Vitality: 0 unused; 1 after one material swap; 3 after three; at 2 steps
    /// 3 >> 2 = 0, floored to 1 (a shortcut on the decayed count alone, without the floor, reads
    /// it dead: [838]); at 32 * STEP - 1 (31 steps) the floor, 1; at 32 * STEP (32 steps, past
    /// the horizon) 0, dead by decay, its slot not empty. psi = v * 2^b.
    function test_GatePsi_IsTheGatesPsiAlongAWrappersLife() public {
        BlazePhoenixGateWrapper w = _wrapper();
        vm.warp(T0);
        _allBuckets(address(w), 0, "unused");
        _swap(w);
        _allBuckets(address(w), 1, "one swap");
        _swap(w);
        _swap(w);
        _allBuckets(address(w), 3, "three swaps");
        vm.warp(T0 + 2 * STEP);
        _allBuckets(address(w), 1, "two steps, the floor");
        vm.warp(T0 + 32 * STEP - 1);
        _allBuckets(address(w), 1, "31 steps, the floor");
        vm.warp(T0 + 32 * STEP);
        _allBuckets(address(w), 0, "32 steps, dead by decay");
        assertTrue(w.vitalSlot() != 0, "the dead slot is not empty");
    }

    /// Quantity: psi of slots no swap writes, at every bucket. A count of 2^32 - 1 with every
    /// other field set (a stale bucket 15 among them, and tau, the slot's own clock, at its
    /// ceiling) stamped now: v = count * 24 576 / (m * tau) = 24 576 / 4 (m = 4, 2026-10-27;
    /// it read 2^32 - 1 on the fixed step), and only the live bucket counts. A count of 5 never stamped (lastUpdateTs 0): v = 0, from a word that
    /// is not empty. A count of 9 stamped 1 000 s in the future: age 0, v = 9.
    function test_GatePsi_IsTheGatesPsiForSlotsNoSwapWrites() public {
        BlazePhoenixGateWrapper w = _wrapper();
        vm.warp(T0);
        _store(w, (type(uint256).max & ~LAST_TS) | (T0 << 64));
        _allBuckets(address(w), 6_144, "every field set");
        _store(w, uint256(5) << 160);
        _allBuckets(address(w), 0, "never stamped");
        _store(w, (uint256(9) << 160) | ((T0 + 1_000) << 64));
        _allBuckets(address(w), 9, "stamped in the future");
    }

    /// Quantity: psi of any slot, at any age and bucket: gatePsi equals gatePsi at 59ecf3f, bit
    /// for bit. The shapes weigh where the shortcut decides: the empty word, any word, any word
    /// stamped `age` seconds ago (up to 40 steps), and any word never stamped.
    function testFuzz_GatePsi_IsTheGatesPsiForAnySlot(uint256 raw, uint256 age, uint8 b, uint8 shape) public {
        BlazePhoenixGateWrapper w = _wrapper();
        vm.warp(T0);
        uint256 s;
        shape %= 4;
        if (shape == 1) s = raw;
        if (shape == 2) s = (raw & ~LAST_TS) | ((T0 - bound(age, 0, 40 * STEP)) << 64);
        if (shape == 3) s = raw & ~LAST_TS;
        _store(w, s);
        adapter.setDeclaredDepth(10 ** (15 + uint256(b % 16)));
        assertEq(BPC.gatePsi(address(gate), address(w)), GatePsiAt59ecf3f.gatePsi(address(gate), address(w)));
    }

    // ─── 3. a slot gatePsi cannot read asks the Gate ───

    /// Quantity: psi for a pool whose slot cannot be read: no code, a revert, an answer shorter
    /// than a word. gatePsi asks the Gate, as at 59ecf3f, and relays its psi (7, the stub's):
    /// only a slot READ, and read at vitality 0, is answered without the Gate. Green at 59ecf3f
    /// by design: the property is that the shortcut leaves these pools where they were.
    function test_GatePsi_AnUnreadableSlotAsksTheGate() public {
        GatePsiStubGate g = new GatePsiStubGate();
        address[3] memory ws =
            [address(0xCAFE), address(new GatePsiUnreadable(0)), address(new GatePsiUnreadable(1))];
        for (uint256 i; i < 3; ++i) {
            assertEq(GatePsiAt59ecf3f.gatePsi(address(g), ws[i]), 7, "the Gate's psi at 59ecf3f");
            assertEq(BPC.gatePsi(address(g), ws[i]), 7, "gatePsi asks the Gate");
        }
    }

    /// Quantity: the gas the slot read may burn. A pool whose vitalSlot burns every unit it is
    /// given costs gatePsi GAS_CAP (100k) and no more: the rest is three cold accounts (the
    /// library, the pool, the Gate) and the Gate's answer, which gatePsi relays, under 20k. An
    /// uncapped read would hand over 63/64 of the 3M budget, a doubled cap 200k. RED at 59ecf3f:
    /// there was no read, so the neighbour (the burn is seen) fails.
    function test_GatePsi_TheSlotReadIsGasCapped() public {
        GatePsiStubGate g = new GatePsiStubGate();
        address w = address(new GatePsiUnreadable(2));
        (uint256 used, uint256 p) = probe.lazy{gas: 3_000_000}(address(g), w);
        emit log_named_uint("gatePsi, a slot read that burns, gas", used);
        assertEq(p, 7, "a failed read asks the Gate");
        assertGt(used, BPC.GAS_CAP, "the neighbour: the read burned its cap");
        assertLt(used, BPC.GAS_CAP + 20_000, "the read is capped at GAS_CAP");
    }

    // ─── 4. gas ───

    /// Quantity: the gas of psi for a wrapper never swapped, its adapter honest: one slot read
    /// of the wrapper against the Gate's whole vitalOf at 59ecf3f (the wrapper's getters, the
    /// adapter's quote, the venue, two balanceOf, two decimals) for the same 0. Each reading
    /// from cold accounts, both libraries warm. RED at 59ecf3f: the two readers were one.
    function test_GatePsi_AnUnusedWrapperSkipsTheDepthRead() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setDeclaredDepth(1e30);
        probe.lazy(address(0xdead), address(0xdead));
        probe.eager(address(0xdead), address(0xdead));
        _cool(address(w));
        (uint256 lazyGas, uint256 p) = probe.lazy(address(gate), address(w));
        _cool(address(w));
        (uint256 eagerGas, uint256 q) = probe.eager(address(gate), address(w));
        emit log_named_uint("gatePsi, unused wrapper, gas", lazyGas);
        emit log_named_uint("gatePsi at 59ecf3f, unused wrapper, gas", eagerGas);
        assertEq(p, 0, "psi 0");
        assertEq(q, 0, "psi 0 at 59ecf3f");
        assertLt(lazyGas * 2, eagerGas, "the depth read is skipped: less than half the gas");
    }

    /// Quantity: the gas of psi for a wrapper never swapped whose adapter burns every unit its
    /// quote is given: gatePsi spends one slot read, under 50k; at 59ecf3f the Gate's depth read
    /// burned its whole GATE_QUOTE_GAS first (the neighbour: the burn is real). Both read 0.
    function test_GatePsi_AnUnusedWrapperNeverPaysABurningAdapter() public {
        address w = _burningWrapper();
        (uint256 lazyGas, uint256 p) = probe.lazy{gas: 3_000_000}(address(gate), w);
        (uint256 eagerGas, uint256 q) = probe.eager{gas: 3_000_000}(address(gate), w);
        assertEq(p, 0, "psi 0");
        assertEq(q, 0, "psi 0 at 59ecf3f");
        assertGt(eagerGas, BPC.GATE_QUOTE_GAS * 63 / 64, "the neighbour: at 59ecf3f the adapter burned its cap");
        assertLt(lazyGas, 50_000, "gatePsi never reaches the adapter");
    }
}
