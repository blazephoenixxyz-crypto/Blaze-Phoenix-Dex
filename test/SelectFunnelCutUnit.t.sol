// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title The funnel cut and the seat, read on `BlazePhoenixMath.select` alone
/// @notice `select` is the library's public door (the Solver calls it once per hop). These
///         tests hand it the probe pass directly: no Hub, no Solver, no psi produced by a
///         pool's history. Each assertion names the row the cut or the seat must reach, from
///         an oracle written here (the rates, depths and addresses the test chose).
/// @dev    WHY HERE AND NOT THROUGH THE DOOR. On f6d2b9a the door-level fixtures of
///         test/FunnelCutTieReadsNoScore.t.sol no longer reach a weight tie: traced on the
///         release profile, `select` returns nBand = 6, n = 5 and psis
///         [9950, 9950, 9950, 9950, 10000, 9900]. The measured depths differ with the price,
///         so the worst-priced pool is the lightest and the cut drops it on weight alone; the
///         tie-break is never read, and mutants [370] [1075] [1052] [1053] [1051] passed
///         (mutation guard, PR #123). Here the depths are equal by construction, so the
///         weights tie exactly and only the tie-break can choose.
///         Mutants: [370] [1075] [1052] [1053] -> the weight-tie test; [1051] -> the distinct-
///         weights test; C3 (`_seatTheSplit` cannotPay) -> the empty-book test; [seat-tie]
///         (`seatOf` drops the address tie-break) -> the seat test.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMath, IHubMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, PoolInfo, MAX_LEGS_PER_HOP} from "../src/BlazePhoenixCore.sol";

