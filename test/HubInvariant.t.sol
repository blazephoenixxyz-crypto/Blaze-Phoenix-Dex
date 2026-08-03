// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub } from "../src/BlazePhoenixHub.sol";
import { PoolInfo } from "../src/BlazePhoenixCore.sol";

/// @dev Drives recordSwap with bounded random pools/depths on a fixed pair.
///      Acts as the Hub's router so recordSwap is authorised.
contract HubHandler is Test {
    BlazePhoenixHub public hub;
    address public immutable t0;
    address public immutable t1;
    uint256 public inserts;

    constructor(BlazePhoenixHub h, address a, address b) { hub = h; t0 = a; t1 = b; }

    function recordSwap(uint256 seed, uint256 depth) external {
        // distinct, non-zero pool address from the seed
        address pool = address(uint160(uint256(keccak256(abi.encode(seed))) | 1));
        depth = bound(depth, 0, 1e30);
        uint8 kind = uint8(bound(uint256(uint160(pool)), 0, 1)); // V2 or V3
        try hub.recordSwap(pool, kind, 3000, address(0), t0, t1, 1e18, 1e18, depth) {
            inserts++;
        } catch {}
    }
}

/// @notice Stateful invariant testing of the Hub registry. The core safety
///         property: a pair can never hold more than MAX_SLOTS (16) active
///         pools, and every active entry resolves to a real pool address —
///         no matter how registration/eviction interleave.
contract HubInvariantTest is Test {
    BlazePhoenixHub hub;
    HubHandler handler;
    address constant T0 = address(0x1111);
    address constant T1 = address(0x2222);
    uint256 constant MAX_SLOTS = 16;

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
        handler = new HubHandler(hub, T0, T1);
        hub.setRoles(address(handler), address(0x5), address(0x6)); // router = handler
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_neverExceedsMaxSlots() public view {
        assertLe(hub.getActivePools(T0, T1).length, MAX_SLOTS);
    }

    function invariant_activePoolsResolve() public view {
        PoolInfo[] memory ps = hub.getActivePools(T0, T1);
        for (uint256 i; i < ps.length; ++i) {
            assertTrue(ps[i].pool != address(0), "active pool must resolve");
        }
    }
}
