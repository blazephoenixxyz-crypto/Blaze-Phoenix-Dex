// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Each registration door writes what only it knows.
//
//  Since hubcura-1022, `Hub._register` takes runtime values only, so it keeps
//  one body whatever the AST IDs. Two fields moved out of it, to the doors:
//
//  1. The tier. Each door builds the born slot itself
//     (`Hub._born(kind, fee, trusted)`), with its own literal:
//
//         addV4      (operator)   tier 0
//         seedPool   (operator)   tier 0
//         claimV4    (anyone)     tier 2
//         recordSwap (router)     tier 2
//
//     test/FrozenAtWriteProbes.t.sol pins the seedPool and recordSwap arms
//     (`test_control_tier_isRefreshedInPlaceBySeedPool`). This file pins the
//     two V4 doors, which no test read before.
//
//  2. The hook. `hooksOf[key]` is written by the two doors that admit one,
//     addV4 and seedPool, after `_register`. The addV4 write is pinned by the
//     V4 routing tests (a hooked pool that is not routed); this file pins the
//     seedPool write, read back through `getActivePools`.
//
//  Setup follows test/ClaimV4ReclaimIsIdempotent.t.sol.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DoorsBirthStateManager {
    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
}

contract HubDoorsBirthTheirRowsTest is Test {
    BlazePhoenixHub hub;
    DoorsBirthStateManager mgr;

    address bridgeTok;
    address tokenB;
    address claimer = address(0xCA11);
    address hookListed = address(uint160(0x2000));

    uint24 constant FEE = 3000;
    int24  constant TS  = 60;
    uint128 constant LIQ = 1e24;

    function setUp() public {
        mgr = new DoorsBirthStateManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.setRoles(address(this), address(this), address(this));
        bridgeTok = address(new MockERC20("BRG", "BRG"));
        tokenB = address(new MockERC20("B", "B"));
        hub.addBridge(bridgeTok);
        hub.allowHook(hookListed, true);
    }

    function _plantV4Pool(address tA, address tB) private returns (bytes32 key) {
        (address s0, address s1) = BPC.sortTokens(tA, tB);
        bytes32 pid = BPC.computeV4PoolId(s0, s1, FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
        key = hub.keyOf(address(uint160(uint256(pid))), s0, s1);
    }

    function test_addV4_birthsItsRowAtTier0() public {
        bytes32 key = _plantV4Pool(bridgeTok, tokenB);
        assertEq(hub.addV4(bridgeTok, tokenB, FEE, TS, address(0)), key, "addV4 keys the planted pool");
        uint256 s = hub.getSlot(key);
        assertEq(BPC.decodeKind(s), BPC.KIND_V4, "pre-condition: the row is the V4 row");
        assertEq(BPC.decodeTier(s), 0, "the operator's V4 door births a curated row");
    }

    function test_claimV4_birthsItsRowAtTier2() public {
        bytes32 key = _plantV4Pool(bridgeTok, tokenB);
        vm.prank(claimer);
        assertEq(hub.claimV4(bridgeTok, tokenB, FEE, TS), key, "claimV4 keys the planted pool");
        uint256 s = hub.getSlot(key);
        assertEq(BPC.decodeKind(s), BPC.KIND_V4, "pre-condition: the row is the V4 row");
        assertEq(BPC.decodeTier(s), 2, "the permissionless V4 door births an uncurated row");
    }

    function test_seedPool_writesTheHookItAdmitted() public {
        address pool = address(0xF00E);
        hub.seedPool(pool, BPC.KIND_V2, 30, hookListed, bridgeTok, tokenB);
        PoolInfo[] memory rows = hub.getActivePools(bridgeTok, tokenB);
        assertEq(rows.length, 1, "pre-condition: the seeded row is the pair's one row");
        assertEq(rows[0].pool, pool, "pre-condition: it is the seeded pool");
        assertEq(rows[0].hooks, hookListed, "the seed door records the hook it admitted");
    }

    /// Control: a hookless seed reads back no hook, so the test above does not pass on a
    /// reader that reports the listed hook for every row.
    function test_control_seedPool_withoutAHookRecordsNone() public {
        hub.seedPool(address(0xF00E), BPC.KIND_V2, 30, address(0), bridgeTok, tokenB);
        PoolInfo[] memory rows = hub.getActivePools(bridgeTok, tokenB);
        assertEq(rows.length, 1, "pre-condition: the seeded row is the pair's one row");
        assertEq(rows[0].hooks, address(0), "a hookless seed records no hook");
    }
}
