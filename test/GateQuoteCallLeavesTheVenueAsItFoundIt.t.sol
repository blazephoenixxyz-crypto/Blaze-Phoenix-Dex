// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// 3330 (imnw313). `previewRouteExact` prices every leg twice in one eth_call: `_exact` prices the
// plan as committed, then `_fundedOut` prices the route as the Router will fund it once the
// protocol fee is taken. A Gate leg whose adapter has no view price is asked by `quoteCall`, and
// some venues only price by running the swap: the Balancer V3 Vault's `quote` runs it and returns
// without unwinding it. The second pricing then met the venue the first one moved, and the
// scalar an integrator turns into userMinOut was the lower of the two (PoC on a Base fork at
// block 52,900,000, reports/plano-1026/pocs/3330.log: 326 bps under delivery on a 0.01 ETH
// WETH->RATE route, 1,444 bps with the order split over two legs). Red here at e31c6ea: exactOut
// 991241419527741341670 against a floor of 993218161492991487486 (19.9 bps under), and the
// venue's input reserve 1,997.2e18 above where the preview found it (both passes kept their
// swap); the control is green before and after the fix.
//
// The fixture is a constant-product venue whose only price is a query that writes the reserves
// the swap would leave (the Vault's shape), behind an adapter whose view `quote` answers 0 (the
// Balancer V3 adapter's shape): `Core.gateQuote` finds the wrapper live and prices it 0, and
// `_priceLeg` asks `quoteCall`. The route touches no bridge, so the Router charges the fee on
// the input and `_fundedOut` prices the leg a second time. The preview runs as an integrator
// runs it, by eth_call, whose state is thrown away (snapshot and revert) before the fill.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockGateAdapter, MockGateRegistry} from "./mocks/MockGateAdapters.sol";

/// A PUSH constant-product venue (30 bps on the input). `query` prices the swap by running it on
/// the reserves and keeping what it wrote, as the Balancer V3 Vault's `quote` keeps the pool's
/// balances; `peek` is the same price as a view.
contract QueryCpVenue {
    address public token0;
    address public token1;
    uint256 public r0;
    uint256 public r1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function sync() public {
        r0 = MockERC20(token0).balanceOf(address(this));
        r1 = MockERC20(token1).balanceOf(address(this));
    }

    function _out(uint256 amtIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inAfterFee = amtIn * 9_970;
        return inAfterFee * rOut / (rIn * 10_000 + inAfterFee);
    }

    /// The swap priced and written, nothing paid: the state a simulation leaves behind.
    function query(bool zeroForOne, uint256 amtIn) external returns (uint256 out) {
        if (zeroForOne) {
            out = _out(amtIn, r0, r1);
            (r0, r1) = (r0 + amtIn, r1 - out);
        } else {
            out = _out(amtIn, r1, r0);
            (r1, r0) = (r1 + amtIn, r0 - out);
        }
    }

    function peek(bool zeroForOne, uint256 amtIn) external view returns (uint256) {
        return zeroForOne ? _out(amtIn, r0, r1) : _out(amtIn, r1, r0);
    }

    function sell(bool zeroForOne, address to) external returns (uint256 out) {
        (address tIn, address tOut, uint256 rIn, uint256 rOut) =
            zeroForOne ? (token0, token1, r0, r1) : (token1, token0, r1, r0);
        out = _out(MockERC20(tIn).balanceOf(address(this)) - rIn, rIn, rOut);
        MockERC20(tOut).transfer(to, out);
        sync();
    }
}

/// An adapter with no view price, so the Quoter asks `quoteCall`; `persist` chooses whether the
/// venue's simulation keeps what it wrote (the Vault's `quote`) or is a view (the control).
contract QueryCallAdapter is MockGateAdapter {
    bool public persist = true;

    constructor(BlazePhoenixGate g, MockGateRegistry r) MockGateAdapter(g, r) {}

    function setPersist(bool p) external { persist = p; }

    function quote(address, bytes32, bytes32, bool, uint256)
        external pure override returns (uint256, uint256)
    {
        return (0, 0);
    }

    function quoteCall(address vp, bytes32, bytes32, bool zeroForOne, uint256 amtIn)
        external override returns (uint256)
    {
        return persist ? QueryCpVenue(vp).query(zeroForOne, amtIn) : QueryCpVenue(vp).peek(zeroForOne, amtIn);
    }
}

