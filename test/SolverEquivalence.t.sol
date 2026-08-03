// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BlazePhoenixSolver }    from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixSolverOld } from "./refs/BlazePhoenixSolverOld.sol";
import { PoolInfo, Route, Hop, Leg, RoutePlan } from "../src/BlazePhoenixCore.sol";
import { MockERC20, MockV2Pool, MockV3Pool, MockHub } from "./mocks/Mocks.sol";

/// @notice Differential fuzz: the optimised (1-probe) Solver must produce
///         BIT-FOR-BIT identical route plans to the original (3-probe) Solver
///         for every pool configuration and trade size. Both point at the same
///         MockHub, so any observable divergence is a bug in the refactor.
contract SolverEquivalenceTest {
    uint256 constant Q96 = 0x1000000000000000000000000;

    address tokenA;
    address tokenB;

    function setUp() public {
        // Deploy two tokens and order them so tokenA < tokenB (protocol assumes
        // sorted token0/token1).
        MockERC20 x = new MockERC20(18);
        MockERC20 y = new MockERC20(18);
        (tokenA, tokenB) = address(x) < address(y)
            ? (address(x), address(y))
            : (address(y), address(x));
    }

    function _b(uint256 v, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (v % (hi - lo + 1));
    }
    function _req(bool c, string memory m) internal pure { require(c, m); }

    /// @dev Build `nPools` pools (mix of V2 and V3) into a fresh hub from the
    ///      fuzz seed, then assert both solvers agree.
    function _buildAndCompare(uint256[8] memory seed, uint256 nPools, uint256 amountIn) internal {
        MockHub hub = new MockHub();
        nPools = _b(nPools, 2, 5);

        for (uint256 i; i < nPools; ) {
            uint256 s = seed[i];
            bool isV3 = (s & 1) == 1;
            uint256 psi = _b(s >> 1, 1, 1_000); // vary Ψ to vary top-K ordering
            PoolInfo memory p;
            address poolAddr;
            if (isV3) {
                uint160 sp = uint160(_b(s >> 8, Q96 / 2, Q96 * 2));
                uint128 L  = uint128(_b(s >> 40, 1e18, 1e26));
                MockV3Pool v3 = new MockV3Pool(tokenA, tokenB, sp, L);
                poolAddr = address(v3);
                p = PoolInfo({
                    active: true, stable: false, kind: 1 /*V3*/, fee: uint24(_b(s >> 70, 100, 10000)),
                    tickSpacing: 60, token0: tokenA, token1: tokenB, pool: poolAddr, hooks: address(0)
                });
            } else {
                uint112 r0 = uint112(_b(s >> 8,  1e18, 1e24));
                uint112 r1 = uint112(_b(s >> 60, 1e18, 1e24));
                MockV2Pool v2 = new MockV2Pool(tokenA, tokenB, r0, r1);
                poolAddr = address(v2);
                // Seed a realistic tokenB balance so the capital anchor engages.
                MockERC20(tokenB).setBalance(poolAddr, r1);
                p = PoolInfo({
                    active: true, stable: false, kind: 0 /*V2*/, fee: uint24(_b(s >> 100, 0, 100)),
                    tickSpacing: 0, token0: tokenA, token1: tokenB, pool: poolAddr, hooks: address(0)
                });
            }
            hub.register(tokenA, tokenB, p, psi);
            unchecked { ++i; }
        }

        BlazePhoenixSolver    sNew = new BlazePhoenixSolver(address(hub));
        BlazePhoenixSolverOld sOld = new BlazePhoenixSolverOld(address(hub));

        (bool okNew, bytes32 hNew) = _runNew(sNew, amountIn);
        (bool okOld, bytes32 hOld) = _runOld(sOld, amountIn);

        _req(okNew == okOld, "equiv: success/revert mismatch");
        if (okNew) _req(hNew == hOld, "equiv: route plan differs");
    }

    function _runNew(BlazePhoenixSolver s, uint256 amt) internal view returns (bool, bytes32) {
        try s.findBestRoutePlan(tokenA, tokenB, amt) returns (RoutePlan memory p) {
            return (true, keccak256(abi.encode(p)));
        } catch { return (false, bytes32(0)); }
    }
    function _runOld(BlazePhoenixSolverOld s, uint256 amt) internal view returns (bool, bytes32) {
        try s.findBestRoutePlan(tokenA, tokenB, amt) returns (RoutePlan memory p) {
            return (true, keccak256(abi.encode(p)));
        } catch { return (false, bytes32(0)); }
    }

    // ─── Broad fuzz: any pool mix, any trade size ───
    function testFuzz_equivalence(uint256[8] memory seed, uint256 nPools, uint256 amountIn) public {
        amountIn = _b(amountIn, 1e6, 1e28);
        _buildAndCompare(seed, nPools, amountIn);
    }

    // ─── Targeted: 4 near-equal-price V2 pools force the multi-leg split path
    //     (median + band + Ψ allocation), which is exactly where the three
    //     redundant probe quotes lived. ───
    function testFuzz_equivalence_multiLeg(uint256 amountIn, uint256 jitter) public {
        amountIn = _b(amountIn, 1e12, 1e24);
        MockHub hub = new MockHub();
        uint256 baseR0 = 1e22;
        uint256 baseR1 = 2e22; // price ~2.0
        for (uint256 i; i < 4; ) {
            // ±0.5% jitter keeps all four inside the ±2% band so the splitter
            // must allocate across multiple legs.
            uint256 j = _b(jitter >> (i * 8), 0, 100); // 0..1.0%
            uint112 r0 = uint112(baseR0);
            uint112 r1 = uint112(baseR1 + (baseR1 * j) / 10000);
            MockV2Pool v2 = new MockV2Pool(tokenA, tokenB, r0, r1);
            MockERC20(tokenB).setBalance(address(v2), r1);
            PoolInfo memory p = PoolInfo({
                active: true, stable: false, kind: 0, fee: 30,
                tickSpacing: 0, token0: tokenA, token1: tokenB, pool: address(v2), hooks: address(0)
            });
            hub.register(tokenA, tokenB, p, 1); // equal Ψ
            unchecked { ++i; }
        }
        BlazePhoenixSolver    sNew = new BlazePhoenixSolver(address(hub));
        BlazePhoenixSolverOld sOld = new BlazePhoenixSolverOld(address(hub));
        (bool okNew, bytes32 hNew) = _runNew(sNew, amountIn);
        (bool okOld, bytes32 hOld) = _runOld(sOld, amountIn);
        _req(okNew == okOld, "equiv-ml: success/revert mismatch");
        _req(okNew, "equiv-ml: expected a route");
        // Confirm we actually exercised a multi-leg split.
        try sNew.findBestRoutePlan(tokenA, tokenB, amountIn) returns (RoutePlan memory p) {
            _req(p.best.hops.length == 1, "equiv-ml: expected one hop");
            _req(p.best.hops[0].legs.length >= 2, "equiv-ml: expected >=2 legs");
        } catch { _req(false, "equiv-ml: new reverted unexpectedly"); }
        _req(hNew == hOld, "equiv-ml: route plan differs");
    }
}
