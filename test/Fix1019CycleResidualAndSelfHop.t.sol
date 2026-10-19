// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  fix-1019 (oc-1018 H9, H3): two degenerate token identities in a crafted route.
//
//  H9. Route tokenIn == tokenOut (cycle A -> B -> A) whose hop 0 commits less
//  than the pull. The `_execute` docstring says the unspent input belongs to
//  the PAYER; on the cyclic branch the tokenIn sweep is skipped and the
//  residual is counted as output and paid to the RECIPIENT. It also counts
//  toward the floors, so it can mask a bad conversion (axis M).
//
//  H3. Hop tokenIn == tokenOut (self-hop B -> B through a pair-shaped contract
//  with token0 == token1). The pair guard admits it, and `_execScaled` turns
//  `legOut == tokenIn` into address(0): the per-leg floor and Layer 1 are off
//  for that hop, even with the caller's own attestation.
//
//  Written at 57a4bab (origin/main). RED there: the four `_IsRefundedToThePayer`,
//  `_DoesNotCountTowardTheFloor`, `_IsRefusedRouterE3` tests. GREEN there and
//  after the fix: the controls (acyclic sweep, payer == recipient, honest
//  routes, alias leg in a normal hop).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

interface IF19AliasToken {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IF19V3Callback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// A V3-shaped contract with token0 == token1: the only way to express a
/// self-hop leg. No factory can deploy it (V2/V3 sort and require distinct
/// tokens); a crafted route can still name it. It quotes at `liquidity` and
/// fills at `swapLiquidity`.
contract F19AliasPool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint128 public swapLiquidity;

    constructor(address t, uint24 _fee) { token0 = t; token1 = t; fee = _fee; }

    function setState(uint160 sp, uint128 l) external { sqrtPriceX96 = sp; liquidity = l; }
    function setSwapLiquidity(uint128 l) external { swapLiquidity = l; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact-out unsupported");
        uint256 amtIn = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, swapLiquidity, fee, zeroForOne, 0);
        if (amtOut == 0) amtOut = 1;
        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);
        uint256 balBefore = IF19AliasToken(token0).balanceOf(address(this));
        IF19V3Callback(msg.sender).uniswapV3SwapCallback(amount0, amount1, "");
        require(IF19AliasToken(token0).balanceOf(address(this)) - balBefore >= amtIn, "insufficient input");
        IF19AliasToken(token0).transfer(recipient, amtOut);
    }
}

contract Fix1019CycleResidualAndSelfHopTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB; // bridge
    MockERC20 tokenC;
    MockV3Pool pAB;
    MockV3Pool pBA;
    MockV3Pool pBC;
    F19AliasPool aliasA;
    F19AliasPool aliasB;

    address user = address(0xBEEF);
    address recip = address(0xCAFE);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = uint128(1e27);
    uint128 constant THIN = uint128(1e19);
    uint256 constant AMT = 1_000e18; // pulled from the payer
    uint256 constant X0 = 400e18;    // hop 0's commitment in the cycle

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
        pBA = new MockV3Pool(address(tokenB), address(tokenA), 3000);
        pBA.setState(Q96, LIQ);
        pBC = new MockV3Pool(address(tokenB), address(tokenC), 3000);
        pBC.setState(Q96, LIQ);
        aliasA = new F19AliasPool(address(tokenA), 3000);
        aliasA.setState(Q96, LIQ);
        aliasA.setSwapLiquidity(THIN);
        aliasB = new F19AliasPool(address(tokenB), 3000);
        aliasB.setState(Q96, LIQ);
        aliasB.setSwapLiquidity(THIN);
        tokenB.mint(address(pAB), 1_000_000e18);
        tokenA.mint(address(pBA), 1_000_000e18);
        tokenC.mint(address(pBC), 1_000_000e18);
        tokenB.mint(address(aliasB), 1_000_000e18);
        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    // --- oracle and builders ------------------------------------------------------

    function _e(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// The V3 swap step on the pool's published state (Q96, LIQ, 30 bps).
    function _q(MockV3Pool p, address tIn, uint256 amt) private view returns (uint256) {
        return BPC.outV3(amt, Q96, LIQ, 3000, p.token0() == tIn, 0);
    }

    function _netOfFee(uint256 b) private pure returns (uint256) {
        return b - BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function _leg(address pool, bool z, uint256 amt, uint256 exp) private pure returns (Leg memory) {
        return Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: z, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
    }

    function _hop(address tIn, address tOut, uint256 amt, Leg memory l) private pure returns (Hop memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: 0, legs: ls});
    }

    function _route(Hop[] memory hs, uint256 out) private pure returns (Route memory) {
        return Route({hops: hs, totalOut: out, singleOut: out, singleOutFloor: 1, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// A -> B -> A, hop 0 commits X0 < AMT. Returns the oracle output y of the
    /// closing leg on the fee-net bridge amount.
    function _cycle() private view returns (Route memory r, uint256 y) {
        uint256 bNet = _netOfFee(_q(pAB, address(tokenA), X0));
        y = _q(pBA, address(tokenB), bNet);
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(address(tokenA), address(tokenB), X0, _leg(address(pAB), pAB.token0() == address(tokenA), X0, 0));
        hs[1] = _hop(address(tokenB), address(tokenA), bNet, _leg(address(pBA), pBA.token0() == address(tokenB), bNet, 0));
        r = _route(hs, y);
    }

    /// Same hop 0, output C: the acyclic branch, where the tokenIn sweep runs.
    function _acyclic() private view returns (Route memory r, uint256 y) {
        uint256 bNet = _netOfFee(_q(pAB, address(tokenA), X0));
        y = _q(pBC, address(tokenB), bNet);
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(address(tokenA), address(tokenB), X0, _leg(address(pAB), pAB.token0() == address(tokenA), X0, 0));
        hs[1] = _hop(address(tokenB), address(tokenC), bNet, _leg(address(pBC), pBC.token0() == address(tokenB), bNet, 0));
        r = _route(hs, y);
    }

    /// A -> B -> B -> C with the self-hop through `aliasB`; `aliasExp` is the
    /// caller's attestation on the alias leg (0 = none).
    function _selfHop(uint256 aliasExp) private view returns (Route memory r, uint256 fair) {
        uint256 b = _q(pAB, address(tokenA), AMT);
        fair = _q(pBC, address(tokenB), _netOfFee(b));
        Hop[] memory hs = new Hop[](3);
        hs[0] = _hop(address(tokenA), address(tokenB), AMT, _leg(address(pAB), pAB.token0() == address(tokenA), AMT, 0));
        hs[1] = _hop(address(tokenB), address(tokenB), b, _leg(address(aliasB), true, b, aliasExp));
        hs[2] = _hop(address(tokenB), address(tokenC), b, _leg(address(pBC), pBC.token0() == address(tokenB), b, 0));
        r = _route(hs, fair);
    }

    // --- H9 ------------------------------------------------------------------------

    /// H9 RED on 57a4bab: the payer is charged the whole pull (AMT); the
    /// recipient receives the converted output PLUS the payer's residual.
    /// After the fix the payer spends only the committed X0 and the recipient
    /// receives exactly the conversion y (oracle: outV3 on the pools' state).
    function test_H9_CyclicResidual_IsRefundedToThePayer() public {
        (Route memory r, uint256 y) = _cycle();
        uint256 payer0 = tokenA.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, recip, block.timestamp + 1);
        assertEq(payer0 - tokenA.balanceOf(user), X0, "payer spends only what hop 0 committed");
        assertEq(tokenA.balanceOf(recip), y, "recipient receives the conversion, not the residual");
        assertEq(out, y, "returned amount is the conversion");
        assertEq(tokenA.balanceOf(address(router)), 0, "Router holds nothing");
    }

    /// H9, axis M, RED on 57a4bab: the residual counts as output, so a
    /// userMinOut ONE wei above what the route converted is satisfied by the
    /// payer's own unspent input. After the fix the floor sees only y.
    function test_H9_CyclicResidual_DoesNotCountTowardTheFloor() public {
        (Route memory r, uint256 y) = _cycle();
        vm.prank(user);
        vm.expectRevert(_e(5));
        router.swapExactIn(r, AMT, y + 1, recip, block.timestamp + 1);
    }

    /// Mirror, GREEN on both trees: payer == recipient. Net A delta is
    /// X0 - y either way (refunded as residual or delivered as output), so
    /// this case could never show the defect, and the fix must not move it.
    function test_H9_Cyclic_PayerIsRecipient_NetDeltaIsX0MinusY() public {
        (Route memory r, uint256 y) = _cycle();
        uint256 payer0 = tokenA.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertEq(payer0 - tokenA.balanceOf(user), X0 - y, "payer == recipient: net delta X0 - y");
        assertEq(tokenA.balanceOf(address(router)), 0, "Router holds nothing");
    }

    /// Sibling, GREEN on both trees: the acyclic branch already sweeps the
    /// residual to the payer, and the recipient gets only the output token.
    function test_H9_Acyclic_ResidualIsRefundedToThePayer() public {
        (Route memory r, uint256 y) = _acyclic();
        uint256 payer0 = tokenA.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, recip, block.timestamp + 1);
        assertEq(payer0 - tokenA.balanceOf(user), X0, "acyclic: payer spends only X0");
        assertEq(out, y, "acyclic: output is the conversion");
        assertEq(tokenC.balanceOf(recip), y, "acyclic: recipient gets C");
        assertEq(tokenA.balanceOf(recip), 0, "acyclic: recipient gets no A");
    }

    // --- H3 ------------------------------------------------------------------------

    /// H3 RED on 57a4bab: the self-hop settles (far under the fair output,
    /// with the per-leg floor off). After the fix a hop whose tokenIn equals
    /// its tokenOut is refused as a route shape, RouterE(3).
    function test_H3_SelfHop_IsRefusedRouterE3() public {
        (Route memory r,) = _selfHop(0);
        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// H3 RED on 57a4bab: the alias silences the caller's OWN attestation on
    /// that leg (legOut -> address(0) disarms the guard whatever expectedOut
    /// says). After the fix the shape never reaches `_execScaled`.
    function test_H3_SelfHop_WithAttestedLeg_IsRefusedRouterE3() public {
        uint256 b = _q(pAB, address(tokenA), AMT);
        (Route memory r,) = _selfHop(b);
        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// Control, GREEN on both trees: an alias leg inside a NORMAL hop (A -> B)
    /// is already refused by the pair guard, RouterE(3).
    function test_H3_AliasLegInNormalHop_IsRefusedByThePairGuard() public {
        Leg[] memory ls = new Leg[](2);
        ls[0] = _leg(address(aliasA), true, 0, 0);
        ls[1] = _leg(address(pAB), pAB.token0() == address(tokenA), AMT, 0);
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB), amountIn: 0, expectedOut: 0, legs: ls});
        Route memory r = _route(hs, 0);
        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// Control, GREEN on both trees: the honest A -> B -> C route the self-hop
    /// was spliced into settles at the oracle output. A fix that refuses too
    /// much (every hop, every bridge reuse) turns this red.
    function test_H3_HonestTwoHop_SettlesAtTheOracle() public {
        uint256 b = _q(pAB, address(tokenA), AMT);
        uint256 fair = _q(pBC, address(tokenB), _netOfFee(b));
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(address(tokenA), address(tokenB), AMT, _leg(address(pAB), pAB.token0() == address(tokenA), AMT, 0));
        hs[1] = _hop(address(tokenB), address(tokenC), b, _leg(address(pBC), pBC.token0() == address(tokenB), b, 0));
        Route memory r = _route(hs, fair);
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, fair, user, block.timestamp + 1);
        assertEq(out, fair, "honest two-hop settles at the oracle");
    }
}
