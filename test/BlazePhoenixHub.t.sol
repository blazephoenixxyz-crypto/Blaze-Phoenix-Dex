// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

contract BlazePhoenixHubTest is Test {
    BlazePhoenixHub hub;
    address admin = address(this);
    address tokenA = address(0x1111);
    address tokenB = address(0x2222);

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(admin, address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    /// @notice Regression for the V4 pool-key collision: addV4 must register
    ///         under the SAME key formula recordSwap looks up later, or the
    ///         pool's first real swap silently creates a duplicate registry
    ///         entry instead of ticking the existing one.
    function test_AddV4_KeyMatchesRecordSwapKey() public {
        uint24 fee = 500;
        int24 tickSpacing = 10;
        address hooks = address(0);

        bytes32 keyFromAddV4 = hub.addV4(tokenA, tokenB, fee, tickSpacing, hooks);

        (address s0, address s1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, tickSpacing, hooks);
        address poolAddr = address(uint160(uint256(pid)));
        bytes32 keyRecordSwapWouldUse = hub.keyOf(poolAddr, s0, s1);

        assertEq(keyFromAddV4, keyRecordSwapWouldUse,
            "addV4 must register under the exact key recordSwap computes for the same pool");

        PoolInfo[] memory before = hub.getActivePools(tokenA, tokenB);
        assertEq(before.length, 1);
        uint32 swapCountBefore = BPC.decodeSwapCount(hub.getSlot(keyFromAddV4));

        hub.recordSwap(poolAddr, BPC.KIND_V4, fee, hooks, tokenA, tokenB, 1e18, 1e18, 123);

        PoolInfo[] memory afterSwap = hub.getActivePools(tokenA, tokenB);
        assertEq(afterSwap.length, 1,
            "recordSwap on the same V4 pool must not create a duplicate registry entry");
        assertEq(BPC.decodeSwapCount(hub.getSlot(keyFromAddV4)), swapCountBefore + 1,
            "the SAME slot must have its swap count incremented, not a new one created");
    }

    function test_AddFactory_RejectsCurveWithoutMetaMode() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(address(0x3333), BPC.KIND_STABLE, 0, bytes32(0), new uint24[](0), new int24[](0));
    }

    function test_RenounceControl_LeavesCuratorPowersAvailable() public {
        hub.renounceControl();
        // Curator power (onlyAdmin) must still work post-renouncement.
        hub.allowHook(address(0x4444), true);
        // Control power (onlyControl) must now be permanently disabled.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        hub.setPaused(true);
    }

    /// @notice addBridge/addFactory are documented as CURATOR powers that
    ///         also survive renounceControl (unlike allowHook's dedicated
    ///         test above) — the "grows the registry only" claim covers all
    ///         three onlyAdmin functions, not just allowHook.
    function test_RenounceControl_AddBridgeAndAddFactoryStillWork() public {
        hub.renounceControl();
        hub.addBridge(address(0x5555));
        assertTrue(hub.isBridgeToken(address(0x5555)));
        hub.addFactory(address(0x6666), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        assertEq(hub.factoryCount(), 1);
    }

    function test_RenounceControl_RemoveBridgeDisabledAfterRenounce() public {
        hub.addBridge(address(0x5555));
        hub.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        hub.removeBridge(0);
    }

    // =========================================================================
    //  addFactory — coherence-guard matrix
    // =========================================================================

    function test_AddFactory_RevertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 3));
        hub.addFactory(address(0), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
    }

    function test_AddFactory_RevertsOnInvalidKind() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(address(0x3333), 8, 0, bytes32(0), new uint24[](0), new int24[](0));
    }

    function test_AddFactory_RevertsOnInvalidMode() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(address(0x3333), BPC.KIND_V2, 9, bytes32(0), new uint24[](0), new int24[](0));
    }

    function test_AddFactory_Create2ModeRequiresInitHash() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(address(0x3333), BPC.KIND_V2, 4, bytes32(0), new uint24[](0), new int24[](0));
    }

    function test_AddFactory_V2SaltModeRejectsNonV2Kind() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(address(0x3333), BPC.KIND_V3, 4, bytes32(uint256(1)), new uint24[](0), new int24[](0));
    }

    function test_AddFactory_CloneModeRejectsNonSolidlyKind() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(address(0x3333), BPC.KIND_V2, 6, bytes32(uint256(1)), new uint24[](0), new int24[](0));
    }

    function test_AddFactory_V3SaltModeRejectsWrongKind() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(address(0x3333), BPC.KIND_V2, 5, bytes32(uint256(1)), new uint24[](0), new int24[](0));
    }

    function test_AddFactory_AlgebraRequiresZeroFeeSentinel() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500; // non-zero: Algebra is dynamic-fee, this must be rejected
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 5));
        hub.addFactory(address(0x3333), BPC.KIND_ALGEBRA, 5, bytes32(uint256(1)), fees, new int24[](0));
    }

    function test_AddFactory_AlgebraAcceptsZeroFeeSentinel() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = 0;
        uint8 idx = hub.addFactory(address(0x3333), BPC.KIND_ALGEBRA, 5, bytes32(uint256(1)), fees, new int24[](0));
        assertEq(idx, 0);
        assertEq(hub.factoryCount(), 1);
    }

    function test_AddFactory_ValidV2FactoryCall_Succeeds() public {
        uint8 idx = hub.addFactory(address(0x3333), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        assertEq(idx, 0);
        assertEq(hub.factoryCount(), 1);
    }

    function test_AddFactory_OnlyAdmin() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        hub.addFactory(address(0x3333), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
    }

    function test_AddFactory_RevertsAboveMaxFactories() public {
        for (uint256 i; i < 16; ++i) {
            hub.addFactory(address(uint160(0x9000 + i)), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        }
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 4));
        hub.addFactory(address(0xAAAA), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
    }

    // =========================================================================
    //  Bridges
    // =========================================================================

    function test_AddBridge_RevertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 3));
        hub.addBridge(address(0));
    }

    function test_AddBridge_RevertsAboveMaxBridges() public {
        hub.addBridge(address(0x5555));
        hub.addBridge(address(0x6666));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 7));
        hub.addBridge(address(0x7777));
    }

    function test_RemoveBridge_ShiftsArrayAndClearsFlag() public {
        hub.addBridge(address(0x5555));
        hub.addBridge(address(0x6666));
        hub.removeBridge(0);
        assertFalse(hub.isBridgeToken(address(0x5555)));
        assertTrue(hub.isBridgeToken(address(0x6666)));
        assertEq(hub.bridgeCount(), 1);
        assertEq(hub.bridge(0), address(0x6666), "surviving bridge must shift into slot 0");
    }

    function test_RemoveBridge_RevertsOnBadIndex() public {
        hub.addBridge(address(0x5555));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 4));
        hub.removeBridge(1);
    }

    // =========================================================================
    //  seedPool
    // =========================================================================

    function test_SeedPool_RegistersImmediately() public {
        bytes32 key = hub.seedPool(address(0x7777), BPC.KIND_V2, 30, address(0), tokenA, tokenB);
        assertTrue(BPC.isActive(hub.getSlot(key)));
        assertEq(hub.getPool(key), address(0x7777));
    }

    function test_SeedPool_OnlyOperator() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        hub.seedPool(address(0x7777), BPC.KIND_V2, 30, address(0), tokenA, tokenB);
    }

    function test_SeedPool_RevertsOnZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 3));
        hub.seedPool(address(0), BPC.KIND_V2, 30, address(0), tokenA, tokenB);
    }

    // =========================================================================
    //  recordSwap — access control, ticking, eviction
    // =========================================================================

    function test_RecordSwap_OnlyRouter() public {
        hub.setRoles(address(0xF00D), address(this), address(this));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        hub.recordSwap(address(0x7777), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
    }

    function test_RecordSwap_RevertsWhenPaused() public {
        hub.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 2));
        hub.recordSwap(address(0x7777), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
    }

    function test_RecordSwap_NewPoolRegistersThenTicksOnNextCall() public {
        hub.recordSwap(address(0x7777), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        bytes32 key = hub.keyOf(address(0x7777), tokenA, tokenB);
        assertEq(BPC.decodeSwapCount(hub.getSlot(key)), 1);

        hub.recordSwap(address(0x7777), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        assertEq(BPC.decodeSwapCount(hub.getSlot(key)), 2, "second call must tick the SAME slot");
        assertEq(hub.getActivePools(tokenA, tokenB).length, 1);
    }

    function test_RecordSwap_EvictsWeakestWhenFullAndNewcomerClearsMargin() public {
        // Fill all 16 slots with equal, shallow depth.
        for (uint256 i; i < 16; ++i) {
            hub.recordSwap(address(uint160(1000 + i)), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        }
        assertEq(hub.getActivePools(tokenA, tokenB).length, 16);

        // A vastly deeper newcomer (1000x) clears the 25% margin and must evict slot 0.
        hub.recordSwap(address(0x9999), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e21);

        PoolInfo[] memory active = hub.getActivePools(tokenA, tokenB);
        assertEq(active.length, 16, "count stays capped at MAX_SLOTS");
        bool sawEvictedPool;
        bool sawNewcomer;
        for (uint256 i; i < active.length; ++i) {
            if (active[i].pool == address(uint160(1000))) sawEvictedPool = true;
            if (active[i].pool == address(0x9999)) sawNewcomer = true;
        }
        assertFalse(sawEvictedPool, "weakest incumbent must be evicted");
        assertTrue(sawNewcomer, "deep newcomer must be admitted");
    }

    function test_RecordSwap_RejectsInsertWhenMarginNotCleared() public {
        for (uint256 i; i < 16; ++i) {
            hub.recordSwap(address(uint160(2000 + i)), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        }
        // Same depth as incumbents -> fails the strict 25% margin -> rejected.
        hub.recordSwap(address(0x9999), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);

        PoolInfo[] memory active = hub.getActivePools(tokenA, tokenB);
        for (uint256 i; i < active.length; ++i) {
            assertTrue(active[i].pool != address(0x9999), "newcomer must be rejected without clearing the margin");
        }
    }

    function test_RecordSwap_NoOpOnZeroPoolOrZeroAmountIn() public {
        hub.recordSwap(address(0), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        hub.recordSwap(address(0x7777), BPC.KIND_V2, 30, address(0), tokenA, tokenB, 0, 1e18, 1e18);
        assertEq(hub.getActivePools(tokenA, tokenB).length, 0);
    }

    // =========================================================================
    //  discoverFor — factory-call family + hasCode guard
    // =========================================================================

    function test_DiscoverFor_FindsFactoryCallPool() public {
        MockV2Factory factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        address pool = address(new MockERC20("P", "P")); // any deployed contract has code
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        factory.setPair(t0, t1, pool);

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1);
        assertEq(hits[0].pool, pool);
        assertEq(hits[0].kind, BPC.KIND_V2);
    }

    function test_DiscoverFor_SkipsCodelessDerivedAddress() public {
        MockV2Factory factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        factory.setPair(t0, t1, address(0xDEAD)); // no bytecode there

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 0, "hasCode guard must discard a codeless derived address");
    }

    function test_DiscoverFor_EmptyWhenNoFactoriesRegistered() public view {
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 0);
    }

    // =========================================================================
    //  initialize
    // =========================================================================

    function test_Initialize_RevertsOnSecondCall() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        hub.initialize(admin, address(0xBEEF));
    }

    function test_Initialize_RevertsWhenCalledByNonDeployer() public {
        BlazePhoenixHub fresh = new BlazePhoenixHub();
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        fresh.initialize(address(0xBAD), address(0));
    }
}
