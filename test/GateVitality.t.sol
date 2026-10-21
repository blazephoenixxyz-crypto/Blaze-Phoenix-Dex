// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  GATE VITALITY (gatevit-1021): how the registry's fitness sees the Gate's
//  pools without a byte of the Hub. Red at 85720ef (no `vitalOf`, no use count).
//
//  The four properties, one test (and one mutant in mutants.py) per guard:
//    1. identity is derived: only the Gate's own wrappers, with a live adapter,
//       and through the Quoter only an admitted Gate's (BPC.gateWrapperLive);
//    2. depth by shape, never attested: the adapter's word capped by the mass
//       the venue pool really holds (Core.heldMass18, the registry's own cap);
//    3. use that costs nothing is not use (W5-C1): a swap ticks only when it
//       moves a material share of BOTH of the venue's holdings;
//    4. one producer per quantity: the wrapper writes its use, Gate.vitalOf
//       answers vitality, depth and psi, through Core's formulas.
//
//  Oracle: the tokens' balances, the venue's own pay rule, and thresholds and
//  buckets computed here by hand; never the code under test.
//
//  Cheatcodes: vm.warp (time passing is the route: the adapter timelock and the
//  decay), vm.prank (the user is the route through the Router's door).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {
    MockGateVenue, MockGateRegistry, MockGateAdapter, MockGateHostileAdapter
} from "./mocks/MockGateAdapters.sol";

interface IGateVital {
    function vitalOf(address w) external view returns (uint256 v, uint256 depth18, uint256 psi);
}

interface IQuoterVital {
    function gateVitalOf(address pool, address tA, address tB, uint24 fee)
        external view returns (uint256 v, uint256 depth18, uint256 psi);
}

/// An honest adapter that also declares a depth: the word the Gate must cap.
contract GateDeclaringAdapter is MockGateAdapter {
    uint256 public word;
    constructor(BlazePhoenixGate g, MockGateRegistry r) MockGateAdapter(g, r) {}
    function setWord(uint256 w) external { word = w; }
    function quote(address vp, bytes32, bytes32, bool, uint256 amtIn)
        external view override returns (uint256, uint256)
    {
        return (MockGateVenue(vp).quoteSell(amtIn), word);
    }
}

/// Answers every getter a wrapper answers, with a use count of 1 000 and an absurd depth, and
/// names the real Gate: what `vitalOf` would rank if it trusted the address it is asked about.
contract GateVitalImpostor {
    address public gate;
    uint8 public family;
    address public token0;
    address public token1;
    address public venuePool;
    uint256 public vitalSlot;
    constructor(address g, uint8 f, address a, address b, address vp, uint24 key) {
        (gate, family, token0, token1, venuePool) = (g, f, a, b, vp);
        vitalSlot = BPC.encodeSlot(true, key, BPC.KIND_EXTERNAL, 2, 0, uint32(block.timestamp), 0, 0, 1_000, 0,
            uint32(block.number));
    }
    function quote(bool, uint256) external pure returns (uint256, uint256) { return (0, 1e30); }
}

/// Gas spent by one vitalOf call, as the EVM accounts it inside this frame.
contract GateVitalGasProbe {
    function measure(address g, address w) external view returns (uint256 used, uint256 d) {
        uint256 before = gasleft();
        (, d, ) = IGateVital(g).vitalOf(w);
        used = before - gasleft();
    }
}

