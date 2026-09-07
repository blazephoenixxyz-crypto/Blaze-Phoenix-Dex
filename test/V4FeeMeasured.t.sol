// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  INV-20 (V4-FEE-MEASURED). A static-fee V4 key carries its real fee in the
//  key. A dynamic-fee key uses the sentinel 0x800000, whose true fee lives only
//  in slot0's lpFee (measure-not-nominal) — the sentinel must never reach
//  outV3 as a fee (it is >= 1e6 and would make every dynamic-fee pool quote 0).
//  On a static key the PoolManager's protocol fee (per direction, 12 bits each)
//  composes as p + lp − p·lp/1e6 (v4-core ProtocolFeeLibrary.calculateSwapFee);
//  on a dynamic key a non-zero protocolFee fails closed.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract V4FeeMeasuredTest is Test {
    uint24 constant DYN = 0x800000; // LPFeeLibrary dynamic-fee sentinel (8_388_608)

    function test_StaticFee_KeyIsTruth_WhenNoProtocolFee() public pure {
        // static-fee keys ignore slot0's lpFee; with protocolFee 0 the key is the fee
        assertEq(BPC.effV4Fee(500, 9999, 0, true), 500);
        assertEq(BPC.effV4Fee(10000, 0, 0, false), 10000);
    }

    function test_StaticFee_ComposesProtocolFee_PerDirection() public pure {
        // v4-core: swapFee = p + lp − p·lp/1e6; zeroForOne reads the low 12 bits,
        // oneForZero the high 12 bits. Measured before this test: the static arm
        // returned the key fee and the quote overstated the output by p pips.
        uint24 packed = uint24((7 << 12) | 5); // oneForZero = 7, zeroForOne = 5
        assertEq(uint256(BPC.effV4Fee(3000, 1, packed, true)), 3005);  // 3000 + 5 − ⌊5·3000/1e6⌋ = 3005
        assertEq(uint256(BPC.effV4Fee(3000, 1, packed, false)), 3007); // 3000 + 7 − ⌊7·3000/1e6⌋ = 3007
        // the cap of a direction's field is 1000 pips (0.1 %): 1000 + 10000 − 10 = 10990
        assertEq(uint256(BPC.effV4Fee(10000, 0, 1000, true)), 10990);
        // a direction with no protocol fee is untouched even when the other has one
        assertEq(BPC.effV4Fee(3000, 1, uint24(7 << 12), true), 3000);
    }

    function test_DynamicFee_UsesSlot0LpFee() public pure {
        // the Clanker "OpenAI" pool measured lpFee = 1% (10000) live on Base
        assertEq(BPC.effV4Fee(DYN, 10000, 0, true), 10000);
        assertEq(BPC.effV4Fee(DYN, 500, 0, true), 500);
        assertEq(BPC.effV4Fee(DYN, 0, 0, true), 0); // 0% dynamic is legal
    }

    function test_DynamicFee_WithProtocolFee_FailsClosed() public pure {
        // non-zero protocolFee → unquotable sentinel that trips outV3's >=1e6 guard
        assertEq(BPC.effV4Fee(DYN, 3000, 1, true), 0xFFFFFF);
        assertGe(uint256(BPC.effV4Fee(DYN, 3000, 1, true)), 1_000_000);
        // protocolFee packs two 12-bit halves — both set must also fail closed
        assertEq(BPC.effV4Fee(DYN, 3000, uint24((1 << 12) | 1), false), 0xFFFFFF);
    }

    function test_Sentinel_NeverSurvivesAsFee() public pure {
        // the resolved fee for a live (protoFee==0) dynamic pool is always < 1e6,
        // so outV3 prices it instead of returning 0
        assertLt(uint256(BPC.effV4Fee(DYN, 10000, 0, true)), 1_000_000);
    }

    function testFuzz_DynamicResolvesToLpFeeOrFailClosed(uint24 lpFee, uint24 protoFee) public pure {
        uint24 eff = BPC.effV4Fee(DYN, lpFee, protoFee, true);
        if (protoFee == 0) {
            assertEq(eff, lpFee);
        } else {
            assertEq(eff, 0xFFFFFF); // fail-closed
        }
    }
}
