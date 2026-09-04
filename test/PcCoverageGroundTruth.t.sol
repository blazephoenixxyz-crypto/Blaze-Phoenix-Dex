// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";

/// @dev The known instance that `pc_coverage.py` has to find before any number it prints is
///      worth reading. `touched` is called by the single test below; `untouched` and
///      `alsoUntouched` are called by nothing, here or anywhere else in the suite, and the
///      compiler cannot remove them because they are external.
///
///      The instrument seeds itself from the hit counts in `forge coverage --report bytecode`
///      and closes that seed under the successors control flow forces. A closure rule that
///      leaks - following a JUMPI arm, say, or a JUMP whose target is not a literal - would
///      reach into these two functions, and every coverage figure downstream would be
///      inflated by an amount nobody could see. This contract is what makes that visible:
///      the check demands EXACTLY zero reached instructions in both.
contract PcCoverageProbeTarget {
    uint256 public x;

    function touched(uint256 a) external {
        x = a + 1;
    }

    function untouched(uint256 a) external {
        x = a + 999999;
    }

    function alsoUntouched(uint256 a, uint256 b) external {
        x = (a * b) ^ 0xdeadbeef;
    }
}

contract PcCoverageGroundTruthTest is Test {
    PcCoverageProbeTarget internal probe;

    function setUp() public {
        probe = new PcCoverageProbeTarget();
    }

    /// @dev Deliberately calls ONE of the three. The assertion here is ordinary; the real
    ///      assertion is made by pc_coverage.py --check against the disassembly this run
    ///      produces, and it fails the build if the closure reaches either of the other two.
    function test_OnlyTouchedRuns() public {
        probe.touched(41);
        assertEq(probe.x(), 42, "the probe must actually execute, or the ground truth is vacuous");
    }
}
