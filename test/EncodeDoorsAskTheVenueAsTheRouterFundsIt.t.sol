// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// 3336 (Ash). The encode doors return the bytes of a `swapExactIn` with `effectiveMinOut` inside
// them, and empty bytes when the preview already knows the call will not settle. Their
// `canExecute` was the plan preview's: `_pack` takes the protocol fee off the route's gross
// output, but on a route whose output is not a bridge the Router takes it off the INPUT
// (`Router._execute`), and a venue's output is an integer step function of its input. On a deep
// V3 pool one step is worth more than the fee, so the venue funded as the Router funds it pays
// a step less than the estimate: the report's counterexample (1013 in, a caller's floor of
// 1000) previewed netOut 1006 and encoded bytes the Router refused with RouterE(5) for a
// delivery of 997 (reports/plano-1026/pocs/3336.log). The exact door has asked the venue as the
// Router funds it since 1f1c4bf (`_fundedOut`); the encode doors never did. The iron floor is
// not at stake (965 here): only a floor the caller tightened into the gap.
//
// The fixture is the report's: one V3 pool at 1 bp, price 1, liquidity 1e30, whose output moves
// in steps of L / 2^96 (about 12.6 wei), and no bridge, so the Router charges the input.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract EncodeDoorsAskTheVenueAsTheRouterFundsItTest is Test {
    uint256 constant AMT = 1013;      // the report's counterexample
    uint256 constant USER_MIN = 1000; // a floor between the delivery and the estimate

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    MockV3Pool pool;
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        pool = new MockV3Pool(address(tA), address(tB), 100);
        pool.setState(uint160(BPC.Q96), 1e30);
        tB.mint(address(pool), 1e30);
        hub.seedPool(address(pool), BPC.KIND_V3, 100, address(0), address(tA), address(tB));
    }

    /// The encoded bytes, submitted to the Router as returned.
    function _submit(uint256 amt, bytes memory data) internal returns (bool ok, bytes memory ret, uint256 out) {
        tA.mint(address(this), amt);
        tA.approve(address(router), amt);
        (ok, ret) = address(router).call(data);
        if (ok) out = abi.decode(ret, (uint256));
    }

    /// @notice The report's counterexample: a floor the venue cannot meet as the Router funds the
    ///         route is not encoded, however the estimate reads.
    function test_AFloorTheVenueCannotMeetAsFundedIsNotEncoded() public {
        assertFalse(hub.isBridgeToken(address(tB)), "premise: no bridge, so the Router charges the input");
        (BlazePhoenixQuoter.Preview memory est, , ) = quoter.previewPlan(address(tA), address(tB), AMT);
        (, uint256 exactOut) = quoter.previewPlanExact(address(tA), address(tB), AMT);
        assertLt(exactOut, USER_MIN, "premise: the venue, funded as the Router funds it, pays under the floor");
        assertGe(est.netOut, USER_MIN, "premise: the estimate clears the floor");

        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = quoter.previewAndEncodeWithMinOut(
            address(tA), address(tB), AMT, USER_MIN, recipient, block.timestamp + 1);
        if (data.length != 0) {
            (bool ok, bytes memory ret, uint256 out) = _submit(AMT, data);
            assertTrue(ok, string.concat("bytes the Router refuses: ", vm.toString(ret)));
            assertGe(out, pv.effectiveMinOut, "bytes that settle under the floor they carry");
        }
        assertFalse(pv.canExecute, "a floor the venue cannot meet as funded is not executable");
        assertEq(data.length, 0, "and has no bytes");
    }

    /// @notice Control: the floor the venue meets as funded is encoded and the bytes settle at it.
    function test_Control_AFloorTheVenueMeetsIsEncodedAndSettles() public {
        (, uint256 exactOut) = quoter.previewPlanExact(address(tA), address(tB), AMT);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = quoter.previewAndEncodeWithMinOut(
            address(tA), address(tB), AMT, exactOut, recipient, block.timestamp + 1);
        assertTrue(pv.canExecute, "the venue meets exactOut");
        (bool ok, , uint256 out) = _submit(AMT, data);
        assertTrue(ok, "the bytes settle");
        assertGe(out, pv.effectiveMinOut, "at the floor they carry");
    }

    /// @notice Control: with no floor of the caller's, the iron floor is encoded and settles.
    function test_Control_TheIronFloorAloneIsEncodedAndSettles() public {
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) =
            quoter.previewAndEncode(address(tA), address(tB), AMT, recipient, block.timestamp + 1);
        assertTrue(pv.canExecute, "the iron floor is met");
        (bool ok, , uint256 out) = _submit(AMT, data);
        assertTrue(ok, "the bytes settle");
        assertGe(out, pv.effectiveMinOut, "at the floor they carry");
    }

    /// @notice Any amount, any floor near the estimate: bytes exist only where the Router settles
    ///         them at the floor they carry.
    function testFuzz_EncodedBytesSettleAtTheirFloor(uint256 amtSeed, uint256 offSeed) public {
        uint256 amt = bound(amtSeed, 1_000, 1e9);
        (BlazePhoenixQuoter.Preview memory est, , ) = quoter.previewPlan(address(tA), address(tB), amt);
        assertGt(est.netOut, 0, "premise: the amount is routed");
        uint256 userMin = est.netOut - bound(offSeed, 0, est.netOut < 32 ? est.netOut : 32);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = quoter.previewAndEncodeWithMinOut(
            address(tA), address(tB), amt, userMin, recipient, block.timestamp + 1);
        if (data.length == 0) {
            assertFalse(pv.canExecute, "no bytes, no execution");
            return;
        }
        (bool ok, bytes memory ret, uint256 out) = _submit(amt, data);
        assertTrue(ok, string.concat("bytes the Router refuses: ", vm.toString(ret)));
        assertGe(out, pv.effectiveMinOut, "bytes that settle under the floor they carry");
    }
}
