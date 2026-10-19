// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  H3 (oc-1018, Info, hardening) - a hop whose tokenIn == tokenOut is refused.
//
//  `legOutRaw` (the token a leg delivers into, one snapshot of the pool's pair in
//  `_legTokens`) has two consumers that asked different questions: the pair guard
//  in `_execute` ("is it the hop's tokenOut?") and `_execScaled` ("is it the leg's
//  own input?" - if so the per-leg floor fails open). A pool answering
//  token0() == token1() == B satisfied both at once inside a self-hop B -> B: the
//  pair guard passed and the per-leg floor switched itself off, even against an
//  attestation of the caller. No factory pool has token0 == token1 and the Solver
//  never emits a self-hop (`findBestRoutePlan`: tIn != tOut, bridges distinct from
//  both ends and from each other), so the refusal costs nothing to an honest route.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

interface ISelfHopToken {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface ISelfHopCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice V3-shaped hostile pool answering token0() == token1() == T on every read,
///         so `_legTokens` derives legIn == legOutRaw == T. Quotes against `liquidity`
///         (deep), fills against `swapLiquidity` (thin): what the per-leg floor exists
///         to catch.
contract SelfPairPool {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint128 public swapLiquidity;

    constructor(address t, uint24 _fee) { token0 = t; token1 = t; fee = _fee; }

    function setState(uint160 sp, uint128 l) external { sqrtPriceX96 = sp; liquidity = l; }
    function setSwapLiquidity(uint128 l) external { swapLiquidity = l; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact-out unsupported");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 && sqrtPriceLimitX96 > 4295128739
                : sqrtPriceLimitX96 > sqrtPriceX96
                    && sqrtPriceLimitX96 < 1461446703485210103287273052203988822378723970342,
            "SPL"
        );
        uint256 amtIn = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, swapLiquidity, fee, zeroForOne, 0);
        if (amtOut == 0) amtOut = 1;
        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);
        uint256 balBefore = ISelfHopToken(token0).balanceOf(address(this));
        ISelfHopCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, "");
        require(ISelfHopToken(token0).balanceOf(address(this)) - balBefore >= amtIn, "insufficient input");
        ISelfHopToken(token0).transfer(recipient, amtOut);
    }
}

