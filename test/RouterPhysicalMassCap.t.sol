// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ROUTER PHYSICAL-MASS CAP  -  the Router half of PROV-01
//
//  THE CLAIM. A pool's declared getReserves() is a self-declaration. The depth
//  bucket the Hub stores for that pool is NOT: it ranks the funnel's top-K and
//  it decides evictions. Router._v2Depth18 (Router:2044-2060) therefore caps
//  each declared reserve by the balance the pool PHYSICALLY holds:
//
//      Router:2047        (uint256 r0, uint256 r1) = BPC.getReserves(pool);
//      Router:2055        uint256 b0 = BPC.balanceOf(t0, pool);
//      Router:2056        uint256 b1 = BPC.balanceOf(t1, pool);
//      Router:2057        if (b0 < r0) r0 = b0;
//      Router:2058        if (b1 < r1) r1 = b1;
//      Router:2059        return BPC.shortSide18(r0, ..., r1, ...);
//
//  WHY THIS FILE EXISTS. SHARED_QUANTITIES.md, row "pool depth source", says in
//  writing that this copy of the cap is the unguarded one:
//
//      "Escape: the Router copy of the cap has no test of its own yet - a
//       forged pair still enters the registry through a self-swap, and only the
//       cap keeps its bucket honest; until a Router-level probe exists, that
//       half rests on reading, not on a red."
//
//  test/FrozenAtWriteProbes.t.sol::test_probe_forgedMass_... pins the SOLVER
//  copy (mutant "PROV-01 ... (Solver)"). It reaches the Hub by calling
//  hub.recordSwap directly with a hand-written depthWad, so it never executes
//  Router._v2Depth18 at all. This file closes that gap by driving a REAL
//  swapExactIn end to end and then reading the bucket the Hub actually holds.
//
//  RED OR GREEN TODAY (main @ 6438fe4): every test in this file is GREEN. The
//  cap is already in the tree; what is missing is the evidence that anything
//  would notice its removal. The three mutants in .github/scripts/mutants.py are what
//  make these tests load-bearing - each one deletes one arm of the cap and must
//  turn its named test RED.
//
//  WHY THE TESTS ARE NOT VACUOUS. Three independent guards:
//    1. test_arith_TheTwoAnswersReallyDiffer pins, as pure arithmetic, that the
//       DECLARED reserves and the PHYSICAL ones land in DIFFERENT buckets at
//       the constants this file uses (15 vs 6, and 9 vs 6). Without that, an
//       assertion on the bucket could hold on the broken tree too.
//    2. Every probe asserts the slot's swap counter went 0 -> 1, so the bucket
//       it reads was written by THIS swap's _recordHits and is not the value
//       seedPool left behind.
//    3. Every probe asserts the swap delivered a non-zero amount, so the route
//       really executed and _recordHits really ran.
//
//  WHY MockV2Pair CANNOT BE USED HERE, and this is the whole reason a local
//  mock exists: MockV2Pair.swap() ends with
//      reserve0 = uint112(IERC20Min(token0).balanceOf(address(this)));
//      reserve1 = uint112(IERC20Min(token1).balanceOf(address(this)));
//  i.e. it re-syncs its declared reserves from its real balances. That destroys
//  the forgery INSIDE the swap, before _recordHits reads getReserves, and the
//  capped and uncapped answers would then coincide - a green that proves
//  nothing. ForgedReservePair below is MockV2Pair minus the re-sync, and
//  nothing else.
//
//  forge test --match-contract RouterPhysicalMassCap -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IPairPayoutERC20 {
    function transfer(address to, uint256 amt) external returns (bool);
}

