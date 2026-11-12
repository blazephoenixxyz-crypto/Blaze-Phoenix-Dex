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
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
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

        // fix-1102 A: was an unanchored swap; now anchored, because only an anchored V4 swap teaches a code (BlazePhoenixHub.sol:1789)
        hub.recordSwap(pool, BPC.KIND_V4, FEE, address(0), W, X, 1e18, 1e18, 1e18 | BPC.TICK_ANCHORED);

        // fix-1102 A: was != 0 on the whole word; now the low 48 bits are FEE << 24 | TS and bits 48+ the teacher's bucket, 3 = ilog10(1e18 / 1e15) (BlazePhoenixHub.sol:1460, BlazePhoenixCore.sol:2539)
        assertEq(hub.v4CodeOf(X) & ((uint256(1) << 48) - 1), (uint256(FEE) << 24) | uint256(uint24(TS)),
            "the counterpart learns the tier it just traded on");
        assertEq(hub.v4CodeOf(X) >> 48, 3, "the counterpart's code carries the swap's depth bucket");
        assertEq(hub.v4CodeOf(W), 0, "a bridge never learns a V4 code: it pairs with everything");
    }

    /// CONTROL: with no bridge configured, BOTH sides learn. Without this the
    /// test above could pass because nothing ever learns anything.
    function test_noBridge_bothSidesLearn() public {
        hub.addV4(W, X, FEE, TS, address(0));
        address pool = _poolAddr(W, X);
        // fix-1102 A: was an unanchored swap; now anchored, because only an anchored V4 swap teaches a code (BlazePhoenixHub.sol:1789)
        hub.recordSwap(pool, BPC.KIND_V4, FEE, address(0), W, X, 1e18, 1e18, 1e18 | BPC.TICK_ANCHORED);
        // fix-1102 A: was != 0 on the whole word; now the low 48 bits are FEE << 24 | TS and bits 48+ the teacher's bucket, 3 = ilog10(1e18 / 1e15) (BlazePhoenixHub.sol:1460, BlazePhoenixCore.sol:2539)
        uint256 tier = (uint256(FEE) << 24) | uint256(uint24(TS));
        assertEq(hub.v4CodeOf(W) & ((uint256(1) << 48) - 1), tier, "control: a non-bridge t0 learns");
        assertEq(hub.v4CodeOf(W) >> 48, 3, "control: t0's code carries the swap's depth bucket");
        assertEq(hub.v4CodeOf(X) & ((uint256(1) << 48) - 1), tier, "control: a non-bridge t1 learns");
        assertEq(hub.v4CodeOf(X) >> 48, 3, "control: t1's code carries the swap's depth bucket");
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
//
//  History: until 2026-11-06 the Router took three hops (MAX_HOPS = 3) and
//  A -> C -> B -> C settled; the claim was pinned on it directly. MAX_HOPS is
//  now 2 (Core's single producer): the only hop with h != 0 is the last, whose
//  tokenOut IS the route's, so an intermediate hop can no longer produce the
//  final token. The topology is refused (first test below), and I1 is pinned on
//  the two-hop shape that remains: tokenOut stranded while the last hop makes it.
// ─────────────────────────────────────────────────────────────────────────────
contract McdcInert_IntermediateHopProducesTokenOut is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
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
        solver = new BlazePhoenixSolver(address(hub), address(0));
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
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
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
    /// totalOut is a positive declared figure for the preview only (the Router does not read it):
    /// with 0 the preview's netOut is 0 and it refuses every route, the ceiling included or not.
    function _routeThroughTokenOut() private view returns (Route memory r) {
        Hop[] memory hops = new Hop[](3);
        hops[0] = _hop(poolAC, address(tokenA), address(tokenC));
        hops[1] = _hop(poolBC, address(tokenC), address(tokenB));
        hops[2] = _hop(poolBC, address(tokenB), address(tokenC));
        r = Route({hops: hops, totalOut: AMT / 2, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// A -> C -> B, the same pools one hop shorter: tokenOut is B, produced by the last hop only.
    function _routeTwoHops() private view returns (Route memory r) {
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(poolAC, address(tokenA), address(tokenC));
        hops[1] = _hop(poolBC, address(tokenC), address(tokenB));
        r = Route({hops: hops, totalOut: AMT / 2, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// THE CLAIM, MOVED. A -> C -> B -> C is three hops, past the ceiling: the preview calls it
    /// not executable and the Router refuses it with RouterE(3), so no stranded C can be scaled
    /// into a middle hop. The arm that carried the claim on this shape, the `toutStart` branch of
    ///   Router:1147  foreignBase = hop.tokenIn == tokenOut ? toutStart : bridgeBase[h - 1];
    /// is unreachable now, and its mutant is EQUIVALENT: the line runs only for h != 0, so h = 1,
    /// the last hop (MAX_HOPS = 2, Router:995), whose tokenOut is the route's (Router:996); there
    /// `hop.tokenIn == tokenOut` means a tokenOut -> tokenOut hop, refused at Router:1124 first.
    /// History: until 2026-11-06 (MAX_HOPS = 3) this was
    /// `test_strandedTokenOut_isNotScaledIntoAnIntermediateHop`: the route settled, a stranded C
    /// changed nothing it delivered (1e15 rel) and stayed in the Router. The two-hop analog is next.
    function test_strandedTokenOut_throughAnIntermediateHop_isPastTheCeiling() public {
        assertTrue(quoter.previewRoute(_routeTwoHops(), 1).canExecute,
            "premise: the preview endorses the same pools one hop shorter, so its refusal below is the ceiling's");
        Route memory r = _routeThroughTokenOut();
        assertFalse(quoter.previewRoute(r, 1).canExecute,
            "the preview endorses A -> C -> B -> C, a three-hop route the Router refuses");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// THE CLAIM ON TWO HOPS (I1, holds-nothing): B, the route's tokenOut, is stranded in the
    /// Router while the last hop of A -> C -> B produces it. The output is the balance delta
    /// against the entry baseline `toutStart` (Router:1025, :1470), so the stranded B is neither
    /// paid to the caller nor spent: the delivery equals the clean run's and the B stays.
    /// B is taxed 1 % on every transfer on purpose. Untaxed, the output cap (3310, Router:1478)
    /// alone cuts an unbased delta back to what poolBC declared, and nothing would watch the
    /// baseline (mutants.py, the h11-1019 P2 note); taxed, less B arrives than poolBC declared,
    /// and only the baseline keeps the stranded B from making up the difference.
    function test_strandedTokenOut_isNeitherPaidNorSpent_twoHops() public {
        tokenB.setFeeOnTransferBps(100);
        Route memory r = _routeTwoHops();

        // Reference: the same route with nothing stranded (same 0.1 % reasoning as before: one
        // 100e18 swap moves the 10M/10M reserves by ~1e-5).
        vm.prank(user);
        uint256 gotClean = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(gotClean, 0, "premise: the A -> C -> B route settles with a taxed B");

        tokenB.mint(address(router), STRANDED);
        vm.prank(user);
        uint256 gotStranded = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        assertApproxEqRel(gotStranded, gotClean, 1e15,
            "a stranded balance of tokenOut changed what an honest swap delivered: it made up the tax the last hop's output paid");
        assertEq(tokenB.balanceOf(address(router)), STRANDED,
            "the stranded B is not the swap's unit: it must be neither spent nor paid out");
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
