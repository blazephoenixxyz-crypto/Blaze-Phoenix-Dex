// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Audit PoC #1 — Core.solidlyStable accepts a NON-BOOLEAN `stable()` answer.
//
//  `isSolidlyShaped` and `solidlyStable` are twins: both staticcall selector
//  0x22be3de1 (`stable()`) and both accept ANY 32-byte answer. `fix/pending-1010`
//  (commit 406a869) hardens `isSolidlyShaped` to require an ABI bool (<2) but
//  leaves `solidlyStable` unchanged — the second door of the same class.
//
//  Impact: `Hub._register` (BlazePhoenixHub.sol:2015) sets the registry's
//  `stable` bit from `solidlyStable(pool)`. A hostile Solidly-shaped pair answers
//  `stable()` with a word that is not 0/1 and its curve is stored as STABLE,
//  which prices it on the stable curve (`outSolidlyStable`) in every
//  replicated-curve fallback. The two functions also read `stable()` in
//  SEPARATE calls, so a pool may answer `1` to one and `2` to the other and have
//  its FAMILY and its `stable` BIT disagree.
//
//  forge test --match-path 'poc/F1_SolidlyStable_PoC.t.sol' -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// Answers `stable()` with a settable word (view, so a staticcall reads it).
contract B1013StablePool {
    uint256 public word;
    function set(uint256 w) external { word = w; }
    // selector 0x22be3de1 — deliberately NOT an ABI bool for the hostile cases.
    function stable() external view returns (uint256) { return word; }
}

contract B1013BoolHarness {
    function isSolidlyShaped(address p) external view returns (bool) { return BPC.isSolidlyShaped(p); }
    function solidlyStable(address p) external view returns (bool) { return BPC.solidlyStable(address(p)); }
}

contract Bounty1013SolidlyStableIsABoolTest is Test {
    B1013BoolHarness h;

    function setUp() public { h = new B1013BoolHarness(); }

    function test_A_zeroIsNotStable() public {
        B1013StablePool p = new B1013StablePool();
        p.set(0);
        // isSolidlyShaped answers "does this pool EXPOSE stable()?" — the getter
        // exists, so true. solidlyStable answers "is stable() non-zero?" — false.
        assertTrue(h.isSolidlyShaped(address(p)), "the getter exists");
        assertFalse(h.solidlyStable(address(p)), "0 is not stable");
    }

    /// #42: a word above 1 is neither a shape nor a stable answer (twin of the shape read).
    function test_NonBooleanWordIsNotStable() public {
        B1013StablePool p = new B1013StablePool();
        p.set(2);
        assertFalse(h.isSolidlyShaped(address(p)), "word 2 is not a shape");
        assertFalse(h.solidlyStable(address(p)), "word 2 is not stable");
        p.set(type(uint256).max);
        assertFalse(h.solidlyStable(address(p)), "dirty word is not stable");
        p.set(1);
        assertTrue(h.solidlyStable(address(p)), "control: 1 is stable");
    }
}
