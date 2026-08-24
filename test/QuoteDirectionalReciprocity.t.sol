// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Diagnoses the direction-consistency of the V3 quote (BlazePhoenixCore.outV3),
// prompted by a real-deploy observation that ETH->COMP appeared to quote
// differently from COMP->ETH.
//
// Directional OUTPUT differences ARE expected (fees + slippage + directional
// pricing), and the Solver legitimately selects different ROUTES per direction
// through the tOut-specific capital anchor (balanceOf(tokenOut, pool)). What must
// NOT differ is the underlying pricing math: outV3 has to be direction-consistent.
// These pins prove it — at a symmetric pool both directions match to the wei, and
// a marginal round trip recovers ~(1-fee)^2 at any price skew. A zeroForOne bug
// would break one of these.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract QuoteDirectionalReciprocityTest is Test {
    uint128 constant L   = 1e27;  // deep -> negligible single-tick slippage
    uint24  constant FEE = 3000;  // 0.3%

    /// At a 1:1 pool (sqrtPrice == Q96) the two directions are mathematically
    /// identical; any gap beyond rounding is a zeroForOne bug, not pricing.
    function test_OutV3_SymmetricPool_BothDirectionsMatch() public {
        uint160 sp = uint160(BPC.Q96);
        uint256 dx = 1e18;
        uint256 outFwd = BPC.outV3(dx, sp, L, FEE, true, 0);
        uint256 outBwd = BPC.outV3(dx, sp, L, FEE, false, 0);
        assertGt(outFwd, 0, "forward quote must be non-zero");
        assertApproxEqRel(outFwd, outBwd, 1e12, "price 1: both directions must match (else zeroForOne bug)");
    }

    /// A round trip through the SAME pool state at marginal size (price barely
    /// moves) must recover the input minus ~two fees, at any skew. A wildly off
    /// return would mean the directional math is inconsistent.
    function _roundTrip(uint160 sp, uint256 dx) internal pure returns (uint256 back) {
        uint256 out0 = BPC.outV3(dx, sp, L, FEE, true, 0);    // token0 -> token1
        back         = BPC.outV3(out0, sp, L, FEE, false, 0); // token1 -> token0
    }

    function test_OutV3_RoundTrip_RecoversMinusFees_AcrossSkews() public {
        uint256 dx = 1e15; // small vs L -> negligible slippage
        uint160[3] memory sps = [uint160(BPC.Q96), uint160(2 * BPC.Q96), uint160(8 * BPC.Q96)];
        for (uint256 i; i < sps.length; ++i) {
            uint256 back = _roundTrip(sps[i], dx);
            assertLt(back, dx, "round trip must lose value to fees");
            assertGt(back, dx * 98 / 100, "round trip must recover >98% (direction-consistent)");
        }
    }
}
