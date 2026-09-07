// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The in-frame PROMISE for a V4 leg is bounded at the current range's edge.
//  Measured before this test (main 8949a9d): `sqrtBoundary` was defined in the
//  Core and called by nothing — Router._v4LegQuote priced every V4 leg with the
//  unclamped single-tick form, so a leg that left its range promised more than
//  the range could deliver and the floor, derived from that promise, followed.
//  `BlazePhoenixCore.v4LegOut` is the wired form: slot0 + liquidity from the
//  singleton, the fee in the swap's direction, and `outV3` truncated at
//  `sqrtBoundary`. This test is red on the unwired code (the function does not
//  exist there) and stays red on the mutant that passes 0 as the limit.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract MockV4ManagerTicked {
    mapping(bytes32 => bytes32) public slot;
    function set(bytes32 s, bytes32 v) external { slot[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slot[s]; }
}

contract V4PromiseBoundTest is Test {
    int24 constant TS = int24(60);
    MockV4ManagerTicked mgr;
    address tokenA = address(0xA11);
    address tokenB = address(0xB22);
    bytes32 pid;

    function setUp() public {
        mgr = new MockV4ManagerTicked();
        (address s0, address s1) = BPC.sortTokens(tokenA, tokenB);
        pid = BPC.computeV4PoolId(s0, s1, 3000, TS, address(0));
    }

    /// @dev slot0 = sqrtPriceX96 | tick<<160 | protocolFee<<184 | lpFee<<208; liquidity at +3.
    function _seed(uint160 sqrtP, int24 tick, uint24 protoFee, uint24 lpFee, uint128 liq) internal {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        bytes32 word0 = bytes32(
            uint256(sqrtP) | (uint256(uint24(tick)) << 160) | (uint256(protoFee) << 184) | (uint256(lpFee) << 208)
        );
        mgr.set(base, word0);
        mgr.set(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    function test_RangeExit_PromiseIsTruncatedAtTheBoundary() public {
        // tick 59 of a 60-spaced pool, price 1, thin liquidity, a swap that would
        // push the price far below the range's lower edge.
        uint160 P = uint160(BPC.Q96);
        _seed(P, int24(59), 0, 3000, uint128(1e18));
        uint256 amt = 1e21;
        uint256 bounded   = BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, true);
        uint256 unclamped = BPC.outV3(amt, P, uint128(1e18), 3000, true, 0);
        uint256 expected  = BPC.outV3(amt, P, uint128(1e18), 3000, true, BPC.sqrtBoundary(P, int24(59), TS, true));
        assertEq(bounded, expected, "promise must be the boundary-truncated single-tick output");
        assertLt(bounded, unclamped, "a leg that leaves its range promises strictly less than the unclamped form");
        assertGt(bounded, 0, "and still a positive promise for what fits inside the range");
    }

    function test_InsideRange_PromiseEqualsSingleTickForm() public {
        // a small swap deep inside the range: the clamp does not bind
        uint160 P = uint160(BPC.Q96);
        _seed(P, int24(30), 0, 3000, uint128(1e24));
        uint256 amt = 1e18;
        assertEq(BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, true), BPC.outV3(amt, P, uint128(1e24), 3000, true, 0));
    }

    function test_StaticKey_ProtocolFee_ReachesThePromise() public {
        // the same pool with a 5-pip zeroForOne protocol fee promises less than without it
        uint160 P = uint160(BPC.Q96);
        _seed(P, int24(30), 0, 3000, uint128(1e24));
        uint256 without = BPC.v4LegOut(address(mgr), pid, 1e18, 3000, TS, true);
        _seed(P, int24(30), 5, 3000, uint128(1e24));
        uint256 withFee = BPC.v4LegOut(address(mgr), pid, 1e18, 3000, TS, true);
        assertLt(withFee, without, "a protocol fee on a static key lowers the promise");
        assertEq(withFee, BPC.outV3(1e18, P, uint128(1e24), 3005, true, 0), "by exactly the composed fee");
    }

    function test_EmptyPool_PromisesZero() public view {
        assertEq(BPC.v4LegOut(address(mgr), pid, 1e18, 3000, TS, true), 0);
    }
}
