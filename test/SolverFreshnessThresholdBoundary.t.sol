// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Boundaries of the Solver's discovery-freshness gate (`_registryFresh`).
//
//  The gate skips the discovery sweep for a pair once MIN_FRESH_VENUES
//  CURATED rows (tier 0) of that pair were stamped within
//  DISCOVERY_TTL_SECONDS. SolverFreshnessGateTrustsOnlyCuratedRows pins WHO
//  may vouch (tier 0 only) and that three fresh curated rows skip the sweep.
//  This file pins the two edges that file leaves open:
//
//  1. COUNT. Every curated row below the threshold leaves the sweep on. A
//     deploy writes one curated row per seedPool / addV4, so a pair with a
//     lone deploy row must still be discovered: one row must not hide every
//     venue nobody has registered yet. The walk 0, 1, 2, 3 pins the threshold
//     at exactly MIN_FRESH_VENUES from both sides; the number is the owner's,
//     and changing it means changing this pin on purpose.
//  2. AGE. A row aged exactly DISCOVERY_TTL_SECONDS is still fresh; one second
//     later it is stale and the sweep resumes. The age is read from the row
//     the Hub wrote (decodeLastUpdateTs), never assumed from the warp.
//
//  RED under the registered mutants (.github/scripts/mutants.py):
//  MIN_FRESH_VENUES 3 -> 1 turns the walk red at the first row; the TTL
//  comparison `<=` -> `<` turns the age boundary red at exactly the TTL.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

contract SolverFreshnessThresholdBoundaryTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV2Factory factory;
    MockV2Pair honest;

    uint256 constant AMT = 1_000e18;
    /// Pinned by behaviour, not read: BlazePhoenixSolver.MIN_FRESH_VENUES and
    /// DISCOVERY_TTL_SECONDS are internal. Both tests below go red if either
    /// value moves, so this is a parity pin, not a dead copy.
    uint256 constant MIN_FRESH = 3;
    uint256 constant TTL = 3_600;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        // An admitted mode-0 factory that answers getPair with a DEEP honest
        // pool. Never registered: only the sweep can reach it.
        factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        honest = _pair(1_000_000e18, 1_000_000e18);
        factory.setPair(address(tokenA), address(tokenB), address(honest));
    }

    /// Funded to its declared reserves (PROV-01 caps declared depth by what
    /// the pair physically holds).
    function _pair(uint112 rA, uint112 rB) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokenA), address(tokenB));
        (uint112 r0, uint112 r1) = address(tokenA) < address(tokenB) ? (rA, rB) : (rB, rA);
        p.setReserves(r0, r1);
        tokenA.mint(address(p), rA);
        tokenB.mint(address(p), rB);
    }

    /// Seeds one curated row and returns the stamp the Hub wrote for it.
    function _seedCurated() private returns (uint256 last) {
        MockV2Pair p = _pair(10_000e18, 10_000e18);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        uint256 s = hub.getSlot(hub.keyOf(address(p), address(tokenA), address(tokenB)));
        assertEq(uint256(BPC.decodeTier(s)), 0, "premise: an operator seed is a curated row");
        last = uint256(BPC.decodeLastUpdateTs(s));
        assertGt(last, 0, "premise: the seed is stamped");
        assertLe(block.timestamp - last, TTL, "premise: the seed is fresh");
    }

    function _planUsesHonestPool() private view returns (bool) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT);
        for (uint256 h; h < plan.best.hops.length; ) {
            for (uint256 l; l < plan.best.hops[h].legs.length; ) {
                if (plan.best.hops[h].legs[l].pool == address(honest)) return true;
                unchecked { ++l; }
            }
            unchecked { ++h; }
        }
        return false;
    }

    /// COUNT: 0, 1 and 2 fresh curated rows leave the sweep on (the honest,
    /// unregistered pool routes); the third row reaches the threshold and the
    /// registry alone builds the plan, as designed.
    function test_EachCuratedRowBelowTheThreshold_LeavesTheSweepOn() public {
        assertTrue(_planUsesHonestPool(), "control: an empty registry runs the sweep");
        for (uint256 k = 1; k <= MIN_FRESH; ) {
            _seedCurated();
            if (k < MIN_FRESH) {
                assertTrue(_planUsesHonestPool(),
                    "below the threshold a fresh curated row must not hide discovery");
            } else {
                assertFalse(_planUsesHonestPool(),
                    "at the threshold the curated rows vouch: the sweep is skipped, as designed");
            }
            unchecked { ++k; }
        }
    }

    /// AGE: rows aged exactly the TTL still vouch; one second later they are
    /// stale and the sweep resumes. All rows are seeded in one block, so they
    /// share a stamp; the boundary is taken from that stamp.
    function test_CuratedRowsAgedExactlyTheTtl_StillVouch_OneSecondLater_SweepResumes() public {
        uint256 stamp = _seedCurated();
        for (uint256 k = 1; k < MIN_FRESH; ) {
            assertEq(_seedCurated(), stamp, "premise: one block, one stamp");
            unchecked { ++k; }
        }
        vm.warp(stamp + TTL);
        assertFalse(_planUsesHonestPool(), "an age of exactly the TTL is still fresh: the sweep is skipped");
        vm.warp(stamp + TTL + 1);
        assertTrue(_planUsesHonestPool(), "one second past the TTL the rows are stale: the sweep resumes");
    }
}
