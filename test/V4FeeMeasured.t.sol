// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  INV-20 (V4-FEE-MEASURED). A static-fee V4 key carries its real fee in the
//  key. A dynamic-fee key uses the sentinel 0x800000, whose true fee lives only
//  in slot0's lpFee (measure-not-nominal) — the sentinel must never reach
//  outV3 as a fee (it is >= 1e6 and would make every dynamic-fee pool quote 0).
//  A non-zero protocolFee fails closed until its composition is anchored.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract V4FeeMeasuredTest is Test {
    uint24 constant DYN = 0x800000; // LPFeeLibrary dynamic-fee sentinel (8_388_608)

    function test_StaticFee_KeyIsTruth() public pure {
        // static-fee keys ignore slot0 fields entirely
        assertEq(BPC.effV4Fee(500, 9999, 0), 500);
        assertEq(BPC.effV4Fee(3000, 1, 5), 3000);
        assertEq(BPC.effV4Fee(10000, 0, 0), 10000);
    }

    function test_DynamicFee_UsesSlot0LpFee() public pure {
        // the Clanker "OpenAI" pool measured lpFee = 1% (10000) live on Base
        assertEq(BPC.effV4Fee(DYN, 10000, 0), 10000);
        assertEq(BPC.effV4Fee(DYN, 500, 0), 500);
        assertEq(BPC.effV4Fee(DYN, 0, 0), 0); // 0% dynamic is legal
    }

    function test_DynamicFee_WithProtocolFee_FailsClosed() public pure {
        // non-zero protocolFee → unquotable sentinel that trips outV3's >=1e6 guard
        assertEq(BPC.effV4Fee(DYN, 3000, 1), 0xFFFFFF);
        assertGe(uint256(BPC.effV4Fee(DYN, 3000, 1)), 1_000_000);
    }

    function test_Sentinel_NeverSurvivesAsFee() public pure {
        // the resolved fee for a live (protoFee==0) dynamic pool is always < 1e6,
        // so outV3 prices it instead of returning 0
        assertLt(uint256(BPC.effV4Fee(DYN, 10000, 0)), 1_000_000);
    }

    function testFuzz_DynamicResolvesToLpFeeOrFailClosed(uint24 lpFee, uint24 protoFee) public pure {
        uint24 eff = BPC.effV4Fee(DYN, lpFee, protoFee);
        if (protoFee == 0) {
            assertEq(eff, lpFee);
        } else {
            assertEq(eff, 0xFFFFFF); // fail-closed
        }
    }
}
