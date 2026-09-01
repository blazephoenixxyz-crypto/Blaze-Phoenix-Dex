// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

/// @notice Thin external wrapper around BlazePhoenixCore's internal library
///         functions, so tests can call them directly (a library's internal
///         functions are inlined into callers, not independently callable
///         from a test contract without something like this).
contract CoreHarness {
    function safeTransfer(address token, address to, uint256 amt) external {
        BPC.safeTransfer(token, to, amt);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amt) external {
        BPC.safeTransferFrom(token, from, to, amt);
    }

    function safeApprove(address token, address spender, uint256 amt) external {
        BPC.safeApprove(token, spender, amt);
    }

    function balanceOf(address token, address who) external view returns (uint256) {
        return BPC.balanceOf(token, who);
    }

    /// The stable-curve solver, exposed so a test can observe whether an
    /// admitted pool QUOTES or REVERTS. `outSolidlyStable` is internal, and an
    /// inlined revert is invisible to vm.expectRevert.
    function outSolidlyStable(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, uint8 dIn, uint8 dOut
    ) external pure returns (uint256) {
        return BPC.outSolidlyStable(ain, rIn, rOut, fee, dIn, dOut);
    }
}
