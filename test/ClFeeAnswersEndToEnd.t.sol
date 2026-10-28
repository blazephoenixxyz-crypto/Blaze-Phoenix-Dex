// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PAR (2026-10-27), item 2: THE CL fee() ANSWER, END TO END. `getV3Fee` reads a concentrated
// pool's fee() on its own budget and takes the low 24 bits of the answer word; `quoteV3Fee` asks
// the pool first and falls back to the row's key (the fee() of the registration block, kept only
// when the pool agreed with its factory tier, `Hub._concRowFee`) when the pool does not answer;
// `outV3` refuses a fee of 100% or more (`if (fee >= 1_000_000) return 0`). The unit tests pin each
// branch of the read (CoreReadsBranches, FeeProducersSingle, ClFeeReadHasItsOwnBudget); none drove
// an answer of these three shapes through the Solver, the preview and the Router:
//  - fee() answers 1_000_000 or more: the venue is unquotable, the route goes around it, and the
//    Router delivers the preview's netOut taken as the user's floor; alone, it leaves no route;
//  - fee() runs past its budget on a pool whose row carries a key: the quote prices the key. The
//    key can be stale on the side that over-promises (the pool charges more now than when it was
//    registered). That is a known limit, measured here (the deviation is logged), not refuted: the
//    user's floor is what holds - the Router refuses a userMinOut taken from the preview, and
//    delivers what the pool pays now to a floor at or under it;
//  - fee() answers a word with bits above the 24th set, on a pool with no key (the read is the
//    only source): the fee is the low 24 bits, and the preview is the fill.
// The pool is MockV3Pool's single-tick swap with the answer of fee() set apart from the fee the
// swap charges.
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20V3, IV3SwapCallback} from "./mocks/MockV3Pool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

/// @dev MockV3Pool's swap; fee() burns `burn` gas (short of it, it runs out) and returns the raw
///      32-byte `word`, while the swap charges `charged`.
contract FeeAnswerV3Pool {
    address public token0;
    address public token1;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint24 public charged;
    uint256 internal word;
    uint256 internal burn;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setState(uint160 sp, uint128 l) external { sqrtPriceX96 = sp; liquidity = l; }
    function setCharged(uint24 f) external { charged = f; }
    function setAnswer(uint256 w, uint256 b) external { word = w; burn = b; }

    function fee() external view returns (uint256) {
        uint256 g = gasleft();
        uint256 stop = g > burn ? g - burn : 0;
        while (gasleft() > stop) {}
        return word;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 sqrtPriceLimitX96, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified > 0, "FeeAnswerV3Pool: exact-out unsupported");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 && sqrtPriceLimitX96 > 4295128739
                : sqrtPriceLimitX96 > sqrtPriceX96
                    && sqrtPriceLimitX96 < 1461446703485210103287273052203988822378723970342,
            "SPL"
        );
        uint256 amtIn = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, charged, zeroForOne, 0);
        require(amtOut > 0, "FeeAnswerV3Pool: zero out");
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        (amount0, amount1) = zeroForOne ? (int256(amtIn), -int256(amtOut)) : (-int256(amtOut), int256(amtIn));
        uint256 balBefore = IERC20V3(tokenIn).balanceOf(address(this));
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20V3(tokenIn).balanceOf(address(this)) - balBefore >= amtIn, "FeeAnswerV3Pool: insufficient input");
        IERC20V3(tokenOut).transfer(recipient, amtOut);
    }
}

contract ClFeeAnswersEndToEndTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    address recipient = makeAddr("recipient");

    uint256 constant AMOUNT_IN = 1e18;
    // Past CL_FEE_GAS (192_288): the read runs out inside fee() and takes nothing.
    uint256 constant PAST_BUDGET = 250_000;
    // The lowest and the highest fee() sampled on the Base Slipstream pool (DEX-17 fixture).
    uint24 constant KEY = 150;
    uint24 constant LIVE = 937;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2")
        );
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
    }

    /// A tA/tB pool at price 1, 1e30 deep, registered through a factory whose one tier is `tier`
    /// while fee() answers `answer` (the row keeps the tier as its key only if the two agree).
    function _venue(uint24 tier, uint256 answer, uint24 charges) internal returns (FeeAnswerV3Pool p) {
        p = new FeeAnswerV3Pool(address(tA), address(tB));
        p.setState(uint160(BPC.Q96), 1e30);
        p.setCharged(charges);
        p.setAnswer(answer, 0);
        tA.mint(address(p), 1e30);
        tB.mint(address(p), 1e30);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, tier);
        hub.seedPool(address(p), BPC.KIND_V3, tier, address(0), address(tA), address(tB));
    }

    function _preview() internal returns (BlazePhoenixQuoter.Preview memory pv) {
        vm.roll(block.number + 1);
        (pv, ) = quoter.previewAndEncode(address(tA), address(tB), AMOUNT_IN, recipient, block.timestamp);
    }

    function _uses(BlazePhoenixQuoter.Preview memory pv, address p) internal pure returns (bool) {
        for (uint256 h; h < pv.route.hops.length; ++h) {
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                if (pv.route.hops[h].legs[l].pool == p) return true;
            }
        }
        return false;
    }

    function _oneLegInto(BlazePhoenixQuoter.Preview memory pv, address p) internal pure {
        assertEq(pv.route.hops.length, 1, "premise: a direct route into the bridge");
        assertEq(pv.route.hops[0].legs.length, 1, "premise: one leg, no safety buffer");
        assertEq(pv.route.hops[0].legs[0].pool, p, "premise: the leg is the pool");
    }

    function _fund(uint256 n) internal {
        tA.mint(address(this), n * AMOUNT_IN);
        tA.approve(address(router), n * AMOUNT_IN);
    }

    /// @notice PAR 2a. A pool whose fee() answers 100% or more is no venue: the preview goes
    ///         around it, and the Router delivers the preview's netOut taken as the user's floor.
    function testFuzz_AFeeOfAHundredPercentOrMoreIsRoutedAround(uint24 absurd) public {
        absurd = uint24(bound(absurd, 1_000_000, type(uint24).max));
        FeeAnswerV3Pool good = _venue(3000, 3000, 3000);
        FeeAnswerV3Pool bad = _venue(500, 500, 500);
        hub.addBridge(address(tB));
        assertTrue(_uses(_preview(), address(bad)), "premise: at 500 the pool is a venue");
        bad.setAnswer(absurd, 0);
        bad.setCharged(absurd);
        BlazePhoenixQuoter.Preview memory pv = _preview();
        assertFalse(_uses(pv, address(bad)), "a fee of 100% or more is no venue");
        _oneLegInto(pv, address(good));
        _fund(1);
        uint256 delivered = router.swapExactIn(pv.route, AMOUNT_IN, pv.netOut, recipient, block.timestamp);
        assertEq(delivered, pv.netOut, "the Router delivers the preview, taken as the user's floor");
    }

    /// @notice PAR 2a, the pool alone. Unquotable is not "quotes almost nothing": with the pool
    ///         that answers 100% or more as the only venue there is no route (SolverE(5)), and the
    ///         guard prices it at 0, not at a wei.
    function testFuzz_AFeeOfAHundredPercentOrMoreAloneIsNoRoute(uint24 absurd) public {
        absurd = uint24(bound(absurd, 1_000_000, type(uint24).max));
        FeeAnswerV3Pool bad = _venue(500, 500, 500);
        hub.addBridge(address(tB));
        _oneLegInto(_preview(), address(bad));
        bad.setAnswer(absurd, 0);
        bad.setCharged(absurd);
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        quoter.previewAndEncode(address(tA), address(tB), AMOUNT_IN, recipient, block.timestamp);
        assertEq(
            BPC.outV3(AMOUNT_IN, uint160(BPC.Q96), 1e30, absurd, true, 0), 0,
            "a fee of 100% or more prices nothing, not a wei"
        );
    }

    /// @notice PAR 2b, a known limit, measured. The row's key is the fee() of the registration
    ///         block; with fee() past its budget the quote prices the key, and the key can be stale
    ///         on the side that over-promises. The user's floor holds: a userMinOut taken from the
    ///         preview, or one wei above what the pool pays now, is refused (RouterE(5)); at what
    ///         the pool pays now, that is delivered.
    function test_AStaleKeyPricesAFeeReadPastItsBudget_TheUsersFloorHolds() public {
        FeeAnswerV3Pool p = _venue(KEY, KEY, KEY);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory atKey = _preview();
        _oneLegInto(atKey, address(p));
        assertEq(atKey.route.hops[0].legs[0].fee, KEY, "premise: the row carries the key");
        p.setCharged(LIVE);
        p.setAnswer(LIVE, 0);
        uint256 live = _preview().netOut;
        p.setAnswer(LIVE, PAST_BUDGET);
        BlazePhoenixQuoter.Preview memory pv = _preview();
        _oneLegInto(pv, address(p));
        assertEq(pv.netOut, atKey.netOut, "fee() unread: the quote prices the key");
        assertGt(pv.netOut, live, "premise: the key is stale on the side that over-promises");
        _fund(1);
        bytes memory refused = abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5));
        vm.expectRevert(refused);
        router.swapExactIn(pv.route, AMOUNT_IN, pv.netOut, recipient, block.timestamp);
        vm.expectRevert(refused);
        router.swapExactIn(pv.route, AMOUNT_IN, live + 1, recipient, block.timestamp);
        uint256 delivered = router.swapExactIn(pv.route, AMOUNT_IN, live, recipient, block.timestamp);
        assertEq(delivered, live, "the Router delivers what the pool pays now");
        emit log_named_uint("PAR 2b quote - delivery (wei)", pv.netOut - delivered);
        emit log_named_uint("PAR 2b quote - delivery (ppm of the quote)", (pv.netOut - delivered) * 1e6 / pv.netOut);
    }

    /// @notice PAR 2c. fee() answers a word with bits above the 24th set: the fee is its low 24
    ///         bits. The tier disagreed with the read at registration, so the row has no key and
    ///         the read is the only source; the preview is the fill. `low` runs past 2^16, so a
    ///         mask narrower than 24 bits mis-prices it, and stops at 80%: a leg whose fee
    ///         alone takes 90% is a destroyer the Solver refuses (MAX_ROUTE_IMPACT_BPS).
    function testFuzz_ADirtyFeeWordIsReadByItsLowTwentyFourBits(uint256 high, uint24 low) public {
        low = uint24(bound(low, 100, 800_000));
        high = bound(high, 1, type(uint232).max);
        FeeAnswerV3Pool p = _venue(1, (high << 24) | low, low);
        hub.addBridge(address(tB));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        _oneLegInto(pv, address(p));
        assertEq(pv.route.hops[0].legs[0].fee, 0, "premise: no key, the read is the only source");
        _fund(1);
        uint256 delivered = router.swapExactIn(pv.route, AMOUNT_IN, pv.netOut, recipient, block.timestamp);
        assertEq(delivered, pv.netOut, "the quote charged the low 24 bits, as the pool does");
    }
}
