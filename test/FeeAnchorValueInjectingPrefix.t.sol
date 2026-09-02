// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE MEASURED RESIDUAL of the fee anchor (review 2026-09-02).
//
//  The fee is charged ONCE, on the first hop whose INPUT is a bridge coin
//  (owner's decision 2026-08-22; see `_chargeHopFee` and the fee block in
//  `_execute`). The docstring argued immunity by exhaustion for prefixes
//  WITHOUT value. This is the prefix WITH value:
//
//    hop 0: 2 wei of WETH  ->  a pair the attacker wrote, funded with the
//                              attacker's own USDC, which it pays out
//    hop 1: that USDC      ->  the REAL pool, fee-free
//
//  WETH is a bridge, so hop 0 IS the anchor; the fee is charged on 2 wei
//  (rounded up to 1 wei) and the real pool is crossed with hundreds of USDC
//  of the attacker's own value. No user is harmed; the treasury loses the
//  rate on that trade. The evader's alternative was calling the pool directly
//  and paying nothing, so the leak is bounded by what the Router's own
//  guarantees are worth to them.
//
//  There is no anchor immune to this without a price (the Router's docstring
//  proves the negative); the only immune rule is charge-on-every-hop, which
//  doubles the honest two-hop cost and was rejected by the owner. The rate
//  rule is therefore the owner's decision. This test does NOT assert the
//  wished-for behaviour: it PINS THE LEAK AS IT IS, so the acceptance is a
//  measured number and not an assumption — and so that the day the rule
//  changes, this test flips and has to be rewritten on purpose.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract FeeAnchorValueInjectingPrefixTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 weth;
    MockERC20 usdc;
    MockERC20 y;
    MockV2Pair attackerPair;   // (WETH, USDC): 1 wei of WETH against the attacker's USDC
    MockV2Pair realPool;       // (USDC, Y): the venue the attacker wants to use fee-free

    address attacker = address(0xA77AC4);
    address t1 = address(0xFEE1);
    address t2 = address(0xFEE2);
    uint256 constant INJECTED_USDC = 666e6;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        weth = new MockERC20("WETH", "WETH");
        usdc = new MockERC20("USDC", "USDC");
        y    = new MockERC20("Y", "Y");
        hub.addBridge(address(weth));
        hub.addBridge(address(usdc));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), t1, t2);

        // The attacker's pair: it holds 1 wei of WETH and the USDC it will pay out.
        attackerPair = new MockV2Pair(address(weth), address(usdc));
        weth.mint(address(attackerPair), 1);
        usdc.mint(address(attackerPair), INJECTED_USDC);
        _setReserves(attackerPair, address(weth), 1, INJECTED_USDC);

        // The real pool, deep.
        realPool = new MockV2Pair(address(usdc), address(y));
        usdc.mint(address(realPool), 1_000_000e18);
        y.mint(address(realPool), 1_000_000e18);
        _setReserves(realPool, address(usdc), 1_000_000e18, 1_000_000e18);

        weth.mint(attacker, 2);
        vm.prank(attacker);
        weth.approve(address(router), type(uint256).max);
    }

    function _setReserves(MockV2Pair p, address tokX, uint256 rX, uint256 rOther) private {
        bool xIs0 = p.token0() == tokX;
        p.setReserves(uint112(xIs0 ? rX : rOther), uint112(xIs0 ? rOther : rX));
    }

    function _leg(MockV2Pair p, address tIn, address tOut, uint256 amt) private pure returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: tIn < tOut, stable: false, amountIn: amt, expectedOut: 1, auxId: bytes32(0)
        });
    }

    function _route() private view returns (Route memory route) {
        Hop[] memory hops = new Hop[](2);
        Leg[] memory l0 = new Leg[](1); l0[0] = _leg(attackerPair, address(weth), address(usdc), 2);
        Leg[] memory l1 = new Leg[](1); l1[0] = _leg(realPool, address(usdc), address(y), 300e6);
        hops[0] = Hop({ tokenIn: address(weth), tokenOut: address(usdc), amountIn: 2,     expectedOut: 1, legs: l0 });
        hops[1] = Hop({ tokenIn: address(usdc), tokenOut: address(y),    amountIn: 300e6, expectedOut: 1, legs: l1 });
        route = Route({
            hops: hops, totalOut: 1, singleOut: 1, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// Pins the leak as measured. GREEN today BY DESIGN — see the header.
    function test_RESIDUAL_ValueInjectingBridgePrefix_PaysOneWeiOfFee_OwnerDecision() public {
        uint256 usdcInRealBefore = usdc.balanceOf(address(realPool));

        vm.prank(attacker);
        uint256 got = router.swapExactIn(_route(), 2, 1, attacker, block.timestamp + 1);

        uint256 usdcCrossed = usdc.balanceOf(address(realPool)) - usdcInRealBefore;
        uint256 feeUsdc = usdc.balanceOf(t1) + usdc.balanceOf(t2);
        uint256 feeWeth = weth.balanceOf(t1) + weth.balanceOf(t2);
        uint256 rateOnValue = BPC.mulDivUp(usdcCrossed, BPC.PROTOCOL_FEE_BPS, BPC.BPS);

        assertGt(got, 0, "the attacker received Y from the real pool");
        assertGt(usdcCrossed, 300e6, "hundreds of USDC of the attacker's own value crossed the real pool");
        assertEq(feeUsdc, 0, "MEASURED LEAK: no fee was charged in the coin that carried the value");
        assertEq(feeWeth, 1, "MEASURED LEAK: the fee anchored on the 2-wei prefix, rounded up to 1 wei");
        // For scale: ~332 USDC crossed (outV2 of 1 wei against reserves 1 : 666e6),
        // so the rate on the value moved is ~0.93 USDC (931_000 in 6-decimal
        // units), against the 1 wei of WETH that was actually charged.
        assertGt(rateOnValue, 900_000, "for scale: the rate on the value moved is ~0.93 USDC, not 1 wei");
    }
}