contract GateVitalityTest is Test {
    uint8 constant FAM = 1;
    uint24 constant KEY = uint24(uint256(FAM) << 16 | 1);
    uint24 constant KEY2 = uint24(uint256(FAM) << 16 | 2);
    uint8 constant HFAM = 2;
    uint24 constant HKEY = uint24(uint256(HFAM) << 16 | 1);
    uint256 constant HELD = 1_000_000e18;
    /// HELD >> 16, by hand: 1e24 = 2^24 * 5^24, so the shift is exact (2^8 * 5^24).
    uint256 constant THR = 15_258_789_062_500_000_000;

    BlazePhoenixGate gate;
    BlazePhoenixHub hub;
    MockGateRegistry reg;
    MockGateVenue venue;
    GateDeclaringAdapter adapter;
    MockGateHostileAdapter hostile;
    MockERC20 t0;
    MockERC20 t1;

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
        adapter = new GateDeclaringAdapter(gate, reg);
        hostile = new MockGateHostileAdapter(gate, reg);
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    // ─── helpers ───

    function _accept(BlazePhoenixGate g, uint8 f, address a) internal {
        g.proposeAdapter(f, a);
        vm.warp(block.timestamp + g.ADAPTER_DELAY());
        g.acceptAdapter(f);
    }

    function _wrapper() internal returns (BlazePhoenixGateWrapper w) {
        _accept(gate, FAM, address(adapter));
        w = BlazePhoenixGateWrapper(gate.create(address(t1), address(t0), KEY, abi.encode(address(venue))));
    }

    /// One direct swap of `amt` of token0, paid by this contract's callback.
    function _swap(BlazePhoenixGateWrapper w, uint256 amt) internal {
        t0.mint(address(this), amt);
        w.swap(address(this), true, int256(amt), 0, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(msg.sender);
        if (a0 > 0) MockERC20(w.token0()).transfer(msg.sender, uint256(a0));
        else if (a1 > 0) MockERC20(w.token1()).transfer(msg.sender, uint256(a1));
    }

    function _v(address w) internal view returns (uint256 v) {
        (v, , ) = IGateVital(address(gate)).vitalOf(w);
    }

    function _admit() internal {
        if (hub.factoryCodehashOf(address(gate)) != bytes32(0)) return;
        uint24[] memory fees = new uint24[](1);
        fees[0] = KEY;
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0));
    }

    // ─── 3. use: only a material swap ticks (W5-C1) ───

    /// Quantity: the wrapper's use count. Two material swaps through the wrapper read 2.
    function test_GateVital_MaterialSwapTicks() public {
        BlazePhoenixGateWrapper w = _wrapper();
        assertEq(_v(address(w)), 0, "born with no use");
        _swap(w, 100e18);
        assertEq(_v(address(w)), 1, "one material swap");
        _swap(w, 100e18);
        assertEq(_v(address(w)), 2, "two material swaps");
    }

    /// Quantity: the use count, ticked by the Router's explicit door like any direct caller.
    function test_GateVital_RouterDoorTicks() public {
        BlazePhoenixGateWrapper w = _wrapper();
        _admit();
        BlazePhoenixRouter router =
            new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        uint256 amt = 1_000e18;
        address u = address(0xA11CE);
        t0.mint(u, amt);
        vm.prank(u);
        t0.approve(address(router), type(uint256).max);
        Leg[] memory l = new Leg[](1);
        uint256 exp = venue.quoteSell(amt);
        l[0] = Leg({pool: address(w), hooks: address(0), kind: BPC.KIND_EXTERNAL, fee: KEY, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: amt, expectedOut: exp, legs: l});
        Route memory r = Route({hops: hs, totalOut: exp, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        vm.prank(u);
        router.swapExactIn(r, amt, 1, u, block.timestamp + 1);
        assertEq(_v(address(w)), 1, "the Router's swap is one material swap");
    }

    /// Quantity: the INPUT side of materiality. The venue overpays (101 %), so the output is
    /// material whatever the input: an input one wei under HELD >> 16 does not tick, an input
    /// of exactly HELD >> 16 does.
    function test_GateVital_DustInputNeverTicks() public {
        BlazePhoenixGateWrapper w = _wrapper();
        venue.setPayBps(10_100);
        _swap(w, THR - 1);
        assertEq(_v(address(w)), 0, "dust in: no tick, though the output was material");
        venue.sync();
        // The swap moved the holdings; the threshold is the venue's mass of token0 now.
        _swap(w, t0.balanceOf(address(venue)) >> 16);
        assertEq(_v(address(w)), 1, "exactly the threshold ticks");
    }

    /// Quantity: the OUTPUT side of materiality. A material input that buys less than
    /// HELD >> 16 of the output does not tick; one that buys exactly that does.
    function test_GateVital_DustOutputNeverTicks() public {
        BlazePhoenixGateWrapper w = _wrapper();
        venue.setPayBps(4_999);
        _swap(w, 2 * THR);
        assertEq(_v(address(w)), 0, "material in, dust out: no tick");
        // Reset the venue to HELD of token1, so its threshold is THR again: in 2 * THR at 50 %.
        t1.mint(address(venue), HELD - t1.balanceOf(address(venue)));
        venue.sync();
        venue.setPayBps(5_000);
        _swap(w, 2 * THR);
        assertEq(_v(address(w)), 1, "an output of exactly the threshold ticks");
    }

    /// Quantity: use against a venue empty of the output. Its threshold is 0, so only the
    /// `out != 0` arm stops a material input that buys nothing from ticking.
    function test_GateVital_NothingOutNeverTicks() public {
        _accept(gate, FAM, address(adapter));
        MockGateVenue v2 = new MockGateVenue(address(t0), address(t1));
        reg.add(address(v2));
        t0.mint(address(v2), HELD);
        v2.sync();
        v2.setPayBps(0); // it holds no token1 to pay with
        BlazePhoenixGateWrapper w =
            BlazePhoenixGateWrapper(gate.create(address(t0), address(t1), KEY2, abi.encode(address(v2))));
        _swap(w, 100e18);
        assertEq(t1.balanceOf(address(this)), 0, "the venue paid nothing");
        assertEq(_v(address(w)), 0, "nothing out is not use");
    }

    // ─── 2. depth: the adapter's word, capped by the mass the venue pool holds ───

    /// Quantity: Gate depth18 when the word exceeds the mass. HELD of each token is held, so
    /// the cap is HELD (the larger normalised holding).
    function test_GateVital_DepthIsTheWordCappedByTheMassHeld() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setWord(1e30);
        (, uint256 d, ) = IGateVital(address(gate)).vitalOf(address(w));
        assertEq(d, HELD, "a word above the mass is capped at the mass held");
    }

    /// Quantity: Gate depth18 when the word is under the mass: the word stands (a singleton's
    /// balance is every pool's, so the cap alone would overstate one pool).
    function test_GateVital_AnHonestWordBelowTheMassStands() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setWord(5e20);
        (, uint256 d, ) = IGateVital(address(gate)).vitalOf(address(w));
        assertEq(d, 5e20, "the word, not the singleton-wide mass");
    }

    /// Quantity: Gate depth18 on a venue holding one token only: the cap is the side it
    /// holds, not the empty side (a range wholly on one side holds real tokens).
    function test_GateVital_OneSidedVenueKeepsTheSideItHolds() public {
        _accept(gate, FAM, address(adapter));
        MockGateVenue v2 = new MockGateVenue(address(t0), address(t1));
        reg.add(address(v2));
        t0.mint(address(v2), HELD);
        v2.sync();
        address w = gate.create(address(t0), address(t1), KEY2, abi.encode(address(v2)));
        adapter.setWord(1e22);
        (, uint256 d, ) = IGateVital(address(gate)).vitalOf(w);
        assertEq(d, 1e22, "one side held: the word under that side's mass stands");
    }

    /// Quantity: the gas the depth read may burn. An adapter that burns every unit it is given
    /// reads depth 0, and the whole of vitalOf spends GATE_QUOTE_GAS (500k) plus its own reads,
    /// not the 63/64 of a 3M budget an uncapped call hands over. Measured by a probe contract
    /// around the one call, so the figure is the EVM's own accounting of that call.
    function test_GateVital_DepthReadIsGasCapped() public {
        _accept(gate, HFAM, address(hostile));
        address w = gate.create(address(t0), address(t1), HKEY, abi.encode(address(venue)));
        hostile.setMode(7);
        GateVitalGasProbe probe = new GateVitalGasProbe();
        (uint256 used, uint256 d) = probe.measure{gas: 3_000_000}(address(gate), w);
        assertEq(d, 0, "a burning adapter declares nothing");
        assertLt(used, 1_000_000, "the burn is capped at GATE_QUOTE_GAS");
        assertGt(used, BPC.GATE_QUOTE_GAS * 63 / 64, "the neighbour: the adapter did burn its cap");
    }

    // ─── psi: Core's formula over the live bucket ───

    /// Quantity: Gate psi = vitality * 2^bucket(depth now). One swap, word 5e20: bucket
    /// floor(log10(5e20 / 1e15)) = 5, psi 32. The word moves to 5e22 with no swap: bucket 7,
    /// psi 128. The bucket is read now, never a snapshot of the last tick.
    function test_GateVital_PsiIsVitalityTimesTheLiveBucket() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setWord(5e20);
        _swap(w, 100e18);
        (uint256 v, , uint256 p) = IGateVital(address(gate)).vitalOf(address(w));
        assertEq(v, 1);
        assertEq(p, 32, "1 * 2^5");
        adapter.setWord(5e22);
        (, , p) = IGateVital(address(gate)).vitalOf(address(w));
        assertEq(p, 128, "1 * 2^7, without a swap");
    }

    // ─── 1. identity ───

    /// Quantity: who vitalOf answers for. A contract answering every wrapper getter, naming
    /// this Gate, with a use count of 1 000, reads (0, 0, 0): the Gate made no such wrapper.
    function test_GateVital_OnlyTheGatesOwnWrappers() public {
        BlazePhoenixGateWrapper w = _wrapper();
        _swap(w, 100e18);
        assertEq(_v(address(w)), 1, "the neighbour: the Gate's own wrapper answers");
        GateVitalImpostor imp =
            new GateVitalImpostor(address(gate), FAM, address(t0), address(t1), address(venue), KEY);
        (uint256 v, uint256 d, uint256 p) = IGateVital(address(gate)).vitalOf(address(imp));
        assertEq(v + d + p, 0, "an address the Gate did not create has no vitality");
    }

    /// Quantity: a wrapper whose family was cleared is dead: no vitality, no depth, no psi.
    function test_GateVital_ClearedFamilyIsDead() public {
        BlazePhoenixGateWrapper w = _wrapper();
        adapter.setWord(5e20);
        _swap(w, 100e18);
        assertEq(_v(address(w)), 1, "the neighbour: live family");
        gate.clearAdapter(FAM);
        (uint256 v, uint256 d, uint256 p) = IGateVital(address(gate)).vitalOf(address(w));
        assertEq(v + d + p, 0, "a cleared family cannot execute, so it does not rank");
    }

    /// Quantity: the Quoter's door asks BPC.gateWrapperLive: an unadmitted Gate's wrapper with
    /// real use reads 0, the admitted Gate's wrapper reads its use.
    function test_GateVital_QuoterAsksTheAdmittedIdentity() public {
        BlazePhoenixGateWrapper w = _wrapper();
        _admit();
        BlazePhoenixGate g2 = new BlazePhoenixGate(address(this));
        // The mock adapter serves one Gate's wrappers only, so the second Gate has its own.
        _accept(g2, FAM, address(new GateDeclaringAdapter(g2, reg)));
        BlazePhoenixGateWrapper w2 =
            BlazePhoenixGateWrapper(g2.create(address(t0), address(t1), KEY, abi.encode(address(venue))));
        _swap(w, 100e18);
        _swap(w2, 100e18);
        (uint256 v2, , ) = IGateVital(address(g2)).vitalOf(address(w2));
        assertEq(v2, 1, "the unadmitted Gate counts its own wrapper's use");
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(0xD0D0));
        (uint256 v, , ) = IQuoterVital(address(quoter)).gateVitalOf(address(w2), address(t0), address(t1), KEY);
        assertEq(v, 0, "the Quoter reads only an admitted Gate");
        (v, , ) = IQuoterVital(address(quoter)).gateVitalOf(address(w), address(t1), address(t0), KEY);
        assertEq(v, 1, "the admitted Gate's wrapper");
    }
}
