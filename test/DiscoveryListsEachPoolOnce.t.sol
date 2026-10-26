// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Discovery lists each pool once - on both channels that can produce a repeat.
//
//  1. Factory-call rows (`_probe`): a factory that lists ONE pool at two fee
//     tiers answers the same pool to two questions its mode does ask
//     (`getPool(t0, t1, fee)`, mode 1). A mode that does not read the fee
//     asks once whatever the grid (`_axes`,
//     test/DiscoveryProbesEachDerivationOnce.t.sol): `MockV2Factory`'s
//     `getPair` takes no fee, so its two tiers are one question, and
//     `test_FactoryCall_SamePoolForTwoFees_ListedOnce` pins the outcome
//     without reaching the dedup.
//  2. The V4 derive scan (`_admitV4`): the canonical pass and the row's extras
//     pass reach the SAME pool id when an extra equals a canonical tier.
//
//  Both loops carry the same guard, `if (hits[d].pool == p) return ...;`.
//  Without it one venue fills several of the Solver's top-K seats and crowds
//  out deeper ones. The control shows two distinct pools still list as two.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockOriginFactory} from "./mocks/MockOriginFactory.sol";

/// @dev V4 PoolManager state mock: the batched and the single extsload over one
///      settable slot map (the two reads the derive scan makes).
contract DedupV4DeriveManager {
    mapping(bytes32 => bytes32) public slots;

    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }

    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }

    function extsload(bytes32[] calldata targets) external view returns (bytes32[] memory out) {
        out = new bytes32[](targets.length);
        for (uint256 i; i < targets.length; ++i) out[i] = slots[targets[i]];
    }
}

contract DiscoveryListsEachPoolOnceTest is Test {
    BlazePhoenixHub hub;

    uint8 constant MODE_ASK       = 0;
    uint8 constant MODE_ASK_FEE   = 1;
    uint8 constant MODE_V4_DERIVE = 9;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
    }

    function _sorted(address a, address b) private pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    /// @notice One factory, two fee tiers, one pool: listed once.
    function test_FactoryCall_SamePoolForTwoFees_ListedOnce() public {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        MockV2Pair pair = new MockV2Pair(address(a), address(b));

        MockV2Factory fac = new MockV2Factory();
        fac.setPair(address(a), address(b), address(pair));

        uint24[] memory fees = new uint24[](2);
        fees[0] = 100;
        fees[1] = 300;
        hub.addFactory(address(fac), BPC.KIND_V2, MODE_ASK, bytes32(0), fees, new int24[](0));

        (address t0, address t1) = _sorted(address(a), address(b));
        PoolInfo[] memory hits = hub.discoverFor(t0, t1);

        assertEq(hits.length, 1, "the same pool for two fees is listed once");
        assertEq(hits[0].pool, address(pair), "the one venue is the factory's pair");
    }

    /// @notice One factory lists one pool at two fee tiers, and mode 1 asks for each tier:
    ///         two questions, one answer, listed once.
    function test_FactoryCall_OnePoolAtTwoTiersItReads_ListedOnce() public {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        MockV2Pair pair = new MockV2Pair(address(a), address(b));

        MockOriginFactory fac = new MockOriginFactory();
        fac.list(address(pair), address(a), address(b), 100, false);
        fac.list(address(pair), address(a), address(b), 300, false);

        uint24[] memory fees = new uint24[](2);
        fees[0] = 100;
        fees[1] = 300;
        hub.addFactory(address(fac), BPC.KIND_V3, MODE_ASK_FEE, bytes32(0), fees, new int24[](0));

        (address t0, address t1) = _sorted(address(a), address(b));
        PoolInfo[] memory hits = hub.discoverFor(t0, t1);

        assertEq(hits.length, 1, "one pool at two tiers is listed once");
        assertEq(hits[0].pool, address(pair), "the one venue is the factory's pool");
        assertEq(hits[0].fee, 100, "at the first tier that answered it");
    }

    /// @notice Control: two factories, two distinct pools, two venues.
    function test_Control_FactoryCall_TwoDistinctPools_TwoVenues() public {
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        MockV2Pair p1 = new MockV2Pair(address(a), address(b));
        MockV2Pair p2 = new MockV2Pair(address(a), address(b));

        MockV2Factory f1 = new MockV2Factory();
        f1.setPair(address(a), address(b), address(p1));
        MockV2Factory f2 = new MockV2Factory();
        f2.setPair(address(a), address(b), address(p2));

        hub.addFactory(address(f1), BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));
        hub.addFactory(address(f2), BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));

        (address t0, address t1) = _sorted(address(a), address(b));
        assertEq(hub.discoverFor(t0, t1).length, 2, "distinct pools remain two venues");
    }

    /// @notice A V4 derive row whose extra equals a canonical tier: the
    ///         canonical pass and the extras pass reach the same pool id, and
    ///         it is listed once.
    function test_V4Derive_CanonicalAndExtraOnTheSameTier_ListedOnce() public {
        DedupV4DeriveManager mgr = new DedupV4DeriveManager();
        hub.initialize(address(this), address(mgr));
        address bridge = address(new MockERC20("BRG", "BRG"));
        address counter = address(new MockERC20("CTR", "CTR"));
        hub.addBridge(bridge);

        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        int24[] memory spacings = new int24[](1);
        spacings[0] = 60;
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), fees, spacings);

        (address s0, address s1) = _sorted(bridge, counter);
        bytes32 pid  = BPC.computeV4PoolId(s0, s1, 3000, 60, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(1e24)));

        PoolInfo[] memory hits = hub.discoverFor(bridge, counter);
        assertEq(hits.length, 1, "canonical and extra on the same tier list the pool once");
        assertEq(hits[0].pool, address(uint160(uint256(pid))), "the one venue is the planted pool");
    }
}