/// @notice A V2-shaped pair whose DECLARED reserves are independent of what it
///         holds and are never re-synced. Everything else - token0/token1
///         sorting, the getReserves() ABI, the swap() liquidation ABI - is
///         byte-identical to test/mocks/MockV2Pair.sol.
/// @dev    It exposes no stable(), no slot0() and no globalState(), so
///         Hub.recordSwap's shape refutation resolves it to KIND_V2:
///           BPC.v3StateAndDynFee(pool) -> sp == 0  => isConc == false
///           BPC.isSolidlyShaped(pool)  -> false    => kind stays KIND_V2
contract ForgedReservePair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    /// @dev Pays out of its own balance. NO re-sync: the declaration survives
    ///      the swap, which is exactly the adversary's position.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IPairPayoutERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IPairPayoutERC20(token1).transfer(to, amount1Out);
    }
}

contract RouterPhysicalMassCapTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    ForgedReservePair pair;

    // The pair's own slot ordering, cached once so no helper has to make an
    // external call after a cheatcode has been armed.
    address s0;
    address s1;

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    // ---- Blind-constant law: every bucket asserted below is derived from these.
    uint256 constant AMT     = 1_000e18;          // the user's input
    uint112 constant FORGED  = uint112(1e30);     // the declaration. Fits uint112 (max ~5.19e33).
    uint256 constant SHALLOW = 5_000e18;          // physical mass on the short side
    uint256 constant DEEP    = 5_000_000e18;      // physical mass on the deep side

    // depthBucket(d) = min(15, floor(log10(d / 1e15))), Core:1893.
    //   FORGED   1e30            -> 1e30/1e15 = 1e15   -> 15
    //   ~6e21    (SHALLOW + in)  -> 5.997e6            ->  6
    //   ~5e24    (DEEP - out)    -> 4.99999e9          ->  9
    uint8 constant B_DECLARED = 15;
    uint8 constant B_PHYSICAL = 6;
    uint8 constant B_DEEP     = 9;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        // this = admin/control/operator; the Router is the only recordSwap caller.
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pair   = new ForgedReservePair(address(tokenA), address(tokenB));
        s0 = pair.token0();
        s1 = pair.token1();

        tokenA.mint(user, 1_000_000e18);
        tokenB.mint(user, 1_000_000e18);
        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // --- helpers (no cheatcode is ever armed while one of these runs) --------

    function _fund(address token, uint256 amt) internal {
        MockERC20(token).mint(address(pair), amt);
    }

    function _seed() internal {
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), s0, s1);
    }

    function _key() internal view returns (bytes32) {
        return hub.keyOf(address(pair), s0, s1);
    }

    function _bucket() internal view returns (uint8) {
        return BPC.decodeBucket(hub.getSlot(_key()));
    }

    function _swapCount() internal view returns (uint32) {
        return BPC.decodeSwapCount(hub.getSlot(_key()));
    }

    /// @dev One hop, one leg, trading FROM the token sitting at pair slot
    ///      `slotIn`. zeroForOne is set from the same slot, so
    ///      Router._recordHits derives t0 == pair.token0() and _v2Depth18
    ///      caps r0 with the balance of the pair's real token0.
    function _routeFromSlot(uint8 slotIn) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair),
            hooks: address(0),
            kind: BPC.KIND_V2,
            fee: 30,
            tickSpacing: 0,
            zeroForOne: slotIn == 0,
            stable: false,
            amountIn: AMT,
            expectedOut: 0,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn:     slotIn == 0 ? s0 : s1,
            tokenOut:    slotIn == 0 ? s1 : s0,
            amountIn:    AMT,
            expectedOut: 0,
            legs:        legs
        });
        r = Route({
            hops:              hops,
            totalOut:          0,
            singleOut:         0,
            singleOutFloor:    0,
            expectedImpactBps: 0,
            confidenceWad:     0,
            estGas:            0,
            hasSurplus:        false,
            isV4Bundle:        false
        });
    }

    // =========================================================================
    //  0. NON-VACUITY: the capped and the uncapped answers are different
    //     buckets at these constants. If this ever stops holding, every
    //     assertion below becomes a green that proves nothing.
    // =========================================================================

    function test_arith_TheTwoAnswersReallyDiffer() public pure {
        assertEq(BPC.depthBucket(uint256(FORGED)), B_DECLARED,
            "the declared mass must land in the top bucket");
        // The short side after a 1_000e18 swap against SHALLOW mass stays
        // strictly inside [1e21, 1e22), the bucket-6 decade, with a wide margin
        // on both ends: SHALLOW alone is 5e21 and the swap moves ~1e21.
        assertEq(BPC.depthBucket(SHALLOW), B_PHYSICAL,
            "the physical mass must land in bucket 6");
        assertEq(BPC.depthBucket(DEEP), B_DEEP,
            "the deep honest side must land in bucket 9");
        assertTrue(B_PHYSICAL != B_DECLARED && B_PHYSICAL != B_DEEP,
            "the three answers must be distinguishable");
    }

    // =========================================================================
    //  1. THE PROBE. Both declared reserves forged, both physical sides
    //     shallow. A real swapExactIn executes, and the bucket the Hub then
    //     holds must be the PHYSICAL one.
    //
    //     Killed by: mutant "PROV-01 (Router): the physical cap is gone".
    //     With both `if` lines removed, _v2Depth18 returns shortSide18(1e30,
    //     1e30) = 1e30 and tickSlot writes bucket 15.
    // =========================================================================

    function test_probe_forgedReserves_registryBucketIsThePhysicalMass() public {
        _fund(s0, SHALLOW);
        _fund(s1, SHALLOW);
        pair.setReserves(FORGED, FORGED);
        _seed();
        assertEq(_bucket(), 0, "pre-condition: seedPool leaves the bucket at 0");
        assertEq(_swapCount(), 0, "pre-condition: the row has never been ticked");

        Route memory r = _routeFromSlot(0);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertGt(got, 0, "the swap must really have executed");
        assertEq(_swapCount(), 1, "the row must have been ticked by THIS swap");
        assertEq(_bucket(), B_PHYSICAL,
            "PROV-01 (Router): the registry bucket followed the pool's own declaration");
    }

    // =========================================================================
    //  2. THE SLOT-0 ARM ALONE. Only reserve0 is forged; reserve1 is honest and
    //     deep. The pair's slot-0 side is the SHORT physical one, so the whole
    //     answer turns on `if (b0 < r0)`.
    //
    //     Killed by: mutant "PROV-01 (Router): the token0 arm of the cap".
    //     Without it the short side becomes min(1e30, ~5e24) = ~5e24 -> bucket 9.
    //     The token1 arm is inert in this configuration (removing it alone
    //     leaves the answer at bucket 6), which is what makes this test
    //     directional rather than a second copy of test 1.
    // =========================================================================

    function test_probe_forgedReserves_slot0ArmCapsTheShortSide() public {
        _fund(s0, SHALLOW);
        _fund(s1, DEEP);
        pair.setReserves(FORGED, uint112(DEEP));   // r1 honest: equal to the balance
        _seed();
        assertEq(_swapCount(), 0, "pre-condition: the row has never been ticked");

        Route memory r = _routeFromSlot(0);        // spend the slot-0 token
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertGt(got, 0, "the swap must really have executed");
        assertEq(_swapCount(), 1, "the row must have been ticked by THIS swap");
        assertEq(_bucket(), B_PHYSICAL,
            "PROV-01 (Router): reserve0 was believed over the pair's token0 balance");
    }

    // =========================================================================
    //  3. THE SLOT-1 ARM ALONE. The mirror image. Written out rather than
    //     parameterised because the two arms are two `if`s in the source and a
    //     shared body would let one mutant kill both tests - the sibling-channel
    //     defect this codebase keeps producing.
    //
    //     Killed by: mutant "PROV-01 (Router): the token1 arm of the cap".
    // =========================================================================

    function test_probe_forgedReserves_slot1ArmCapsTheShortSide() public {
        _fund(s0, DEEP);
        _fund(s1, SHALLOW);
        pair.setReserves(uint112(DEEP), FORGED);   // r0 honest: equal to the balance
        _seed();
        assertEq(_swapCount(), 0, "pre-condition: the row has never been ticked");

        Route memory r = _routeFromSlot(1);        // spend the slot-1 token
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertGt(got, 0, "the swap must really have executed");
        assertEq(_swapCount(), 1, "the row must have been ticked by THIS swap");
        assertEq(_bucket(), B_PHYSICAL,
            "PROV-01 (Router): reserve1 was believed over the pair's token1 balance");
    }

    // =========================================================================
    //  4. THE COLD PATH. The forged pair is NOT seeded: it registers itself
    //     through the swap, which is the shape SHARED_QUANTITIES.md names ("a
    //     forged pair still enters the registry through a self-swap"). The
    //     bucket it is BORN with must already be the physical one - the cap has
    //     to bind on _register + the first tick, not only on later ticks.
    // =========================================================================

    function test_probe_forgedReserves_coldRegistrationIsBornAtThePhysicalBucket() public {
        _fund(s0, SHALLOW);
        _fund(s1, SHALLOW);
        pair.setReserves(FORGED, FORGED);
        assertEq(hub.getPool(_key()), address(0), "pre-condition: the pair is unknown to the registry");

        Route memory r = _routeFromSlot(0);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertGt(got, 0, "the swap must really have executed");
        assertEq(hub.getPool(_key()), address(pair),
            "pre-condition: the self-swap registered the pair, so there is a bucket to read");
        assertEq(BPC.decodeKind(hub.getSlot(_key())), BPC.KIND_V2,
            "pre-condition: the row is the pair-shaped one whose depth _v2Depth18 produced");
        assertEq(_bucket(), B_PHYSICAL,
            "PROV-01 (Router): a self-registering forged pair was born in the declared bucket");
    }

    // =========================================================================
    //  5. CONTROL - MUST STAY GREEN AFTER ANY FIX.
    //     On an honest pair (declared reserves never exceed physical holdings)
    //     the cap is INERT and the registry bucket is the one the declaration
    //     already implied. This is what forbids buying test 1 with rigidity: a
    //     "fix" that clamps every pool downward, or that refuses to register a
    //     pair whose reserves and balances differ at all, breaks this control.
    // =========================================================================

    function test_control_honestPair_capIsInertAndTheBucketIsTheDeclaredOne() public {
        _fund(s0, DEEP);
        _fund(s1, DEEP);
        pair.setReserves(uint112(DEEP), uint112(DEEP));   // declaration == holdings
        _seed();

        Route memory r = _routeFromSlot(0);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertGt(got, 0, "control: an honest deep pair must still route");
        assertEq(_swapCount(), 1, "control: the row must still be ticked");
        assertEq(_bucket(), B_DEEP,
            "control: the cap changed the bucket of a pair that declared nothing it does not hold");
    }

    // =========================================================================
    //  6. CONTROL - the cap is a REGISTRY rule, not an execution rule.
    //     The forged pair still trades: the cap must never reject a swap, only
    //     refuse to believe the mass afterwards. If a future fix reverts here
    //     instead of capping, the user's already-executed swap starts failing
    //     over a registry decision - which Hub.recordSwap's own doctrine
    //     forbids ("skips registration, does NOT revert").
    // =========================================================================

    function test_control_theForgedPairStillSettlesTheSwap() public {
        _fund(s0, SHALLOW);
        _fund(s1, SHALLOW);
        pair.setReserves(FORGED, FORGED);
        _seed();

        uint256 before = tokenBalance(s1, user);
        Route memory r = _routeFromSlot(0);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertEq(tokenBalance(s1, user) - before, got,
            "control: the delivered amount is what the recipient actually received");
        assertGt(got, 0, "control: capping the registry must not refuse the trade");
    }

    function tokenBalance(address token, address who) internal view returns (uint256) {
        return MockERC20(token).balanceOf(who);
    }
}
