// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Router's V4 pool-id derivations, counted.
//
//  Three Router functions derive a V4 pool id from coordinates of their own -
//  `_v4LegQuote`, `_execV4Amt` and `_recordHits` (a native and a common arm) - and
//  two of them first normalise the native side through `nativeMapVerified`. They
//  agree by the convention they share, so a fifth derivation, or a normalisation
//  that disappears from one door without the other knowing, is the forgotten-sibling
//  shape this codebase has paid for before. This pins the structure (source text,
//  like HookSieveCensusPin); it does not prove semantics. If it fails, re-derive
//  the convention for every site, then re-pin the counts.
// =============================================================================

import {Test} from "forge-std/Test.sol";

contract V4PoolIdSiteCensusPinTest is Test {
    function test_RouterV4PoolIdSitesAreUnchanged() public view {
        string memory src = vm.readFile("src/BlazePhoenixRouter.sol");
        assertEq(_count(src, "BPC.computeV4PoolId("), 4,
            "a V4 pool-id derivation appeared in or left the Router: re-derive the convention");
        assertEq(_count(src, "BPC.nativeMapVerified("), 2,
            "a native normalisation appeared in or left the Router: a door may be left unnormalised");
    }

    function _count(string memory hay, string memory needle) internal pure returns (uint256 c) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return 0;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) { if (h[i + j] != n[j]) { ok = false; break; } }
            if (ok) { ++c; i += n.length - 1; }
        }
    }
}
