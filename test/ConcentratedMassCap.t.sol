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
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

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

// =============================================================================
//  THE BOOK THAT HOLDS NOTHING (ninth wave, Binod Bk).
//
//  The seat above is bought at the mass a pool holds - while it holds BOTH
//  sides. A V3-shaped contract that forwards its input away and pays out all it
//  holds ends every swap empty, and an empty side used to switch the mass cap
//  off at every producer: the registry stamped the declared depth, and the
//  Solver's capacity clamp skipped a book holding no tokenOut. From one dust
//  swap on, such a book took the whole order from a pool holding 1,000,000 a
//  side, and the Router's floors - re-derived in frame from the same declared
//  state - accepted any fill the book chose to pay above them.
//
//  The book below is the reporter's, unchanged except for the `keepInput`
//  switch the one-sided control needs. RED at 28118dd, all six: the one-sided
//  control too, because an empty side switched the cap off in both directions
//  and the declared top bucket was stamped either way. Expected values come
//  from the constant-product formula written here, never from the Solver or
//  the Router.
// =============================================================================

interface IERC20Book {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice A V3-shaped contract that answers every read the protocol makes. What
///         it holds is its owner's choice; `liquidity()` is a declaration.
contract PhantomBook {
    address public immutable owner;
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint256 public payBps;
    bool    public keepInput;

    constructor(address a, address b, uint24 f) {
        owner = msg.sender;
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
    }

    function setState(uint160 sp, uint128 l) external { sqrtPriceX96 = sp; liquidity = l; }
    function setPayBps(uint256 b) external { payBps = b; }
    function setKeepInput(bool k) external { keepInput = k; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn = uint256(amountSpecified);
        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        uint256 held = IERC20Book(tokenOut).balanceOf(address(this));
        uint256 pay  = payBps == 0 ? held : (amountIn * payBps) / 10_000;
        if (pay > held) pay = held;

        amount0 = zeroForOne ? int256(amountIn) : -int256(pay);
        amount1 = zeroForOne ? -int256(pay)     : int256(amountIn);

        (bool ok, ) = msg.sender.call(
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", amount0, amount1, ""));
        require(ok, "callback failed");

        if (pay > 0) IERC20Book(tokenOut).transfer(recipient, pay);

        if (!keepInput) {
            uint256 take = IERC20Book(tokenIn).balanceOf(address(this));
            if (take > 0) IERC20Book(tokenIn).transfer(owner, take);
        }
    }
}

contract ConcentratedEmptyBookTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20   tokenA;
    MockERC20   tokenB;
    MockV2Pair  honest;
    PhantomBook book;

    address constant USER     = address(0xBEEF);
    address constant ATTACKER = address(0xBAD);

    uint160 constant Q96        = uint160(uint256(1) << 96);
    uint256 constant ORDER      = 1_000e18;
    uint112 constant DEEP       = uint112(1_000_000e18);
    uint128 constant DECLARED_L = uint128(1e33);
    uint256 constant DUST       = 1e15;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        honest = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(honest), DEEP);
        tokenB.mint(address(honest), DEEP);
        honest.setReserves(DEEP, DEEP);
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));

        vm.prank(ATTACKER);
        book = new PhantomBook(address(tokenA), address(tokenB), 3000);
        book.setState(Q96, DECLARED_L);

        tokenA.mint(USER, 10_000e18);
        vm.prank(USER);
        tokenA.approve(address(router), type(uint256).max);
    }

    /// @dev The honest pool's delivery for `order`, from the constant-product
    ///      formula with its 30 bps fee, after the protocol's 28 bps on the input.
    function _honestOut(uint256 order) internal pure returns (uint256) {
        uint256 x = order - (order * 28 + 9_999) / 10_000;
        uint256 r = uint256(DEEP);
        return (x * 997 * r) / (r * 1000 + x * 997);
    }

    function _key() internal view returns (bytes32) {
        return hub.keyOf(address(book), address(tokenA), address(tokenB));
    }

    /// @dev One swap from an unprivileged address naming the book as a V3 pool -
    ///      the whole cost of a seat. The book is funded with just what it pays.
    function _seat(uint256 amt) internal {
        tokenA.mint(ATTACKER, amt);
        tokenB.mint(address(book), amt);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(book), hooks: address(0), kind: BPC.KIND_V3,
            fee: 3000, tickSpacing: 0,
            zeroForOne: book.token0() == address(tokenA), stable: false,
            amountIn: amt, expectedOut: amt, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA), tokenOut: address(tokenB),
            amountIn: amt, expectedOut: amt, legs: legs
        });
        Route memory r = Route({
            hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        vm.startPrank(ATTACKER);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactIn(r, amt, 1, ATTACKER, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_AnEmptyBookIsSeatedAtTheMassItHolds_WhichIsNone() public {
        _seat(DUST);
        assertEq(hub.getPool(_key()), address(book), "setup: the dust swap must have seated the book");
        assertEq(tokenA.balanceOf(address(book)) + tokenB.balanceOf(address(book)), 0,
            "setup: the book must end the swap holding nothing");

        uint8 written = BPC.decodeBucket(hub.getSlot(_key()));
        emit log_named_uint("bucket stamped for an empty book", written);
        assertEq(written, 0, "an empty book was stamped at a depth it does not hold");
    }

    /// @dev The control that keeps the rule honest in the other direction: a book
    ///      holding ONE side keeps the mass of that side. A cap that read "an empty
    ///      side is zero mass" would zero a concentrated range that sits wholly on
    ///      one side of its tick, which holds real tokens.
    function test_AOneSidedBookKeepsTheMassOfTheSideItHolds() public {
        uint256 seat = 100e18;
        book.setKeepInput(true);
        _seat(seat);
        assertEq(tokenB.balanceOf(address(book)), 0, "setup: the book must hold no tokenOut");
        uint256 heldA = tokenA.balanceOf(address(book));
        assertGt(heldA, 0, "setup: the book must hold the input side");

        uint8 written = BPC.decodeBucket(hub.getSlot(_key()));
        uint8 supported = BPC.depthBucket(heldA);
        emit log_named_uint("bucket stamped", written);
        emit log_named_uint("bucket the held side supports", supported);
        assertGt(supported, 0, "setup: the held side must land above bucket 0 to tell the rules apart");
        assertEq(written, supported, "a one-sided book was not stamped at the mass of the side it holds");
    }

    /// @dev Two honest pools, so the planner SPLITS (the regime this is about: the
    ///      split clamp only decides when a split is chosen - with one honest pool
    ///      the single leg wins and the clamp is never asked, which is how the first
    ///      version of this test let its mutant through).
    function test_ABookHoldingNoTokenOutIsNeverRouted() public {
        MockV2Pair honest2 = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(honest2), DEEP);
        tokenB.mint(address(honest2), DEEP);
        honest2.setReserves(DEEP, DEEP);
        hub.seedPool(address(honest2), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        _seat(DUST);

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        Leg[] memory legs = plan.best.hops[0].legs;
        for (uint256 i; i < legs.length; ++i) {
            assertTrue(legs[i].pool != address(book), "a book holding no tokenOut was given part of the order");
        }
        assertGe(legs.length, 2, "setup: the plan must split, or the split clamp is never asked");
    }

    function test_AnEmptyBookAloneOnItsPairYieldsNoRoute() public {
        MockERC20 tokenC = new MockERC20("C", "C");
        vm.prank(ATTACKER);
        PhantomBook lone = new PhantomBook(address(tokenA), address(tokenC), 3000);
        lone.setState(Q96, DECLARED_L);

        tokenA.mint(ATTACKER, DUST);
        tokenC.mint(address(lone), DUST);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(lone), hooks: address(0), kind: BPC.KIND_V3,
            fee: 3000, tickSpacing: 0,
            zeroForOne: lone.token0() == address(tokenA), stable: false,
            amountIn: DUST, expectedOut: DUST, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenC), amountIn: DUST, expectedOut: DUST, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: DUST, singleOut: DUST, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
        vm.startPrank(ATTACKER);
        tokenA.approve(address(router), type(uint256).max);
        router.swapExactIn(r, DUST, 1, ATTACKER, block.timestamp + 1);
        vm.stopPrank();
        assertEq(hub.getPool(hub.keyOf(address(lone), address(tokenA), address(tokenC))), address(lone),
            "setup: the lone book must be seated");

        // The Solver's no-route answer, by selector and code: nothing on the pair can pay.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        solver.findBestRoutePlan(address(tokenA), address(tokenC), ORDER);
    }

    /// @dev Differential: the same door, same order, same block, with and without the
    ///      empty book seated. An empty book must never cost the user anything. It is
    ///      not asserted EQUAL, and the reason was measured: the book keeps the minimum
    ///      split weight (1 in 10,001), its share is cut to nothing by the clamp and,
    ///      as the last leg, has no leg after it to flow to - so the committed input is
    ///      999.90001 A where it was 1,000 A. The fee is taken on the commitment (the
    ///      "hop commitment" row of SHARED_QUANTITIES.md), and the user received
    ///      0.00028 B MORE. The direction is the property; the size is the fee on 0.01%.
    function test_AnEmptyBookSeatedBesideTheRouteNeverCostsTheUserAnything() public {
        uint256 snap = vm.snapshotState();
        uint256 before = tokenB.balanceOf(USER);
        vm.prank(USER);
        router.swapBestExactIn(address(tokenA), address(tokenB), ORDER, 1, USER, block.timestamp + 1);
        uint256 without = tokenB.balanceOf(USER) - before;
        assertGe(without, _honestOut(ORDER), "setup: the door must at least match the honest pool alone");
        vm.revertToState(snap);

        _seat(DUST);
        before = tokenB.balanceOf(USER);
        vm.prank(USER);
        router.swapBestExactIn(address(tokenA), address(tokenB), ORDER, 1, USER, block.timestamp + 1);
        assertGe(tokenB.balanceOf(USER) - before, without,
            "seating an empty book cost the user part of the delivery");
    }

    /// @dev What the depth cap buys: the believability band is anchored by MASS.
    ///      The book holds 20,000 of each side - real, but fifty times less than the
    ///      honest pool - and declares a price 10% better with L = 1e33. The band is a
    ///      depth-weighted median of the candidates' rates (±5%); weighted by the
    ///      declaration, the book anchors it and the honest pool falls outside as the
    ///      outlier, leaving the book as the only believable venue. Weighted by mass,
    ///      the honest pool anchors it and the book is the outlier. (Mass decides the
    ///      band and the split weights; a book holding several times the order can
    ///      still win a single leg on its declared curve - that is not this test.)
    function test_TheBandIsAnchoredByTheMassHeld_NotTheMassDeclared() public {
        tokenA.mint(address(book), 20_000e18);
        tokenB.mint(address(book), 20_000e18);
        book.setKeepInput(true);
        book.setPayBps(11_000); // pays what its own declared curve promises, so the seat settles
        // 10% better for A -> B: price 1.1 when A is token0, 1/1.1 otherwise.
        uint256 r = 104_880_884_817; // sqrt(1.1) * 1e11
        book.setState(address(tokenA) < address(tokenB)
            ? uint160(uint256(Q96) * r / 1e11)
            : uint160(uint256(Q96) * 1e11 / r), DECLARED_L);
        _seat(DUST);

        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        Leg[] memory legs = plan.best.hops[0].legs;
        bool honestRouted;
        for (uint256 i; i < legs.length; ++i) {
            assertTrue(legs[i].pool != address(book),
                "a book anchored the band with mass it declares and does not hold");
            if (legs[i].pool == address(honest)) honestRouted = true;
        }
        assertTrue(honestRouted, "the honest pool fell outside the band");
    }
}
