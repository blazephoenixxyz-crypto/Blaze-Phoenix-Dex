// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Router fallback's calldata-length gate, pinned at its exact threshold.
//
//      fallback() external payable {
//          if (msg.value > 0) revert RouterE(3);
//          if (msg.data.length < 4 + 64) revert RouterE(3);
//          ... calldataload(4), calldataload(36) ... _v3Callback(a0, a1);
//      }
//
//  A real `uniswapV3SwapCallback(int256,int256,bytes)` always carries the
//  `bytes` tail, so ordinary swaps reach this gate from far above the
//  threshold. These tests approach it from below. The two outcomes carry
//  different codes: under 68 bytes the length gate refuses with RouterE(3); at
//  exactly 68 the call passes the gate and the callback authentication refuses
//  it with RouterE(6) (no swap in flight, so no expected caller). Asserting the
//  code at 67 and 68 fixes both the threshold and the side of the comparison.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";

contract FallbackCalldataLengthGateTest is Test {
    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;

    /// @dev The fallback never reads the selector.
    bytes4 internal constant ANY_SELECTOR = 0x12345678;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this),
            address(0xFEE1), address(0xFEE2)
        );
    }

    /// @dev Calldata of the requested length: a 4-byte selector, then zeros.
    function _calldata(uint256 len) internal pure returns (bytes memory cd) {
        require(len >= 4, "shorter than a selector");
        cd = new bytes(len);
        cd[0] = ANY_SELECTOR[0];
        cd[1] = ANY_SELECTOR[1];
        cd[2] = ANY_SELECTOR[2];
        cd[3] = ANY_SELECTOR[3];
    }

    /// @dev Calls the fallback and returns the RouterE code it refused with
    ///      (0 means it accepted, which none of these cases may do).
    function _routerCode(bytes memory cd) internal returns (uint16 code) {
        (bool ok, bytes memory ret) = address(router).call(cd);
        if (ok) return 0;
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector,
            "the refusal must be RouterE, not a panic and not a fall-through");
        code = abi.decode(_tail(ret), (uint16));
    }

    function _tail(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = b[i + 4];
    }

    /// @notice 68 bytes passes the length gate and is refused by the callback
    ///         authentication.
    function test_ExactlyTheMinimumLengthReachesTheCallbackAuth() public {
        bytes memory cd = _calldata(4 + 64);
        assertEq(cd.length, 68, "precondition: exactly 4 + 64");
        assertEq(_routerCode(cd), 6,
            "68 bytes must pass the length gate and stop at the callback auth (RouterE(6))");
    }

    /// @notice 67 bytes is refused by the length gate itself.
    function test_OneByteShortOfTheMinimumIsRefusedByTheLengthGate() public {
        bytes memory cd = _calldata(4 + 63);
        assertEq(cd.length, 67, "precondition: exactly 4 + 63");
        assertEq(_routerCode(cd), 3,
            "67 bytes is short of the minimum and must stop at the length gate (RouterE(3))");
    }

    /// @notice Control: a plainly short calldata is refused with the same code.
    function test_PlainlyShortCalldataIsRefusedByTheLengthGate() public {
        assertEq(_routerCode(_calldata(44)), 3,
            "a plainly short calldata must stop at the length gate (RouterE(3))");
    }
}
