// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Bounty #85 (Remember Me, 2026-10-12; residual of the forged-reserves fix #96, duxun D1).
// A synthetic pair registers honest with one dust swap (`reservesHeld` is asked only at that
// first swap), then forges `getReserves`. The Solver's mass vote for a pair is
// min(declared depth, balanceOf(tokenOut)): with the declaration free, the vote collapses to
// the pool's tokenOut balance, which a recoverable donation fills. Thirteen million donated
// against three honest pools of four million a side moved the depth-weighted median onto the
// attacker's rate 6 % under fair, every honest pool fell outside the band, and the victim was
// filled 5.48 % under honest routing with every floor passing.
//
// Option (b): only mass a factory vouches for (or an operator curated) votes the band's base.
// A row the Router wrote for whoever swapped first (tier 2) of a pair-shaped or concentrated-
// shaped kind still quotes and still executes, but its depth does not move the depth-weighted
// median (`Solver._depthWeightedMedian`, masked by `Solver._mutedVotes`) - unless the Solver's
// discovery sweep found the same pool at a registered factory, in
// which case its code is the factory's and its mass is the market's. When no live candidate
// may vote, the set falls back to the vote it always had. Red on 31cd55d: the forged pair,
// the hostile concentrated contract and the parked pair each capture the band; a factory-born
// row outvotes a liar. With option (a)'s holdings door in the same tree (Core.heldBy), the
// two gaps the vote leaves alone close too: a liar inside the band, and a forged pair where
// nobody may vote. `test_limit_` pins, measured, what neither door closes (a pair with no
// vouched mass and a contract that HOLDS what it declares); `test_cost_` what the vote gives
// up (a deep permissionless pool's vote, when the only voters left are shallow curated ones).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan, PoolInfo, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockV2Pair} from "../test/mocks/MockV2Pair.sol";
import {MockV3Pool} from "../test/mocks/MockV3Pool.sol";
import {MockV2Factory} from "../test/mocks/MockV2Factory.sol";

interface IERC20Min85 {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice The reporter's synthetic pair: reports any reserves once forged, pays exactly what
///         the Router computes from them, and lets its owner take everything back.
contract LyingPair85Vote {
    address public token0;
    address public token1;
    address public owner;
    uint112 public reserve0;
    uint112 public reserve1;
    bool public forged;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        owner = msg.sender;
    }

    function syncHonest() external {
        reserve0 = uint112(IERC20Min85(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Min85(token1).balanceOf(address(this)));
    }

    function forge(uint112 r0, uint112 r1) external {
        require(msg.sender == owner, "only owner");
        (reserve0, reserve1, forged) = (r0, r1, true);
    }

    function recover(address token, address to) external {
        require(msg.sender == owner, "only owner");
        IERC20Min85(token).transfer(to, IERC20Min85(token).balanceOf(address(this)));
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 a0, uint256 a1, address to, bytes calldata) external {
        if (a0 > 0) IERC20Min85(token0).transfer(to, a0);
        if (a1 > 0) IERC20Min85(token1).transfer(to, a1);
        if (!forged) {
            reserve0 = uint112(IERC20Min85(token0).balanceOf(address(this)));
            reserve1 = uint112(IERC20Min85(token1).balanceOf(address(this)));
        }
    }
}

contract Bounty1013BandVoteIsVouchedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;

    address attacker = address(0xA77AC);
    address user     = address(0xBEEF);

