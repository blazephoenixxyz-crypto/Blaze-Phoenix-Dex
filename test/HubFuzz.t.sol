// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub } from "../src/BlazePhoenixHub.sol";
import { PoolInfo } from "../src/BlazePhoenixCore.sol";

/// @notice Targeted fuzz/unit tests for the Hub registry: access control,
///         configuration guards, registration, ticking and eviction.
contract HubFuzzTest is Test {
    BlazePhoenixHub hub;
    address constant TA = address(0xAAaA);
    address constant TB = address(0xBBbB);

    // kinds / modes mirrored from the Hub
    uint8 constant KIND_V2 = 0;
    uint8 constant KIND_V3 = 1;
    uint8 constant KIND_STABLE = 2;
    uint8 constant KIND_SOLIDLY = 5;
    uint8 constant KIND_CURVE = 7;
    uint8 constant MODE_CALL_V2 = 0;
    uint8 constant MODE_CREATE2_V2 = 4;
    uint8 constant MODE_CREATE2_V3 = 5;
    uint8 constant MODE_CREATE2_CLONE = 6;
    uint8 constant MODE_CURVE_META = 8;

    bytes32 constant IH = bytes32(uint256(1));
    uint24[] noFees;
    int24[]  noSp;

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        // make this contract the router so we can drive recordSwap
        hub.setRoles(address(this), address(0x5), address(0x6));
    }

    // ─── initialize: only the deployer, only once (front-run closed) ───
    function test_initialize_onlyDeployerOnce() public {
        BlazePhoenixHub h = new BlazePhoenixHub(); // this contract is the deployer
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        h.initialize(address(0xBEEF), address(0));            // stranger cannot init
        h.initialize(address(this), address(0));              // deployer can
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        h.initialize(address(this), address(0));              // not twice
    }

    // ─── renounceControl: freezes control powers, keeps curator powers ───
    function test_renounceControl_freezesControlKeepsCurator() public {
        hub.renounceControl();

        // control powers are now frozen
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.setRoles(address(1), address(2), address(3));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.setV4Manager(address(9));

        // curator powers still work: registry can still grow
        uint8 idx = hub.addFactory(address(0xF), KIND_V3, MODE_CREATE2_V3, IH, noFees, noSp);
        assertEq(idx, 0);
        hub.addBridge(address(0xB1));
        hub.allowHook(address(0xABCD), true);

        // recording (router path, set before renounce) still works
        hub.recordSwap(address(0xC0fe), KIND_V3, 3000, address(0), TA, TB, 1e18, 1e18, 1e21);
        assertEq(hub.getActivePools(TA, TB).length, 1);
    }

    // ─── access control ───
    function test_recordSwap_onlyRouter() public {
        vm.prank(address(0xdEad));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.recordSwap(address(0x1234), KIND_V3, 3000, address(0), TA, TB, 1e18, 1e18, 1e18);
    }

    function test_seedPool_onlyOperator() public {
        vm.prank(address(0xdEad));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        hub.seedPool(address(0x1234), KIND_V3, 3000, address(0), TA, TB);
    }

    // ─── bridge cap (MAX_BRIDGES = 2) ───
    function test_bridge_capIsTwo() public {
        hub.addBridge(address(0x1));
        hub.addBridge(address(0x2));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(7)));
        hub.addBridge(address(0x3));
    }

    // ─── addFactory coherence guards ───
    function test_addFactory_rejectsInvalidKind() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(address(0xF), 8 /*>KIND_CURVE*/, MODE_CALL_V2, bytes32(0), noFees, noSp);
    }
    function test_addFactory_rejectsCurveWithoutMetaMode() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(address(0xF), KIND_STABLE, MODE_CALL_V2, bytes32(0), noFees, noSp);
    }
    function test_addFactory_rejectsCreate2WithoutHash() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(address(0xF), KIND_V3, MODE_CREATE2_V3, bytes32(0), noFees, noSp);
    }
    function test_addFactory_rejectsV2SaltForNonV2() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(address(0xF), KIND_V3, MODE_CREATE2_V2, IH, noFees, noSp);
    }
    function test_addFactory_rejectsCloneForNonSolidly() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(address(0xF), KIND_V3, MODE_CREATE2_CLONE, IH, noFees, noSp);
    }
    function test_addFactory_acceptsValidV3Create2() public {
        uint8 idx = hub.addFactory(address(0xF), KIND_V3, MODE_CREATE2_V3, IH, noFees, noSp);
        assertEq(idx, 0);
        assertEq(hub.factoryCount(), 1);
    }

    /// @dev Fuzz the (kind, mode) domain: a successful addFactory must satisfy
    ///      every documented coherence rule.
    function testFuzz_addFactory_guardsConsistent(uint8 kind, uint8 mode, bytes32 ih) public {
        kind = uint8(bound(kind, 0, 9));
        mode = uint8(bound(mode, 0, 9));
        try hub.addFactory(address(0xF), kind, mode, ih, noFees, noSp) {
            // If it succeeded, all invariants below must hold.
            assertLe(kind, KIND_CURVE);
            assertLe(mode, MODE_CURVE_META);
            if (kind == KIND_STABLE || kind == KIND_CURVE) assertEq(mode, MODE_CURVE_META);
            if (mode >= MODE_CREATE2_V2 && mode != MODE_CURVE_META) assertTrue(ih != bytes32(0));
            if (mode == MODE_CREATE2_V2) assertEq(kind, KIND_V2);
            if (mode == MODE_CREATE2_CLONE) assertEq(kind, KIND_SOLIDLY);
        } catch {}
    }

    // ─── keyOf is order-independent ───
    function testFuzz_keyOf_orderIndependent(address pool, address a, address b) public view {
        assertEq(hub.keyOf(pool, a, b), hub.keyOf(pool, b, a));
    }

    // ─── seed → active read ───
    function test_seedPool_thenActive() public {
        bytes32 key = hub.seedPool(address(0xC0fe), KIND_V3, 3000, address(0), TA, TB);
        PoolInfo[] memory ps = hub.getActivePools(TA, TB);
        assertEq(ps.length, 1);
        assertEq(ps[0].pool, address(0xC0fe));
        assertEq(hub.getPool(key), address(0xC0fe));
    }

    // ─── recordSwap ticks an existing pool (slot mutates, count stays) ───
    function test_recordSwap_ticksExisting() public {
        bytes32 key = hub.seedPool(address(0xC0fe), KIND_V3, 3000, address(0), TA, TB);
        uint256 before = hub.getSlot(key);
        hub.recordSwap(address(0xC0fe), KIND_V3, 3000, address(0), TA, TB, 1e18, 1e18, 1e21);
        uint256 afterSlot = hub.getSlot(key);
        assertTrue(afterSlot != before, "slot must mutate on tick");
        assertEq(hub.getActivePools(TA, TB).length, 1, "tick must not add a slot");
    }

    // ─── eviction: a deep newcomer displaces a shallow incumbent at capacity ──
    function test_eviction_deepDisplacesShallow() public {
        // fill 16 shallow pools (bucket 0)
        for (uint256 i; i < 16; ++i) {
            address p = address(uint160(uint256(keccak256(abi.encode("shallow", i))) | 1));
            hub.recordSwap(p, KIND_V3, 3000, address(0), TA, TB, 1e18, 1e18, 5e15);
        }
        assertEq(hub.getActivePools(TA, TB).length, 16, "should be full");

        address deep = address(uint160(uint256(keccak256("deep")) | 1));
        hub.recordSwap(deep, KIND_V3, 3000, address(0), TA, TB, 1e18, 1e18, 1e30);

        PoolInfo[] memory ps = hub.getActivePools(TA, TB);
        assertLe(ps.length, 16, "must never exceed MAX_SLOTS");
        bool found;
        for (uint256 i; i < ps.length; ++i) if (ps[i].pool == deep) found = true;
        assertTrue(found, "deep pool should have been admitted");
    }
}
