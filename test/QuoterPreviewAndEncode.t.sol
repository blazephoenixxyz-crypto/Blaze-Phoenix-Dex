// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter, IRouterExec} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice `previewAndEncode`: one call returns the preview AND the calldata that executes it.
///
///         These tests do not compare the bytes to the code that produced them - that would pass
///         on any encoding at all. They SUBMIT the bytes to the Router and check what settles, they
///         compare them to an independently hand-built encoding, and they decode them back to
///         confirm the floor the preview promised is the floor the transaction carries.
contract QuoterPreviewAndEncodeTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA; MockERC20 tB; MockERC20 tC;
    MockV2Pair pair;
    address user = address(0xBEEF);
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));

        tA = new MockERC20("A", "A"); tB = new MockERC20("B", "B"); tC = new MockERC20("C", "C");
        pair = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(pair), 1_000_000e18); tB.mint(address(pair), 1_000_000e18);
        pair.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));

        // Seed the registry through the router role, then hand the role to the real Router.
        hub.setRoles(address(this), address(solver), address(quoter));
        for (uint256 i; i < 5; ++i) {
            hub.recordSwap(address(pair), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, 1_000_000e18);
        }
        hub.setRoles(address(router), address(solver), address(quoter));

        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    /// @dev Calldata-slicing helper: decode the argument tuple behind the 4-byte selector.
    function decodeArgs(bytes calldata data) external pure
        returns (Route memory r, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
    {
        return abi.decode(data[4:], (Route, uint256, uint256, address, uint256));
    }

    /// @notice The bytes are canonical, they execute, and they settle at or above the floor
    ///         the preview promised.
    function test_TheEncodedBytesSettleAtOrAboveThePreviewedFloor() public {
        uint256 deadline = block.timestamp + 1;
        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            quoter.previewAndEncode(address(tA), address(tB), AMT, user, deadline);

        assertTrue(pv.canExecute, "premise: the Solver must find an executable route");
        assertGt(call.length, 4, "premise: bytes were produced");
        assertEq(bytes4(call), IRouterExec.swapExactIn.selector, "the selector is swapExactIn's");

        // Independent encoding of the same arguments: the bytes must match to the byte.
        bytes memory byHand = abi.encodeCall(IRouterExec.swapExactIn,
            (pv.route, AMT, pv.effectiveMinOut, user, deadline));
        assertEq(keccak256(call), keccak256(byHand), "the encoding must be the canonical one");

        // And they execute - which is the only test of calldata that means anything.
        uint256 before = tB.balanceOf(user);
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(call);
        assertTrue(ok, "the encoded transaction must settle");
        uint256 got = abi.decode(ret, (uint256));
        assertGe(got, pv.effectiveMinOut, "delivered at or above the floor the preview promised");
        assertEq(tB.balanceOf(user) - before, got, "and the user really received it");
    }

    /// @notice A pair with no route does not encode a doomed transaction: the Solver refuses
    ///         fail-closed with `SolverE(5)` before any bytes exist, and that refusal propagates.
    ///         Nothing to submit is the correct answer, and it arrives as a revert rather than as
    ///         empty bytes a caller might overlook.
    function test_AnUnroutablePairRefusesBeforeAnyBytesExist() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        quoter.previewAndEncode(address(tA), address(tC), AMT, user, block.timestamp + 1);
    }

    /// @notice A caller-tightened floor travels INSIDE the bytes: decoded back, the minOut the
    ///         transaction carries is the tightened one, and it is still the protocol's floor
    ///         when the caller's is looser.
    function test_TheTightenedFloorTravelsInsideTheBytes() public {
        uint256 deadline = block.timestamp + 1;
        (BlazePhoenixQuoter.Preview memory pv0, ) =
            quoter.previewAndEncode(address(tA), address(tB), AMT, user, deadline);
        uint256 tighter = pv0.ironFloor + 1;

        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            quoter.previewAndEncodeWithMinOut(address(tA), address(tB), AMT, tighter, user, deadline);
        assertEq(pv.effectiveMinOut, tighter, "the caller may tighten the floor");
        (, uint256 amountIn, uint256 minOut, address to, uint256 dl) = this.decodeArgs(call);
        assertEq(minOut, tighter, "and the tightened floor is what the bytes carry");
        assertEq(amountIn, AMT); assertEq(to, user); assertEq(dl, deadline);

        // Looser than the protocol's floor is ignored: the bytes still carry the protocol's.
        (BlazePhoenixQuoter.Preview memory pv2, bytes memory call2) =
            quoter.previewAndEncodeWithMinOut(address(tA), address(tB), AMT, 1, user, deadline);
        (, , uint256 minOut2, , ) = this.decodeArgs(call2);
        assertEq(minOut2, pv2.ironFloor, "a looser caller floor never weakens the encoded one");
    }
}
