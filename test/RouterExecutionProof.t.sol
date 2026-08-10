// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ExecutionProof — the per-swap, on-chain, oracle-free execution-quality
//  artifact: (quoted, realized, floorUsed, block). Anyone can audit
//  realized-vs-quoted from the event stream alone; this is the protocol's
//  core promise made verifiable. Harness mirrors test/BlazePhoenixRouter.t.sol.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RouterExecutionProofTest is Test {
    event ExecutionProof(
        address indexed user, address indexed tokenOut,
        uint256 quoted, uint256 realized, uint256 floorUsed, uint256 blockNumber
    );

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );

        tokenIn.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);

        tokenIn.mint(user, 3_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _buildRoute(uint256 amountIn, uint256 claimedTotalOut) private view returns (Route memory route) {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: amountIn, expectedOut: claimedTotalOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: claimedTotalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedTotalOut, singleOut: claimedTotalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @notice Every successful swap emits the proof with the in-frame V2
    ///         quote as `quoted`, the delivered amount as `realized`, a
    ///         non-zero floor below the quote, and the current block.
    function test_ExecutionProof_EmittedWithQuoteRealizedFloor() public {
        uint256 amountIn = 1_000e18;
        uint256 realQuote = BPC.outV2(amountIn, 10_000e18, 10_000e18, 30);
        Route memory route = _buildRoute(amountIn, realQuote);

        // Check indexed topics + that the event fires; data fields asserted below.
        vm.recordLogs();
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), user, "user topic");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(tokenOut), "tokenOut topic");
            (uint256 quoted, uint256 realized, uint256 floorUsed, uint256 blk) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(quoted, realQuote, "quoted == in-frame on-chain quote");
            assertEq(realized, delivered, "realized == delivered");
            assertGt(floorUsed, 0, "floor recorded");
            assertLe(floorUsed, quoted, "floor is a fraction of the quote");
            assertEq(blk, block.number, "block stamped");
        }
        assertTrue(found, "ExecutionProof must be emitted on every successful swap");
    }
}
