// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, MAX_HOPS} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// @notice The FLOOR-01 anchor names a TOKEN, and the token is named by calldata. This file is
///         the evidence for a question that was raised, tested, and answered - and it exists
///         because the answer was nearly kept without the proof.
///
///         The observation is correct and worth restating: `tokenOut` is read at `Router:953`
///         from `route.hops[route.hops.length - 1].tokenOut`, which is the same DECLARATION
///         FLOOR-01 was written to stop trusting, and the anchor gate compares
///         `route.hops[h].tokenOut` against it - calldata on both sides. Only `hopGot != 0` is
///         measured. For the concentrated-single family `_legTokens` returns `leg.auxId`, also
///         calldata, so the leg/hop token gate consults no pool at all. On paper a trailing hop
///         of that family can therefore rename the route's output currency for the price of
///         calldata, leave no hop able to satisfy the gate, and drop `finalHopQuote` back to
///         zero - which is exactly the pre-fix outcome FLOOR-01 exists to prevent.
///
///         It does not get there, and the reason is worth pinning rather than trusting: a
///         currency nothing produces is a currency nothing DELIVERS, and the Router refuses on
///         delivery before the floor is ever computed. Both arms are here, because one arm
///         alone would leave it an accident of one construction.
///
///         Since 2026-11-06 a route has at most MAX_HOPS = 2 hops. The control arm's no-op tail
///         back into tOut takes three, so it is refused at the hop ceiling now; the arm that
///         settles is the two-hop route whose last hop names the real output and anchors the
///         floor there, while a quote in a bridge's units never does.
contract FloorAnchorTokenIdentityTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tIn;
    MockERC20 tOut;
    MockERC20 tGhost;
    MockV2Pair pair;
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        tIn = new MockERC20("In", "IN");
        tOut = new MockERC20("Out", "OUT");
        tGhost = new MockERC20("Ghost", "GHO");
        pair = new MockV2Pair(address(tIn), address(tOut));
        tIn.mint(address(pair), 10_000e18);
        tOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);
        tIn.mint(user, 10_000e18);
        vm.prank(user);
        tIn.approve(address(router), type(uint256).max);
    }

    function _realLeg(uint256 amt) private view returns (Leg memory) {
        return Leg({pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                    tickSpacing: 0, zeroForOne: address(tIn) < address(tOut), stable: false,
                    amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
    }

    /// @dev A concentrated-single leg naming its output through `auxId` alone - the family for
    ///      which `_legTokens` returns early and no pool needs to exist.
    function _ghostLeg(address out) private pure returns (Leg memory) {
        return Leg({pool: address(uint160(uint256(keccak256("nowhere")))), hooks: address(0),
                    kind: 4, fee: 500, tickSpacing: 10, zeroForOne: true, stable: false,
                    amountIn: 0, expectedOut: 0, auxId: bytes32(uint256(uint160(out)))});
    }

    function _twoHop(uint256 amt, address trailingOut) private view returns (Route memory r) {
        Leg[] memory l0 = new Leg[](1); l0[0] = _realLeg(amt);
        Leg[] memory l1 = new Leg[](1); l1[0] = _ghostLeg(trailingOut);
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut),
                       amountIn: amt, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(tOut), tokenOut: trailingOut,
                       amountIn: 0, expectedOut: 0, legs: l1});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// @dev The control arm's route: the same real hop, then a no-op tail of ghost legs that
    ///      goes out through `mid` and back into tOut. Since 2026-10-19 a self-hop tOut -> tOut
    ///      is refused outright (RouterE(3), H3), and this is the shape left that still ends the
    ///      route on a hop naming the real output while moving nothing.
    function _noOpTailBackToOut(uint256 amt) private returns (Route memory r) {
        MockERC20 mid = new MockERC20("Mid", "MID");
        Leg[] memory l0 = new Leg[](1); l0[0] = _realLeg(amt);
        Leg[] memory l1 = new Leg[](1); l1[0] = _ghostLeg(address(mid));
        Leg[] memory l2 = new Leg[](1); l2[0] = _ghostLeg(address(tOut));
        l2[0].pool = address(uint160(uint256(keccak256("nowhere2"))));
        Hop[] memory hops = new Hop[](3);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut),
                       amountIn: amt, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(tOut), tokenOut: address(mid),
                       amountIn: 0, expectedOut: 0, legs: l1});
        hops[2] = Hop({tokenIn: address(mid), tokenOut: address(tOut),
                       amountIn: 0, expectedOut: 0, legs: l2});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    function _floorFromProof() private returns (uint256 quoted, uint256 floorUsed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i)
            if (logs[i].topics[0] == sig)
                (quoted, , floorUsed, ) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
    }

    /// @notice A trailing hop renaming the output to a currency nothing produces is REFUSED,
    ///         and refused before the floor matters. The specific code is asserted: a bare
    ///         "it reverted" would pass on a Router that refused every route.
    function test_TrailingHopCannotRenameTheOutputToACurrencyNothingProduces() public {
        uint256 amt = 100e18;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(_twoHop(amt, address(tGhost)), amt, 1, user, block.timestamp + 1);
    }

    /// @notice The control arm's shape, one hop past the ceiling: the real hop, then a no-op
    ///         tail out through `mid` and back into tOut. Refused on its length (RouterE(3))
    ///         before any hop runs; the preview's half of the same refusal is pinned in
    ///         FloorAnchorAndLegCount on this route with legs whose keys hold together.
    ///
    ///         History: until 2026-11-06 this was test_TrailingHopNamingTheRealOutputLeavesTheFloorStanding:
    ///         the route settled and its floor had to stay above 9000 bps of the quote, the arm
    ///         that made the refusal above mean something. That property needed the third hop;
    ///         at two hops the arm that settles is the next test.
    function test_ThreeHops_NoOpTailBackToTheRealOutput_IsRefused() public {
        uint256 amt = 100e18;
        Route memory r = _noOpTailBackToOut(amt); // deploys `mid`: built before the prank
        assertEq(r.hops.length, MAX_HOPS + 1, "premise: the route is one hop past the ceiling");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    function _v3Leg(MockV3Pool p, address from, address to, uint256 amt, uint256 exp)
        private pure returns (Leg memory)
    {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
                    tickSpacing: 0, zeroForOne: from < to, stable: false,
                    amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
    }

    /// @notice The anchor gate's token half, at two hops. Hop 0 tIn -> mid is quoted in frame;
    ///         hop 1 mid -> tOut is blind (its pool reports no liquidity, so the frame cannot
    ///         price it; it fills honestly, at about a third of impact) and anchors the floor on
    ///         its own declared figure, which is less than hop 0's quote. The gate names the
    ///         output TOKEN: hop 0's quote is in `mid`'s units and never anchors a floor in tOut.
    ///         Read without the gate, it would anchor first and the smaller declaration would not
    ///         replace it (the anchor only rises), and a floor of ~80-96% of a quote in another
    ///         unit would refuse this honest fill.
    ///
    ///         History: new on 2026-11-06, the two-hop arm that settles beside the rename refusal
    ///         above (its three-hop control is the test before this one).
    function test_TwoHops_TheAnchorNamesTheOutputToken_ABridgeQuoteNeverAnchors() public {
        uint256 amt = 1_000e18;
        uint160 q96 = uint160(uint256(1) << 96);
        MockERC20 mid = new MockERC20("Mid", "MID");
        MockV3Pool p0 = new MockV3Pool(address(tIn), address(mid), 3000);
        p0.setState(q96, 1e27);
        mid.mint(address(p0), 1e24);
        MockV3Pool p1 = new MockV3Pool(address(mid), address(tOut), 3000);
        p1.setState(q96, 0);           // unpriced: the frame cannot quote hop 1
        p1.setSwapLiquidity(2e21);     // but it fills honestly
        tOut.mint(address(p1), 1e24);

        uint256 q0 = BPC.outV3(amt, q96, 1e27, 3000, address(tIn) < address(mid), 0);
        uint256 declared = BPC.outV3(q0, q96, 2e21, 3000, address(mid) < address(tOut), 0) * 90 / 100;
        assertLt(declared, q0, "premise: the last hop declares less than hop 0 quoted, in other units");

        Leg[] memory l0 = new Leg[](1);
        l0[0] = _v3Leg(p0, address(tIn), address(mid), amt, q0);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _v3Leg(p1, address(mid), address(tOut), q0, 0); // blind: no attestation, no quote
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(mid),
                       amountIn: amt, expectedOut: q0, legs: l0});
        hops[1] = Hop({tokenIn: address(mid), tokenOut: address(tOut),
                       amountIn: q0, expectedOut: declared, legs: l1});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                                expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                                hasSurplus: false, isV4Bundle: false});

        vm.recordLogs();
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (r, amt, 1, user, block.timestamp + 1)));
        assertTrue(ok, string.concat(
            "ANCHOR: an honest two-hop fill was refused (a bridge-unit anchor?): ", vm.toString(ret)));
        uint256 got = abi.decode(ret, (uint256));
        (uint256 quoted, uint256 floorUsed) = _floorFromProof();

        assertEq(quoted, declared, "the anchor is the last hop's figure in tOut, not hop 0's quote");
        assertGt(floorUsed, 0, "the protocol floor stands on that anchor");
        assertGe(got, floorUsed, "and the delivery clears it");
    }
}
