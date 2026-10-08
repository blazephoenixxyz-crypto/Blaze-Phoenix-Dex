// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The classic door re-prices a nominal floor by the measured pull.
//
//  The measured-net-ratio note is written three times, once per door:
//  `swapExactInWithPermit2`, `swapBestExactIn` and the classic `swapExactIn`
//  (its private `_swap` tail):
//
//      if (received != amountIn) _noteFot(BPC.mulDiv(received, BPC.BPS, amountIn));
//
//  `test/PartialFotAtPrePulledDoors.t.sol` drives the classic door with an
//  asymmetric token (taxes transferFrom, exempts transfer) but with a zero
//  floor, where the note has nowhere to show. Its nominal-floor cases enter
//  through the pre-pulled doors. This file runs the same nominal-floor scenario
//  through the classic door: a one-leg V2 route whose `singleOutFloor` is
//  priced on the NOMINAL amountIn, which sits above what the measured pull
//  produces. With the note, the floor is re-priced by the measured ratio and
//  the honest swap settles; without it, the nominal floor applies and refuses.
//  The tests assert the observable delivery, not the transient slot.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {TransferFromTaxERC20} from "./PartialFotAtPrePulledDoors.t.sol";

contract ClassicDoorAsymmetricFotRepriceTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    TransferFromTaxERC20 asymIn; // taxes transferFrom, exempts transfer
    MockERC20 tokenOut;
    MockV2Pair pairAsym;

    address user = address(0xBEEF);

    uint256 constant RESERVE = 1_000_000e18;
    uint256 constant N = 1_000e18;
    uint16  constant TAX = 2_500; // 25%

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        asymIn = new TransferFromTaxERC20("Asym In", "AIN");
        tokenOut = new MockERC20("Out", "OUT");

        pairAsym = new MockV2Pair(address(asymIn), address(tokenOut));
        asymIn.mint(address(pairAsym), RESERVE);
        tokenOut.mint(address(pairAsym), RESERVE);
        pairAsym.setReserves(uint112(RESERVE), uint112(RESERVE));
        hub.seedPool(address(pairAsym), BPC.KIND_V2, 30, address(0),
                     address(asymIn), address(tokenOut));

        asymIn.mint(user, 100_000e18);
        vm.prank(user);
        asymIn.approve(address(router), type(uint256).max);

        asymIn.setTaxBps(TAX);
    }

    /// @dev The mock's tax: fee = amt * bps / 10_000 (rounded down).
    function _taxed(uint256 amt, uint16 t) private pure returns (uint256) {
        return amt - (amt * t) / 10_000;
    }

    /// @dev What the measured pull predicts: the protocol fee is taken on
    ///      `received`, the push to the pool is exempt, and MockV2Pair pays
    ///      `outV2` exactly.
    function _expectedDelivered() private pure returns (uint256) {
        uint256 received = _taxed(N, TAX);
        uint256 feeH = BPC.mulDivUp(received, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        return BPC.outV2(received - feeH, RESERVE, RESERVE, 30);
    }

    /// @dev One leg, shaped as the Solver emits it: the attestation priced on
    ///      the nominal amountIn (the Solver cannot see the tax).
    function _route(uint256 floorOut) private view returns (Route memory r) {
        uint256 q = BPC.outV2(N, RESERVE, RESERVE, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pairAsym), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: pairAsym.token0() == address(asymIn),
            stable: false, amountIn: N, expectedOut: q, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(asymIn), tokenOut: address(tokenOut),
            amountIn: N, expectedOut: q, legs: legs
        });
        r = Route({
            hops: hops, totalOut: q, singleOut: q, singleOutFloor: floorOut,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// @dev The nominal floor, the Solver's formula.
    function _nominalFloor() private pure returns (uint256) {
        uint256 gross = BPC.outV2(N, RESERVE, RESERVE, 30);
        return BPC.mulDiv(gross, BPC.ironFloorBps(BPC.impactV2Bps(N, RESERVE), 1, 0), BPC.BPS);
    }

    function _swapClassic(uint256 floorOut) private returns (uint256 d) {
        Route memory r = _route(floorOut);
        vm.prank(user);
        d = router.swapExactIn(r, N, 1, user, block.timestamp + 1);
    }

    /// @notice Control: with no floor the classic door settles the asymmetric
    ///         token at the measured-pull figure, and holds nothing.
    function test_ClassicDoor_AsymTax25_NoFloor_SettlesAtTheMeasuredFigure() public {
        uint256 delivered = _swapClassic(0);
        assertEq(delivered, _expectedDelivered(),
            "classic door: the tax is charged once, at the measured pull");
        assertEq(tokenOut.balanceOf(user), delivered, "recipient got exactly the returned amount");
        assertEq(asymIn.balanceOf(address(router)), 0, "router holds no tokenIn");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router holds no tokenOut");
    }

    /// @notice The nominal floor sits above the honest delivery; the classic
    ///         door re-prices it by the measured ratio and settles.
    function test_ClassicDoor_AsymTax25_NominalFloorIsRepricedAndSettles() public {
        uint256 floorOut = _nominalFloor();
        uint256 delivered = _swapClassic(floorOut);

        assertEq(delivered, _expectedDelivered(),
            "classic door: the measured-pull reprice must not change the delivery");
        assertGt(floorOut, delivered,
            "precondition: the nominal floor really is above the honest delivery");
    }

    /// @notice Same route, same state, with and without the floor: the floor
    ///         basis never touches what the swap delivers.
    function test_ClassicDoor_AsymTax25_RepriceDoesNotTouchTheDelivery() public {
        uint256 s1 = vm.snapshotState();
        uint256 noFloor = _swapClassic(0);
        vm.revertToState(s1);

        assertEq(_swapClassic(_nominalFloor()), noFloor,
            "the floor basis must not change the delivered amount");
    }
}
