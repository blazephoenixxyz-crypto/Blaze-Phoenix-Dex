// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  forceApprove — USDT-safe approvals. A USDT-family token reverts approve()
//  when going non-zero -> non-zero, so a residual per-leg allowance (left by
//  a partial/fee-on-transfer pull) would brick every later swap through that
//  leg. forceApprove tries the direct approval first (cheap common case) and
//  falls back to reset-to-zero-then-set only when the token refuses.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev USDT-style: approve reverts on non-zero -> non-zero, returns nothing.
contract MockUSDTStyle {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amt) external {
        require(amt == 0 || allowance[msg.sender][spender] == 0, "USDT: reset first");
        allowance[msg.sender][spender] = amt;
        // returns nothing, like real USDT
    }
}

/// @dev A token that signals refusal with an explicit `false` instead of a
///      revert — forceApprove must treat that as failure and take the reset path.
contract MockFalseReturnToken {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amt) external returns (bool) {
        if (amt != 0 && allowance[msg.sender][spender] != 0) return false;
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

contract CoreForceApproveTest is Test {
    address constant SPENDER = address(0xCAFE);

    function test_ForceApprove_PlainToken_SingleCall() public {
        MockERC20 t = new MockERC20("T", "T");
        BPC.forceApprove(address(t), SPENDER, 100e18);
        assertEq(t.allowance(address(this), SPENDER), 100e18);
        // Overwrite without reset — plain ERC20 allows it.
        BPC.forceApprove(address(t), SPENDER, 55e18);
        assertEq(t.allowance(address(this), SPENDER), 55e18);
    }

    function test_ForceApprove_USDTStyle_ResetPathOnResidual() public {
        MockUSDTStyle t = new MockUSDTStyle();
        // Fresh: direct approval works.
        BPC.forceApprove(address(t), SPENDER, 100e18);
        assertEq(t.allowance(address(this), SPENDER), 100e18);
        // Residual allowance present: direct approve REVERTS inside the token;
        // forceApprove must recover via reset-to-zero and land the new value.
        BPC.forceApprove(address(t), SPENDER, 77e18);
        assertEq(t.allowance(address(this), SPENDER), 77e18);
    }

    function test_ForceApprove_FalseReturningToken_ResetPath() public {
        MockFalseReturnToken t = new MockFalseReturnToken();
        BPC.forceApprove(address(t), SPENDER, 100e18);
        assertEq(t.allowance(address(this), SPENDER), 100e18);
        // Token signals `false` (no revert) on non-zero -> non-zero: must
        // still be detected as failure and recovered via the reset path.
        BPC.forceApprove(address(t), SPENDER, 33e18);
        assertEq(t.allowance(address(this), SPENDER), 33e18);
    }
}
