// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PHANTOM LEG REGISTRY CREDIT — a leg that never touched a pool must never
//  move that pool's registry slot.
//
//  Router._recordHits (Router:1787) walks the legs from CALLDATA with NO
//  executed-check and calls hub.recordSwap(leg.pool, ..., leg.amountIn,
//  leg.expectedOut, depth) for every one of them. Execution, however, SKIPS a
//  leg whose scaled input rounds to zero:
//
//      Router:1345   if (amt == 0) return (0, 0);   // no pool.swap()
//
//  A hop scales each leg by mulDiv(leg.amountIn, scaleNum, scaleDen) where
//  scaleDen = Σ leg.amountIn and scaleNum = realIn (the measured input AFTER
//  the protocol fee is removed, capped at scaleDen — Router:697). Because the
//  fee is removed first, realIn < scaleDen always, so a leg declaring
//  leg.amountIn = 1 wei scales to floor(1 · scaleNum / scaleDen) = 0 and is
//  skipped. Yet _recordHits still credits it, and Hub.recordSwap (Hub:1356)
//  guards only the RAW calldata amount:
//
//      Hub:1356   if (pool == address(0) || amtIn == 0) return;   // amtIn = 1 ≠ 0
//
//  so the guard passes, the pool's slot is ticked (swap counter bumped,
//  block/timestamp stamped, depth bucket rewritten — BPC.tickSlot). A pool
//  that never traded is promoted in the fitness/vitality ranking on the back
//  of a one-wei phantom leg the attacker never had to execute.
//
//  userMinOut is IRRELEVANT here: this is a side effect on HUB STATE, not a
//  value transfer to the caller, so minOut = 1 models nothing about a victim —
//  it only lets the executing leg complete so the phantom credit is observable.
//
//  RED BEFORE THE FIX: test_PhantomLeg_NotCreditedToRegistry — the phantom
//  pool's swap counter increments although its leg never reached pool.swap().
//  The fix must gate recordSwap on EXECUTED input, not calldata input.
//
//  forge test --match-contract PhantomLegRegistryCredit -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract PhantomLegRegistryCreditTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool0;       // the leg that really executes
    MockV3Pool poolPhantom; // the one-wei leg that scales to zero and never runs

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    // Pinned constants (blind-constant law: the whole zero-scaling argument
    // below is derived from these, so the file must break if either moves).
    uint256 constant PROTOCOL_FEE_BPS = BPC.PROTOCOL_FEE_BPS; // 28
    uint256 constant BPS              = BPC.BPS;              // 10_000

    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0 = 2**96
    uint128 constant LIQ      = 1_000_000e18;
    uint24  constant POOL_FEE = 3000;

    // The user hands over exactly leg0's declared input; leg1 declares one wei
    // on top, so scaleDen = BIG_IN + 1 and, after the fee is removed,
    // scaleNum = realIn < scaleDen => leg1 scales to 0.
    uint256 constant BIG_IN   = 10_000e18;
    uint256 constant PHANTOM_DECLARED = 1;

    bool zfo;
    bytes32 keyPhantom;
    bytes32 key0;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        pool0 = new MockV3Pool(address(tokenA), address(tokenB), POOL_FEE);
        pool0.setState(SQRT_P_1, LIQ);
        tokenB.mint(address(pool0), 1_000_000e18);

        poolPhantom = new MockV3Pool(address(tokenA), address(tokenB), POOL_FEE);
        poolPhantom.setState(SQRT_P_1, LIQ);
        tokenB.mint(address(poolPhantom), 1_000_000e18);

        // Both pools trade the SAME sorted pair, so a single hop A->B may name
        // both — the two legs are homogeneous (Router Layer-1 requirement).
        zfo = pool0.token0() == address(tokenA);

        // Register both pools so recordSwap takes the s != 0 tick+stamp branch:
        // a phantom credit then shows up as a swap-counter bump on an existing
        // slot, exactly the "bumps the swap counter" symptom.
        hub.seedPool(address(pool0),       BPC.KIND_V3, POOL_FEE, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(poolPhantom), BPC.KIND_V3, POOL_FEE, address(0), address(tokenA), address(tokenB));
        key0       = hub.keyOf(address(pool0),       address(tokenA), address(tokenB));
        keyPhantom = hub.keyOf(address(poolPhantom), address(tokenA), address(tokenB));

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    // ─── route builders ──────────────────────────────────────────────────────

    function _leg(address pool, uint256 amountIn) internal view returns (Leg memory) {
        return Leg({
            pool: pool,
            hooks: address(0),
            kind: BPC.KIND_V3,
            fee: POOL_FEE,
            tickSpacing: 0,
            zeroForOne: zfo,
            stable: false,
            amountIn: amountIn,
            expectedOut: 0,
            auxId: bytes32(0)
        });
    }

    /// @dev One hop A->B with two homogeneous legs: pool0 (BIG_IN) and
    ///      poolPhantom (one wei). Order is hookless-before-hookless with the
    ///      phantom last, so it takes the last-leg remaining-balance clamp —
    ///      which cannot lift a zero back above zero.
    function _twoLegRoute() internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(pool0), BIG_IN);
        legs[1] = _leg(address(poolPhantom), PHANTOM_DECLARED);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: BIG_IN,
            expectedOut: 0,
            legs: legs
        });
        r = _wrap(hops);
    }

    /// @dev A single real leg on poolPhantom — it MUST be credited.
    function _singleRealRoute() internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(address(poolPhantom), BIG_IN);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: BIG_IN,
            expectedOut: 0,
            legs: legs
        });
        r = _wrap(hops);
    }

    function _wrap(Hop[] memory hops) internal pure returns (Route memory r) {
        r = Route({
            hops: hops,
            totalOut: 0,
            singleOut: 0,
            singleOutFloor: 0,
            expectedImpactBps: 0,
            confidenceWad: 0,
            estGas: 0,
            hasSurplus: false,
            isV4Bundle: false
        });
    }

    function _phantomSwapCount() internal view returns (uint32) {
        return BPC.decodeSwapCount(hub.getSlot(keyPhantom));
    }

    // ─── BOUNDARY: the exact scaling ratio at which a leg rounds to zero ──────

    function test_Arithmetic_ScalingReachesZero() public pure {
        // On hop 0 the fee is removed first, so scaleNum = realIn < scaleDen.
        uint256 scaleDen = BIG_IN + 1;                    // Σ leg.amountIn
        uint256 fee      = BPC.mulDivUp(BIG_IN, PROTOCOL_FEE_BPS, BPS);
        uint256 scaleNum = BIG_IN - fee;                  // realIn (capped at scaleDen)

        // A one-wei declared leg scales to zero the instant scaleNum < scaleDen.
        assertEq(BPC.mulDiv(PHANTOM_DECLARED, scaleNum, scaleDen), 0,
            "a one-wei leg scales through zero whenever the input is fee-reduced below the sum of leg.amountIn");

        // The zero-crossing is exact: k = ceil(scaleDen / scaleNum) is the first
        // declared amount that survives scaling; k-1 still rounds to zero.
        uint256 k = (scaleDen + scaleNum - 1) / scaleNum;
        assertGt(BPC.mulDiv(k, scaleNum, scaleDen), 0, "k wei is the first executable amount at this ratio");
        assertEq(BPC.mulDiv(k - 1, scaleNum, scaleDen), 0, "k-1 wei still rounds to zero");
    }

    // ─── NEGATIVE (RED): a non-executing leg must not be credited ─────────────

    function test_PhantomLeg_NotCreditedToRegistry() public {
        uint32 before = _phantomSwapCount();
        uint32 pool0Before = BPC.decodeSwapCount(hub.getSlot(key0));

        vm.prank(user);
        uint256 got = router.swapExactIn(
            _twoLegRoute(), BIG_IN, 1, user, block.timestamp + 1);

        assertGt(got, 0, "the executing leg delivered, so this is a real swap");

        // The executing leg (pool0) MUST have been credited — proves the swap
        // really ran and _recordHits really executed.
        assertEq(BPC.decodeSwapCount(hub.getSlot(key0)), pool0Before + 1,
            "the leg that executed must be credited exactly once");

        // THE CLAIM: the phantom leg scaled to zero and never reached
        // pool.swap(), so poolPhantom's registry slot must be untouched. Before
        // the fix its swap counter is bumped anyway — a phantom credit on the
        // raw calldata amount.
        assertEq(_phantomSwapCount(), before,
            "a leg that never executed changed the phantom pool's swap counter");
    }

    // ─── POSITIVE (GREEN): a leg that DOES execute must be credited ───────────

    function test_ExecutedLeg_IsCreditedToRegistry() public {
        uint32 before = _phantomSwapCount();

        vm.prank(user);
        uint256 got = router.swapExactIn(
            _singleRealRoute(), BIG_IN, 1, user, block.timestamp + 1);

        assertGt(got, 0, "the single real leg delivered");
        assertEq(_phantomSwapCount(), before + 1,
            "a leg that executed must tick its pool's slot exactly once");
    }
}
