// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The `mayPin` predicate of Hub.addFactory, after renunciation.
//
//  It decides whether the Algebra CREATE2 origin attested at admission
//  (`factoryDeployer`) is rewritten on a re-listing:
//
//      bool mayPin = pinned == address(0)
//          ? (row == n || !$.controlRenounced)              // first listing
//          : (!$.controlRenounced && live != address(0));   // already admitted
//      if (mayPin) $.factoryDeployer[factory] = live;
//
//  The files that pin renunciation admit mode 4, which never enters this mode-5
//  block, and the deployer-pin test reaches the block without renouncing. This
//  covers the combination:
//    A. a renounced re-admission of an already-admitted mode-5 row does not move
//       the pin (the second arm);
//    B. a fresh mode-5 listing after renunciation still attests (the first arm).
//  Both assert the outcome - which pool discovery serves - not the code.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {SwappableDeployerFactory} from "./T19AlgebraDeployerPin.t.sol";

contract RenouncedFactoryPinPredicateTest is Test {
    BlazePhoenixHub hub;

    address constant tokenA = address(0x2222);
    address constant tokenB = address(0x3333);
    address constant DEP_ATTESTED = address(0xA77E57ED);
    address constant DEP_SWAPPED  = address(0xBAD0DE99);

    uint8   constant MODE_CREATE2_V3 = 5;
    bytes32 constant INIT_HASH = keccak256("algebra-init");

    uint24[] internal noFees;
    int24[]  internal noSpacings;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xD00D));
    }

    function _algebraPool(address origin) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", origin, keccak256(abi.encode(tokenA, tokenB)), INIT_HASH
        )))));
    }

    // =========================================================================
    //  A. After renounce, an identical re-add of an admitted mode-5 row must
    //     NOT move the attested origin -- even if the live answer has moved.
    // =========================================================================

    function test_A_RenouncedReAdd_DoesNotMoveTheAttestedOrigin() public {
        SwappableDeployerFactory fac = new SwappableDeployerFactory(DEP_ATTESTED);
        hub.addFactory(address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings);

        address poolHonest  = _algebraPool(DEP_ATTESTED);
        address poolSteered = _algebraPool(DEP_SWAPPED);
        vm.etch(poolHonest, hex"fe");

        // Control: the attested origin governs before any renunciation.
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "control: one candidate");
        assertEq(hits[0].pool, poolHonest, "control: derived from the attested origin");

        hub.renounceControl();
        // The live answer moves (proxy swap); the codehash does not.
        fac.setPoolDeployer(DEP_SWAPPED);
        vm.etch(poolSteered, hex"fe");

        // Identical re-add of the SAME row (passes the HubE(1) freeze guard).
        hub.addFactory(address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings);

        hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "one row, one origin");
        assertEq(
            hits[0].pool, poolHonest,
            "after renunciation the attested origin must be FROZEN: an identical re-add may not move the pin"
        );
    }

    // =========================================================================
    //  B. A FRESH mode-5 listing after renounce must still attest its origin
    //     (`row == n`, the grow-only power Hub:411-418 keeps).
    // =========================================================================

    function test_B_RenouncedFreshListing_StillAttests() public {
        hub.renounceControl();

        SwappableDeployerFactory fresh = new SwappableDeployerFactory(DEP_ATTESTED);
        hub.addFactory(address(fresh), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings);

        address poolHonest = _algebraPool(DEP_ATTESTED);
        vm.etch(poolHonest, hex"fe");

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "a never-listed factory must still be admissible after renounce");
        assertEq(
            hits[0].pool, poolHonest,
            "a fresh listing attests its poolDeployer() answer: discovery must derive from it, not the factory fallback"
        );
    }
}