contract RouterSelfHopRefusedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    MockV3Pool pAB;      // A -> B, honest
    MockV3Pool pBC;      // B -> C, honest
    SelfPairPool selfA;  // token0 == token1 == A
    SelfPairPool selfB;  // token0 == token1 == B

    address user = address(0xBEEF);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = uint128(1e27);
    uint128 constant THIN = uint128(1e19);
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        hub.addBridge(address(tokenB));

        pAB = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pAB.setState(Q96, LIQ);
        pBC = new MockV3Pool(address(tokenB), address(tokenC), 3000);
        pBC.setState(Q96, LIQ);
        selfA = new SelfPairPool(address(tokenA), 3000);
        selfA.setState(Q96, LIQ);
        selfA.setSwapLiquidity(THIN);
        selfB = new SelfPairPool(address(tokenB), 3000);
        selfB.setState(Q96, LIQ);
        selfB.setSwapLiquidity(THIN);

        tokenB.mint(address(pAB), 1_000_000e18);
        tokenC.mint(address(pBC), 1_000_000e18);
        tokenA.mint(address(selfA), 1_000_000e18);
        tokenB.mint(address(selfB), 1_000_000e18);

        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _e(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    function _legV3(address pool, address tIn, uint256 amt, uint256 att) private view returns (Leg memory) {
        return Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: MockV3Pool(pool).token0() == tIn, stable: false, amountIn: amt, expectedOut: att,
            auxId: bytes32(0)});
    }

    function _legSelf(address pool, uint256 amt, uint256 att) private pure returns (Leg memory) {
        return Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: att, auxId: bytes32(0)});
    }

    function _hop(address tIn, address tOut, Leg memory l) private pure returns (Hop memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: 0, expectedOut: 0, legs: ls});
    }

    function _wrap(Hop[] memory hs) private pure returns (Route memory) {
        return Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 1,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// A -> B honest, B -> B through a (B,B) pool, B -> C honest. `att` is the
    /// caller's attestation on the self-hop leg (0 = none).
    function _selfHopRoute(uint256 att) private view returns (Route memory) {
        uint256 b = BPC.outV3(AMT, Q96, LIQ, 3000, pAB.token0() == address(tokenA), 0);
        Hop[] memory hs = new Hop[](3);
        hs[0] = _hop(address(tokenA), address(tokenB), _legV3(address(pAB), address(tokenA), AMT, 0));
        hs[1] = _hop(address(tokenB), address(tokenB), _legSelf(address(selfB), b, att));
        hs[2] = _hop(address(tokenB), address(tokenC), _legV3(address(pBC), address(tokenB), b, 0));
        return _wrap(hs);
    }

    /// THE RED: the mid-route self-hop whose leg has legOutRaw == legIn == B is
    /// refused with RouterE(3) and nothing moves. Unfixed: settles far below the
    /// pool-state oracle (the per-leg floor failed open).
    function test_legOutRaw_MidRouteSelfHop_IsRefused() public {
        Route memory r = _selfHopRoute(0);
        uint256 userBefore = tokenA.balanceOf(user);

        bool ok; bytes memory err;
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256) { ok = true; }
        catch (bytes memory e) { err = e; }

        assertTrue(!ok, "a self-hop (hop.tokenIn == hop.tokenOut) must be refused");
        assertEq(keccak256(err), keccak256(_e(3)), "the refusal is the route-shape RouterE(3)");
        assertEq(tokenA.balanceOf(user), userBefore, "nothing may move on a refused route");
        assertEq(tokenC.balanceOf(user), 0, "no output on a refused route");
    }

    /// The same self-hop WITH the caller's attestation on the leg: the alias used to
    /// override it (per-leg floor still off). Refused the same way.
    function test_legOutRaw_AttestedSelfHop_IsRefused() public {
        uint256 b = BPC.outV3(AMT, Q96, LIQ, 3000, pAB.token0() == address(tokenA), 0);
        Route memory r = _selfHopRoute(b);

        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// Single-hop A -> A through a (A,A) pool: the degenerate pair alone.
    function test_legOutRaw_SingleSelfHop_IsRefused() public {
        Hop[] memory hs = new Hop[](1);
        hs[0] = _hop(address(tokenA), address(tokenA), _legSelf(address(selfA), AMT, 0));
        Route memory r = _wrap(hs);

        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// Control: the (A,A) pool inside a NORMAL hop A -> B was already refused by
    /// the pair guard (legOutRaw != hop.tokenOut). Unchanged.
    function test_legOutRaw_Control_SelfPairInNormalHop_PairGuard() public {
        Leg[] memory ls = new Leg[](2);
        ls[0] = _legSelf(address(selfA), 0, 0);
        ls[1] = _legV3(address(pAB), address(tokenA), AMT, 0);
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB), amountIn: 0, expectedOut: 0, legs: ls});
        Route memory r = _wrap(hs);

        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// Control: the honest two-hop route the self-hop was spliced into settles.
    function test_legOutRaw_Control_HonestTwoHop_Settles() public {
        uint256 b = BPC.outV3(AMT, Q96, LIQ, 3000, pAB.token0() == address(tokenA), 0);
        uint256 bNet = b - BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 fair = BPC.outV3(bNet, Q96, LIQ, 3000, pBC.token0() == address(tokenB), 0);
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(address(tokenA), address(tokenB), _legV3(address(pAB), address(tokenA), AMT, 0));
        hs[1] = _hop(address(tokenB), address(tokenC), _legV3(address(pBC), address(tokenB), bNet, 0));
        Route memory r = _wrap(hs);

        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertEq(out, fair, "honest route delivers the pool-state oracle");
    }
}
