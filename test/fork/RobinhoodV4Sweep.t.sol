// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../../src/BlazePhoenixCore.sol";

// =============================================================================
//  GENERAL proof that Uniswap-V4 pools are DISCOVERED and ROUTED — a sweep, not
//  a token-specific assertion.
//
//  V4's singleton PoolManager has no on-chain pair enumeration, so bespoke-fee
//  pools (the launchpad norm) cannot be found by a fixed on-chain grid. The
//  general mechanism is the permissionless, chain-VERIFIED claim (`claimV4`):
//  an off-chain scan of the PoolManager's Initialize logs feeds candidate keys,
//  and the chain proves each one (initialized + liquid + hookless) before it
//  becomes routable. This test feeds a SET of real Robinhood V4 pools through
//  that path and tallies, exactly like the Base top-100 sweep:
//     discovered  = claimV4 accepted (on-chain existence proof passed)
//     routedViaV4 = a live quote's chosen plan contains a KIND_V4 leg
//
//  The set is swept with try/catch so an empty or illiquid candidate never
//  fails the run; the invariant asserted is the MECHANISM: at least one V4 pool
//  is discovered AND at least one swap is routed through a V4 leg.
// =============================================================================
contract RobinhoodV4SweepTest is Test {
    // Placeholder test-only fee recipients — never the real treasuries.
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);

    address constant V4_MGR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH   = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // the chain's dollar

    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    struct Cand { address token; uint24 fee; int24 tickSpacing; }

    function setUp() public {
        vm.createSelectFork("robinhood");
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4_MGR);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(WETH);
        hub.addBridge(USDG);
    }

    function test_V4_Discovered_And_Routed_Sweep() public {
        // Candidate hookless V4 pools vs the USDG bridge, read from the live
        // PoolManager's Initialize logs (2026-08-12). A general set — the run
        // tallies whichever are live, it does not depend on any single one.
        Cand[3] memory set = [
            Cand({token: 0x6b711B581aDDe09158B5B26Df9ed428cAf8479B1, fee: 50000,  tickSpacing: 100}),  // SPAC
            Cand({token: 0xe37E4a8b3D14274a3fdE3D841dE65E83E2a943aC, fee: 900000, tickSpacing: 9000}), // MOMO
            Cand({token: 0x616bcd920e1e1F354750BBaf2FB3b3fa3B4aAE16, fee: 870000, tickSpacing: 8700})  // BAG
        ];

        uint256 discovered;
        uint256 routedViaV4;

        for (uint256 i; i < set.length; ++i) {
            Cand memory c = set[i];
            try hub.claimV4(USDG, c.token, c.fee, c.tickSpacing) returns (bytes32) {
                discovered++;
                try quoter.previewPlan(USDG, c.token, 100e6) returns (
                    BlazePhoenixQuoter.Preview memory pv, Route memory, bool
                ) {
                    if (pv.grossOut > 0 && _hasV4Leg(pv.route)) routedViaV4++;
                } catch {}
            } catch {}
        }

        console2.log("V4 candidates swept:", set.length);
        console2.log("V4 pools discovered (claim verified):", discovered);
        console2.log("swaps routed via a V4 leg:", routedViaV4);

        assertGt(discovered, 0, "no V4 pool passed the on-chain discovery proof");
        assertGt(routedViaV4, 0, "no swap was routed through a V4 leg");
    }

    function _hasV4Leg(Route memory r) private pure returns (bool) {
        for (uint256 h; h < r.hops.length; ++h) {
            Leg[] memory legs = r.hops[h].legs;
            for (uint256 l; l < legs.length; ++l) {
                if (legs[l].kind == BPC.KIND_V4) return true;
            }
        }
        return false;
    }
}
