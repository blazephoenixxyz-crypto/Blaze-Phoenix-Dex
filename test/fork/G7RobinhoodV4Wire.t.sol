// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  G7 draw robinhood midtail-1 idx 1 (block 103,357,447): USDG -> USDe, amount_in 2,007,996,423
//  (2,007.996423 USDG). G7 lines: the 9 mode-D draws of midtail-1 and the 12 G8 pool-v4/xb-v4
//  rows, all `SolverE(5)` (no topology found a route), while the seeded M0 row of the same draw
//  quotes net_out 2,004,069,985,591,771,679,372 through the PoolManager.
//
//  The market is a single V4 pool (USDG/USDe fee 100, tickSpacing 1, liquidity ~2e20 at this
//  block); both UniV3 pools of the pair are dust. The Hub runs its V4 derive scan only for a
//  factory row with mode MODE_V4_DERIVE (Hub `_scanV4`), and `G7Deploy._robinhood` never wrote
//  one (`_v4Wire` was called from `_base` only). Cold discovery therefore saw no V4 pool at all.
//  The harness was at fault, not the contracts.
//
//  Pinned here (stack: tools/g7-gas-campaign/G7Deploy.s.sol, inherited, admin = this test):
//    control: the wiring before the fix (`_robinhood` without `_v4Wire`) finds no route for
//             USDG -> USDe at any size. Green before and after the fix.
//    cause  : `G7Deploy._robinhood` quotes the draw at the seeded twin's exact net_out, and a
//             larger input never buys more per unit. Red before the fix (SolverE(5)); green
//             since `_robinhood` calls `_v4Wire`.
//  Mutant: drop the `addFactory(mgr, KIND_V4, MODE_V4_DERIVE, ...)` line of `_v4Wire` -> the
//  cause tests go red with SolverE(5). In .github/scripts/mutants.py the mutant is pinned to the
//  offline twin test/G7DeployV4Wire.t.sol (this file skips without DRPC_KEY).
//  Run: forge test --match-path test/fork/G7RobinhoodV4Wire.t.sol -vv (DRPC_KEY set).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {G7Deploy} from "../../tools/g7-gas-campaign/G7Deploy.s.sol";

contract G7RobinhoodV4WireTest is G7Deploy, Test {
    uint256 internal constant BLK = 103_357_447;
    address internal constant RH_PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant RH_USDE = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    uint256 internal constant DRAW_IN = 2_007_996_423;
    // net_out of the M0 row of the same draw (results-bb4cdbb.tsv, robinhood midtail-1 idx 1)
    uint256 internal constant M0_NET_OUT = 2_004_069_985_591_771_679_372;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("robinhood", BLK);
    }

    /// @dev `G7Deploy._robinhood` as it stood before the fix: no `_v4Wire`.
    function _wireWithoutV4() internal {
        _core(address(this), RH_PM, true);
        hub.addBridge(RH_WETH);
        hub.addBridge(RH_USDG);
        hub.addBridge(0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31);
        hub.addFactory(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
    }

    function _assertSolverE5(uint256 amountIn) internal {
        (bool ok, bytes memory err) =
            address(quoter).staticcall(abi.encodeCall(BlazePhoenixQuoter.previewPlan, (RH_USDG, RH_USDE, amountIn)));
        assertFalse(ok, "unexpected quote");
        assertEq(err, abi.encodeWithSignature("SolverE(uint16)", uint16(5)), "not SolverE(5)");
    }

    function _net(uint256 amountIn) internal view returns (uint256) {
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(RH_USDG, RH_USDE, amountIn);
        return pv.netOut;
    }

    // ── control: without the derive row the V4 market is invisible ──

    function test_G7Rh_WithoutV4Wire_ColdDiscoveryFindsNoRoute() public {
        _wireWithoutV4();
        _assertSolverE5(20_079_964);       // 20.08 USDG, the smallest rung of the draw ladder
        _assertSolverE5(DRAW_IN);          // the draw
        _assertSolverE5(200_000_000_000);  // 200,000 USDG
    }

    // ── cause: the G7 deploy wires the derive row and quotes the V4 pool ──

    function test_G7Rh_DeployWiring_QuotesTheDrawAtTheSeededTwin() public {
        _robinhood(address(this));
        assertEq(_net(DRAW_IN), M0_NET_OUT, "cold discovery != seeded twin");
    }

    function test_G7Rh_DeployWiring_LargerInputNeverBuysMorePerUnit() public {
        _robinhood(address(this));
        uint256[3] memory a = [uint256(20_079_964), DRAW_IN, 200_000_000_000];
        uint256 prev;
        for (uint256 i; i < 3; ++i) {
            uint256 n = _net(a[i]);
            assertGt(n, 0, "no quote");
            // n / a[i] <= prev / a[i-1], cross-multiplied
            if (i > 0) assertLe(n * a[i - 1], prev * a[i], "a larger input bought more per unit");
            prev = n;
        }
    }
}
