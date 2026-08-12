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
    bytes32 revertKey;
    bool hasRevertKey;
    function set(bytes32 s, bytes32 v) external { slot[s] = v; }
    function setRevertKey(bytes32 s) external { revertKey = s; hasRevertKey = true; }
    function extsload(bytes32 s) external view returns (bytes32) {
        if (hasRevertKey && s == revertKey) revert("boom");
        return slot[s];
    }
}

/// @dev Malformed singleton: answers every call with 16 bytes, not a word.
contract ShortReturnV4Manager {
    fallback() external {
        assembly { return(0, 16) }
    }
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
    function _base() internal view returns (bytes32) {
        (address s0, address s1) = BPC.sortTokens(tokenA, tokenB);
        bytes32 pid = BPC.computeV4PoolId(s0, s1, DYN, TS, address(0));
        return keccak256(abi.encode(pid, uint256(6)));
    }

    function _seed(uint24 lpFee, uint24 protoFee, uint160 sqrtP, uint128 liq) internal {
        bytes32 base = _base();
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

    // ---- guards added by the INV-20 security review ----

    function test_CodelessManager_QuotesZero() public {
        QuoteCtx memory c = _ctx();
        c.v4Manager = address(0xDEAD); // no code: staticcall succeeds, empty returndata
        (uint256 out, ) = BPC.universalQuote(c, 1e18);
        assertEq(out, 0, "codeless manager must fail closed, not quote garbage");
    }

    function test_ShortReturnManager_QuotesZero() public {
        QuoteCtx memory c = _ctx();
        c.v4Manager = address(new ShortReturnV4Manager());
        (uint256 out, ) = BPC.universalQuote(c, 1e18);
        assertEq(out, 0, "sub-word returndata must fail closed");
    }

    function test_SecondSlotReverting_QuotesZero() public {
        _seed(3000, 0, uint160(uint256(2) ** 96), uint128(1e21));
        mgr.setRevertKey(bytes32(uint256(_base()) + 3)); // liquidity read reverts
        (uint256 out, ) = BPC.universalQuote(_ctx(), 1e18);
        assertEq(out, 0, "partial state (slot0 ok, liquidity revert) must fail closed");
    }

    function test_TickAndDirtyHighBits_DoNotLeakIntoFees() public {
        _seed(3000, 0, uint160(uint256(2) ** 96), uint128(1e21));
        (uint256 clean, ) = BPC.universalQuote(_ctx(), 1e18);
        // same pool, but tick = -1 (bits [160,184) all ones) and dirty spare bits
        bytes32 word0 = bytes32(
            uint256(uint160(uint256(2) ** 96))
                | (uint256(0xFFFFFF) << 160)  // tick int24 = -1
                | (uint256(3000) << 208)      // lpFee unchanged
                | (uint256(0xABCDEF) << 232)  // dirty [232,256) spare bits
        );
        mgr.set(_base(), word0);
        (uint256 dirty, ) = BPC.universalQuote(_ctx(), 1e18);
        assertGt(clean, 0, "baseline must quote");
        assertEq(dirty, clean, "tick/spare bits must not alias into lpFee/protoFee");
    }
}
