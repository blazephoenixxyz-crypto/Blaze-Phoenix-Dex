// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A HOP WHERE NO ROW VOTES IS BASED ON ITS MEDIAN ROW.
//
//  `BlazePhoenixMath._wMedian` answers NONE when the live rows carry no mass between
//  them (every live depth 0), and `_select` then bases the band on the plain median's
//  row, ord[m / 2] of the live rows sorted by price. Without the `massa == 0` exit the
//  walk to half of nothing stops at once and answers the CHEAPEST row: the band is
//  centred on the lowest price the hop holds, the side a stale or lagging venue sits on.
//
//  Read at the library (`BlazePhoenixMath.select`) on rows built by hand: KIND_V2 pairs,
//  every row vouched (`active`: no Hub read), fee 0 and error bounds 0, so the band keeps
//  exactly the rows at the base's price, and the kept set names the base.
//  Oracle: the sort by hand (prices are the rates, fee 0), not the library.
//
//  Matrix (gama x vetor x dimensao):
//    3 and 4 live rows, all depth 0, rows out of price order  x  no voter  x  unit
//    one row with depth (control: the vote still decides)     x  honest     x  unit
//
//  Mutant in .github/scripts/mutants.py: "Math:599" (`m == 0 || massa == 0` ->
//  `m == 0`: the cheapest row is the base) -> red.
//
//  forge test --match-path test/NoVoteBaseIsTheMedianRow.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMath as BPM, IHubMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

contract NoVoteBaseIsTheMedianRowTest is Test {
    /// The rows `select` keeps (bit i = row i) for live V2 rows at `rate`, each of depth `depth`,
    /// fee 0, a real balance of 1e18 of the output token each.
    function _kept(uint256[] memory rate, uint256[] memory depth) internal view returns (uint256 set) {
        uint256 n = rate.length;
        uint256[] memory rates = new uint256[](n);
        uint256[] memory depths = new uint256[](n);
        uint256[] memory bals = new uint256[](n);
        uint256[] memory fe = new uint256[](n);
        PoolInfo[] memory c = new PoolInfo[](n);
        for (uint256 i; i < n; ++i) {
            rates[i] = rate[i];
            depths[i] = depth[i];
            bals[i] = 1e18;
            c[i] = PoolInfo({
                active: true, stable: false, kind: BPC.KIND_V2,
                fee: 0, tickSpacing: 0, token0: address(0xA), token1: address(0xB),
                pool: address(uint160(0x1000 + i)), hooks: address(0)
            });
        }
        (uint256 nBand, , , uint256[] memory map, ) =
            BPM.select(rates, depths, bals, fe, c, address(0xA), IHubMath(address(0)), 8);
        for (uint256 j; j < nBand; ++j) set |= 1 << map[j];
    }

    function _three(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory x) {
        x = new uint256[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function _four(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (uint256[] memory x) {
        x = new uint256[](4);
        (x[0], x[1], x[2], x[3]) = (a, b, c, d);
    }

    /// Three live rows at 1, 2 and 4, none with depth: by price the order is rows 0, 1, 2 and the
    /// median's row is ord[1] = row 1. Fee 0 keeps only the base's price: the set is {1}.
    function test_AHopWhereNoRowVotesIsBasedOnItsMedianRow() public view {
        assertEq(_kept(_three(1e18, 2e18, 4e18), _three(0, 0, 0)), 2,
            "no row voted and the band was based on a row other than the median");
        // rows out of price order: 4, 1, 2 sort to rows 1, 2, 0, the median is row 2
        assertEq(_kept(_three(4e18, 1e18, 2e18), _three(0, 0, 0)), 4,
            "the no-vote base was read in row order, not in price order");
        // four rows 8, 2, 1, 4 sort to rows 2, 1, 3, 0: ord[4 / 2] = row 3
        assertEq(_kept(_four(8e18, 2e18, 1e18, 4e18), _four(0, 0, 0, 0)), 8,
            "four rows with no vote were not based on ord[m / 2]");
    }

    /// Control: one row with depth carries the whole vote and is the base, cheapest or not.
    function test_Control_OneRowWithDepthIsTheBase() public view {
        assertEq(_kept(_three(1e18, 2e18, 4e18), _three(1e18, 0, 0)), 1, "the one voter was not the base");
        assertEq(_kept(_three(1e18, 2e18, 4e18), _three(0, 0, 1e18)), 4, "the one voter was not the base");
    }
}
