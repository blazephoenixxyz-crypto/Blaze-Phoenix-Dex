// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20MinK {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Solidly-shaped pair that ENFORCES the K invariant, unlike the
///         permissive shared mocks. A real Solidly/Aerodrome pair recomputes
///         its input as `balance - reserve` inside swap() and reverts when
///         the requested output would shrink K — which is exactly the check
///         that turned a nominal-priced ask on a fee-on-transfer input into
///         a hard revert before the router fix. Volatile curve (x*y) only;
///         the raw-balance K check is slightly looser than a real pair's
///         fee-adjusted one, which is fine: any transfer tax above the swap
///         fee still fails it, and a correctly measured ask still passes.
contract SolidlyPairK {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    bool    public constant stable = false;
    uint256 public feeBps = 30;

    /// @notice When true, getAmountOut() returns 0 so the router exercises
    ///         its replicated-curve fallback path.
    bool public hideGetAmountOut;

    constructor(address _token0, address _token1) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
    }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function setHideGetAmountOut(bool b) external { hideGetAmountOut = b; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256) {
        if (hideGetAmountOut) return 0;
        (uint256 rIn, uint256 rOut) = tokenIn == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        return BPC.outSolidly(amountIn, rIn, rOut, feeBps, false);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        if (amount0Out > 0) IERC20MinK(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20MinK(token1).transfer(to, amount1Out);
        uint256 bal0 = IERC20MinK(token0).balanceOf(address(this));
        uint256 bal1 = IERC20MinK(token1).balanceOf(address(this));
        // Constant-product K on the measured balances: pay out only what the
        // measured input actually funds. This is the pool-side seam the
        // fee-on-transfer defect collided with.
        require(bal0 * bal1 >= r0 * r1, "SolidlyPairK: K");
        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
    }
}

