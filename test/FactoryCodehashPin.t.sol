// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev The implementation a proxy factory delegates to: it answers `getPair`
///      with one fixed address. Swapping the implementation swaps the answer
///      without changing the proxy's own runtime code.
contract FixedPairLogic {
    address internal immutable pair;
    constructor(address pair_) { pair = pair_; }
    function getPair(address, address) external view returns (address) { return pair; }
}

/// @dev A factory that is an upgradeable proxy. Its runtime codehash is fixed
///      forever; what it RETURNS is not.
contract MutableFactoryProxy {
    address public implementation;
    function upgradeTo(address next) external { implementation = next; }
    fallback() external {
        address target = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @notice Hooks carry a runtime-codehash pin (`isHookLive`): a hook whose code
///         changes stops being routable. Factories admitted under the
///         factory-CALL modes carried no equivalent commitment, and there is no
///         `removeFactory`, so after `renounceControl()` an admitted mutable
///         factory could redirect discovery to arbitrary pools with no remaining
///         control-plane response.
///
///         Reported externally 2026-08-26 (T17). The asymmetry was real: the
///         design already knew how to bind a listed dependency's runtime — it
///         simply never applied it to factories. The cure mirrors `isHookLive`
///         and fails CLOSED (the factory stops producing candidates) rather than
///         reverting, so one stale dependency can never brick discovery for the
///         pairs every other factory still serves.
contract FactoryCodehashPinTest is Test {
    BlazePhoenixHub internal hub;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockV2Pair internal honest;
    MockV2Pair internal attackerPool;
    MutableFactoryProxy internal factory;
    bytes32 internal factoryCodehashAtAdmission;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));

        tokenA = new MockERC20("Dollar A", "USDA");
        tokenB = new MockERC20("Dollar B", "USDB");
        honest = _pair(1_000_000e18);
        attackerPool = _pair(1e18);

        factory = new MutableFactoryProxy();
        factory.upgradeTo(address(new FixedPairLogic(address(honest))));
        hub.addFactory(
            address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0)
        );
        factoryCodehashAtAdmission = address(factory).codehash;
    }

    function _pair(uint256 reserve) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(p), reserve);
        tokenB.mint(address(p), reserve);
        p.setReserves(uint112(reserve), uint112(reserve));
    }

    function _discoveredPools() internal returns (address[] memory found) {
        PoolInfo[] memory hits = hub.discoverFor(address(tokenA), address(tokenB));
        found = new address[](hits.length);
        for (uint256 i; i < hits.length; ++i) found[i] = hits[i].pool;
    }

    /// The honest baseline: an unchanged factory is discovered normally.
    function test_UnchangedFactoryStillDiscovers() public {
        address[] memory found = _discoveredPools();
        bool sawHonest;
        for (uint256 i; i < found.length; ++i) if (found[i] == address(honest)) sawHonest = true;
        assertTrue(sawHonest, "an unchanged factory must keep serving discovery");
    }

    /// RED BEFORE THE FIX: a factory whose RUNTIME changes after admission —
    /// the selfdestruct-and-redeploy shape, and any non-proxy mutation — stops
    /// steering discovery, exactly as a mutated hook stops being routable.
    function test_RuntimeMutatedFactoryStopsBeingADiscoverySource() public {
        hub.renounceControl();

        // The factory's code is replaced at the same address (what a redeploy at a
        // CREATE2 address, or any runtime mutation, looks like from the chain).
        FixedPairLogic hostile = new FixedPairLogic(address(attackerPool));
        vm.etch(address(factory), address(hostile).code);
        assertTrue(
            address(factory).codehash != factoryCodehashAtAdmission,
            "precondition: the runtime really changed"
        );

        address[] memory found = _discoveredPools();
        for (uint256 i; i < found.length; ++i) {
            assertTrue(
                found[i] != address(attackerPool),
                "a factory whose runtime changed must not steer discovery"
            );
        }
    }

    /// THE DISCLOSED LIMIT, pinned so nobody mistakes the guarantee for a wider
    /// one. A DELEGATE PROXY changes what it answers WITHOUT changing its own
    /// runtime, so no codehash pin can detect it — and the EVM offers no way to
    /// read another contract's storage, so the implementation slot cannot be
    /// pinned on-chain either. This is a property of the machine, not an
    /// oversight: the defence against a mutable factory is (a) not admitting
    /// one, (b) the CREATE2 modes 4-7, which derive addresses and never ask,
    /// and (c) the impact ceiling that stops any newly-surfaced thin pool from
    /// authorising an extreme fill (see MaxImpactCeiling.t.sol).
    function test_ProxyUpgradeIsNotDetectableByAnyCodehashPin() public {
        hub.renounceControl();
        bytes32 before_ = address(factory).codehash;
        factory.upgradeTo(address(new FixedPairLogic(address(attackerPool))));
        assertEq(address(factory).codehash, before_, "a proxy upgrade leaves the runtime identical");
    }

    /// The guard is fail-CLOSED, never a new revert: a stale factory stops
    /// contributing candidates, so the set discovery returns can only SHRINK
    /// when a source goes stale — never grow, never revert. (The proxy shape
    /// above leaves the runtime unchanged; here the runtime really changes.)
    function test_StaleFactoryDegradesGracefullyInsteadOfReverting() public {
        hub.renounceControl();
        address[] memory before_ = _discoveredPools();
        bool servedHonest;
        for (uint256 i; i < before_.length; ++i) if (before_[i] == address(honest)) servedHonest = true;
        assertTrue(servedHonest, "precondition: the factory served the honest pool while it was live");

        vm.etch(address(factory), address(new FixedPairLogic(address(attackerPool))).code);
        address[] memory after_ = _discoveredPools();   // returns: one stale source never bricks the pair
        assertLe(after_.length, before_.length, "a stale factory can only remove candidates, never add");
        for (uint256 i; i < after_.length; ++i) {
            assertTrue(after_[i] != address(attackerPool), "a stale factory steers nothing");
        }
    }
}
