// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE REPORTED ORIENTATION OF A NATIVE V4 POOL IS THE CONTRACTED ONE.
//
// `Hub._readPoolInfo` returns a native V4 pool with token0 = the wrapped-native side, which is
// what the Solver and the Quoter assume when they derive the key from `zeroForOne`. The registry
// index stays sorted by address; only the REPORTED pair is reoriented, from the pool's entry:
//     src/BlazePhoenixHub.sol   p.token0 = e0.currency1 == t0 ? t1 : t0;
// FALSIFIED BY: that line -> `p.token0 = t0;` turns the first test red. The second test is the
// "nothing to reorient" control (WETH already sorts first), the third the "another kind is not
// reoriented" control.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// Minimal Router: the Hub only asks it for the canonical WETH (same shape as
/// test/V4NativeRegistration.t.sol).
contract WethStub {
    address public weth;
    constructor(address w) { weth = w; }
}

contract V4NativeReportedOrientationIsRestoredTest is Test {
    /// The same currencies as the suite's fixture: USDC 0x05DC < WETH 0xEEEE, so WETH sorts
    /// SECOND and the reported pair must be reoriented.
    address constant WETH_HIGH = address(0xEEEE);
    address constant USDC = address(0x05DC);
    /// WETH below USDC: WETH is already token0, nothing to reorient.
    address constant WETH_LOW = address(0x0101);
    uint24 constant FEE = 500;
    int24 constant TS = 10;

    function _hubWith(address weth) internal returns (BlazePhoenixHub hub) {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0x4444));
        hub.setRoles(address(new WethStub(weth)), address(this), address(this));
    }

    /// Non-vacuity premise: in this fixture WETH is NOT the sorted token0. Without it an
    /// orientation assertion would pass with the reorientation on or off.
    function test_WethSortingSecond_TheReportedOrientationIsTheContract() public {
        BlazePhoenixHub hub = _hubWith(WETH_HIGH);
        (address s0, ) = BPC.sortTokens(WETH_HIGH, USDC);
        assertEq(s0, USDC, "premise: USDC sorts first");
        assertTrue(s0 != WETH_HIGH, "non-vacuity premise: WETH is NOT the sorted token0");

        hub.addV4(address(0), USDC, FEE, TS, address(0));
        PoolInfo[] memory out = hub.getActivePools(WETH_HIGH, USDC);
        assertEq(out.length, 1, "premise: the native pool is registered under WETH/USDC");
        assertEq(out[0].kind, BPC.KIND_V4_NATIVE, "premise: it is native");

        assertEq(out[0].token0, WETH_HIGH, "the reported token0 must be the WETH side");
        assertEq(out[0].token1, USDC, "and token1 the other side");
        assertTrue(out[0].token0 != s0, "the reorientation must act: the reported pair is not the index order");
    }

    /// CONTROL: with WETH already the sorted token0 there is nothing to reorient; the reported
    /// pair is the sorted one.
    function test_WethSortingFirst_NothingIsCorrected() public {
        BlazePhoenixHub hub = _hubWith(WETH_LOW);
        (address s0, ) = BPC.sortTokens(WETH_LOW, USDC);
        assertEq(s0, WETH_LOW, "premise: this WETH is itself the sorted token0");

        hub.addV4(address(0), USDC, FEE, TS, address(0));
        PoolInfo[] memory out = hub.getActivePools(WETH_LOW, USDC);
        assertEq(out.length, 1, "premise: registered under the pair");
        assertEq(out[0].token0, s0, "without reorientation the reported pair IS the index order");
        assertEq(out[0].token1, USDC, "and token1 the other side");
    }

    /// CONTROL the other way: the SAME two addresses in a NON-native pool are not reoriented.
    /// Without it, a change that always reoriented, whatever the kind, would pass the first test.
    function test_NonNativePoolWithTheSameAddresses_IsNotCorrected() public {
        BlazePhoenixHub hub = _hubWith(WETH_HIGH);
        hub.addV4(USDC, WETH_HIGH, FEE, TS, address(0));
        PoolInfo[] memory out = hub.getActivePools(WETH_HIGH, USDC);
        assertEq(out.length, 1, "premise: registered");
        assertTrue(out[0].kind != BPC.KIND_V4_NATIVE, "premise: this one is NOT native");
        assertEq(out[0].token0, USDC, "not native, not reoriented: token0 is the sorted one");
    }
}