    uint256 constant HONEST_SIDE = 4_000_000e18;   // three honest pools, 4M a side
    uint256 constant DONATION    = 13_000_000e18;  // more than half of the 12M honest mass
    uint256 constant ORDER       = 100_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        for (uint256 i; i < 3; ++i) _honestPool();
    }

    // ── fixtures ─────────────────────────────────────────────────

    function _honestPool() internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), HONEST_SIDE);
        tB.mint(address(p), HONEST_SIDE);
        p.setReserves(uint112(HONEST_SIDE), uint112(HONEST_SIDE));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tA), address(tB));
    }

    function _plan() internal view returns (RoutePlan memory) {
        return solver.findBestRoutePlan(address(tA), address(tB), ORDER);
    }

    function _route1(address pool, uint8 kind, uint24 fee, bool zfo, uint256 amt, uint256 exp)
        internal pure returns (Route memory r)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: kind, fee: fee, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(0), tokenOut: address(0), amountIn: amt, expectedOut: exp, legs: legs});
        r = Route({hops: hops, totalOut: exp, singleOut: exp, singleOutFloor: 1, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: true, isV4Bundle: false});
    }

    /// @dev The attacker's own dust swap through `pool`: the Router registers it (tier 2).
    function _dustSwap(address pool, uint8 kind, uint24 fee, bool zfo, uint256 exp) internal {
        uint256 dust = 100e18;
        tA.mint(attacker, dust);
        Route memory r = _route1(pool, kind, fee, zfo, dust, exp);
        r.hops[0].tokenIn = address(tA);
        r.hops[0].tokenOut = address(tB);
        vm.startPrank(attacker);
        tA.approve(address(router), dust);
        router.swapExactIn(r, dust, 1, attacker, block.timestamp + 1);
        vm.stopPrank();
    }

    function _lyingPair() internal returns (LyingPair85Vote atk) {
        vm.prank(attacker);
        atk = new LyingPair85Vote(address(tA), address(tB));
        tA.mint(address(atk), 2_000e18);
        tB.mint(address(atk), 2_000e18);
        atk.syncHonest();
        _dustSwap(address(atk), BPC.KIND_V2, 30, atk.token0() == address(tA), 1);
        assertTrue(hub.getSlot(hub.keyOf(address(atk), address(tA), address(tB))) != 0, "fixture: registered");
    }

    /// @dev Forge the pair at `rate` (tokenB out per tokenA in, 1e18 = par) over 1e30 of tA.
    function _forge(LyingPair85Vote atk, uint256 rate) internal {
        uint112 rIn = uint112(1e30);
        uint112 rOut = uint112(rate * 1e12);
        bool aIs0 = atk.token0() == address(tA);
        vm.prank(attacker);
        if (aIs0) atk.forge(rIn, rOut); else atk.forge(rOut, rIn);
    }

    /// @dev A V3-shaped contract the attacker wrote (MockV3Pool: anyone sets its state, it pays
    ///      what its own state quotes). Registered honest by a dust swap, then repriced.
    function _hostileConc() internal returns (MockV3Pool c) {
        c = new MockV3Pool(address(tA), address(tB), 3000);
        c.setState(uint160(1 << 96), uint128(2_000e18));
        tA.mint(address(c), 2_000e18);
        tB.mint(address(c), 2_000e18);
        _dustSwap(address(c), BPC.KIND_V3, 3000, c.token0() == address(tA), 1);
        assertTrue(hub.getSlot(hub.keyOf(address(c), address(tA), address(tB))) != 0, "fixture: registered");
    }

    /// @dev sqrtPriceX96 at which tA -> tB pays `rate` (1e18 = par) before the fee.
    function _sqrtAt(MockV3Pool c, uint256 rate) internal view returns (uint160) {
        uint256 p = c.token0() == address(tA) ? rate : (1e36 / rate);   // token1 per token0, 1e18
        return uint160(_sqrt(BPC.mulDiv(p, uint256(1) << 192, 1e18)));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    function _uses(RoutePlan memory plan, address pool) internal pure returns (bool) {
        for (uint256 h; h < plan.best.hops.length; ++h) {
            Leg[] memory legs = plan.best.hops[h].legs;
            for (uint256 l; l < legs.length; ++l) if (legs[l].pool == pool) return true;
        }
        return false;
    }

    /// @dev The victim signs 99 % of the preview and executes it.
    function _victim(RoutePlan memory plan) internal returns (uint256 received) {
        tA.mint(user, ORDER);
        vm.startPrank(user);
        tA.approve(address(router), ORDER);
        uint256 b0 = tB.balanceOf(user);
        router.swapExactIn(plan.best, ORDER, (plan.best.totalOut * 99) / 100, user, block.timestamp + 1);
        vm.stopPrank();
        received = tB.balanceOf(user) - b0;
    }

    /// @dev What the same victim receives with no attacker on the pair (executed, then undone).
    function _honestFill() internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        got = _victim(_plan());
        vm.revertToState(snap);
    }

    function _lossBps(uint256 honest, uint256 got) internal pure returns (uint256) {
        return got >= honest ? 0 : ((honest - got) * 10_000) / honest;
    }

    // ── pairs with no curated mass (fresh tokens, rows written by swaps) ──

    /// @dev Replaces the pair under test with two fresh tokens: no seeded pool, no row.
    function _freshTokens() internal {
        tA = new MockERC20("C", "C");
        tB = new MockERC20("D", "D");
    }

    /// @dev An honest pool at `rate` (tB per tA, 1e18 = par) over `sideA` of tA, registered by
    ///      a dust swap: a permissionless (tier 2) row.
    function _permissionlessPool(uint256 sideA, uint256 rate) internal returns (MockV2Pair p) {
        p = _heldPool(sideA, rate);
        _dustSwap(address(p), BPC.KIND_V2, 30, p.token0() == address(tA), 1);
    }

    function _heldPool(uint256 sideA, uint256 rate) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tA), address(tB));
        uint256 sideB = BPC.mulDiv(sideA, rate, 1e18);
        tA.mint(address(p), sideA);
        tB.mint(address(p), sideB);
        if (p.token0() == address(tA)) p.setReserves(uint112(sideA), uint112(sideB));
        else p.setReserves(uint112(sideB), uint112(sideA));
    }

    // ── the report ───────────────────────────────────────────────

    /// @notice The reporter's numbers: forged at 0.94, 13M donated. The liar's row is tier 2:
    ///         it does not vote, the base stays on the curated pools and the liar is out of band.
    function test_ForgedPairDoesNotCaptureTheBand() public {
        uint256 honestOut = _honestFill();
        LyingPair85Vote atk = _lyingPair();
        _forge(atk, 0.94e18);
        tB.mint(address(atk), DONATION);
        RoutePlan memory plan = _plan();
        assertFalse(_uses(plan, address(atk)), "a permissionless row does not move the band");
        assertGt(plan.best.hops[0].legs.length, 1, "the honest pools split the order again");
        uint256 got = _victim(plan);
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertGe(got, (honestOut * 9_990) / 10_000, "the victim is filled at the honest price");
    }

    /// @notice A V3-shaped contract the attacker wrote: no reserves to compare, a donation to
    ///         hold. It is a tier-2 row like the pair, so it does not vote either.
    function test_ConcentratedShapeDoesNotCaptureTheBand() public {
        uint256 honestOut = _honestFill();
        MockV3Pool c = _hostileConc();
        c.setState(_sqrtAt(c, 0.94e18), type(uint128).max / 4);
        tB.mint(address(c), DONATION);
        RoutePlan memory plan = _plan();
        assertFalse(_uses(plan, address(c)), "the hostile concentrated pool is out of band");
        uint256 got = _victim(plan);
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertGe(got, (honestOut * 9_990) / 10_000, "honest fill");
    }

    /// @notice A pair that HOLDS what it declares (both sides parked, recoverable by its owner)
    ///         passes every holdings check there is; it does not vote because nobody vouches
    ///         for its code.
    function test_ParkedHeldPairDoesNotCaptureTheBand() public {
        uint256 honestOut = _honestFill();
        LyingPair85Vote atk = _lyingPair();
        uint256 inSide = 14_000_000e18;
        uint256 outSide = 13_160_000e18;   // 0.94 x inSide
        tA.mint(address(atk), inSide);
        tB.mint(address(atk), outSide);
        bool aIs0 = atk.token0() == address(tA);
        vm.prank(attacker);
        if (aIs0) atk.forge(uint112(inSide), uint112(outSide));
        else atk.forge(uint112(outSide), uint112(inSide));
        RoutePlan memory plan = _plan();
        assertFalse(_uses(plan, address(atk)), "a parked pair is out of band");
        uint256 got = _victim(plan);
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertGe(got, (honestOut * 9_990) / 10_000, "honest fill");
    }

    /// @notice No curated pool on the pair. The honest mass is ONE factory-born pool whose row
    ///         a swap wrote (tier 2, like the liar's). Discovery finds it at a registered
    ///         factory, so it votes; the liar's row is found nowhere, so it does not.
    function test_FactoryBornRowVotesAndTheLiarDoesNot() public {
        _freshTokens();
        MockV2Factory f = new MockV2Factory();
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        MockV2Pair honest = _heldPool(12_000_000e18, 1e18);
        f.setPair(address(tA), address(tB), address(honest));
        _dustSwap(address(honest), BPC.KIND_V2, 30, honest.token0() == address(tA), 1);
        uint256 honestOut = _honestFill();
        LyingPair85Vote atk = _lyingPair();
        _forge(atk, 0.94e18);
        tB.mint(address(atk), DONATION);
        RoutePlan memory plan = _plan();
        assertFalse(_uses(plan, address(atk)), "the liar does not outvote a factory-born pool");
        assertTrue(_uses(plan, address(honest)), "the factory-born pool carries the order");
        uint256 got = _victim(plan);
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertGe(got, (honestOut * 9_990) / 10_000, "honest fill");
    }

    /// @notice The same set, with the attacker's contract HOLDING what it declares (both sides
    ///         parked): `heldBy` sees nothing wrong, so only the vote stands between it and the
    ///         band. Its 13.16M outweighs the factory-born pool's 12M; unvouched, it does not
    ///         vote. This is the case that watches `_mutedVotes` once option (a) is in the tree.
    function test_FactoryBornRowVotesAndAParkedPairDoesNot() public {
        _freshTokens();
        MockV2Factory f = new MockV2Factory();
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        MockV2Pair honest = _heldPool(12_000_000e18, 1e18);
        f.setPair(address(tA), address(tB), address(honest));
        _dustSwap(address(honest), BPC.KIND_V2, 30, honest.token0() == address(tA), 1);
        uint256 honestOut = _honestFill();
        LyingPair85Vote atk = _lyingPair();
        uint256 inSide = 14_000_000e18;
        uint256 outSide = 13_160_000e18;   // 0.94 x inSide
        tA.mint(address(atk), inSide);
        tB.mint(address(atk), outSide);
        bool aIs0 = atk.token0() == address(tA);
        vm.prank(attacker);
        if (aIs0) atk.forge(uint112(inSide), uint112(outSide));
        else atk.forge(uint112(outSide), uint112(inSide));
        RoutePlan memory plan = _plan();
        assertFalse(_uses(plan, address(atk)), "a parked pair does not outvote a factory-born pool");
        assertTrue(_uses(plan, address(honest)), "the factory-born pool carries the order");
        uint256 got = _victim(plan);
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertGe(got, (honestOut * 9_990) / 10_000, "honest fill");
    }

    // ── controls (green on both trees) ───────────────────────────

    /// @notice An honest pair that RECEIVED a donation holds more than it declares: it is
    ///         still quoted, still routed.
    function test_control_DonatedHonestPairStillRoutes() public {
        PoolInfo[] memory rows = hub.getActivePools(address(tA), address(tB));
        MockV2Pair p = MockV2Pair(rows[0].pool);
        tB.mint(address(p), 1_000_000e18);   // balance above reserves
        RoutePlan memory plan = _plan();
        assertTrue(_uses(plan, address(p)), "a donated honest pair keeps its place in the split");
        assertGt(plan.best.hops[0].legs.length, 1, "split intact");
    }

    /// @notice Not voting is not being excluded: an honest permissionless pool at the fair
    ///         price is inside the band the curated pools set, and takes its share of the split.
    function test_control_PermissionlessHonestPoolStillTakesItsShare() public {
        MockV2Pair p = _permissionlessPool(HONEST_SIDE, 1e18);
        RoutePlan memory plan = _plan();
        assertTrue(_uses(plan, address(p)), "a tier-2 row at the fair price is still routed");
    }

    // ── what option (b) does not close, measured ─────────────────

    /// @notice A liar forged INSIDE the band (0.97): it has no vote, but it does not need one.
    ///         The vote alone measured 93 bps here; the pair declares more than it holds, so
    ///         every door prices it dead and it takes no share.
    function test_ForgedPairInsideTheBandTakesNoShare() public {
        uint256 honestOut = _honestFill();
        LyingPair85Vote atk = _lyingPair();
        _forge(atk, 0.97e18);
        tB.mint(address(atk), DONATION);
        RoutePlan memory plan = _plan();
        uint256 got = _victim(plan);
        uint256 loss = _lossBps(honestOut, got);
        emit log_named_uint("loss vs honest routing (bps)", loss);
        assertFalse(_uses(plan, address(atk)), "a lying pair is dead at every door");
        assertEq(loss, 0, "honest fill");
    }

    /// @notice A pair with no curated and no factory-born mass: every row is tier 2, nobody may
    ///         vote, and the set falls back to the vote it always had. The vote alone measured
    ///         521 bps here; the forged pair is dead at every door, so the old vote is honest.
    function test_NoVouchedMassAndAForgedPairFillsHonestly() public {
        _freshTokens();
        for (uint256 i; i < 3; ++i) _permissionlessPool(HONEST_SIDE, 1e18);
        uint256 honestOut = _honestFill();
        LyingPair85Vote atk = _lyingPair();
        _forge(atk, 0.94e18);
        tB.mint(address(atk), DONATION);
        RoutePlan memory plan = _plan();
        uint256 got = _victim(plan);
        uint256 loss = _lossBps(honestOut, got);
        emit log_named_uint("loss vs honest routing (bps)", loss);
        assertFalse(_uses(plan, address(atk)), "a lying pair is dead at every door");
        assertEq(loss, 0, "honest fill");
    }

    /// @notice What neither door closes: no vouched mass on the pair, and the attacker's
    ///         contract HOLDS what it declares (both sides parked, recoverable). Nobody may
    ///         vote, the old vote returns, and held mass buys the band as in the report.
    function test_limit_NoVouchedMassAndAParkedHeldPairStillCaptures() public {
        _freshTokens();
        for (uint256 i; i < 3; ++i) _permissionlessPool(HONEST_SIDE, 1e18);
        uint256 honestOut = _honestFill();
        LyingPair85Vote atk = _lyingPair();
        uint256 inSide = 14_000_000e18;
        uint256 outSide = 13_160_000e18;   // 0.94 x inSide
        tA.mint(address(atk), inSide);
        tB.mint(address(atk), outSide);
        bool aIs0 = atk.token0() == address(tA);
        vm.prank(attacker);
        if (aIs0) atk.forge(uint112(inSide), uint112(outSide));
        else atk.forge(uint112(outSide), uint112(inSide));
        RoutePlan memory plan = _plan();
        uint256 got = _victim(plan);
        uint256 loss = _lossBps(honestOut, got);
        emit log_named_uint("loss vs honest routing (bps)", loss);
        assertTrue(_uses(plan, address(atk)), "measured: with no voter, held mass captures the band");
        // Measured 588 bps (13/10), the same as holdings alone on a pair with curated mass.
        assertGe(loss, 570, "measured: the report's capture, with held mass");
        assertLe(loss, 610, "measured: bracket");
    }

    // ── what option (b) gives up, measured ───────────────────────

    /// @notice A deep honest permissionless pool (not factory-born) and one shallow curated
    ///         pool 10 % off. Only the curated pool votes: the band moves onto it and the deep
    ///         pool is filtered out. Under the mass vote the deep pool set the band.
    function test_cost_ShallowCuratedPoolOutvotesADeepPermissionlessOne() public {
        _freshTokens();
        MockV2Pair deep = _permissionlessPool(12_000_000e18, 1e18);
        MockV2Pair shallow = _heldPool(500_000e18, 0.9e18);
        hub.seedPool(address(shallow), BPC.KIND_V2, 30, address(0), address(tA), address(tB));
        (uint256 rIn, uint256 rOut) = _oriented(deep);
        uint256 deepOut = BPC.outV2(ORDER, rIn, rOut, 30);
        RoutePlan memory plan = _plan();
        uint256 got = _victim(plan);
        uint256 loss = _lossBps(deepOut, got);
        emit log_named_uint("loss vs the deep pool alone (bps)", loss);
        assertFalse(_uses(plan, address(deep)), "measured: the deep permissionless pool is filtered out");
        assertTrue(_uses(plan, address(shallow)), "measured: the shallow curated pool takes the order");
        // Measured 2451 bps (13/10): the order fills at the shallow pool's price and depth.
        assertGe(loss, 2_400, "measured: the victim loses about a quarter");
        assertLe(loss, 2_500, "measured: bracket");
    }

    function _oriented(MockV2Pair p) internal view returns (uint256 rIn, uint256 rOut) {
        (uint112 r0, uint112 r1,) = p.getReserves();
        (rIn, rOut) = p.token0() == address(tA) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }
}
