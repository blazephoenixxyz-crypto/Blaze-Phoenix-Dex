// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  NM-002 (external report, BoyD) and its sibling, review 2026-09-02.
//
//  The protocol floor is `mulDivUp(finalHopQuote, floorBps, BPS)`. When the
//  last hop cannot be QUOTED in-frame the quote is 0, the floor is 0, and the
//  code said so: "the protocol floor is inert for this swap". Absence read as
//  permission. Two ways to reach that state on a pool that still DELIVERS:
//
//   1. A liquidity gap at the current tick (the getter reads 0, execution
//      fills by crossing into the next initialised tick). Attacker-triggerable
//      by a JIT burn/mint on a thin concentrated pool: the victim's guaranteed
//      floor dropped from ~96% to the 80% per-leg floor.
//   2. A concentrated leg whose fee cannot be measured (fee() == 0 -> the
//      0xFFFFFF sentinel -> outV3 == 0). Here the quote arm ran, answered 0,
//      and `impactV3FromOut(0)` charged BPS of impact — which `ironFloorBps`
//      SUBTRACTS, collapsing the floor to its 80% clamp. The two sibling arms
//      charge DEFAULT_IMPACT_BPS in the same situation.
//
//  Fix 1: floor on the hop's ATTESTED quote when the measured one is absent
//  (never revert: a 0-fee CL pool is legal). Fix 2: the unquotable arm charges
//  DEFAULT_IMPACT_BPS like its siblings. Both tests are RED on main 19b2f08.
//
//  Fixture: tokenOut is a bridge, so the fee comes out of the OUTPUT after
//  the floor check and the floor sees the gross delivery — no input-side fee
//  to fold into the arithmetic.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract ProtocolFloorFallsBackToAttestedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address user = address(0xBEEF);
    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0
    uint128 constant LIQ = 1_000_000e18;
    uint256 constant AMT = 1e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        // tokenOut is a bridge: the fee comes out of the output, AFTER the floor.
        hub.addBridge(address(tokenB));
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _pool(uint24 fee_, uint128 reported, uint128 executed) private returns (MockV3Pool p) {
        p = new MockV3Pool(address(tokenA), address(tokenB), fee_);
        p.setState(SQRT_P_1, reported);
        p.setSwapLiquidity(executed);
        tokenB.mint(address(p), 1_000_000e18);
    }

    function _route(MockV3Pool p, uint256 attested) private view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: p.fee(),
            tickSpacing: 0, zeroForOne: address(tokenA) < address(tokenB), stable: false,
            amountIn: AMT, expectedOut: attested, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA), tokenOut: address(tokenB),
            amountIn: AMT, expectedOut: attested, legs: legs
        });
        route = Route({
            hops: hops, totalOut: attested, singleOut: attested,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _e5() private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5));
    }

    /// What the pool will deliver for AMT with the liquidity it EXECUTES on.
    function _delivered(MockV3Pool p, uint128 execL) private view returns (uint256) {
        return BPC.outV3(AMT, SQRT_P_1, execL, p.fee(), address(tokenA) < address(tokenB), 0);
    }

    // ───────────────────────── 1. the liquidity gap ─────────────────────────

    /// RED on main: the quoter reads liquidity 0, the pool still fills, the
    /// caller attested 15% more than the fill. Inside the 20% per-leg slack,
    /// outside the ~96% protocol floor — and the protocol floor was 0.
    function test_LiquidityGapOnLastHop_FloorFallsBackToAttested() public {
        MockV3Pool p = _pool(3000, 0, LIQ);
        assertEq(p.liquidity(), 0, "premise: the current tick reports no liquidity");
        uint256 got = _delivered(p, LIQ);
        // Built BEFORE the prank/expectRevert: `_route` reads `p.fee()`, an
        // external call that would otherwise consume both cheatcodes (the
        // instrument-destroys-the-reading class, caught on the first red run).
        Route memory route = _route(p, (got * 100) / 85);

        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
    }

    /// Guard: an HONEST attestation on the same gap still settles. The fallback
    /// floors on the attested figure; it never turns a legitimate gap fill
    /// into a refusal.
    function test_Control_LiquidityGap_HonestAttestationSettles() public {
        MockV3Pool p = _pool(3000, 0, LIQ);
        Route memory route = _route(p, _delivered(p, LIQ));

        vm.prank(user);
        uint256 out = router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "an honest gap fill settles");
    }

    // ────────────────────── 2. the unquotable fee-0 leg ─────────────────────

    /// RED on main: fee() == 0 makes the in-frame quote 0 through the fee
    /// sentinel; the impact arm charged BPS and the floor collapsed to 80%.
    /// With the sibling arms' DEFAULT_IMPACT_BPS the floor stays near 96% of
    /// the attested figure and a 15% shortfall is refused.
    function test_UnquotableFeeZeroLeg_FloorDoesNotCollapseToTheClamp() public {
        MockV3Pool p = _pool(0, LIQ, 0);
        assertEq(p.fee(), 0, "premise: the fee is unmeasurable, the quote is 0");
        uint256 got = _delivered(p, LIQ);
        Route memory route = _route(p, (got * 100) / 85);

        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
    }

    /// Guard: the fee-0 pool with an honest attestation settles (a legitimately
    /// 0-fee concentrated pool is a legal venue, never refused outright).
    function test_Control_FeeZeroLeg_HonestAttestationSettles() public {
        MockV3Pool p = _pool(0, LIQ, 0);
        Route memory route = _route(p, _delivered(p, LIQ));

        vm.prank(user);
        uint256 out = router.swapExactIn(route, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "a 0-fee pool with an honest attestation settles");
    }
}
