// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  INV-20 end-to-end. A dynamic-fee V4 pool (key fee = 0x800000) is now priced
//  from slot0's real lpFee via universalQuote, instead of the sentinel tripping
//  outV3's fee>=1e6 guard and returning 0. A non-zero protocolFee fails closed.
//  The mock answers extsload(bytes32) from a settable slot map, so the whole
//  v4SqrtAndLiq -> effV4Fee -> outV3 path is exercised with no live chain.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../src/BlazePhoenixCore.sol";

/// @dev Minimal Uniswap-V4-shaped singleton: extsload(bytes32) reads a map.
contract MockV4Manager {
    mapping(bytes32 => bytes32) public slot;
    function set(bytes32 s, bytes32 v) external { slot[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slot[s]; }
}

contract V4DynamicFeeQuoteTest is Test {
    uint24 constant DYN = 0x800000;
    int24  constant TS  = int24(60);

    MockV4Manager mgr;
    address tokenA = address(0xA11);
    address tokenB = address(0xB22);

    function setUp() public { mgr = new MockV4Manager(); }

    /// @dev Craft slot0 (sqrtPriceX96 | protocolFee<<184 | lpFee<<208) and
    ///      liquidity (word3) at the exact slots v4SqrtAndLiq reads.
    function _seed(uint24 lpFee, uint24 protoFee, uint160 sqrtP, uint128 liq) internal {
        (address s0, address s1) = BPC.sortTokens(tokenA, tokenB);
        bytes32 pid  = BPC.computeV4PoolId(s0, s1, DYN, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        bytes32 word0 = bytes32(
            uint256(sqrtP) | (uint256(protoFee) << 184) | (uint256(lpFee) << 208)
        );
        mgr.set(base, word0);
        mgr.set(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    function _ctx() internal view returns (QuoteCtx memory c) {
        c.kind        = BPC.KIND_V4;
        c.zeroForOne  = true;
        c.fee         = DYN;
        c.tickSpacing = TS;
        c.tokenIn     = tokenA;
        c.tokenOther  = tokenB;
        c.hooks       = address(0);
        c.v4Manager   = address(mgr);
    }

    function test_DynamicFeePool_NowQuotesNonZero() public {
        _seed(3000, 0, uint160(uint256(2) ** 96), uint128(1e21)); // price 1, deep, 0.3%
        (uint256 out, ) = BPC.universalQuote(_ctx(), 1e18);
        assertGt(out, 0, "dynamic-fee V4 pool must quote non-zero after INV-20");
    }

    function test_DynamicFeePool_WithProtocolFee_FailsClosed() public {
        _seed(3000, 1, uint160(uint256(2) ** 96), uint128(1e21));
        (uint256 out, ) = BPC.universalQuote(_ctx(), 1e18);
        assertEq(out, 0, "non-zero protocolFee must fail closed");
    }

    function test_EmptyPool_QuotesZero() public {
        (uint256 out, ) = BPC.universalQuote(_ctx(), 1e18); // unseeded slot0 = 0
        assertEq(out, 0, "empty pool quotes zero");
    }
}
