// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PROV-01's SIBLING: the physical-mass cap covers PAIR-shaped pools only.
//
//  OBJECTION. `Router._recordHits` computes the registry depth three ways
//  (src/BlazePhoenixRouter.sol:2055-2103):
//     A_RESERVES  -> _v2Depth18(...)                 caps r0/r1 by balanceOf  (PROV-01)
//     A_CONC_SING -> depthFromL18(v4SqrtAndLiq(...))  no cap
//     else (V3)   -> depthFromL18(getLiquidity(pool), spReg, ...)   NO CAP
//  The V3/Algebra arm reads `liquidity()` and `slot0()` from `leg.pool`, an
//  address the caller wrote. The code assumes a pool's declared `liquidity()`
//  is backed by tokens it holds; NOTHING forces that.
//
//  The Solver's copy of the cap has the same scope, in one line:
//     src/BlazePhoenixSolver.sol:629  if (BPC.kindHas(cands[i].kind, BPC.A_RESERVES))
//
//  SHARED_QUANTITIES.md row "pool depth source" states PROV-01 as closed at
//  "both producers", and every sentence in it is about `getReserves`. The
//  concentrated family was never asked.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract ConcentratedMassCapTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool;

    address s0;
    address s1;

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint160 constant Q96     = uint160(uint256(1) << 96);   // price 1:1
    uint256 constant AMT     = 1_000e18;                    // the swap
    uint128 constant FORGED_L = uint128(1e33);              // the declaration
    uint256 constant PHYS    = 5_000e18;                    // what it really holds

    uint8 constant B_DECLARED = 15;   // depthBucket(1e33)  -> min(15, log10(1e18))
    uint8 constant B_PHYSICAL = 6;    // depthBucket(~4e21) -> log10(4.0e6)

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pool   = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pool.setState(Q96, FORGED_L);
        s0 = pool.token0();
        s1 = pool.token1();

        // The pool physically holds dust relative to what it declares.
        tokenA.mint(address(pool), PHYS);
        tokenB.mint(address(pool), PHYS);

        tokenA.mint(user, 1_000_000e18);
        tokenB.mint(user, 1_000_000e18);
        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _key() internal view returns (bytes32) {
        return hub.keyOf(address(pool), s0, s1);
    }

    function _route() internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool), hooks: address(0), kind: BPC.KIND_V3,
            fee: 3000, tickSpacing: 0, zeroForOne: true, stable: false,
            amountIn: AMT, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: s0, tokenOut: s1, amountIn: AMT, expectedOut: 0, legs: legs});
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _swap() internal returns (uint256) {
        vm.prank(user);
        return router.swapExactIn(_route(), AMT, 1, user, block.timestamp + 1);
    }

    // -------------------------------------------------------------------
    //  0. NON-VACUITY. The declared and the physical answers are different
    //     buckets at these constants.
    // -------------------------------------------------------------------
    function test_arith_TheTwoAnswersReallyDiffer() public pure {
        assertEq(BPC.depthBucket(BPC.depthFromL18(FORGED_L, Q96, 18, 18)), B_DECLARED,
            "declared L must land in the top bucket");
        assertEq(BPC.depthBucket(4_003e18), B_PHYSICAL,
            "physical short side must land in bucket 6");
    }

    // -------------------------------------------------------------------
    //  1. THE COUNTEREXAMPLE. One swap through a pool that declares
    //     liquidity 1e33 while holding 5_000e18 a side. PREDICTION: RED —
    //     the registry stores bucket 15, the physical mass supports 6.
    // -------------------------------------------------------------------
    function test_ConcentratedDepthIsTheDeclaredL_NotThePhysicalMass() public {
        uint256 got = _swap();
        assertGt(got, 0, "setup: the swap must really have executed");

        uint256 slot = hub.getSlot(_key());
        assertEq(BPC.decodeSwapCount(slot), 1, "setup: bucket must be written by THIS swap");

        uint8 written = BPC.decodeBucket(slot);
        // The bucket the pool's real holdings support, MEASURED after the swap.
        uint256 physical = BPC.shortSide18(
            tokenA.balanceOf(address(pool)), 18, tokenB.balanceOf(address(pool)), 18);
        uint8 supported = BPC.depthBucket(physical);

        emit log_named_uint("registry bucket written", written);
        emit log_named_uint("bucket the physical mass supports", supported);

        assertLe(written, supported,
            "the registry stored a depth the pool does not physically hold");
    }

    // -------------------------------------------------------------------
    //  2. THE CONSEQUENCE, and the property is not what it first looked like.
    //     The original assertion here was "the forged pool must not win a
    //     seat", written against a registry that had stored bucket 15 for a
    //     pool holding 5,000e18 a side. With the physical cap in place the
    //     stored bucket is 6, which this pool HONESTLY HOLDS - and refusing a
    //     real pool with real mass would be the wrong behaviour, not the right
    //     one. So the property to pin is the one the cap actually buys:
    //
    //         you may win a seat, but only at the mass you physically hold.
    //
    //     Sixteen incumbents seeded with no depth measurement sit at bucket 0,
    //     so a genuine bucket-6 pool beating them is the registry working.
    //     What must never happen again is the seat being bought at bucket 15.
    // -------------------------------------------------------------------
    function test_ASeatIsWonAtThePhysicalMassAndNotAtTheDeclaredOne() public {
        for (uint256 i; i < 16; ++i) {
            hub.seedPool(address(uint160(0xA0000 + i)), BPC.KIND_V2, 30, address(0), s0, s1);
        }
        assertEq(hub.getActivePools(s0, s1).length, 16, "setup: pair must be full");
        assertEq(hub.getPool(_key()), address(0), "setup: the forged pool is not registered yet");

        _swap();

        address seated = hub.getPool(_key());
        emit log_named_address("pool seated", seated);

        uint8 written = BPC.decodeBucket(hub.getSlot(_key()));
        uint256 physical = BPC.shortSide18(
            tokenA.balanceOf(address(pool)), 18, tokenB.balanceOf(address(pool)), 18);
        uint8 supported = BPC.depthBucket(physical);
        emit log_named_uint("bucket recorded for the seated pool", written);
        emit log_named_uint("bucket its holdings support", supported);

        // The seat itself is legitimate at this mass. What is asserted is the PRICE of it.
        assertLe(written, supported,
            "a seat was taken at a depth the pool does not physically hold");
        assertLt(uint256(written), uint256(B_DECLARED),
            "the seat was priced at the DECLARED liquidity, which is the whole defect");
    }
}
