// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  depthWad - the COMPOSITION the registry ranks on, down to the bucket.
//
//  DepthUnitParity covers the primitive (`depthFromL`), and
//  DepthFromL18UnequalDecimals the normaliser. This pins the chain the registry
//  actually uses: `registryDepth18` reads decimalsOf(t0) and decimalsOf(t1) and
//  takes `shortSide18` on the reserves arm. The law it holds is the one a defect
//  already escaped through once: normalise BEFORE the min, or a USDC(6)/WETH(18)
//  pair picks the side with fewer UNITS instead of the physically shallower one.
//
//  Every fixture makes the SHORT side the one whose decimals vary, so a producer
//  that skipped the normalisation would land in another bucket - the tests can fail.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";

contract RegistryDepthCompositionTest is Test {
    /// @dev A V2 pair of a `d0`-decimal token holding r0 and an 18-decimal token holding r1,
    ///      returned with the tokens in the pool's own order, as the producer expects them.
    function _pair(uint8 d0, uint112 r0, uint112 r1)
        private returns (MockV2Pair p, PathologicalERC20 t0, PathologicalERC20 t1)
    {
        t0 = new PathologicalERC20("USD", "USD", d0);
        t1 = new PathologicalERC20("WETH", "WETH", 18);
        p = new MockV2Pair(address(t0), address(t1));
        t0.mint(address(p), r0);
        t1.mint(address(p), r1);
        if (p.token0() == address(t0)) {
            p.setReserves(r0, r1);
        } else {
            p.setReserves(r1, r0);
            (t0, t1) = (t1, t0);
        }
    }

    /// 700 USDC (6) against 1,000 WETH (18): normalised, USDC is the short side (700e18);
    /// the raw min would also pick USDC but at 700e6 - nine orders of magnitude off.
    function test_ShortSideIsNormalisedBeforeTheMin() public pure {
        uint256 a = BPC.shortSide18(700e6, 6, 1_000e18, 18);
        assertEq(a, 700e18, "the short side is USDC, normalised to 18 decimals");
    }

    /// The same physical book labelled (6, 18) and (18, 18) has one depth and one bucket.
    function test_BucketIsDecimalRelabelInvariant() public pure {
        uint256 dA = BPC.shortSide18(700e6, 6, 1_000e18, 18);
        uint256 dB = BPC.shortSide18(700e18, 18, 1_000e18, 18);
        assertEq(dA, dB, "relabelling the decimals moved the normalised depth");
        assertEq(BPC.depthBucket(dA), BPC.depthBucket(dB), "relabelling the decimals moved the bucket");
    }

    /// The registry's producer reads the decimals from the chain: the same physical
    /// reserves held by a 6-decimal token and by an 18-decimal one give one depth.
    function test_RegistryDepthReadsDecimalsFromTheChain() public {
        (MockV2Pair p6, PathologicalERC20 a6, PathologicalERC20 b6) = _pair(6, 700e6, 1_000e18);
        (MockV2Pair p18, PathologicalERC20 a18, PathologicalERC20 b18) = _pair(18, 700e18, 1_000e18);
        uint256 d6 = BPC.registryDepth18(address(p6), BPC.KIND_V2, address(a6), address(b6), address(0), bytes32(0));
        uint256 d18 = BPC.registryDepth18(address(p18), BPC.KIND_V2, address(a18), address(b18), address(0), bytes32(0));
        assertEq(d6, 700e18, "the 6-decimal side was not normalised");
        assertEq(d6, d18, "one physical book, two depths");
        assertEq(BPC.depthBucket(d6), BPC.depthBucket(d18), "one physical book, two buckets");
    }

    /// Negative control: the raw min of the same book sits in another bucket, so the
    /// assertions above distinguish the two worlds.
    function test_RawMinWouldLandInAnotherBucket() public {
        (MockV2Pair p6, PathologicalERC20 a6, PathologicalERC20 b6) = _pair(6, 700e6, 1_000e18);
        uint256 d = BPC.registryDepth18(address(p6), BPC.KIND_V2, address(a6), address(b6), address(0), bytes32(0));
        uint256 rawMin = 700e6;
        assertTrue(BPC.depthBucket(d) != BPC.depthBucket(rawMin),
            "the raw min lands in the same bucket: the test cannot tell the two apart");
    }
}
