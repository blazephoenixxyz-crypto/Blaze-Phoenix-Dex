// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  R-A, the last open persist axis — `kind` was declared, never refuted.
//
//  Hub.recordSwap is the one door where calldata becomes registry state, and
//  the team already hardened two of its three trusted fields:
//
//      uint24 feeReg = fee;                                 // calldata
//      if (kind != KIND_V4 && kind != KIND_V4_NATIVE) {
//          (, , bool dynShape) = BPC.v3StateAndDynFee(pool); // MEASURES the pool
//          feeReg = dynShape ? 0 : BPC.getV3Fee(pool);       // overrides calldata
//      }
//      _register(key, pool, kind, feeReg, address(0), t0, t1, false);
//      //                  ^^^^ calldata   ^^^^^^ measured  ^^^^ forced to zero
//
//  `fee` is refuted by measurement. `hooks` is eliminated outright. `kind` came
//  through raw — and `kind` is the `if` that decides whether `fee` gets measured
//  at all. The one unverified field governed the verification of the others.
//
//  It is also self-guarding: `_register` skips when the slot is already set, so
//  no honest swap ever corrects a kind planted by whoever got there first.
//  Front-running the first swap on an unregistered real pool pins the wrong
//  kind permanently, and the Solver reads that kind as the pool's shape.
//
//  THE REFUTER ALREADY EXISTS, three lines above, doing this job for `fee`.
//  v3StateAndDynFee returns sqrtPriceX96 (0 when the pool is not concentrated)
//  and a flag for whether the pool answered Algebra's globalState() rather than
//  Uniswap's slot0(). That is enough to decide the concentrated family from the
//  pool itself, and enough to catch a declaration that contradicts the shape.
//
//  RED BEFORE THE FIX: both tests below persist the declared lie.
//
//  forge test --match-contract KindIsDerivedNotDeclared -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev Algebra-shaped pool: it does NOT answer slot0(), only globalState(),
///      which is exactly how the probe tells the two families apart.
contract AlgebraShapedPool {
    address public token0;
    address public token1;
    uint160 internal sqrtP;
    uint16  internal feeBps;

    constructor(address a, address b, uint160 sp, uint16 f) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        sqrtP = sp;
        feeBps = f;
    }

    /// (price, tick, fee, ...) — the probe reads word 0 as the price and word 2
    /// as the dynamic fee.
    function globalState() external view returns (uint160, int24, uint16, uint16, uint8, uint8, bool) {
        return (sqrtP, int24(0), feeBps, 0, 0, 0, true);
    }
}

contract KindIsDerivedNotDeclaredTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;

    MockERC20 tokA;
    MockERC20 tokB;

    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0
    uint128 constant LIQ      = 1_000_000e18;
    uint24  constant POOL_FEE = 3000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        // This test contract IS the Router, so it may call recordSwap.
        hub.setRoles(address(this), address(solver), address(this));

        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");
    }

    function _kindOf(address pool, address t0, address t1) internal view returns (uint8) {
        PoolInfo[] memory ps = hub.getActivePools(t0, t1);
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].pool == pool) return ps[i].kind;
        }
        revert("pool not registered");
    }

    // ─── an Algebra-shaped pool declared as Uniswap V3 ───────────────────────

    /// The two concentrated families price differently: Algebra carries a
    /// dynamic fee the pool itself reports, V3 a static tier. Persisting the
    /// wrong one makes every later quote for this pool use the wrong fee model,
    /// and no honest swap can correct it.
    function test_AlgebraShapedPool_MustNotPersistAsV3() public {
        AlgebraShapedPool p = new AlgebraShapedPool(address(tokA), address(tokB), SQRT_P_1, 500);

        hub.recordSwap(
            address(p), BPC.KIND_V3, POOL_FEE, address(0),
            address(tokA), address(tokB), 1e18, 1e18, 1e21
        );

        assertEq(_kindOf(address(p), address(tokA), address(tokB)), BPC.KIND_ALGEBRA,
            "a pool that answers globalState() is Algebra, whatever the calldata said");
    }

    // ─── a concentrated pool declared as a reserves pool ─────────────────────

    /// A V2 declaration on a concentrated pool is refutable outright: a V2 pair
    /// cannot answer slot0(). Registering it makes the Solver read reserves from
    /// a pool that has none.
    function test_ConcentratedPool_MustNotPersistAsV2() public {
        MockV3Pool p = new MockV3Pool(address(tokA), address(tokB), POOL_FEE);
        p.setState(SQRT_P_1, LIQ);

        hub.recordSwap(
            address(p), BPC.KIND_V2, 30, address(0),
            address(tokA), address(tokB), 1e18, 1e18, 1e21
        );

        PoolInfo[] memory ps = hub.getActivePools(address(tokA), address(tokB));
        for (uint256 i; i < ps.length; ++i) {
            assertTrue(ps[i].pool != address(p),
                "a concentrated pool declared KIND_V2 must not be registered on that lie");
        }
    }

    // ─── control: an honest declaration still registers ──────────────────────

    function test_Control_HonestV2Registers() public {
        MockV2Pair p = new MockV2Pair(address(tokA), address(tokB));
        tokA.mint(address(p), 1_000e18);
        tokB.mint(address(p), 1_000e18);
        p.setReserves(1_000e18, 1_000e18);

        hub.recordSwap(
            address(p), BPC.KIND_V2, 30, address(0),
            address(tokA), address(tokB), 1e18, 1e18, 1e21
        );

        assertEq(_kindOf(address(p), address(tokA), address(tokB)), BPC.KIND_V2,
            "an honest V2 declaration on a real V2 pair must still register");
    }

    function test_Control_HonestV3Registers() public {
        MockV3Pool p = new MockV3Pool(address(tokA), address(tokB), POOL_FEE);
        p.setState(SQRT_P_1, LIQ);

        hub.recordSwap(
            address(p), BPC.KIND_V3, POOL_FEE, address(0),
            address(tokA), address(tokB), 1e18, 1e18, 1e21
        );

        assertEq(_kindOf(address(p), address(tokA), address(tokB)), BPC.KIND_V3,
            "an honest V3 declaration on a slot0 pool must still register");
    }
}
