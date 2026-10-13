// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Solver's discovery-freshness gate (`_registryFresh`) skips the CREATE2
//  discovery sweep when MIN_FRESH_VENUES registered pools were ticked within
//  DISCOVERY_TTL_SECONDS. It counted ANY registered row. Registration is
//  permissionless (recordSwap registers whatever a hand-built route just
//  executed through, after a pair proof a self-written contract satisfies),
//  so three dust pairs written by one attacker, kept fresh by three dust swaps
//  an hour, switched discovery OFF for the pair and hid every honest venue
//  that had never been registered. The registry then contained only what the
//  attacker wrote, and the depth-weighted band was theirs.
//
//  "Registered and recent" was read as "coverage is adequate". The object read
//  (rows written by whoever swapped first) is not the object that can vouch
//  for coverage. The Monoslot already carries the judge: `tier` (bits 40-47)
//  is 0 for a CURATED row (seedPool by an operator) and 2 for a permissionless
//  one (recordSwap, claimV4). Only tier-0 rows may vouch. Permissionless data
//  stays a CANDIDATE; it no longer chooses the path (the Unifying Law).
//
//  RED on main 19b2f08: the honest, discoverable pool is absent from the plan.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, PoolInfo, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

contract SolverFreshnessGateTrustsOnlyCuratedRowsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV2Factory factory;
    MockV2Pair honest;
    MockV2Pair[3] dust;

    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        // This contract plays the Router so it can reach recordSwap, the
        // permissionless registration door.
        hub.setRoles(address(this), address(solver), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        // An admitted mode-0 factory that answers getPair with a DEEP honest
        // pool. Never registered: nobody has routed through it yet.
        factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        honest = _pair(1_000_000e18, 1_000_000e18);
        factory.setPair(address(tokenA), address(tokenB), address(honest));
    }

    /// Funded to its declared reserves. Since 2026-09-02 the Solver caps a
    /// pair's declared depth by what it physically holds (PROV-01), so a mock
    /// with reserves and no tokens is a synthetic pair by definition — which
    /// is not what this file is about.
    function _pair(uint112 rA, uint112 rB) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokenA), address(tokenB));
        (uint112 r0, uint112 r1) = address(tokenA) < address(tokenB) ? (rA, rB) : (rB, rA);
        p.setReserves(r0, r1);
        tokenA.mint(address(p), rA);
        tokenB.mint(address(p), rB);
    }

    /// The attacker registers three self-written dust pairs through the
    /// permissionless door and ticks them "now".
    function _attackerRegistersThreeDustPairs() private {
        for (uint256 i; i < 3; ) {
            dust[i] = _pair(1e6, 1e6);
            hub.recordSwap(address(dust[i]), BPC.KIND_V2, 30, address(0),
                           address(tokenA), address(tokenB), 1, 1, 1e18);
            unchecked { ++i; }
        }
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

    /// Control: with an empty registry discovery runs and the honest pool
    /// routes. Proves the factory, the pool and the Solver are all wired.
    function test_Control_EmptyRegistry_DiscoveryFindsTheHonestPool() public view {
        assertTrue(_planUsesHonestPool(), "control: discovery reaches the honest pool");
    }

    /// RED on main: three permissionless dust rows, all fresh, satisfy the
    /// gate; discovery is skipped; the honest venue is invisible and the plan
    /// is built from the attacker's dust alone.
    function test_ThreeSelfRegisteredDustRows_CannotSilenceDiscovery() public {
        _attackerRegistersThreeDustPairs();
        PoolInfo[] memory reg = hub.getActivePools(address(tokenA), address(tokenB));
        assertEq(reg.length, 3, "premise: the attacker's three rows are registered");
        for (uint256 i; i < 3; ) {
            uint256 s = hub.getSlot(hub.keyOf(address(dust[i]), address(tokenA), address(tokenB)));
            assertEq(uint8(s >> 40), 2, "premise: permissionless rows carry tier 2");
            unchecked { ++i; }
        }
        assertTrue(_planUsesHonestPool(),
            "self-registered rows must not switch discovery off: the honest pool has to be in the plan");
    }

    /// Guard: CURATED rows still vouch. Three operator-seeded pools, all
    /// fresh, keep the gas shortcut: discovery is skipped and the plan is
    /// built from the registry alone (the honest, unregistered pool is
    /// legitimately invisible until the registry goes quiet).
    function test_ThreeCuratedRows_StillSkipDiscovery() public {
        for (uint256 i; i < 3; ) {
            MockV2Pair p = _pair(10_000e18, 10_000e18);
            tokenA.mint(address(p), 10_000e18);
            tokenB.mint(address(p), 10_000e18);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
            unchecked { ++i; }
        }
        assertFalse(_planUsesHonestPool(), "curated rows vouch: the sweep is skipped, as designed");
    }

    /// Guard: once the curated rows go quiet (past the TTL) discovery resumes.
    function test_CuratedRowsGoneQuiet_DiscoveryResumes() public {
        for (uint256 i; i < 3; ) {
            MockV2Pair p = _pair(10_000e18, 10_000e18);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
            unchecked { ++i; }
        }
        vm.warp(block.timestamp + 3_601);
        assertTrue(_planUsesHonestPool(), "quiet registry: the sweep runs again");
    }

    /// THE TWIN OF THE GUARD ABOVE, ONE DOOR FURTHER — and the only test that
    /// exercises the REFRESH. "Curated and recent" is not the age of the seed:
    /// `recordSwap`'s existing-row branch ticks the row and re-stamps its
    /// wall-clock activity time, so a pair that keeps being
    /// routed through keeps vouching for coverage past the TTL of its own seed.
    /// The whole refresh is ONE line, `Hub._stampTs` — the
    /// `ts` argument `tickSlot` receives is contractually IGNORED, which the
    /// Monoslot suite pins as algebra (`DiscoveryRefreshMonoslot`,
    /// TICK_LICENSE = {swapCount, lastBlk, bucket}: `lastUpdateTs` is not in it).
    /// Nothing else in `test/` reaches this path: the suite that pins the
    /// freshness gate only ever warps AWAY from activity, never back into it.
    /// FALSIFIER: neutralise `_stampTs` (`return s`) and this test goes red
    /// while its four siblings stay green.
    function test_CuratedRowsKeptFreshByActivity_StillSkipDiscovery() public {
        MockV2Pair[3] memory seeded;
        for (uint256 i; i < 3; ) {
            seeded[i] = _pair(10_000e18, 10_000e18);
            hub.seedPool(address(seeded[i]), BPC.KIND_V2, 30, address(0),
                         address(tokenA), address(tokenB));
            unchecked { ++i; }
        }
        vm.warp(block.timestamp + 3_601);
        assertTrue(_planUsesHonestPool(),
            "premise: past the seed's TTL and with no activity, the sweep runs");

        // The registry does not go quiet while the pair is being routed through:
        // one swap per curated row. A curated seed enters with no swap counted,
        // so the assertion is the delta, not a hardcoded value.
        for (uint256 i; i < 3; ) {
            bytes32 key = hub.keyOf(address(seeded[i]), address(tokenA), address(tokenB));
            uint256 before = BPC.decodeSwapCount(hub.getSlot(key));
            hub.recordSwap(address(seeded[i]), BPC.KIND_V2, 30, address(0),
                           address(tokenA), address(tokenB), 1, 1, 1e18);
            uint256 nowSlot = hub.getSlot(key);
            assertEq(uint8(nowSlot >> 40), 0, "activity must re-stamp a curated row without re-tiering it");
            assertEq(BPC.decodeSwapCount(nowSlot), before + 1, "the tick counted the swap");
            unchecked { ++i; }
        }

        assertFalse(_planUsesHonestPool(),
            "a curated row ticked within the TTL vouches again: the sweep is skipped, as designed");
    }
}
