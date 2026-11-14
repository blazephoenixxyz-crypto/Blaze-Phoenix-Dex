// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The route the exact door returns (`previewRouteExact`) carries, hop by hop and leg by leg, the
// input the Router will fund and what the venue answers for it: `BlazePhoenixQuoter._walk` in its
// write mode rewrites the plan's figures as it walks. A fee that takes all that entered a hop
// (`fee >= carry`: 1 wei, the only carry a 28 bps fee rounded up eats whole) stops the walk at 0,
// and the hops from there on fund nothing. The oracle is the fee arithmetic and a 1:1 venue,
// never the Quoter: whatever reached a hop after its fee is what its legs may show.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixGate} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockGateAdapter, MockGateRegistry, MockGateVenue} from "./mocks/MockGateAdapters.sol";

/// No view price; `quoteCall` answers 1:1, 0 for 0 (an honest venue).
contract OneToOneGateAdapter is MockGateAdapter {
    constructor(BlazePhoenixGate g, MockGateRegistry r) MockGateAdapter(g, r) {}

    function quote(address, bytes32, bytes32, bool, uint256) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function quoteCall(address, bytes32, bytes32, bool, uint256 amtIn) external pure override returns (uint256) {
        return amtIn;
    }
}

contract QuoterExactRouteShowsOnlyFundedFiguresTest is Test {
    uint8 constant FAM = 1;
    uint24 constant KEY = uint24(uint256(FAM) << 16 | 1);
    /// The plan's figures for every hop after the first: what an unwritten hop would still show.
    uint256 constant PLANNED = 1e18;

    BlazePhoenixGate gate;
    BlazePhoenixHub hub;
    MockGateRegistry reg;
    OneToOneGateAdapter adapter;
    BlazePhoenixQuoter quoter;
    MockERC20[3] tk;

    function setUp() public {
        for (uint256 i; i < 3; ++i) tk[i] = new MockERC20("T", "T");
        gate = new BlazePhoenixGate(address(this));
        reg = new MockGateRegistry();
        adapter = new OneToOneGateAdapter(gate, reg);
        gate.proposeAdapter(FAM, address(adapter));
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(FAM);
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        uint24[] memory fees = new uint24[](1);
        fees[0] = KEY;
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0));
        quoter = new BlazePhoenixQuoter(address(hub), address(0xD0D0));
    }

    function _hop(uint256 i, uint256 amt) internal returns (Hop memory h) {
        (address a, address b) = (address(tk[i]), address(tk[i + 1]));
        MockGateVenue v = new MockGateVenue(a, b);
        reg.add(address(v));
        address w = gate.create(a, b, KEY, abi.encode(address(v)));
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: w, hooks: address(0), kind: BPC.KIND_EXTERNAL, fee: KEY, tickSpacing: 0,
            zeroForOne: a < b, stable: false, amountIn: amt, expectedOut: amt, auxId: bytes32(0)});
        h = Hop({tokenIn: a, tokenOut: b, amountIn: amt, expectedOut: amt, legs: l});
    }

    /// tk[0] -> tk[1] -> tk[2], one 1:1 leg a hop; hop 0 commits the order, hop 1 commits PLANNED.
    function _preview(uint256 amt) internal returns (Route memory q, uint256 exactOut) {
        uint256 s = vm.snapshotState(); // eth_call: the wrappers and the state are thrown away
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(0, amt);
        hs[1] = _hop(1, PLANNED);
        Route memory r = Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        (q, exactOut) = quoter.previewRouteExact(r, amt);
        vm.revertToState(s);
    }

    function _fee(uint256 x) internal pure returns (uint256) {
        return BPC.mulDivUp(x, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// Every figure of hop `h` in the returned route is `funded` (one 1:1 leg: in = out = funded).
    function _assertHop(Route memory q, uint256 h, uint256 funded, string memory what) internal pure {
        assertEq(q.hops[h].amountIn, funded, string.concat(what, ": hop amountIn"));
        assertEq(q.hops[h].expectedOut, funded, string.concat(what, ": hop expectedOut"));
        assertEq(q.hops[h].legs[0].amountIn, funded, string.concat(what, ": leg amountIn"));
        assertEq(q.hops[h].legs[0].expectedOut, funded, string.concat(what, ": leg expectedOut"));
    }

    /// @notice RED-FIRST (JUNTA-ENSAIO-124, 72bb176). Range: 1 wei. Vector: no bridge, so the calendar
    ///         charges every hop on its input. Dimension: unit, 2 hops. The fee on hop 0's 1 wei is
    ///         1 wei: nothing reaches either hop, the door promises 0, and the route it returns must
    ///         fund no leg. Red while the walk's early `return 0` leaves the plan's figures in the
    ///         hops it never reached (hop 0: 1/1, hop 1: PLANNED/PLANNED).
    function test_TwoHops_AFeeThatEatsHopZero_LeavesNoUnfundedFigureInTheRoute() public {
        assertFalse(hub.isBridgeToken(address(tk[1])), "premise: no bridge, every hop pays on its input");
        assertEq(_fee(1), 1, "premise: the fee on 1 wei is 1 wei");
        (Route memory q, uint256 exactOut) = _preview(1);
        assertEq(exactOut, 0, "the fee ate the order: the door promises 0");
        assertEq(q.totalOut, 0, "the route's total is the walk's 0");
        _assertHop(q, 0, 0, "hop 0, eaten by its fee");
        _assertHop(q, 1, 0, "hop 1, never reached");
    }

    /// @notice RED-FIRST. Range: 2 wei, the first order hop 0's fee leaves something of (1 wei), which
    ///         hop 1's fee then eats. Vector: no bridge. Dimension: unit, 2 hops. Hop 0 is written with
    ///         its funded 1 wei; hop 1 must show 0, not PLANNED.
    function test_TwoHops_AFeeThatEatsHopOne_LeavesNoUnfundedFigureInTheRoute() public {
        assertEq(_fee(2), 1, "premise: the fee on 2 wei is 1 wei");
        (Route memory q, uint256 exactOut) = _preview(2);
        assertEq(exactOut, 0, "the fee ate hop 1's input: the door promises 0");
        _assertHop(q, 0, 1, "hop 0, 1 wei funded");
        _assertHop(q, 1, 0, "hop 1, eaten by its fee");
    }

    /// @notice RED-FIRST. Range: 1 wei. Vector: tk[1] a bridge, so only the anchor hop (hop 1) pays,
    ///         on what arrived (1 wei). Dimension: unit, 2 hops, fee at a later hop. Hop 0 is funded
    ///         whole; hop 1 must show 0, not PLANNED.
    function test_TwoHops_AFeeThatEatsTheAnchorHop_LeavesNoUnfundedFigureInTheRoute() public {
        hub.addBridge(address(tk[1]));
        assertTrue(hub.isBridgeToken(address(tk[1])), "premise: tk[1] is a bridge, hop 1 is the anchor");
        (Route memory q, uint256 exactOut) = _preview(1);
        assertEq(exactOut, 0, "the fee ate the anchor hop's input: the door promises 0");
        _assertHop(q, 0, 1, "hop 0, no fee, 1 wei funded");
        _assertHop(q, 1, 0, "hop 1, eaten by its fee");
    }

    /// @notice RED-FIRST (WALKFIX-124). Gama: 1 wei. Vetor: no bridge, every hop pays on its input.
    ///         Dimensão: unit, 2 hops, venue call count. A walk that funded nothing promises 0
    ///         whatever a second walk would say (the promise is at most the walk's 0), so the exact
    ///         door asks no venue again: the funded figure is not re-walked over the zeroed route,
    ///         where hop 0 would ask its venue for 0. Red while `_exact` calls `_fundedOut` on a
    ///         gross of 0 (registered mutant «WALKFIX-124 Quoter: the exact door re-walks a route
    ///         that funded nothing»).
    function test_TwoHops_AFeeThatEatsHopZero_AsksNoVenue() public {
        vm.expectCall(address(adapter), abi.encodeWithSelector(OneToOneGateAdapter.quoteCall.selector), 0);
        (, uint256 exactOut) = _preview(1);
        assertEq(exactOut, 0, "the fee ate the order: the door promises 0");
    }

    /// @notice Control, green today: above the fee every hop is written with what the Router funds.
    ///         Range: 3 wei (the boundary +1: hop 1 keeps 1 wei) and 1e18. Vector: no bridge.
    ///         Dimension: unit, 2 hops. Red under: the walk's hop write `(carry, hopOut)` ->
    ///         `(hop.amountIn, hopOut)` (the route keeps the hop's planned input; registered mutant
    ///         «Quoter: the exact walk leaves a hop's planned input in the returned route»).
    function test_Control_TwoHops_TheRouteCarriesTheFundedFigures() public {
        uint256[2] memory amts = [uint256(3), 1e18];
        for (uint256 i; i < 2; ++i) {
            uint256 amt = amts[i];
            uint256 c0 = amt - _fee(amt); // hop 0: pays on min(order, legs' sum) = amt
            uint256 c1 = c0 - _fee(c0); // hop 1: pays on what arrived
            (Route memory q, uint256 exactOut) = _preview(amt);
            _assertHop(q, 0, c0, "hop 0 funded");
            _assertHop(q, 1, c1, "hop 1 funded");
            assertEq(q.totalOut, c1, "the route's total is hop 1's funded output");
            assertEq(exactOut, c1, "the promise is the funded walk");
        }
    }
}
