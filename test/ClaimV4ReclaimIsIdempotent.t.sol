// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A re-claim of a live V4 pool is idempotent.
//
//  Inside `Hub.claimV4`:
//
//      if ($.poolOf[key] != address(0)) return key;
//
//  A live re-claim must not push a second `V4Entry` nor re-register the pool.
//  `test/DupKeyRepro.t.sol` repeats addV4/seedPool and exercises `_register`'s
//  own guard; this file calls `claimV4` twice on the same pool. The control
//  shows `v4EntryCount` does move for a distinct pool, so the first test does
//  not pass on a stuck counter. Setup follows
//  `test/HardeningA4_ClaimV4Margin.t.sol`.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Only the slots BPC.v4SqrtAndLiq reads.
contract ReclaimV4StateManager {
    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
}

contract ClaimV4ReclaimIsIdempotentTest is Test {
    BlazePhoenixHub hub;
    ReclaimV4StateManager mgr;

    address bridgeTok;
    address tokenB;
    address tokenC;
    address claimer = address(0xCA11);

    uint24 constant FEE = 3000;
    int24  constant TS  = 60;
    uint128 constant LIQ = 1e24;

    function setUp() public {
        mgr = new ReclaimV4StateManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.setRoles(address(this), address(this), address(this));
        bridgeTok = address(new MockERC20("BRG", "BRG"));
        tokenB = address(new MockERC20("B", "B"));
        tokenC = address(new MockERC20("C", "C"));
        hub.addBridge(bridgeTok);
    }

    function _plantV4Pool(address tA, address tB) private returns (bytes32 key) {
        (address s0, address s1) = BPC.sortTokens(tA, tB);
        bytes32 pid = BPC.computeV4PoolId(s0, s1, FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
        key = hub.keyOf(address(uint160(uint256(pid))), s0, s1);
    }

    function test_ReclaimOfALivePoolPushesNoSecondV4Entry() public {
        bytes32 key = _plantV4Pool(bridgeTok, tokenB);

        vm.prank(claimer);
        bytes32 k1 = hub.claimV4(bridgeTok, tokenB, FEE, TS);
        assertEq(k1, key, "the first claim returns the pool's key");
        uint256 after1 = hub.v4EntryCount();
        assertEq(after1, 1, "the first claim creates exactly one V4Entry");

        vm.prank(claimer);
        bytes32 k2 = hub.claimV4(bridgeTok, tokenB, FEE, TS);
        assertEq(k2, k1, "an idempotent re-claim returns the same key");
        assertEq(hub.v4EntryCount(), after1,
            "a re-claim of a live V4 pool must not push a second V4Entry");
    }

    /// @notice Control: a claim for a distinct pair pushes its own V4Entry.
    function test_Control_DistinctPoolPushesANewEntry() public {
        _plantV4Pool(bridgeTok, tokenB);
        _plantV4Pool(bridgeTok, tokenC);

        vm.prank(claimer);
        hub.claimV4(bridgeTok, tokenB, FEE, TS);
        uint256 after1 = hub.v4EntryCount();

        vm.prank(claimer);
        hub.claimV4(bridgeTok, tokenC, FEE, TS);

        assertEq(hub.v4EntryCount(), after1 + 1, "a distinct pair creates its own V4Entry");
    }
}
