// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Offline twin of test/fork/G7RobinhoodV4Wire.t.sol (which skips without DRPC_KEY): every G7
// deploy of a chain with a V4 PoolManager writes a factory row (PoolManager, KIND_V4,
// MODE_V4_DERIVE), the only row for which the Hub runs its V4 derive scan. Without it cold
// discovery (G7 mode D) sees no V4 pool (G7 robinhood midtail-1: 9 D rows SolverE(5)).
// Mutants in .github/scripts/mutants.py: the derive row dropped from `_v4Wire`, and `_v4Wire`
// dropped from `_robinhood`.

import {Test, Vm} from "forge-std/Test.sol";
import {G7Deploy} from "../tools/g7-gas-campaign/G7Deploy.s.sol";

contract G7DeployV4WireTest is G7Deploy, Test {
    bytes32 internal constant FACTORY_EV = keccak256("Factory_(address,uint8,uint8)");

    /// @dev Rows (PoolManager, KIND_V4, MODE_V4_DERIVE) among the recorded Factory_ events.
    function _deriveRows(address pm) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hub) || logs[i].topics[0] != FACTORY_EV) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != pm) continue;
            (uint8 kind, uint8 mode) = abi.decode(logs[i].data, (uint8, uint8));
            if (kind == KIND_V4 && mode == MODE_V4_DERIVE) ++n;
        }
    }

    function _check(address pm) internal {
        assertEq(hub.v4PoolManager(), pm, "Hub PoolManager");
        assertEq(_deriveRows(pm), 1, "V4 derive row");
    }

    function test_G7Deploy_Robinhood_WiresTheV4DeriveRow() public {
        vm.recordLogs();
        _robinhood(address(this));
        _check(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    }

    function test_G7Deploy_Optimism_WiresTheV4DeriveRow() public {
        vm.recordLogs();
        _optimism(address(this));
        _check(0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3);
    }

    function test_G7Deploy_Arbitrum_WiresTheV4DeriveRow() public {
        vm.recordLogs();
        _arbitrum(address(this));
        _check(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);
    }

    function test_G7Deploy_Base_WiresTheV4DeriveRow() public {
        vm.recordLogs();
        _base(address(this));
        _check(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    }
}
