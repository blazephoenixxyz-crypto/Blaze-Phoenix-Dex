// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  EXECUTIONPROOF PUBLISHES THE FLOOR IN THE UNITS OF WHAT WAS DELIVERED.
//
//  The protocol floor is checked against `amountOut`, the Router's own balance
//  delta, before any output-side cut. `realized` is measured at the recipient,
//  after it. Red at f909422: for a tokenOut that taxes transfers, the proof
//  published `floorUsed` in the first unit and `realized` in the second, so a
//  correct settlement emitted floorUsed > realized, a proof that the floor was
//  not met (thomas, bug bounty). The floor is now published net of the tax, by
//  the ratio delivered / amount sent measured at the recipient: the identity on
//  an untaxed token, so the published floor stays the one the Solver attests
//  (FloorParitySolverRouter), and never above `realized` on a taxed one. The
//  check itself, and every revert, are unchanged.
//
//  Quantity: ExecutionProof.floorUsed against ExecutionProof.realized.
//  Oracle: the recipient's balance and the event's own `realized`.
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ExecutionProofFloorInDeliveredUnitsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;
    address user = address(0xBEEF);

    uint256 constant AMT = 1_000e18;
    uint256 constant RES = 10_000e18;
    uint256 constant HARD_FLOOR_BPS = BPC.BPS - BPC.FLOOR_HARD_MAX_LOSS_BPS;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        tokenIn.mint(address(pair), RES);
        tokenOut.mint(address(pair), RES);
        pair.setReserves(uint112(RES), uint112(RES));
        tokenIn.mint(user, 10 * AMT);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _route() private view returns (Route memory r) {
        uint256 netIn = AMT - BPC.mulDivUp(AMT, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 q = BPC.outV2(netIn, RES, RES, 30);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tokenIn) < address(tokenOut), stable: false, amountIn: AMT, expectedOut: q,
            auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenIn), tokenOut: address(tokenOut), amountIn: AMT, expectedOut: q, legs: legs});
        r = Route({hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _proof() private returns (uint256 quoted, uint256 realized, uint256 floorUsed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) {
                (quoted, realized, floorUsed,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
    }

    function _swap() private returns (uint256 out, uint256 got) {
        Route memory r = _route();
        uint256 before = tokenOut.balanceOf(user);
        vm.recordLogs();
        vm.prank(user);
        out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        got = tokenOut.balanceOf(user) - before;
    }

    /// RED at f909422: a 9% output tax settles correctly and the proof says
    /// the floor was not met. The tax is paid twice on the way out (pair to
    /// Router, Router to recipient), so the checked amount clears the floor and
    /// the delivered one lands below it. (At 3% both clear it, which is why the
    /// fuzz below, not this case, is the property.)
    function test_TaxedTokenOut_ExecutionProof_FloorUsedNeverAboveRealized() public {
        tokenOut.setFeeOnTransferBps(900);
        (uint256 out, uint256 got) = _swap();
        (, uint256 realized, uint256 floorUsed) = _proof();
        assertEq(realized, got, "realized is what the recipient received");
        assertEq(out, got, "the return value is what the recipient received");
        assertGt(floorUsed, 0, "the floor is published");
        assertLe(floorUsed, realized, "a settled swap must publish a floor it met");
    }

    /// Fuzz the tax: every settlement publishes a floor at or below what it
    /// delivered, and the published floor shrinks with the delivered amount
    /// rather than vanishing. Taxes too large for the floor still revert on it.
    function testFuzz_TaxedTokenOut_ExecutionProof_FloorUsedNeverAboveRealized(uint16 taxBps) public {
        taxBps = uint16(bound(taxBps, 1, 3_000));
        tokenOut.setFeeOnTransferBps(taxBps);
        Route memory r = _route();
        uint256 before = tokenOut.balanceOf(user);
        vm.recordLogs();
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256) {
            uint256 got = tokenOut.balanceOf(user) - before;
            (uint256 quoted, uint256 realized, uint256 floorUsed) = _proof();
            assertEq(realized, got, "realized is what the recipient received");
            assertLe(floorUsed, realized, "a settled swap must publish a floor it met");
            // Delivered is the post-check amount taxed once more, so the
            // published floor is at least the hard floor of the quote, taxed once.
            uint256 lower = BPC.mulDiv(BPC.mulDiv(quoted, HARD_FLOOR_BPS, BPC.BPS), BPC.BPS - taxBps, BPC.BPS);
            assertGe(floorUsed + 1, lower, "the published floor must not collapse");
        } catch (bytes memory err) {
            assertEq(keccak256(err), keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5))),
                "a refusal must be the floor's");
        }
    }

    /// The neighbouring untaxed route: nothing is cut after the check, so the
    /// published floor is the checked floor, met by the delivery.
    function test_UntaxedTokenOut_ExecutionProof_FloorIsTheCheckedFloor() public {
        (uint256 out, uint256 got) = _swap();
        (uint256 quoted, uint256 realized, uint256 floorUsed) = _proof();
        assertEq(out, got, "untaxed: returned == received");
        assertEq(realized, got, "untaxed: realized == received");
        assertGe(floorUsed, BPC.mulDivUp(quoted, HARD_FLOOR_BPS, BPC.BPS), "the floor is armed at least at the hard floor");
        assertLe(floorUsed, realized, "and met");
    }
}
