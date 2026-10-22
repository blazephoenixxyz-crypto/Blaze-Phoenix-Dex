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
// Option (a): a pair that declares more than it holds is a dead pool at every door that reads
// its declaration - the Core's quote dispatcher (Solver probe, split, single leg, Quoter), the
// registry depth (top-K, seeding), the Router's in-frame quote (the leg is refused), and the
// registry's tick (the row is no longer refreshed). Red on 98f9ac2: the forged pair
// takes the whole route in `test_ForgedPairDoesNotCaptureTheBand` and in the in-band variant,
// the registry depth is non-zero, the Hub refreshes the lying row. The controls are green
// on both trees. The two `test_limit_` tests pin, measured, what this option does NOT close:
// mass that a hostile contract HOLDS (a concentrated-shaped contract, or a pair parking both
// sides) still votes, because holding is not risking.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan, PoolInfo, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockV2Pair} from "../test/mocks/MockV2Pair.sol";
import {MockV3Pool} from "../test/mocks/MockV3Pool.sol";
import {MockSolidlyPair} from "../test/mocks/MockSolidlyPair.sol";
import {Origin} from "../test/mocks/MockOriginFactory.sol";

interface IERC20Min85 {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice The reporter's synthetic pair: reports any reserves once forged, pays exactly what
///         the Router computes from them, and lets its owner take everything back.
contract LyingPair85 {
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

contract Bounty1013ForgedReservesBandTest is Test {
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
        solver = new BlazePhoenixSolver(address(hub), address(0));
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

    function _lyingPair() internal returns (LyingPair85 atk) {
        vm.prank(attacker);
        atk = new LyingPair85(address(tA), address(tB));
        // rizki-3107: the swap door seats only a pool a wired factory derives, so the liar gets
        // the origin it needs. The pair keeps three fresh curated rows, so the Solver skips
        // discovery here and nothing vouches for the tier-2 row: it still does not vote.
        Origin.wire(hub, address(atk), address(tA), address(tB), BPC.KIND_V2, 30);
        tA.mint(address(atk), 2_000e18);
        tB.mint(address(atk), 2_000e18);
        atk.syncHonest();
        _dustSwap(address(atk), BPC.KIND_V2, 30, atk.token0() == address(tA), 1);
        assertTrue(hub.getSlot(hub.keyOf(address(atk), address(tA), address(tB))) != 0, "fixture: registered");
    }

    /// @dev Forge the pair at `rate` (tokenB out per tokenA in, 1e18 = par) over 1e30 of tA.
    function _forge(LyingPair85 atk, uint256 rate) internal {
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
        Origin.wire(hub, address(c), address(tA), address(tB), BPC.KIND_V3, 3000);   // as `_lyingPair`
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

    // ── the report ───────────────────────────────────────────────

    /// @notice The reporter's numbers: forged at 0.94, 13M donated. The pair is dead to the
    ///         Solver and the victim gets the honest split.
    function test_ForgedPairDoesNotCaptureTheBand() public {
        uint256 honestOut = _honestFill();
        LyingPair85 atk = _lyingPair();
        _forge(atk, 0.94e18);
        tB.mint(address(atk), DONATION);
        RoutePlan memory plan = _plan();
        assertFalse(_uses(plan, address(atk)), "a pair declaring more than it holds is not routed");
        assertGt(plan.best.hops[0].legs.length, 1, "the honest pools split the order again");
        uint256 got = _victim(plan);
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertGe(got, (honestOut * 9_990) / 10_000, "the victim is filled at the honest price");
    }

    /// @notice Same pair forged INSIDE the band (0.97 against par): no band to escape, so the
    ///         only thing that keeps it out of the split is that it is not quoted at all.
    function test_ForgedPairInsideTheBandIsNotQuoted() public {
        uint256 honestOut = _honestFill();
        LyingPair85 atk = _lyingPair();
        _forge(atk, 0.97e18);
        tB.mint(address(atk), DONATION);
        RoutePlan memory plan = _plan();
        assertFalse(_uses(plan, address(atk)), "an in-band liar is not routed either");
        uint256 got = _victim(plan);
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertGe(got, (honestOut * 9_990) / 10_000, "honest fill");
    }

    /// @notice Every other door: the Quoter prices it at zero, the registry depth is zero, a
    ///         hand-built route through it is refused by the Router.
    function test_EveryDoorSeesTheLieAsADeadPool() public {
        LyingPair85 atk = _lyingPair();
        _forge(atk, 0.94e18);
        tB.mint(address(atk), DONATION);
        bool zfo = atk.token0() == address(tA);
        (address t0, address t1) = zfo ? (address(tA), address(tB)) : (address(tB), address(tA));
        assertFalse(BPC.reservesHeld(address(atk), BPC.KIND_V2, t0, t1), "fixture: the pair lies");
        assertEq(BPC.registryDepth18(address(atk), BPC.KIND_V2, t0, t1, address(0), bytes32(0)), 0,
            "registry depth of a liar is zero");
        uint256 out = BPC.outV2(ORDER, 1e30, 0.94e30, 30);
        Route memory r = _route1(address(atk), BPC.KIND_V2, 30, zfo, ORDER, out);
        r.hops[0].tokenIn = address(tA);
        r.hops[0].tokenOut = address(tB);
        tA.mint(user, ORDER);
        vm.startPrank(user);
        tA.approve(address(router), ORDER);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(r, ORDER, 1, user, block.timestamp + 1);
        vm.stopPrank();
    }

    /// @notice The registry: the next swap that touches a lying row does not refresh it.
    function test_HubDoesNotRefreshTheLyingRow() public {
        LyingPair85 atk = _lyingPair();
        bytes32 key = hub.keyOf(address(atk), address(tA), address(tB));
        uint256 seated = hub.getSlot(key);
        // An honest dust swap later refreshes the row (control).
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 120);
        vm.prank(address(router));
        hub.recordSwap(address(atk), BPC.KIND_V2, 30, address(0), address(tA), address(tB), 1, 1, 0);
        uint256 refreshed = hub.getSlot(key);
        assertTrue(refreshed != seated, "an honest row is refreshed");
        // Now it declares more than it holds; the Router's next report for it changes nothing.
        _forge(atk, 1e18);
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 120);
        vm.prank(address(router));
        hub.recordSwap(address(atk), BPC.KIND_V2, 30, address(0), address(tA), address(tB), 1, 1, 0);
        assertEq(hub.getSlot(key), refreshed, "the lying row is not refreshed");
    }

    /// @notice The dispatcher itself, both pair arms: one wei of declared reserve above what the
    ///         pair holds and the quote is (0, 0); at the limit it is priced.
    function test_DispatcherPricesBothPairArmsDeadOneWeiOverTheLimit() public {
        MockV2Pair v2 = new MockV2Pair(address(tA), address(tB));
        MockSolidlyPair so = new MockSolidlyPair(address(tA), address(tB), false);
        address[2] memory ps = [address(v2), address(so)];
        uint8[2] memory ks = [BPC.KIND_V2, BPC.KIND_SOLIDLY];
        for (uint256 i; i < 2; ++i) {
            tA.mint(ps[i], 1_000e18);
            tB.mint(ps[i], 1_000e18);
            QuoteCtx memory c;
            c.kind = ks[i]; c.pool = ps[i]; c.fee = 30;
            c.zeroForOne = MockV2Pair(ps[i]).token0() == address(tA);
            c.tokenIn = address(tA); c.tokenOther = address(tB);
            _setRes(ps[i], i, 1_000e18, 1_000e18);
            (uint256 out,) = BPC.universalQuote(c, 1e18);
            assertGt(out, 0, "held reserves are priced");
            _setRes(ps[i], i, 1_000e18, 1_000e18 + 1);
            (out,) = BPC.universalQuote(c, 1e18);
            assertEq(out, 0, "one wei over the holdings is a dead pool");
        }
    }

    function _setRes(address p, uint256 i, uint256 rA, uint256 rB) internal {
        bool aIs0 = MockV2Pair(p).token0() == address(tA);
        (uint112 r0, uint112 r1) = aIs0 ? (uint112(rA), uint112(rB)) : (uint112(rB), uint112(rA));
        if (i == 0) MockV2Pair(p).setReserves(r0, r1); else MockSolidlyPair(p).setReserves(r0, r1);
    }

    // ── controls (green on both trees) ───────────────────────────

    /// @notice An honest pair that RECEIVED a donation holds more than it declares: it is
    ///         still quoted, still routed, and its vote is its reserves (the cap is inert).
    function test_control_DonatedHonestPairStillRoutes() public {
        PoolInfo[] memory rows = hub.getActivePools(address(tA), address(tB));
        MockV2Pair p = MockV2Pair(rows[0].pool);
        tB.mint(address(p), 1_000_000e18);   // balance above reserves
        RoutePlan memory plan = _plan();
        assertTrue(_uses(plan, address(p)), "a donated honest pair keeps its place in the split");
        assertGt(plan.best.hops[0].legs.length, 1, "split intact");
    }

    /// @notice The Quoter's V2 arm now hands the dispatcher both tokens: an honest preview is
    ///         priced, not zeroed (it would be zero with the tokens left at address(0)).
    function test_control_QuoterStillPricesHonestV2Legs() public {
        RoutePlan memory plan = _plan();
        (Route memory r, uint256 exactOut) = quoter.previewPlanExact(address(tA), address(tB), ORDER);
        assertGt(r.hops[0].legs.length, 1, "split");
        for (uint256 l; l < r.hops[0].legs.length; ++l) assertGt(r.hops[0].legs[l].expectedOut, 0, "leg priced");
        assertApproxEqRel(exactOut, plan.best.totalOut, 0.01e18, "preview within 1 % of the plan");
    }

    // ── what holdings alone do not close, closed by the band vote ─

    /// @notice A V3-shaped contract has no reserves to compare with its holdings. Declared
    ///         liquidity is capped by its tokenOut balance, and a recoverable donation fills
    ///         that balance. Holdings alone measured 522 bps here; its row is tier 2 and no
    ///         factory vouches for it, so it does not vote and the band stays on fair.
    function test_ConcentratedShapeWithADonationDoesNotVote() public {
        uint256 honestOut = _honestFill();
        MockV3Pool c = _hostileConc();
        c.setState(_sqrtAt(c, 0.94e18), type(uint128).max / 4);
        tB.mint(address(c), DONATION);
        RoutePlan memory plan = _plan();
        uint256 got = _victim(plan);
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertFalse(_uses(plan, address(c)), "the hostile concentrated pool is out of band");
        assertGe(got, (honestOut * 9_990) / 10_000, "honest fill");
    }

    /// @notice A pair whose reserves ARE held - both sides parked, recoverable by its owner,
    ///         and a pool that need not trade the arbitrage direction - passes `reservesHeld`.
    ///         Holdings alone measured 588 bps here; unvouched, it does not vote.
    function test_ParkedHeldPairDoesNotVote() public {
        uint256 honestOut = _honestFill();
        LyingPair85 atk = _lyingPair();
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
        emit log_named_uint("loss vs honest routing (bps)", _lossBps(honestOut, got));
        assertFalse(_uses(plan, address(atk)), "a parked pair is out of band");
        assertGe(got, (honestOut * 9_990) / 10_000, "honest fill");
    }

    /// @notice What option (a) gives up: an honest pair whose balance fell under its reserves
    ///         (a negative rebase before anyone syncs) is a dead pool until it is synced.
    function test_cost_PairUnderwaterAfterANegativeRebaseIsNotQuoted() public {
        PoolInfo[] memory rows = hub.getActivePools(address(tA), address(tB));
        MockV2Pair p = MockV2Pair(rows[0].pool);
        vm.prank(address(p));
        tB.transfer(address(0xdead), 1e18);   // one token short of its reserves
        RoutePlan memory plan = _plan();
        assertFalse(_uses(plan, address(p)), "measured: an underwater pair is skipped");
        assertGt(plan.best.hops[0].legs.length, 1, "the other two still split");
    }
}