/// @notice Regression: fee-on-transfer tokenIn through a Solidly leg.
///
///         Before the fix, _execSolidlyAmt priced the pool's output on the
///         NOMINAL input, transferred the (taxed) input, and demanded that
///         pre-computed output — the pair's K check then rejected every
///         genuine FoT swap, a DoS on the exact pairing the routing policy
///         ("FoT = route-where-natural") claims to support. The fix measures
///         the input the pool really received and re-quotes on it, mirroring
///         _execV2Amt.
contract RouterFotSolidlyTest is Test {
    uint16  constant TAX_BPS  = 500;        // 5% transfer tax
    uint112 constant RESERVE  = 10_000e18;
    uint256 constant AMOUNT_IN = 500e18;

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 fotToken;      // fee-on-transfer tokenIn
    MockERC20 outToken;      // honest tokenOut
    SolidlyPairK pair;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        fotToken = new MockERC20("Fot", "FOT");
        outToken = new MockERC20("Out", "OUT");
        pair = new SolidlyPairK(address(fotToken), address(outToken));

        router = new BlazePhoenixRouter(
            address(hub), address(0xCAFE), address(this), treasury1, treasury2
        );

        // mint() credits balances directly (no transfer, no tax), so pool
        // balances and stored reserves start exactly aligned.
        fotToken.mint(address(pair), RESERVE);
        outToken.mint(address(pair), RESERVE);
        pair.setReserves(RESERVE, RESERVE);

        fotToken.setFeeOnTransferBps(TAX_BPS);

        fotToken.mint(user, 3_000e18);
        vm.prank(user);
        fotToken.approve(address(router), type(uint256).max);
    }

    function _buildSolidlyRoute(uint256 amountIn, uint256 expectedOut)
        private view returns (Route memory route)
    {
        bool zeroForOne = address(fotToken) < address(outToken);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_SOLIDLY, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: amountIn, expectedOut: expectedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(fotToken), tokenOut: address(outToken),
            amountIn: amountIn, expectedOut: expectedOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: expectedOut, singleOut: expectedOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @dev Net input surviving one taxed transfer.
    function _afterTax(uint256 amt) private pure returns (uint256) {
        return amt - (amt * TAX_BPS) / 10_000;
    }

    /// @notice Harness sanity: the K-enforcing pair rejects exactly what the
    ///         PRE-FIX router did — transfer a taxed input, then demand the
    ///         output priced on the nominal amount. This proves the mock
    ///         would have caught the defect, so the passing test below is a
    ///         real regression gate, not a permissive-mock artefact.
    function test_Harness_KCheckRejectsNominalAskOnTaxedInput() public {
        uint256 nominalAsk = BPC.outSolidly(
            AMOUNT_IN, RESERVE, RESERVE, 30, false
        ) - 1; // the pre-fix router's exact demand (quote on nominal, minus 1 wei)

        bool zeroForOne = address(fotToken) < address(outToken);
        vm.startPrank(user);
        fotToken.transfer(address(pair), AMOUNT_IN); // pool receives 95%
        vm.expectRevert(bytes("SolidlyPairK: K"));
        pair.swap(
            zeroForOne ? 0 : nominalAsk,
            zeroForOne ? nominalAsk : 0,
            user, ""
        );
        vm.stopPrank();
    }

    /// @notice The regression proper: a fee-on-transfer tokenIn now ROUTES
    ///         through a K-enforcing Solidly pool (it reverted before the
    ///         fix), and the delivered amount equals the pool's own quote of
    ///         the doubly-taxed MEASURED input (user→router, router→pool),
    ///         minus the 1 wei rounding armour and the protocol fee — the
    ///         quote≡exec invariant, priced on measured reality.
    function test_FotTokenIn_RoutesThroughSolidly() public {
        // Honest (tax-blind) solver attestation for the nominal input.
        uint256 attestedOut = BPC.outSolidly(AMOUNT_IN, RESERVE, RESERVE, 30, false);

        uint256 pulled = _afterTax(AMOUNT_IN);   // survives user → router
        uint256 realIn = _afterTax(pulled);      // survives router → pool
        uint256 expectedAsk = BPC.outSolidly(realIn, RESERVE, RESERVE, 30, false) - 1;
        uint256 expectedNet = expectedAsk - BPC.mulDiv(expectedAsk, 28, BPC.BPS);

        Route memory route = _buildSolidlyRoute(AMOUNT_IN, attestedOut);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            route, AMOUNT_IN, 1, user, block.timestamp + 1
        );

        assertEq(delivered, expectedNet, "delivered != measured-input quote minus protocol fee");
        assertEq(outToken.balanceOf(user), expectedNet, "user balance mismatch");
    }

    /// @notice Same regression through the replicated-curve FALLBACK path
    ///         (pool hides getAmountOut): the fallback must also price the
    ///         MEASURED input, with its historical 200 bps K-margin haircut.
    function test_FotTokenIn_RoutesThroughSolidlyFallback() public {
        pair.setHideGetAmountOut(true);

        uint256 attestedOut = BPC.outSolidly(AMOUNT_IN, RESERVE, RESERVE, 30, false);
        uint256 realIn = _afterTax(_afterTax(AMOUNT_IN));
        uint256 expectedAsk =
            (BPC.outSolidly(realIn, RESERVE, RESERVE, 30, false) * 9_800) / BPC.BPS;
        uint256 expectedNet = expectedAsk - BPC.mulDiv(expectedAsk, 28, BPC.BPS);

        Route memory route = _buildSolidlyRoute(AMOUNT_IN, attestedOut);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            route, AMOUNT_IN, 1, user, block.timestamp + 1
        );

        assertEq(delivered, expectedNet, "fallback path must price the measured input");
    }

    /// @notice Honest-token parity: with no transfer tax, the reordered
    ///         transfer-then-quote execution is bit-identical to the
    ///         historical quote-then-transfer path (stored reserves are
    ///         untouched by a plain transfer), so the delivered amount is
    ///         exactly the nominal-input quote minus the protocol fee.
    function test_HonestTokenIn_SolidlyUnchanged() public {
        fotToken.setFeeOnTransferBps(0);

        uint256 quote = BPC.outSolidly(AMOUNT_IN, RESERVE, RESERVE, 30, false);
        uint256 expectedAsk = quote - 1;
        uint256 expectedNet = expectedAsk - BPC.mulDiv(expectedAsk, 28, BPC.BPS);

        Route memory route = _buildSolidlyRoute(AMOUNT_IN, quote);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            route, AMOUNT_IN, 1, user, block.timestamp + 1
        );

        assertEq(delivered, expectedNet, "honest-token Solidly path must be unchanged");
    }
}
