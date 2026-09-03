// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  MC/DC INERTS, CLOSED — the sub-conditions the non-guard campaign of
//  2026-09-03 neutralised without a single test noticing, that turned out to
//  change an OUTPUT on reading. (The 42 that only change gas, or are redundant
//  with a guard one call deeper, are recorded with their reasons in the
//  campaign's triage and deliberately get no test: a test for a condition no
//  black-box observer can see is a green that proves nothing.)
//
//  Each test below names the sub-condition, states what the general path does
//  without it, and carries a mutant in mutants.py that deletes exactly that
//  arm. Where the triage first got a verdict wrong and re-derivation fixed it,
//  the correction is written here too, because that is the method.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Core:1415 — `_solidlyStable`: `X > 3.4e38 || Y > 3.4e38`
//  The X arm was exercised; the Y arm was inert. Twin asymmetry.
// ─────────────────────────────────────────────────────────────────────────────
contract McdcInert_SolidlyOverflowTwins is Test {
    /// Past ~3.4e47 the `mulDiv(y, y, WAD)` inside `_solKFits` overflows its
    /// 256-bit RESULT and reverts, which breaks the doctrine written above the
    /// guard: an unusable pool returns 0, it never reverts. The X side of this
    /// sentinel is pinned; this is the Y side. Expected GREEN today; the mutant
    /// that drops the Y arm turns it into a panic.
    function test_absurdOutReserve_returnsZeroNotPanic() public pure {
        uint256 out = BPC.outSolidlyStable(1e18, 1e20, 1e48, 30, 18, 18);
        assertEq(out, 0, "an out-reserve the cubic cannot represent must quote 0, not revert");
    }

    /// The twin, so the file states both arms.
    function test_absurdInReserve_returnsZeroNotPanic() public pure {
        uint256 out = BPC.outSolidlyStable(1e18, 1e48, 1e20, 30, 18, 18);
        assertEq(out, 0, "an in-reserve the cubic cannot represent must quote 0, not revert");
    }

    /// CONTROL: a representable pool still quotes. Guards that refuse the
    /// absurd must not start refusing the ordinary.
    function test_ordinaryReserves_stillQuote() public pure {
        uint256 out = BPC.outSolidlyStable(1e18, 1_000_000e18, 1_000_000e18, 30, 18, 18);
        assertGt(out, 0, "a balanced 1M/1M stable pool quotes a positive amount");
        assertLt(out, 1e18, "and never more than the input on a balanced stable curve");
    }

    /// CORRECTION RECORDED. The triage first listed `_solKFits`'s `b == 0` arm
    /// as load-bearing for dust reserves. Re-derivation: `b = x^2/WAD + y^2/WAD`
    /// is zero only when x, y < 1e9, and then `a = x*y/WAD` is zero as well, so
    /// the `a == 0` arm always answers first and `b == 0` is redundant by
    /// algebra. This test pins the dust case anyway - it is the input that
    /// made the wrong verdict plausible - and documents why no mutant targets
    /// `b == 0`.
    function test_dustReserves_returnZeroNotPanic() public pure {
        uint256 out = BPC.outSolidlyStable(1, 1, 1, 30, 18, 18);
        assertEq(out, 0, "dust reserves quote 0 without touching a zero denominator");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Hub:1218 — `_writeV4Code`: `!$.isBridge[t0]`
//  A bridge pairs with everything; a learned code on it would thrash. The
//  docstring says so; nothing pinned it.
// ─────────────────────────────────────────────────────────────────────────────
contract McdcInert_BridgeNeverLearnsACode is Test {
    BlazePhoenixHub hub;

    // Sorted bare addresses: W sorts BELOW X, so W is t0 at every sorted site.
    address constant W = address(0x1111);
    address constant X = address(0x2222);
    uint24 constant FEE = 3000;
    int24  constant TS  = 60;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        // this = router, so recordSwap is reachable; admin/operator by initialize.
        hub.setRoles(address(this), address(this), address(this));
    }

    function _poolAddr(address a, address b) private pure returns (address) {
        (address s0, address s1) = BPC.sortTokens(a, b);
        return address(uint160(uint256(BPC.computeV4PoolId(s0, s1, FEE, TS, address(0)))));
    }

    /// Route a V4 swap on (W, X) with W a bridge. The registered row takes the
    /// hot path, `_noteV4Code` recovers the tier through the O(1) index, and
    /// `_writeV4Code` must learn a code for X and NOT for W. Expected GREEN
    /// today; the mutant that drops the bridge arm makes W learn one.
    function test_bridgeSide_neverLearnsACode_counterpartDoes() public {
        hub.addBridge(W);
        hub.addV4(W, X, FEE, TS, address(0));
        address pool = _poolAddr(W, X);
        assertTrue(hub.getPool(hub.keyOf(pool, W, X)) == pool, "premise: the V4 row is registered");
        assertEq(hub.v4CodeOf(W), 0, "premise: nothing learned yet");
        assertEq(hub.v4CodeOf(X), 0, "premise: nothing learned yet");

        hub.recordSwap(pool, BPC.KIND_V4, FEE, address(0), W, X, 1e18, 1e18, 1e18);

        assertTrue(hub.v4CodeOf(X) != 0, "the counterpart learns the tier it just traded on");
        assertEq(hub.v4CodeOf(W), 0, "a bridge never learns a V4 code: it pairs with everything");
    }

    /// CONTROL: with no bridge configured, BOTH sides learn. Without this the
    /// test above could pass because nothing ever learns anything.
    function test_noBridge_bothSidesLearn() public {
        hub.addV4(W, X, FEE, TS, address(0));
        address pool = _poolAddr(W, X);
        hub.recordSwap(pool, BPC.KIND_V4, FEE, address(0), W, X, 1e18, 1e18, 1e18);
        assertTrue(hub.v4CodeOf(W) != 0, "control: a non-bridge t0 learns");
        assertTrue(hub.v4CodeOf(X) != 0, "control: a non-bridge t1 learns");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Router:1003 — `_execute`: `if (bt != tokenIn && bt != tokenOut)`
//  bridgeBase for an intermediate hop is skipped when that hop's out-token is
//  the route's own tokenIn or tokenOut. The tokenIn arm is never READ (the next
//  hop then prices against `baseIn`, Router:1059), so it is benign. The
//  tokenOut arm is read: a route whose intermediate hop produces the FINAL
//  token (A -> C -> B -> C) prices its C -> B hop against bridgeBase, and no
//  test in the tree builds that topology.
// ─────────────────────────────────────────────────────────────────────────────
contract McdcInert_IntermediateHopProducesTokenOut is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA; MockERC20 tokenB; MockERC20 tokenC;
    MockV2Pair poolAC; MockV2Pair poolBC;

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint256 constant AMT = 100e18;
    uint112 constant RESERVE = uint112(10_000_000e18);
    uint256 constant STRANDED = 777e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        poolAC = _pool(tokenA, tokenC);
        poolBC = _pool(tokenB, tokenC);
        hub.seedPool(address(poolAC), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenC));
        hub.seedPool(address(poolBC), BPC.KIND_V2, 30, address(0), address(tokenB), address(tokenC));

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _pool(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), uint256(RESERVE));
        y.mint(address(p), uint256(RESERVE));
        p.setReserves(RESERVE, RESERVE);
    }

    function _leg(MockV2Pair p, address tIn) private view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: AMT, expectedOut: 0,
            auxId: bytes32(0)
        });
    }

    function _hop(MockV2Pair p, address tIn, address tOut) private view returns (Hop memory h) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(p, tIn);
        h = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: AMT, expectedOut: 0, legs: legs});
    }

    /// A -> C -> B -> C. The route's tokenOut is C, and hop 0 ALSO produces C.
    function _routeThroughTokenOut() private view returns (Route memory r) {
        Hop[] memory hops = new Hop[](3);
        hops[0] = _hop(poolAC, address(tokenA), address(tokenC));
        hops[1] = _hop(poolBC, address(tokenC), address(tokenB));
        hops[2] = _hop(poolBC, address(tokenB), address(tokenC));
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// THE CLAIM. C is stranded in the Router before the swap. The middle hop
    /// takes C as input, and holds-nothing (invariant I1) says a stranded
    /// balance is never scaled into the swap. GREEN today, and this is the
    /// baseline a first reading missed, recorded here as the file promised:
    ///
    ///   Router:1078  foreignBase = hop.tokenIn == tokenIn ? baseIn
    ///                            : (hop.tokenIn == tokenOut ? toutStart : bridgeBase[h - 1]);
    ///
    /// A hop whose input is the route's own tokenOut prices against `toutStart`
    /// (Router:982), exactly as a hop whose input is tokenIn prices against
    /// `baseIn`. So the `bt != tokenOut` arm at Router:1003, which the MC/DC
    /// campaign found inert, skips a `balanceOf` that line 1078 never reads -
    /// the same shape as its `bt != tokenIn` sibling. Benign, and this test is
    /// the pin of I1 on the one topology nobody had built: the final token
    /// appearing as an intermediate. No mutant targets the 1003 arm, because
    /// deleting it changes no output; the property is carried by 1078.
    function test_strandedTokenOut_isNotScaledIntoAnIntermediateHop() public {
        Route memory r = _routeThroughTokenOut();

        // Reference: the same route with nothing stranded. One 100e18 swap on
        // 10M/10M pools moves the reserves by ~1e-5, so the second swap below
        // sees reserves that differ from the first by far less than the 0.1%
        // tolerance used to compare them.
        vm.prank(user);
        uint256 gotClean = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(gotClean, 0, "premise: the A -> C -> B -> C route settles");

        tokenC.mint(address(router), STRANDED);
        vm.prank(user);
        uint256 gotStranded = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertApproxEqRel(gotStranded, gotClean, 1e15,
            "a stranded balance of tokenOut changed what an honest swap delivered: it was scaled into the middle hop and round-tripped to the caller");
        assertEq(tokenC.balanceOf(address(router)), STRANDED,
            "the stranded C is not the swap's unit: it must be neither spent nor swept");
    }

    /// CONTROL: the plain two-hop A -> C -> B route, where no intermediate hop
    /// produces the final token, is untouched by any of this.
    function test_control_plainTwoHop_settles() public {
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(poolAC, address(tokenA), address(tokenC));
        hops[1] = _hop(poolBC, address(tokenC), address(tokenB));
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(got, 0, "control: a plain two-hop route settles");
    }
}
