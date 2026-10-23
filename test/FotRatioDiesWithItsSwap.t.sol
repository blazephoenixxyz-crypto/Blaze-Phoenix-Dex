// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE MEASURED FEE-ON-TRANSFER RATIO DIES WITH THE SWAP THAT MEASURED IT
//  (revisao-total 2026-10-23)
//
//  `_noteFot` writes the net ratio a taxed input delivered into TSLOT_FOT, and the
//  floor of the route reads it: with no tax seen the route's `singleOutFloor` joins
//  the floor; with a tax seen the floor is re-priced by the measured ratio instead.
//  The floor clears the slot when it consumes it. Transient storage lives for the
//  whole transaction, so without that clear the ratio of one swap reaches the NEXT
//  swap of the same transaction - a batch, a smart wallet, an aggregator running
//  two users' orders - and that swap, taxed by nothing, loses its `singleOutFloor`
//  and has its floor shrunk by a tax it never paid (P3: a safety net never degrades).
//
//  The clear had no test that could see it: its mutant survived the Router's fee and
//  FoT suites (mutant run, revisao-total). Foundry resets transient storage between
//  the test's top-level calls, so the two swaps run inside ONE call.
//
//  forge test --match-path test/FotRatioDiesWithItsSwap.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HonestV2Pair} from "./FotFloorReprice.t.sol";

/// @notice Two orders in one transaction: the first taxed, the second not.
contract TwoOrdersOneTx {
    bool  public secondOk;
    bytes public secondRet;

    function solo(BlazePhoenixRouter router, Route calldata r2, MockERC20 t2, uint256 a2) external {
        t2.approve(address(router), a2);
        (secondOk, secondRet) = address(router).call(abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (r2, a2, 1, address(this), block.timestamp + 1)));
    }

    function run(BlazePhoenixRouter router, Route calldata r1, MockERC20 t1, uint256 a1,
                 Route calldata r2, MockERC20 t2, uint256 a2) external {
        t1.approve(address(router), a1);
        t2.approve(address(router), a2);
        router.swapExactIn(r1, a1, 1, address(this), block.timestamp + 1);
        (secondOk, secondRet) = address(router).call(abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (r2, a2, 1, address(this), block.timestamp + 1)));
    }
}

contract FotRatioDiesWithItsSwapTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20 taxed;
    MockERC20 plainIn;
    MockERC20 out;
    HonestV2Pair pairTaxed;
    HonestV2Pair pairPlain;

    uint256 constant AMT = 1_000e18;
    uint256 constant R   = 100_000e18;

    function setUp() public {
        hub     = new BlazePhoenixHub(address(this));
        router  = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0x7451), address(0x7452));
        taxed   = new MockERC20("T", "T");
        plainIn = new MockERC20("P", "P");
        out     = new MockERC20("O", "O");
        pairTaxed = new HonestV2Pair(address(taxed), address(out));
        pairPlain = new HonestV2Pair(address(plainIn), address(out));
        taxed.mint(address(pairTaxed), R);   out.mint(address(pairTaxed), R);   pairTaxed.setReserves(uint112(R), uint112(R));
        plainIn.mint(address(pairPlain), R); out.mint(address(pairPlain), R);   pairPlain.setReserves(uint112(R), uint112(R));
    }

    function _outV2(uint256 amtIn) private pure returns (uint256) {
        uint256 inAfterFee = amtIn * 9970;
        return (inAfterFee * R) / (R * 10_000 + inAfterFee);
    }

    function _route(HonestV2Pair p, address tIn, uint256 singleOutFloor) private view returns (Route memory r) {
        uint256 q = _outV2(AMT);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
                       zeroForOne: tIn < address(out), stable: false, amountIn: AMT, expectedOut: q, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: address(out), amountIn: AMT, expectedOut: q, legs: legs});
        r = Route({hops: hops, totalOut: q, singleOut: q, singleOutFloor: singleOutFloor,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// FAILS IF DELETED: yes - with the clear removed the second order inherits the first's
    /// ratio, its `singleOutFloor` is dropped, and it settles below the floor it asked for.
    function test_ASecondOrderInTheSameTransaction_KeepsItsOwnFloor() public {
        taxed.setFeeOnTransferBps(500);
        // The second order asks for one unit more than the pool can pay: its floor must refuse it.
        Route memory r2 = _route(pairPlain, address(plainIn), _outV2(AMT) + 1);

        // Control, alone in its transaction: refused by its own floor.
        TwoOrdersOneTx solo = new TwoOrdersOneTx();
        plainIn.mint(address(solo), AMT);
        solo.solo(router, r2, plainIn, AMT);
        assertFalse(solo.secondOk(), "control: the order's own singleOutFloor refuses it");
        assertEq(bytes4(solo.secondRet()), BlazePhoenixRouter.RouterE.selector, "control: by the Router");

        TwoOrdersOneTx batch = new TwoOrdersOneTx();
        taxed.mint(address(batch), AMT);
        plainIn.mint(address(batch), AMT);
        batch.run(router, _route(pairTaxed, address(taxed), 0), taxed, AMT, r2, plainIn, AMT);
        assertFalse(batch.secondOk(), "an untaxed order settled below its floor after a taxed one in the same transaction");
        assertEq(bytes4(batch.secondRet()), BlazePhoenixRouter.RouterE.selector, "refused by the Router's floor");
    }
}
