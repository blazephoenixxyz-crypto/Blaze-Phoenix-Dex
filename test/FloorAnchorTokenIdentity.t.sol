// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

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

    /// @notice And the arm that makes the one above mean something: when the trailing hop names
    ///         the REAL output token, the route settles and the floor is still there - satisfied
    ///         by the hop that actually moved value. Without this, "refused" could just mean the
    ///         construction is malformed rather than that the gate holds.
    function test_TrailingHopNamingTheRealOutputLeavesTheFloorStanding() public {
        uint256 amt = 100e18;
        vm.recordLogs();
        vm.prank(user);
        uint256 got = router.swapExactIn(
            _twoHop(amt, address(tOut)), amt, 1, user, block.timestamp + 1);
        (uint256 quoted, uint256 floorUsed) = _floorFromProof();

        assertGt(got, 0, "premise: the route must settle, or the floor below is not being tested");
        assertGt(quoted, 0, "premise: a real in-frame quote must exist to anchor on");
        assertGt(floorUsed, 0, "the protocol floor must survive a trailing hop that moved nothing");
        // Tighter than "non-zero": the floor must still be most of the quote. Pre-fix this was
        // exactly zero; a regression that merely dented it would slip past a > 0 assertion.
        assertGt((floorUsed * 10_000) / quoted, 9_000,
            "the floor must remain a real fraction of the quote, not a token amount");
    }
}
