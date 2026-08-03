// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BlazePhoenixSolver }    from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixSolverOld } from "./refs/BlazePhoenixSolverOld.sol";
import { PoolInfo } from "../src/BlazePhoenixCore.sol";
import { MockERC20, MockV2Pool, MockV3Pool, MockHub } from "./mocks/Mocks.sol";

/// @notice Measures the gas delta between the original 3-probe Solver and the
///         optimised 1-probe Solver on a 5-pool direct route. Mocks use trivial
///         (memory-cheap) reads, so this is a LOWER BOUND on the real win —
///         production pools pay cold-SLOAD costs on every redundant read.
contract BenchGasTest {
    uint256 constant Q96 = 0x1000000000000000000000000;
    address tA;
    address tB;

    event GasResult(string scenario, uint256 oldGas, uint256 newGas, uint256 saved, uint256 pctBps);

    function setUp() public {
        MockERC20 x = new MockERC20(18);
        MockERC20 y = new MockERC20(18);
        (tA, tB) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
    }

    function _hubWith5V3() internal returns (MockHub hub) {
        hub = new MockHub();
        for (uint256 i; i < 5; ) {
            // Clustered prices (all within ±2%) so all 5 survive → maximal split.
            uint160 sp = uint160(Q96 + (Q96 / 1000) * i); // ~+0.1% steps
            MockV3Pool v3 = new MockV3Pool(tA, tB, sp, uint128(1e23 + i * 1e21));
            PoolInfo memory p = PoolInfo({
                active: true, stable: false, kind: 1, fee: 3000,
                tickSpacing: 60, token0: tA, token1: tB, pool: address(v3), hooks: address(0)
            });
            hub.register(tA, tB, p, 1);
            unchecked { ++i; }
        }
    }

    function _hubWith5V2() internal returns (MockHub hub) {
        hub = new MockHub();
        for (uint256 i; i < 5; ) {
            uint112 r0 = uint112(1e22);
            uint112 r1 = uint112(2e22 + i * 1e19); // clustered ~price 2.0
            MockV2Pool v2 = new MockV2Pool(tA, tB, r0, r1);
            MockERC20(tB).setBalance(address(v2), r1);
            PoolInfo memory p = PoolInfo({
                active: true, stable: false, kind: 0, fee: 30,
                tickSpacing: 0, token0: tA, token1: tB, pool: address(v2), hooks: address(0)
            });
            hub.register(tA, tB, p, 1);
            unchecked { ++i; }
        }
    }

    function _measure(string memory tag, MockHub hub) internal {
        BlazePhoenixSolver    sNew = new BlazePhoenixSolver(address(hub));
        BlazePhoenixSolverOld sOld = new BlazePhoenixSolverOld(address(hub));
        uint256 amt = 1e21;
        bytes memory cd = abi.encodeWithSignature(
            "findBestRoutePlan(address,address,uint256)", tA, tB, amt);

        uint256 g0 = gasleft();
        (bool okO,) = address(sOld).staticcall(cd);
        uint256 oldGas = g0 - gasleft();

        g0 = gasleft();
        (bool okN,) = address(sNew).staticcall(cd);
        uint256 newGas = g0 - gasleft();

        require(okO && okN, "bench: a solver reverted");
        uint256 saved = oldGas > newGas ? oldGas - newGas : 0;
        uint256 pctBps = oldGas == 0 ? 0 : (saved * 10000) / oldGas;
        emit GasResult(tag, oldGas, newGas, saved, pctBps);
        require(newGas <= oldGas, "bench: new not cheaper");
    }

    function test_bench_5xV3() public { _measure("5xV3 direct", _hubWith5V3()); }
    function test_bench_5xV2() public { _measure("5xV2 direct", _hubWith5V2()); }
}
