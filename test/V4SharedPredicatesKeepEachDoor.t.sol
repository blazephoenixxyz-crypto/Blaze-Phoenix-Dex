// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A SHARED V4 PREDICATE KEEPS EVERY DOOR IT GUARDS.
//
//  Two predicates are written once and asked from more than one door:
//    `_v4Live` (in `_admitV4`): a V4 pool the scan found is listed only if it is
//      live. The batch read before it filters on the price alone, so a priced
//      pool with no liquidity reaches `_admitV4` and only `_v4Live` drops it.
//      `refreshPair` seats what `discoverFor` lists, so the same predicate is
//      what keeps such a pool out of the registry.
//    `_matchTiers`: one loop over packed (fee, spacing) codes, asked for the
//      canonical tiers and for each V4 derive row's paired extras when
//      `seedPool` recovers a V4 pool's spacing. A tier only a row's extras
//      carry (not canonical, not on the generator, no learned code, no
//      V4Entry) resolves through that loop and nothing else.
//  Each test pins one door, so a mutant of the shared line is red at each.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockV4ScanManager} from "./mocks/MockV4ScanManager.sol";

contract V4SharedPredicatesKeepEachDoorTest is Test {
    BlazePhoenixHub hub;
    MockV4ScanManager mgr;

    address bridge = address(0x1111);
    address counter = address(0x2222);
    address dummyFactory = address(0xFAC7);

    uint8 constant MODE_V4_DERIVE = 9;
    /// The row's one paired extra: not canonical, and 6000 % 10_000 != 0, off the generator.
    uint24 constant EXTRA_FEE = 6000;
    int24 constant EXTRA_TS = 120;

    function setUp() public {
        mgr = new MockV4ScanManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.addBridge(bridge);
        uint24[] memory fees = new uint24[](1);
        int24[] memory spacings = new int24[](1);
        fees[0] = EXTRA_FEE;
        spacings[0] = EXTRA_TS;
        // The factory address is never called (the scan reads the PoolManager).
        hub.addFactory(dummyFactory, BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), fees, spacings);
    }

    /// A hookless V4 pool at the StateLibrary layout the Core reads: slot0 with
    /// sqrtPriceX96 = Q96 at keccak(pid, 6), liquidity at base + 3.
    function _plant(uint24 fee, int24 ts, uint128 liq) private returns (address) {
        (address s0, address s1) = BPC.sortTokens(bridge, counter);
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, ts, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
        return address(uint160(uint256(pid)));
    }

    function _listed(PoolInfo[] memory hits, address pool) private pure returns (bool) {
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == pool) return true;
        return false;
    }

    // ─── _v4Live, at the discovery door and the refresh door ─────────────

    function test_DiscoverFor_PricedPoolWithoutLiquidity_IsNotListed() public {
        address live = _plant(3000, 60, 1e24);
        address dead = _plant(EXTRA_FEE, EXTRA_TS, 0);
        PoolInfo[] memory hits = hub.discoverFor(bridge, counter);
        assertTrue(_listed(hits, live), "control: the live pool is listed");
        assertFalse(_listed(hits, dead), "a priced pool without liquidity is listed");
    }

    function test_RefreshPair_PricedPoolWithoutLiquidity_SeatsNothing() public {
        address live = _plant(3000, 60, 1e24);
        address dead = _plant(EXTRA_FEE, EXTRA_TS, 0);
        hub.refreshPair(bridge, counter);
        (address t0, address t1) = BPC.sortTokens(bridge, counter);
        assertTrue(hub.getSlot(hub.keyOf(live, t0, t1)) != 0, "control: the live pool is seated");
        assertEq(hub.getSlot(hub.keyOf(dead, t0, t1)), 0, "a priced pool without liquidity is seated");
    }

    // ─── _matchTiers, at the seeding door ─────────────────────────────────

    function test_SeedPool_V4TierOnlyARowsExtrasCarry_Resolves() public {
        address pool = _plant(EXTRA_FEE, EXTRA_TS, 1e24);
        hub.seedPool(pool, BPC.KIND_V4, EXTRA_FEE, address(0), bridge, counter);
        PoolInfo[] memory act = hub.getActivePools(bridge, counter);
        bool found;
        for (uint256 i; i < act.length; ++i) {
            if (act[i].pool != pool) continue;
            found = true;
            assertEq(act[i].tickSpacing, EXTRA_TS, "spacing recovered from the row's extras");
            assertEq(act[i].fee, EXTRA_FEE, "fee as seeded");
        }
        assertTrue(found, "the seeded pool is active");

        // Control: a tier no source carries is refused.
        address stray = _plant(7000, 140, 1e24);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(4)));
        hub.seedPool(stray, BPC.KIND_V4, 7000, address(0), bridge, counter);
    }
}
