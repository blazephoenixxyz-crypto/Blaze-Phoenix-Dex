// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The exact door's fee walk (`BlazePhoenixQuoter._walk`) stops at 0 when the fee charged
// on a hop's input is the whole of what entered it (`fee >= carry`). On an honest venue the
// carry left (0) prices 0 anyway, so the guard is visible only through a venue that quotes
// something for nothing: a Gate wrapper whose adapter has no view price and answers `quoteCall`
// with a fixed figure whatever the input, 0 included. The oracle is the fee arithmetic and the
// adapter's constant, never the Quoter.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockGateAdapter, MockGateRegistry, MockGateVenue} from "./mocks/MockGateAdapters.sol";

/// No view price; `quoteCall` answers FIXED for an input of 0 (the lie) and 1:1 above it.
contract QuotesSomethingForNothing is MockGateAdapter {
    uint256 public constant FIXED = 1e18;

    constructor(BlazePhoenixGate g, MockGateRegistry r) MockGateAdapter(g, r) {}

    function quote(address, bytes32, bytes32, bool, uint256) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function quoteCall(address, bytes32, bytes32, bool, uint256 amtIn) external pure override returns (uint256) {
        return amtIn == 0 ? FIXED : amtIn;
    }
}

contract QuoterExactFeeThatEatsTheCarryIsZeroTest is Test {
    uint8 constant FAM = 1;
    uint24 constant KEY = uint24(uint256(FAM) << 16 | 1);
    uint256 constant FIXED = 1e18;

    BlazePhoenixGate gate;
    BlazePhoenixHub hub;
    MockGateRegistry reg;
    BlazePhoenixQuoter quoter;
    MockERC20[3] tk;

    function setUp() public {
        for (uint256 i; i < 3; ++i) tk[i] = new MockERC20("T", "T");
        gate = new BlazePhoenixGate(address(this));
        reg = new MockGateRegistry();
        QuotesSomethingForNothing adapter = new QuotesSomethingForNothing(gate, reg);
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
            zeroForOne: a < b, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
        h = Hop({tokenIn: a, tokenOut: b, amountIn: amt, expectedOut: 0, legs: l});
    }

    /// `n` hops tk[0] -> ... -> tk[n], one hostile leg each; hop h > 0 commits FIXED.
    function _route(uint256 n, uint256 amt) internal returns (Route memory r) {
        Hop[] memory hs = new Hop[](n);
        for (uint256 h; h < n; ++h) hs[h] = _hop(h, h == 0 ? amt : FIXED);
        r = Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// previewRouteExact as an integrator runs it (eth_call: state thrown away).
    function _exactOut(uint256 n, uint256 amt) internal returns (uint256 exactOut) {
        uint256 s = vm.snapshotState(); // the wrappers too: a second call re-creates them
        Route memory r = _route(n, amt);
        for (uint256 i; i < 3; ++i) {
            assertFalse(hub.isBridgeToken(address(tk[i])), "premise: no bridge, the fee is charged on the input");
        }
        (, exactOut) = quoter.previewRouteExact(r, amt);
        vm.revertToState(s);
    }

    /// @notice Range: 1 wei, the only order a 28 bps fee rounded up eats whole. Vector: a venue that
    ///         quotes FIXED for an input of 0. Dimension: unit, 1 hop. The fee on 1 wei is 1 wei,
    ///         nothing reaches the venue, and the door promises 0, not the venue's FIXED.
    ///         Red under: `fee >= carry` -> `fee > carry` in the walk (the carry 0 asks the venue).
    function test_OneHop_AFeeThatEatsTheWholeInputPromisesZero() public {
        assertEq(BPC.mulDivUp(1, BPC.PROTOCOL_FEE_BPS, BPC.BPS), 1, "premise: the fee on 1 wei is 1 wei");
        assertEq(_exactOut(1, 1), 0, "the fee ate the input: the door promises 0");
    }

    /// @notice Same order on two hops: the anchor-less calendar charges every hop on its input,
    ///         hop 0 is eaten whole, and the walk must stop there (hop 1 would be quoted FIXED).
    ///         Red at 2f1e1b5 (about FIXED promised): the price loop had no guard and wrote 0 into hop 0's
    ///         legs, so the funded walk, which reads the rewritten route, found a 0 commitment, a 0
    ///         fee, and priced both hops again.
    function test_TwoHops_AFeeThatEatsTheWholeInputPromisesZero() public {
        assertEq(_exactOut(2, 1), 0, "the fee ate hop 0's input: the door promises 0");
    }

    /// @notice Control: above the fee the same venue is asked and what the fee leaves is what the
    ///         door promises (one hop: the funded figure), so the zeros above are the guard's.
    ///         Range: 2 wei (the first order the fee leaves something of) and 1e18.
    function test_Control_AboveTheFeeTheVenueIsAsked() public {
        assertEq(_exactOut(1, 2), 1, "2 wei: 1 wei reaches the venue");
        uint256 fee = BPC.mulDivUp(1e18, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(_exactOut(1, 1e18), 1e18 - fee, "1e18: the venue's figure for what the fee leaves");
    }

    /// @notice One hop, no bridge: the Router takes the fee on the hop's input itself, so the
    ///         exact walk prices the order as committed and only the funded walk takes the fee.
    ///         The route the door returns keeps the gross figure; the promise is the funded one.
    ///         Range: 1e18. Vector: a 1:1 venue. Dimension: unit, 1 hop.
    ///         Red under: the walk's `feeOnOut || route.hops.length == 1` -> `feeOnOut` (the fee
    ///         taken in the route too, and once more by the funded walk that reads it).
    function test_OneHop_TheWalkLeavesTheFeeToTheFundedPass() public {
        uint256 s = vm.snapshotState();
        Route memory r = _route(1, 1e18);
        assertFalse(hub.isBridgeToken(address(tk[1])), "premise: no bridge, the fee is charged on the input");
        (Route memory q, uint256 exactOut) = quoter.previewRouteExact(r, 1e18);
        vm.revertToState(s);
        uint256 fee = BPC.mulDivUp(1e18, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(q.totalOut, 1e18, "one hop: the walk prices the order as committed");
        assertEq(q.hops[0].legs[0].amountIn, 1e18, "one hop: the leg keeps the whole order");
        assertEq(exactOut, 1e18 - fee, "the promise is the funded figure, the fee taken once");
    }
}
