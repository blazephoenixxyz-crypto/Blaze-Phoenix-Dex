// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

/// @dev The second ground truth, and the one that exists because the first was not enough.
///
///      `PcCoverageGroundTruth` proved the CLOSURE does not leak: it reaches a called function
///      and leaves two uncalled ones at exactly zero. It passed in three consecutive runs while
///      the instrument's INPUT was quietly unstable - `forge coverage --report bytecode` handed
///      back a different object for `BlazePhoenixRouter` and `BlazePhoenixHub` from one run to
///      the next, same instruction count, different byte span, one run opening on the runtime
///      dispatcher and the next on a constructor's CALLVALUE guard. The first probe could not
///      see that, and the reason is precise: it has no constructor arguments, and the two
///      contracts that moved are the two that have them.
///
///      A self-test blind to the failure that actually occurred is worth naming as such. This
///      one is built to be sensitive to it. `tag` is immutable, so its value is patched into the
///      RUNTIME code at deployment: an artefact's `deployedBytecode` carries a zero placeholder
///      there, while a deployed instance carries the real number. Two instances are deployed
///      with two different tags. Whichever value the disassembly contains therefore says, with
///      no inference at all, WHICH object the report handed back:
///
///        neither tag  -> the artefact, immutables unpatched
///        TAG_A only   -> the first deployed instance
///        TAG_B only   -> the second deployed instance
///        both         -> the listing is not one object
///
///      That question was open after the instability was found and could not be answered from
///      the Router and Hub listings, because `forge coverage` deletes `out/` and leaves nothing
///      to compare them against. Here the answer is a grep.
contract PcCoverageImmutableProbe {
    /// @dev Patched into the runtime code at construction. Deliberately a value that occurs
    ///      nowhere else in this repository, so a search for it cannot match by accident.
    uint256 public immutable tag;

    uint256 public x;

    constructor(uint256 t) {
        tag = t;
    }

    function touchedImm(uint256 a) external {
        x = a + tag;
    }

    function untouchedImm(uint256 a) external {
        x = a + 999983;
    }
}

contract PcCoverageImmutableProbeTest is Test {
    /// @dev Kept in sync with `pc_coverage.py`, which greps the disassembly for both.
    uint256 internal constant TAG_A = 0xC0FFEE01;
    uint256 internal constant TAG_B = 0xC0FFEE02;

    PcCoverageImmutableProbe internal a;
    PcCoverageImmutableProbe internal b;

    function setUp() public {
        a = new PcCoverageImmutableProbe(TAG_A);
        b = new PcCoverageImmutableProbe(TAG_B);
    }

    /// @dev Two instances of one contract, differing only in an immutable, and only ONE of them
    ///      is ever called. The closure must still leave `untouchedImm` at zero instructions -
    ///      that is the property inherited from the first probe. What is new is that the report
    ///      now has two candidate objects to hand back for a single contract name, which is the
    ///      condition the Router and the Hub were in when they moved.
    function test_OnlyOneInstanceIsCalled() public {
        a.touchedImm(1);
        assertEq(a.x(), 1 + TAG_A, "instance A must actually execute, or the probe is vacuous");
        assertEq(b.x(), 0, "instance B is deployed and never called");
        assertTrue(a.tag() != b.tag(), "the two instances must differ in the immutable");
    }
}
