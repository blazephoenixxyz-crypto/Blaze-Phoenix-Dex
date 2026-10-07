// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  KINDS_ROUTABLE, KINDS_EXECUTABLE, KINDS_PAIR_PROOF: three questions, three masks.
//
//  The Hub writes the masks out longhand on purpose: deriving one from another once
//  handed a defect back through the side door. The relation between them is not a
//  subset law - V4_NATIVE is executable and NOT routable, because no factory makes
//  it - so this pins the relation as it stands, reading the real constants, and pins
//  at the source that no mask is defined from another. A new kind reaches a mask only
//  by being written into it.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract HubMaskProbe is BlazePhoenixHub {
    constructor() BlazePhoenixHub(msg.sender) {}
    function routable()   external pure returns (uint256) { return KINDS_ROUTABLE; }
    function executable() external pure returns (uint256) { return KINDS_EXECUTABLE; }
    function pairProof()  external pure returns (uint256) { return KINDS_PAIR_PROOF; }
}

contract KindMaskQuestionSeparationTest is Test {
    HubMaskProbe probe;

    function setUp() public { probe = new HubMaskProbe(); }

    function test_RoutableIsInsideExecutable() public view {
        assertEq(probe.routable() & ~probe.executable(), 0,
            "a kind a factory can register is no longer executable");
    }

    /// The two are NOT equal, and the difference is exactly V4_NATIVE.
    function test_ExecutableMinusRoutableIsExactlyTheNativeKind() public view {
        uint256 r = probe.routable();
        uint256 e = probe.executable();
        assertEq(e & ~r, uint256(1) << BPC.KIND_V4_NATIVE,
            "the difference between the two masks is no longer exactly V4_NATIVE");
        assertEq((r >> BPC.KIND_V4_NATIVE) & 1, 0, "V4_NATIVE became routable: no factory makes it");
    }

    /// PAIR_PROOF is an acceptance predicate, not a shape: it excludes the singleton kinds.
    function test_PairProofExcludesSingletons() public view {
        uint256 p = probe.pairProof();
        assertEq((p >> BPC.KIND_V4) & 1, 0, "V4 is not a pair");
        assertEq((p >> BPC.KIND_V4_NATIVE) & 1, 0, "V4_NATIVE is not a pair");
        assertEq(p & ~probe.executable(), 0, "PAIR_PROOF left the executable universe");
    }

    /// Retired kind numbers 2, 3 and 7 are in no mask and carry no attributes.
    function test_RetiredKindsAreInNoMask() public view {
        uint8[3] memory retired = [uint8(2), 3, 7];
        uint256 all = probe.routable() | probe.executable() | probe.pairProof();
        for (uint256 i; i < retired.length; ++i) {
            assertEq((all >> retired[i]) & 1, 0, "a retired kind number came back in a mask");
            assertEq(BPC.thetaOf(retired[i]), 0, "a retired kind number has attributes");
        }
    }

    /// Structure, not semantics: the forbidden rewrite (one mask defined from another)
    /// has not come back.
    function test_MasksAreNotDerivedFromEachOther() public view {
        string memory hub = vm.readFile("src/BlazePhoenixHub.sol");
        assertFalse(_contains(hub, "KINDS_EXECUTABLE = KINDS_ROUTABLE"), "EXECUTABLE is derived from ROUTABLE");
        assertFalse(_contains(hub, "KINDS_ROUTABLE = KINDS_EXECUTABLE"), "ROUTABLE is derived from EXECUTABLE");
        assertFalse(_contains(hub, "KINDS_PAIR_PROOF = KINDS_"), "PAIR_PROOF is derived from another mask");
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) { if (h[i + j] != n[j]) { ok = false; break; } }
            if (ok) return true;
        }
        return false;
    }
}
