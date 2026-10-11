// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  registryDepth18, concentrated arm: the depth is capped by the tokens the
//  pool holds. The cap was the short side when the pool held both and the one
//  side when it held one, so it was not monotone in holdings: one wei donated
//  to the empty side of an honest one-sided range collapsed the cap from that
//  side's whole mass to one wei (Seavia Resources). Any cap f rising in both
//  holdings with f(a,0)=a and f(0,b)=b has f(a,b) >= max(a,b); the cap is now
//  that larger side, normalised. Red at f909422.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract RegistryDepthMonotoneInHoldingsTest is Test {
    MockERC20 t0;
    MockERC20 t1;
    MockV3Pool pool;
    uint160 constant Q96 = uint160(uint256(1) << 96);

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new MockV3Pool(address(t0), address(t1), 3000);
        pool.setState(Q96, uint128(1e30)); // declared depth far above any holding here
    }

    function _depth() internal view returns (uint256) {
        return BPC.registryDepth18(address(pool), BPC.KIND_V3, address(t0), address(t1), address(0), bytes32(0));
    }

    /// RED at f909422: a one-wei donation to the empty side lowers the depth.
    function test_RegistryDepth18_OneWeiDonation_NeverLowersTheDepth() public {
        t0.mint(address(pool), 1_000_000e18);
        uint256 before = _depth();
        t1.mint(address(pool), 1);
        assertGe(_depth(), before, "registryDepth18: holding more must never read as less depth");
    }

    function testFuzz_RegistryDepth18_MonotoneInHoldings(uint96 a, uint96 extra) public {
        t0.mint(address(pool), a);
        uint256 before = _depth();
        t1.mint(address(pool), extra);
        assertGe(_depth(), before, "registryDepth18: holding more must never read as less depth");
    }
}
