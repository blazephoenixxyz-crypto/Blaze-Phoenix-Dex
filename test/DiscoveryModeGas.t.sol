// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Does the CREATE2 derivation path actually buy gas over the factory-call path?
//
// `BPC.deriveAddress` resolves a pool two ways (see note 045, "Integridade de derivação de
// endereço"): modes 0-3 do a real staticcall into the factory (always correct, costs a call per
// probe), modes 4-7 compute keccak256(0xff‖factory‖salt‖initCodeHash) locally (zero calls, but
// needs the right initCodeHash). Discovery probes every (fee × spacing) combination of every
// registered factory, so if the CREATE2 path is materially cheaper it is the single biggest
// lever on cold-start cost — the phase LifecycleMetrics.t.sol measured at 94,566 gas.
//
// Both arms below find the SAME number of pools, so the delta is purely derivation mechanism.
//
// forge test --match-contract DiscoveryModeGas -vv

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

contract DiscoveryModeGasTest is Test {
    MockERC20 tokenA;
    MockERC20 tokenB;
    address t0;
    address t1;

    // Any non-empty runtime code satisfies the hasCode() guard that discovery applies before
    // accepting a derived address; discovery itself makes no call into the pool.
    bytes constant POOL_CODE = hex"600160005260206000f3";
    bytes32 constant INIT_HASH = keccak256("blazephoenix.test.initcode");

    function setUp() public {
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        (t0, t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
    }

    /// @dev Mirrors deriveAddress's mode-4 (CREATE2_V2) salt: keccak256(t0 ‖ t1).
    function _create2Addr(address factory) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(t0, t1));
        return address(uint160(uint256(
            keccak256(abi.encodePacked(bytes1(0xff), factory, salt, INIT_HASH))
        )));
    }

    function _hubWithFactoryCallMode(uint256 n) internal returns (BlazePhoenixHub hub) {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        for (uint256 i; i < n; ++i) {
            MockV2Factory f = new MockV2Factory();
            address pool = address(uint160(uint256(keccak256(abi.encode("fc-pool", i)))));
            vm.etch(pool, POOL_CODE);
            f.setPair(t0, t1, pool);
            hub.addFactory(address(f), BPC.KIND_V2, 0 /*MODE_CALL*/, bytes32(0),
                new uint24[](0), new int24[](0));
        }
    }

    function _hubWithCreate2Mode(uint256 n) internal returns (BlazePhoenixHub hub) {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        for (uint256 i; i < n; ++i) {
            // The factory needs no code at all on this path — it is only salt material.
            address factory = address(uint160(uint256(keccak256(abi.encode("c2-factory", i)))));
            vm.etch(_create2Addr(factory), POOL_CODE);
            hub.addFactory(factory, BPC.KIND_V2, 4 /*MODE_CREATE2_V2*/, INIT_HASH,
                new uint24[](0), new int24[](0));
        }
    }

    function _measure(BlazePhoenixHub hub) internal view returns (uint256 gasUsed, uint256 found) {
        uint256 g0 = gasleft();
        PoolInfo[] memory hits = hub.discoverFor(address(tokenA), address(tokenB));
        gasUsed = g0 - gasleft();
        found = hits.length;
    }

    function test_DiscoveryGas_FactoryCall_vs_Create2() public {
        uint256[3] memory counts = [uint256(1), 4, 9]; // 9 ~ the real Base deploy's factory count
        for (uint256 c; c < counts.length; ++c) {
            uint256 n = counts[c];
            (uint256 gCall, uint256 foundCall) = _measure(_hubWithFactoryCallMode(n));
            (uint256 gC2, uint256 foundC2) = _measure(_hubWithCreate2Mode(n));

            assertEq(foundCall, n, "factory-call arm must find every pool");
            assertEq(foundC2, n, "CREATE2 arm must find every pool");

            console2.log("factories:", n);
            console2.log("   factory-call (mode 0) gas:", gCall);
            console2.log("   CREATE2      (mode 4) gas:", gC2);
            if (gCall > gC2) {
                console2.log("   saved by CREATE2:", gCall - gC2);
                console2.log("   saved, percent:", ((gCall - gC2) * 100) / gCall);
            } else {
                console2.log("   CREATE2 is NOT cheaper here; extra gas:", gC2 - gCall);
            }
        }
    }

    /// The per-factory marginal cost is what decides whether this scales on a real deploy.
    function test_DiscoveryGas_MarginalCostPerFactory() public {
        (uint256 gCall1,) = _measure(_hubWithFactoryCallMode(1));
        (uint256 gCall9,) = _measure(_hubWithFactoryCallMode(9));
        (uint256 gC2_1,) = _measure(_hubWithCreate2Mode(1));
        (uint256 gC2_9,) = _measure(_hubWithCreate2Mode(9));
        console2.log("marginal gas per extra factory, factory-call:", (gCall9 - gCall1) / 8);
        console2.log("marginal gas per extra factory, CREATE2    :", (gC2_9 - gC2_1) / 8);
    }
}
