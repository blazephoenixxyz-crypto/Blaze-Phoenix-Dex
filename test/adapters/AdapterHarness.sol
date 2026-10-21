// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "./vendor/BlazePhoenixGateSnapshot.sol";
import {ExtAdapterBase} from "../../src/adapters/ExtAdapterBase.sol";

/// The adapters behind the real wrapper (vendored Gate snapshot). This contract plays the Router:
/// it calls `wrapper.swap` exactly as `_execV3Amt` does (recipient = itself, exact-in, data empty)
/// and pays in `uniswapV3SwapCallback` by transfer, as the Router's fallback does.
abstract contract AdapterHarness is Test {
    BlazePhoenixGate internal gate;
    MockERC20 internal t0;
    MockERC20 internal t1;

    function _tokens() internal {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        gate = new BlazePhoenixGate(address(this));
    }

    function _aerr(uint8 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ExtAdapterBase.AdapterE.selector, c);
    }

    function _gerr(uint8 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixGate.GateE.selector, c);
    }

    /// propose -> 48 h -> accept. Also proves the adapter passes the Gate's code scan.
    function _accept(uint8 f, address a) internal {
        assertTrue(gate.codeIsClean(a), "adapter refused by the Gate's scan");
        gate.proposeAdapter(f, a);
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(f);
    }

    /// Router-shaped swap; returns the output measured at this contract.
    function _swap(address w, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        (MockERC20 tIn, MockERC20 tOut) = zeroForOne ? (t0, t1) : (t1, t0);
        tIn.mint(address(this), amt);
        uint256 b = tOut.balanceOf(address(this));
        BlazePhoenixGateWrapper(w).swap(address(this), zeroForOne, int256(amt), 0, "");
        out = tOut.balanceOf(address(this)) - b;
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(msg.sender);
        if (a0 > 0) MockERC20(w.token0()).transfer(msg.sender, uint256(a0));
        else if (a1 > 0) MockERC20(w.token1()).transfer(msg.sender, uint256(a1));
    }

    /// Custody after a call: adapter and wrapper hold nothing of either token, and the adapter
    /// grants nothing to `spender`.
    function _assertEmpty(address adapter, address w, address spender) internal view {
        assertEq(t0.balanceOf(adapter), 0, "adapter t0");
        assertEq(t1.balanceOf(adapter), 0, "adapter t1");
        assertEq(t0.balanceOf(w), 0, "wrapper t0");
        assertEq(t1.balanceOf(w), 0, "wrapper t1");
        assertEq(t0.allowance(adapter, spender), 0, "allowance t0");
        assertEq(t1.allowance(adapter, spender), 0, "allowance t1");
    }

    /// PUSH custody has no approve: no PUSHn (n >= 4) in the runtime code starts with the
    /// selector of approve(address,uint256), 0x095ea7b3 (as PUSH4, or left-aligned in a PUSH32).
    function _hasApproveSelector(address a) internal view returns (bool) {
        bytes memory c = a.code;
        for (uint256 i; i < c.length; ++i) {
            uint8 op = uint8(c[i]);
            if (op >= 0x63 && op <= 0x7f && i + 4 < c.length && uint8(c[i + 1]) == 0x09
                && uint8(c[i + 2]) == 0x5e && uint8(c[i + 3]) == 0xa7 && uint8(c[i + 4]) == 0xb3) return true;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        return false;
    }
}