contract GateQuoteCallLeavesTheVenueAsItFoundItTest is Test {
    uint8 constant FAM = 1;
    uint24 constant KEY = uint24(uint256(FAM) << 16 | 1);
    uint256 constant AMT = 1_000e18; // 0.1% of the venue's reserves: the price moves with it

    BlazePhoenixGate gate;
    BlazePhoenixHub hub;
    MockGateRegistry reg;
    QueryCpVenue venue;
    QueryCallAdapter adapter;
    MockERC20 t0;
    MockERC20 t1;
    BlazePhoenixGateWrapper w;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address user = address(0xA11CE);

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        gate = new BlazePhoenixGate(address(this));
        reg = new MockGateRegistry();
        venue = new QueryCpVenue(address(t0), address(t1));
        reg.add(address(venue));
        t0.mint(address(venue), 1_000_000e18);
        t1.mint(address(venue), 1_000_000e18);
        venue.sync();
        adapter = new QueryCallAdapter(gate, reg);
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        gate.proposeAdapter(FAM, address(adapter));
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(FAM);
        w = BlazePhoenixGateWrapper(gate.create(address(t1), address(t0), KEY, abi.encode(address(venue))));
        uint24[] memory fees = new uint24[](1);
        fees[0] = KEY;
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0));
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(0xD0D0));
        t0.mint(user, AMT);
        vm.prank(user);
        t0.approve(address(router), type(uint256).max);
    }

    function _route() internal view returns (Route memory r) {
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: address(w), hooks: address(0), kind: BPC.KIND_EXTERNAL, fee: KEY, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: AMT, expectedOut: 0, auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: AMT, expectedOut: 0, legs: l});
        r = Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// previewRouteExact as an integrator runs it, by eth_call: its state is thrown away. Then the
    /// fill of the route it returned, in the same block, and the floor `_exact` promises: the
    /// lower of the output deduction and what the Router delivers (the funded pass).
    function _previewAndFill()
        internal
        returns (Route memory q, uint256 exactOut, uint256 delivered, uint256 floor)
    {
        assertFalse(hub.isBridgeToken(address(t0)) || hub.isBridgeToken(address(t1)),
            "premise: no bridge, so the Router charges the fee on the input and the leg is priced twice");
        uint256 snap = vm.snapshotState();
        (q, exactOut) = quoter.previewRouteExact(_route(), AMT);
        vm.revertToState(snap);
        assertEq(q.hops[0].legs[0].expectedOut, venue.peek(true, AMT),
            "premise: the first pass prices the committed leg on the venue as it stands");
        uint256 gross = venue.peek(true, AMT);
        uint256 deduction = gross - BPC.mulDivUp(gross, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        vm.prank(user);
        delivered = router.swapExactIn(q, AMT, 1, user, block.timestamp + 1);
        floor = deduction < delivered ? deduction : delivered;
    }

    /// @notice The scalar is the floor `_exact` promises: its funded pass meets the venue the
    ///         first pass found, not the one the first pass's simulation left.
    function test_AGateLegPricedTwiceIsPricedOnTheVenueAsItStands() public {
        (, uint256 exactOut, uint256 delivered, uint256 floor) = _previewAndFill();
        assertGt(exactOut, 0, "premise: the leg is priced");
        assertLe(exactOut, delivered, "a floor the Router honours");
        assertEq(exactOut, floor, "the lower of the output deduction and the delivery, not less");
    }

    /// @notice The preview leaves the venue as it found it, inside the one call it runs in.
    function test_APreviewLeavesTheVenueAsItFoundIt() public {
        (uint256 r0, uint256 r1) = (venue.r0(), venue.r1());
        quoter.previewRouteExact(_route(), AMT);
        assertEq(venue.r0(), r0, "the venue's reserves of the input, after the preview");
        assertEq(venue.r1(), r1, "the venue's reserves of the output, after the preview");
    }

    /// @notice Control: a venue whose simulation keeps nothing gets the same floor before and after
    ///         the fix; the fixture's figures are the Quoter's own.
    function test_Control_ASimulationThatKeepsNothingIsDeliveredAsQuoted() public {
        adapter.setPersist(false);
        (, uint256 exactOut, uint256 delivered, uint256 floor) = _previewAndFill();
        assertGt(exactOut, 0, "premise: the leg is priced");
        assertLe(exactOut, delivered, "a floor the Router honours");
        assertEq(exactOut, floor, "the lower of the output deduction and the delivery");
    }
}