contract SelectFunnelCutUnitTest is Test {
    address internal constant T_IN  = address(0xA11CE);
    address internal constant T_OUT = address(0xB0B);
    uint256 internal constant FEE   = 3000;                          // pips; error bounds e = e_o = 0
    uint256 internal constant N     = uint256(MAX_LEGS_PER_HOP) + 1; // one row more than the budget
    address internal constant WORST = address(0x1000);               // row k = 0

    /// Row k: pool address 0x1000 + k, active (so no vote is muted and no Hub is read).
    function _row(uint256 k, uint8 kind) private pure returns (PoolInfo memory) {
        return PoolInfo({active: true, stable: false, kind: kind, fee: uint24(FEE), tickSpacing: 0,
            token0: T_IN, token1: T_OUT, pool: address(uint160(0x1000 + k)), hooks: address(0)});
    }

    function _select(PoolInfo[] memory c, uint256[] memory rates, uint256[] memory depths, uint256[] memory bals)
        private view
        returns (uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory map, uint256[] memory psis)
    {
        uint256[] memory fe = new uint256[](c.length);
        for (uint256 i; i < c.length; i++) fe[i] = FEE;
        // V2 and V3 rows never reach `_heldShare` (not A_CONC_SING) and active rows are never
        // muted, so the Hub is not read: address(0) makes any read revert, not pass.
        return BlazePhoenixMath.select(rates, depths, bals, fe, c, T_IN, IHubMath(address(0)), MAX_LEGS_PER_HOP);
    }

    /// N = budget + 1 rows of EQUAL depth (so every weight ties) and distinct rates, the worst
    /// rate on the LOWEST address (so an address tie-break would keep it). Two arrival orders:
    /// worst first, worst last. The row cut is the worst-priced one in both.
    function test_FunnelCut_Unit_WeightTie_DropsTheWorstRate_InAnyArrivalOrder() public view {
        for (uint256 order; order < 2; order++) {
            PoolInfo[] memory c = new PoolInfo[](N);
            uint256[] memory rates = new uint256[](N);
            uint256[] memory depths = new uint256[](N);
            uint256[] memory bals = new uint256[](N);
            for (uint256 i; i < N; i++) {
                uint256 k = order == 0 ? i : N - 1 - i;
                c[i] = _row(k, BPC.KIND_V2);
                rates[i] = 2000e18 + k * 1e15;   // k = 0 the worst; 5e15 in 2000e18 sits inside the band
                depths[i] = 300e18;
                bals[i] = 600_000e18;
            }
            (uint256 nBand, uint256 n,, uint256[] memory map, uint256[] memory psis) = _select(c, rates, depths, bals);
            assertEq(nBand, N, "premise: every row is in the band, so the row dropped is the cut's");
            assertEq(n, N - 1, "premise: the cut dropped exactly one row");
            for (uint256 i; i < n; i++) assertEq(psis[i], psis[0], "premise: every weight ties");
            for (uint256 i; i < n; i++) {
                assertTrue(c[map[i]].pool != WORST, "a weight tie is cut on the rate: the worst-priced row goes");
            }
        }
    }

    /// N = budget + 1 rows of DISTINCT depth and one rate, the lightest on row k = 0. The cut
    /// keeps the heaviest `budget` rows in either arrival order.
    function test_FunnelCut_Unit_DistinctWeights_DropsTheLightest_InAnyArrivalOrder() public view {
        for (uint256 order; order < 2; order++) {
            PoolInfo[] memory c = new PoolInfo[](N);
            uint256[] memory rates = new uint256[](N);
            uint256[] memory depths = new uint256[](N);
            uint256[] memory bals = new uint256[](N);
            for (uint256 i; i < N; i++) {
                uint256 k = order == 0 ? i : N - 1 - i;
                c[i] = _row(k, BPC.KIND_V2);
                rates[i] = 2000e18;
                depths[i] = 300e18 + k * 10e18;   // weights 8571 .. 10000: distinct
                bals[i] = 600_000e18;
            }
            (uint256 nBand, uint256 n,, uint256[] memory map,) = _select(c, rates, depths, bals);
            assertEq(nBand, N, "premise: every row is in the band");
            assertEq(n, N - 1, "premise: the cut dropped exactly one row");
            for (uint256 i; i < n; i++) {
                assertTrue(c[map[i]].pool != WORST, "the cut keeps the heaviest rows: the lightest goes");
            }
        }
    }

    /// Three concentrated rows under the budget (no cut); the middle one holds none of tokenOut.
    /// It cannot pay, so it keeps no weight in the split and the total is the other two.
    function test_Seat_Unit_ABookHoldingNoOutput_KeepsNoWeight() public view {
        uint256 m = 3;
        PoolInfo[] memory c = new PoolInfo[](m);
        uint256[] memory rates = new uint256[](m);
        uint256[] memory depths = new uint256[](m);
        uint256[] memory bals = new uint256[](m);
        for (uint256 i; i < m; i++) {
            c[i] = _row(i, BPC.KIND_V3);
            rates[i] = 2000e18;
            depths[i] = 300e18;
            bals[i] = i == 1 ? 0 : 600_000e18;
        }
        (uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory map, uint256[] memory psis) =
            _select(c, rates, depths, bals);
        assertEq(nBand, m, "premise: every row is in the band");
        assertEq(n, m, "premise: under the budget, nothing is cut");
        for (uint256 i; i < n; i++) {
            if (c[map[i]].pool == address(0x1001)) assertEq(psis[i], 0, "a book holding none of tokenOut keeps no weight");
            else assertEq(psis[i], 10_000, "a book that can pay keeps its full weight");
        }
        assertEq(sumPsi, 20_000, "the split's total is the weight of the books that can pay");
    }

    /// Three rows of one weight and one rate, the lowest address arriving FIRST. The seat (the
    /// last position, the remainder's leg) is the deepest row, a tie to the lowest address,
    /// never the row that happened to arrive last.
    function test_Seat_Unit_WeightTie_GoesToTheLowestAddress() public view {
        uint256 m = 3;
        PoolInfo[] memory c = new PoolInfo[](m);
        uint256[] memory rates = new uint256[](m);
        uint256[] memory depths = new uint256[](m);
        uint256[] memory bals = new uint256[](m);
        for (uint256 i; i < m; i++) {
            c[i] = _row(i, BPC.KIND_V2);
            rates[i] = 2000e18;
            depths[i] = 300e18;
            bals[i] = 600_000e18;
        }
        (, uint256 n,, uint256[] memory map,) = _select(c, rates, depths, bals);
        assertEq(n, m, "premise: under the budget, nothing is cut");
        assertEq(c[map[n - 1]].pool, WORST, "a weight tie seats the lowest address");
    }
}
