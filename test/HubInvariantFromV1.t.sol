// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/HubInvariant.t.sol — a genuine gap: this repo's only
// existing invariant/stateful-fuzz suite (BlazePhoenixRouter.invariant.t.sol) targets the Router,
// not the Hub. No stateful fuzz here exercises the registry's own core safety property under
// random interleaved registration/ticking/eviction: a pair can never hold more than MAX_SLOTS
// (16) active pools, and every active entry resolves to a real, non-zero pool address, no matter
// how insertion order and eviction margins (EVICTION_IMPROVE_BPS) interact across many calls.
//
// forge test --match-contract HubInvariantFromV1 -vv

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {PoolInfo} from "../src/BlazePhoenixCore.sol";

/// @dev Drives recordSwap with bounded random pools/depths on a fixed pair. Acts as the Hub's
///      router so recordSwap is authorised.
contract HubInvariantHandler is Test {
    BlazePhoenixHub public hub;
    address public immutable t0;
    address public immutable t1;
    uint256 public inserts;

    constructor(BlazePhoenixHub h, address a, address b) { hub = h; t0 = a; t1 = b; }

    function recordSwap(uint256 seed, uint256 depth) external {
        // Distinct, non-zero pool address derived from the seed.
        address pool = address(uint160(uint256(keccak256(abi.encode(seed))) | 1));
        depth = bound(depth, 0, 1e30);
        uint8 kind = uint8(bound(uint256(uint160(pool)), 0, 1)); // V2 or V3
        try hub.recordSwap(pool, kind, 3000, address(0), t0, t1, 1e18, 1e18, depth) {
            inserts++;
        } catch {}
    }
}

contract HubInvariantFromV1Test is StdInvariant, Test {
    BlazePhoenixHub hub;
    HubInvariantHandler handler;
    address constant T0 = address(0x1111);
    address constant T1 = address(0x2222);
    uint256 constant MAX_SLOTS = 16;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        handler = new HubInvariantHandler(hub, T0, T1);
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
