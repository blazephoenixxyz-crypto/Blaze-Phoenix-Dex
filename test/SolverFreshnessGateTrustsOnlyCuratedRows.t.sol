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
//
//  Second defect (regfresh-1113): even CURATED rows only measure age and
//  count, never coverage. Three fresh seeds switched the sweep off while a
//  derivable venue the sweep would rank first was never registered (Optimism
//  WETH/wstETH, -378.68 bps vs discovery). Freshness now also needs the pair's
//  sweep stamp, written only by `Hub.refreshPair` after every hit of the Hub's
//  own `discoverFor` is a registry row, over the current factory epoch.
//  RED on pr123-math-b ab0bc56: test_ThreeCuratedSeeds_WithoutSweepStamp_StillSweep.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, PoolInfo, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockOriginFactory, Origin} from "./mocks/MockOriginFactory.sol";

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
        solver = new BlazePhoenixSolver(address(hub), address(0));
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
            // rizki-3107: the swap door seats only a pool a wired factory derives, so the
            // attacker left is one who deploys each dust pair on a permissionless venue the
            // Hub has wired (three forks' factories). Its rows still carry tier 2, and the
            // gate must still not count them.
            Origin.wire(hub, address(dust[i]), address(tokenA), address(tokenB), BPC.KIND_V2, 30);
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
        // regfresh-1113: a fresh sweep stamp, so the row tiers are the only thing left to refuse.
        // The refresh registers the honest pool too, so the plan alone cannot tell: the sweep must run.
        hub.refreshPair(address(tokenA), address(tokenB));
        assertEq(_stamp(), block.timestamp, "premise: the pair carries a fresh sweep stamp");
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.discoverFor.selector));
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
        // regfresh-1113: curated rows vouch only over a fresh sweep stamp; the refresh also
        // registers the honest pool, so the skip is asserted on the call, not on the plan.
        hub.refreshPair(address(tokenA), address(tokenB));
        _expectNoSweep();
        _out();
    }

    function _seedThreeCurated() private {
        for (uint256 i; i < 3; ) {
            MockV2Pair p = _pair(10_000e18, 10_000e18);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
            unchecked { ++i; }
        }
    }

    function test_ThreeCuratedSeeds_WithoutSweepStamp_StillSweep() public {
        _seedThreeCurated();
        // Three tier-0 rows, all stamped this block: the old gate called that
        // coverage. Nobody ever swept the pair, so the deep honest pool the sweep
        // derives was never registered — the sweep has to run.
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.discoverFor.selector));
        assertTrue(_planUsesHonestPool(),
            "fresh curated rows without a sweep stamp must not switch discovery off");
    }

    function _out() private view returns (uint256) {
        return solver.findBestRoutePlan(address(tokenA), address(tokenB), AMT).best.totalOut;
    }

    /// The pair's sweep stamp, keyed in this frame as the Solver keys it.
    function _stamp() private view returns (uint256) {
        return hub.sweptAt(BPC.pairKey(address(0), address(tokenA), address(tokenB)));
    }

    function _expectNoSweep() private {
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.discoverFor.selector), 0);
    }

    function test_RefreshPair_MaterialisesEveryHit_ThenStampsFresh() public {
        _seedThreeCurated();
        uint256 swept = _out();  // no stamp: the sweep runs and prices the honest pool
        vm.prank(address(0xBEEF));  // permissionless: any caller only pays
        hub.refreshPair(address(tokenB), address(tokenA));
        uint256 s = hub.getSlot(hub.keyOf(address(honest), address(tokenA), address(tokenB)));
        assertEq(BPC.decodeTier(s), 2, "the derived hit is a row, born tier 2 (never votes the quorum)");
        assertEq(_stamp(), block.timestamp, "stamped now, after the rows");
        _expectNoSweep();
        assertEq(_out(), swept, "fresh path == sweep path: the registry holds what the sweep finds");
    }

    function test_RefreshPair_NeverRewritesAnExistingRow() public {
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        bytes32 key = hub.keyOf(address(honest), address(tokenA), address(tokenB));
        uint256 before = hub.getSlot(key);
        assertEq(BPC.decodeTier(before), 0, "premise: a curated row");
        vm.warp(block.timestamp + 100);
        vm.roll(block.number + 10);
        hub.refreshPair(address(tokenA), address(tokenB));
        assertEq(hub.getSlot(key), before, "the refresh leaves an existing row's tier and clock untouched");
    }


    /// A full pair admits a swept hit only through `_canInsert`, the gate `recordSwap` and
    /// `claimV4` use. One mode 1 row lists sixteen pools at tiers 1..16 besides the honest
    /// pool of `setUp`: seventeen hits for sixteen seats. Tiers 1..15 are deep, tier 16 is
    /// shallow and is swept last, so a door that seats without the gate evicts a deep row.
    function test_RefreshPair_FullPair_ShallowSeventeenthIsNotSeated() public {
        MockOriginFactory o = Origin.tiers(hub, BPC.KIND_V2, 16);
        MockV2Pair[16] memory ps;
        for (uint24 t = 1; t <= 16; ++t) {
            ps[t - 1] = t < 16 ? _pair(1_000_000e18, 1_000_000e18) : _pair(1_000e18, 1_000e18);
            o.list(address(ps[t - 1]), address(tokenA), address(tokenB), t, false);
        }
        assertEq(hub.discoverFor(address(tokenA), address(tokenB)).length, 17, "premise: seventeen hits");
        hub.refreshPair(address(tokenA), address(tokenB));
        (address t0, address t1) = BPC.sortTokens(address(tokenA), address(tokenB));
        assertTrue(hub.getSlot(hub.keyOf(address(honest), t0, t1)) != 0, "the honest pool is seated");
        for (uint256 i; i < 15; ++i) {
            assertTrue(
                hub.getSlot(hub.keyOf(address(ps[i]), t0, t1)) != 0,
                string.concat("the deep pool at tier ", vm.toString(i + 1), " is seated")
            );
        }
        assertEq(hub.getSlot(hub.keyOf(address(ps[15]), t0, t1)), 0, "the shallow seventeenth is not seated");
    }

    /// The stamp shares the curated rows' boundary (G5-7): fresh while `age <= TTL`.
    /// `t` comes from the cheatcode: under via-IR a `block.timestamp` local can be re-read
    /// after the first warp, which moved the second warp a whole TTL later.
    function test_StampStillFresh_AtTtl() public {
        uint256 t = vm.getBlockTimestamp();
        hub.refreshPair(address(tokenA), address(tokenB));
        vm.warp(t + 1_000);
        _seedThreeCurated();
        vm.warp(t + 3_600);
        _expectNoSweep();
        _out();
    }

    function test_StampExpires_AtTtlPlusOne() public {
        uint256 t = vm.getBlockTimestamp();
        hub.refreshPair(address(tokenA), address(tokenB));
        vm.warp(t + 1_000);
        _seedThreeCurated();  // rows still fresh at t + 3601: only the stamp expired
        vm.warp(t + 3_601);
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.discoverFor.selector));
        _out();
    }

    function test_AddFactory_BumpsEpoch_StampGoesStale() public {
        _seedThreeCurated();
        hub.refreshPair(address(tokenA), address(tokenB));
        assertEq(_stamp(), block.timestamp, "premise: stamped");
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        assertEq(_stamp(), 0, "a stamp over an older universe is not coverage");
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.discoverFor.selector));
        _out();
    }

    function test_SeedPool_DoesNotStamp() public {
        _seedThreeCurated();
        assertEq(_stamp(), 0, "seeding is curation, not a sweep");
    }

    function test_SetV4Manager_BumpsEpoch_StampGoesStale() public {
        _seedThreeCurated();
        hub.refreshPair(address(tokenA), address(tokenB));
        assertEq(_stamp(), block.timestamp, "premise: stamped");
        hub.setV4Manager(address(0xC0FFEE));
        assertEq(_stamp(), 0, "a new V4 manager is a new sweep universe");
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.discoverFor.selector));
        _out();
    }

    /// Guard: once the curated rows go quiet (past the TTL) discovery resumes.
    function test_CuratedRowsGoneQuiet_DiscoveryResumes() public {
        for (uint256 i; i < 3; ) {
            MockV2Pair p = _pair(10_000e18, 10_000e18);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
            unchecked { ++i; }
        }
        vm.warp(block.timestamp + 3_601);
        // regfresh-1113: the stamp is fresh, so only the quiet rows can turn the sweep back on.
        hub.refreshPair(address(tokenA), address(tokenB));
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.discoverFor.selector));
        assertTrue(_planUsesHonestPool(), "quiet registry: the sweep runs again");
    }

    /// THE TWIN OF THE GUARD ABOVE, ONE DOOR FURTHER — and the only test that
    /// exercises the REFRESH. "Curated and recent" is not the age of the seed:
    /// `recordSwap`'s existing-row branch ticks the row and re-stamps its
    /// wall-clock activity time, so a pair that keeps being
    /// routed through keeps vouching for coverage past the TTL of its own seed.
    /// Since fix-1102 the whole refresh is `Core.tickSlot`, the clock's one
    /// writer: it stamps `ts` only on an ANCHORED tick (a material trade, the
    /// Router's TICK_ANCHORED bit) that closes a real interval, so dust no
    /// longer refreshes a curated row (BlazePhoenixCore.sol:2898, :2913;
    /// `Hub._stampTs` is gone).
    /// Nothing else in `test/` reaches this path: the suite that pins the
    /// freshness gate only ever warps AWAY from activity, never back into it.
    /// FALSIFIER: make `tickSlot` keep the old stamp (`lastTs` for `currentTs`
    /// at BlazePhoenixCore.sol:2913) and this test goes red while the four
    /// gate tests above stay green.
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
            // fix-1102 A: was a bare depth (1e18), because any tick counted and stamped; now the Router's
            // anchor bit, because only an anchored tick moves the count and the stamp (BlazePhoenixCore.sol:2898)
            hub.recordSwap(address(seeded[i]), BPC.KIND_V2, 30, address(0),
                           address(tokenA), address(tokenB), 1, 1, 1e18 | BPC.TICK_ANCHORED);
            uint256 nowSlot = hub.getSlot(key);
            assertEq(uint8(nowSlot >> 40), 0, "activity must re-stamp a curated row without re-tiering it");
            assertEq(BPC.decodeSwapCount(nowSlot), before + 1, "the tick counted the swap");
            unchecked { ++i; }
        }

        // regfresh-1113: a fresh sweep stamp, which also registers the honest pool; the skip is
        // asserted on the call.
        hub.refreshPair(address(tokenA), address(tokenB));
        _expectNoSweep();
        _out();
    }

    /// Concordance of two copies of one formula (0 B): the Hub's row stamp and `Core.stampTs`, which
    /// the Gate's wrappers stamp through, write the same field from the same clock. Since fix-1102
    /// `Hub._stampTs` is gone and the Hub's stamp is `Core.tickSlot`'s, written only on an anchored
    /// tick (BlazePhoenixCore.sol:2913). A slot the Hub stamped is a fixed point of Core's stamp at
    /// the same timestamp, so a moved field or a shifted clock in either copy shows here.
    function test_HubStampTs_AgreesWithCoreStampTs() public {
        MockV2Pair p = _pair(10_000e18, 10_000e18);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        vm.warp(block.timestamp + 1_234);
        bytes32 key = hub.keyOf(address(p), address(tokenA), address(tokenB));
        // fix-1102 A: was a bare depth (1e18), because any tick stamped through Hub._stampTs; now the Router's
        // anchor bit, because only an anchored tick stamps lastUpdateTs (BlazePhoenixCore.sol:2898, :2913)
        hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB), 1, 1,
                       1e18 | BPC.TICK_ANCHORED);
        uint256 s = hub.getSlot(key);
        assertEq(uint32(s >> 64), uint32(block.timestamp), "the Hub stamped lastUpdateTs = now");
        assertEq(s, BPC.stampTs(s, uint32(block.timestamp)), "the Hub's stamp is the Core's stamp");
    }
}
