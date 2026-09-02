// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ConditionAdequacyRouter — MC/DC adequacy tests for BlazePhoenixRouter.sol.
//
//  Each test targets ONE compound-decision sub-condition the triage returned as
//  INERT/UNSURE (no test in the tree depended on it). Every test is built so
//  that NEUTRALISING its target — forcing it to the identity of its connective
//  (true under &&, false under ||) — flips THIS test's verdict. Each carries a
//  "kills:" note saying what the assertion reads and why it cannot pass once
//  the arm is neutralised.
//
//  Eight arms of the triage list are NOT here, on purpose — each is a provable
//  equivalent mutant (neutralisation changes no observable in any state):
//    · 896 `sp4 != 0` / `lq4 != 0`: outV3's own first guard (Core:1084) returns
//      0 for sqrtP==0 or liq==0, the exact value the real else leaves; the V4
//      branch's impact is DEFAULT unconditionally (Router:841).
//    · 959 `bt != tokenIn` / `bt != tokenOut`: bridgeBase has exactly two
//      readers (1023-1025 and 1225-1227) and both are gated by the SAME
//      predicate as the seed, so a slot seeded when bt==tokenIn/tokenOut is
//      never read.
//    · 1462 `leg.expectedOut != 0`: neutralised ternary computes
//      mulDiv(0, amt, leg.amountIn) == 0 == the else-arm.
//    · 1493 `legQuote != 0`: neutralised body computes qs = mulDiv(0,..) = 0
//      and `bound < mulDiv(0, MIN_COV, BPS)` is `bound < 0` — unsatisfiable.
//    · 1533 `bound != 0`: body is `bound = mulDiv(bound, legNet, BPS)`; 0 -> 0.
//    · 1548 `bound != 0`: threshold mulDivUp(0, LEG_FLOOR, BPS) == 0 and
//      `got < 0` is unsatisfiable.
//
//  Fixtures/mocks are reused from the sibling suites (RouterPermit2OneStep,
//  RefusalsNeverDriven, FeeEscapeViaBridgeResidual, RouterV4NativeEth) so no
//  self-adjusting parallel fixture is introduced. StuntV3Pool below is the one
//  new mock: a V3-shaped pool with SEPARATELY settable sqrtPrice/liquidity and
//  a settable payout (FeeEscape's UnderConsumingV3Pool hardwires state to zero
//  and pays a fixed 1 wei, so it cannot isolate the 777 arms nor drive the
//  1433 uncounted-delivery states).
//
//  forge test --match-contract ConditionAdequacyRouter -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
// Proven native-V4 harness, reused verbatim for the _v4LegQuote arm (line 891).
import {MockV4ManagerNative, MockWETH9} from "./RouterV4NativeEth.t.sol";

interface IERC20Stunt {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice V3-shaped pool with INDEPENDENTLY settable slot0 sqrtPrice and
///         liquidity, plus a settable payout: demands 1 wei of tokenIn via the
///         callback and delivers `payout` of `payTok`. Lets a concentrated leg
///         reach the Router's quote path with exactly one of {sqrtPrice,
///         liquidity} zero (the 777 arms) or deliver real value against a
///         zero in-frame quote (the 1433 arms). Modelled on FeeEscape's
///         UnderConsumingV3Pool; constants only, cannot self-adjust.
contract StuntV3Pool {
    address public token0;
    address public token1;
    address public immutable payTok;   // == the hop's tokenOut
    uint24  public constant fee = 3000;
    uint160 private _sp;
    uint128 private _lq;
    uint256 public payout = 1;

    constructor(address a, address b, address _payTok) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        payTok = _payTok;
    }

    function setState(uint160 sp_, uint128 lq_) external { _sp = sp_; _lq = lq_; }
    function setPayout(uint256 p) external { payout = p; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (_sp, 0, 0, 0, 0, 0, _sp != 0);
    }
    function liquidity() external view returns (uint128) { return _lq; }

    function swap(address recipient, bool zeroForOne, int256, uint160, bytes calldata data)
        external returns (int256 a0, int256 a1)
    {
        IERC20Stunt(payTok).transfer(recipient, payout);
        (a0, a1) = zeroForOne ? (int256(1), -int256(payout)) : (-int256(payout), int256(1));
        (bool ok, ) = recipient.call(
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", a0, a1, data)
        );
        require(ok, "stunt cb");
    }
}

contract ConditionAdequacyRouterTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tIn;
    MockERC20 tOut;
    MockV2Pair pair;         // deep tIn/tOut pool
    MockPermit2 permit2;
    MockWETH9 weth;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    uint256 constant DEEP = 1e30;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tIn = new MockERC20("In", "IN");
        tOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tIn), address(tOut));
        tIn.mint(address(pair), DEEP);
        tOut.mint(address(pair), DEEP);
        pair.setReserves(uint112(DEEP), uint112(DEEP));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));
        weth = new MockWETH9();
        router.setWeth(address(weth));       // arms the native door (449 passes)

        tIn.mint(user, 100_000e18);
        vm.startPrank(user);
        tIn.approve(address(router), type(uint256).max);
        tIn.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _e(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// @dev One V2 leg wrapped in a one-hop route through `pool` (a -> b).
    function _routeV2(address pool, address a, address b, uint256 amountIn, uint256 legAmt)
        private pure returns (Route memory r)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: a < b, stable: false,
            amountIn: legAmt, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: a, tokenOut: b, amountIn: amountIn, expectedOut: 0, legs: legs });
        r = _wrap(hops);
    }

    function _wrap(Hop[] memory hops) private pure returns (Route memory r) {
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// @dev Reads (quoted, floorUsed) from the swap's ExecutionProof. Reverts
    ///      the test if the event is absent — the anti-vacuity backstop for
    ///      every floor-reading assertion below.
    function _execProof() private returns (uint256 quoted, uint256 floorUsed) {
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            (quoted, , floorUsed, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        require(found, "ExecutionProof missing");
    }

    // =========================================================================
    //  LINE 391 — swapExactInWithPermit2: `amountIn > 0 && userMinOut == 0`
    //  Sub-condition: `amountIn > 0`.
    // =========================================================================
    /// kills: pins RouterE(8) — the zero-receive refusal at 408, reached only
    /// because `amountIn > 0` is FALSE for a (0, 0) call, so the guard at 391
    /// is skipped (the permit2 door's I8 idempotence, never tested before).
    /// Neutralise the arm and 391 collapses to `userMinOut == 0`, which is
    /// true here: the call dies at 391 with RouterE(10) and the exact-byte
    /// expectation of code 8 fails.
    function test_L391_permit2_zeroAmountZeroMinout_diesAt8_not10() public {
        Route memory r = _routeV2(address(pair), address(tIn), address(tOut), 0, 0);
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(tIn), amount: 0 }),
            nonce: 0, deadline: block.timestamp + 60
        });
        vm.prank(user);
        vm.expectRevert(_e(8));
        router.swapExactInWithPermit2(r, 0, 0, user, block.timestamp + 1, permit, "");
    }

    // =========================================================================
    //  LINE 451 — swapExactInNative: `amountIn == 0 || amountIn > uint128.max`
    //  Sub-condition: `amountIn > type(uint128).max`.
    // =========================================================================
    /// kills: with msg.value == 2^128 and userMinOut == 0, the real program
    /// reverts RouterE(3) at 451 (this arm true). Neutralised (arm forced
    /// FALSE) the OR collapses to `amountIn == 0` (false), execution falls to
    /// the very next line and reverts RouterE(10) instead — a different code,
    /// so the exact-byte expectation fails. weth is wired in setUp, so 449
    /// cannot pre-empt with its own RouterE(3).
    function test_L451_native_overUint128_diesAt3_not10() public {
        uint256 huge = uint256(type(uint128).max) + 1;
        vm.deal(user, huge);
        Route memory r = _routeV2(address(pair), address(tIn), address(tOut), huge, huge);
        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactInNative{value: huge}(r, 0, user, block.timestamp + 1);
    }

    // =========================================================================
    //  LINE 535 — _swap: `route.hops.length == 0 || amountIn == 0`
    //  Sub-condition: `route.hops.length == 0`.
    // =========================================================================
    /// kills: classic door, empty hops, amountIn > 0 AND userMinOut > 0 — the
    /// combination no existing test uses (InvariantsEntryGuards passes minOut
    /// 0 and dies at 380 before reaching 535). Real: RouterE(3) at 535.
    /// Neutralised the OR collapses to `amountIn == 0` (false) and line 536
    /// indexes hops[0] on an empty calldata array — Panic(0x32), whose bytes
    /// are not RouterE(3), so the exact expectation fails.
    function test_L535_swap_emptyHops_diesAt3_notPanic() public {
        Hop[] memory hops = new Hop[](0);
        Route memory r = _wrap(hops);
        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactIn(r, 1_000e18, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  LINE 744 — _hopScaleImpactAndQuote: `h == 0 && scaleNum > scaleDen`
    //  Sub-condition: `h == 0`.
    //
    //  The cap must fire ONLY on hop 0. A 2-hop route whose hop-1 plan commits
    //  HALF of what hop 0 actually delivers puts hop 1 in the determining
    //  state (h != 0, scaleNum ≈ 2·scaleDen): the real program scales UP and
    //  spends the whole bridge; the neutralised one caps hop 1 at its
    //  declared Σ leg.amountIn and returns the other half to the payer.
    // =========================================================================
    /// kills: reads the delivered amount and the payer's bridge refund. With
    /// deep 1:1 pools, 1000e18 in delivers ≈ 991e18 out (real, scaled-up) vs
    /// ≈ 498e18 out plus ≈ 494e18 of B refunded (neutralised). The 700e18
    /// threshold and the zero-refund pin both flip.
    function test_L744_laterHopOverDelivery_scalesUp_notCapped() public {
        MockERC20 a = new MockERC20("A7", "A7");
        MockERC20 b = new MockERC20("B7", "B7");   // the bridge
        MockERC20 c = new MockERC20("C7", "C7");
        MockV2Pair ab = new MockV2Pair(address(a), address(b));
        MockV2Pair bc = new MockV2Pair(address(b), address(c));
        a.mint(address(ab), DEEP); b.mint(address(ab), DEEP); ab.setReserves(uint112(DEEP), uint112(DEEP));
        b.mint(address(bc), DEEP); c.mint(address(bc), DEEP); bc.setReserves(uint112(DEEP), uint112(DEEP));
        hub.addBridge(address(b));   // fee anchors once, on hop 1's input

        uint256 amt = 1_000e18;
        a.mint(user, amt);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);

        Leg[] memory l0 = new Leg[](1);
        l0[0] = Leg({ pool: address(ab), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(a) < address(b), stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0) });
        Leg[] memory l1 = new Leg[](1);
        // The under-committed hop: plan says 500e18, the bridge will hold ~994e18.
        l1[0] = Leg({ pool: address(bc), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(b) < address(c), stable: false, amountIn: amt / 2, expectedOut: 0, auxId: bytes32(0) });
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({ tokenIn: address(a), tokenOut: address(b), amountIn: amt, expectedOut: 0, legs: l0 });
        hops[1] = Hop({ tokenIn: address(b), tokenOut: address(c), amountIn: amt / 2, expectedOut: 0, legs: l1 });

        vm.prank(user);
        uint256 delivered = router.swapExactIn(_wrap(hops), amt, 1, user, block.timestamp + 1);

        assertGt(delivered, 700e18, "hop 1 must scale UP to the full bridge, not cap at its declaration");
        assertEq(b.balanceOf(user), 0, "no bridge may come back: the whole over-delivery must be spent");
    }

    // =========================================================================
    //  LINE 777 — _hopScaleImpactAndQuote: `legAmt != 0 && sp != 0 && lq != 0`
    //
    //  Three arms, one observable: the arm decides between the else's
    //  DEFAULT_IMPACT_BPS (50) and the branch's impactV3FromOut(outV3(..)) —
    //  which is BPS (10_000) exactly in each determining state, because outV3
    //  fail-closes to 0 there (Core:1084) and impactV3FromOut(0,..) == BPS.
    //  The impact difference propagates through avgImpact -> ironFloorBps ->
    //  protocolFloorOut, PUBLISHED as ExecutionProof.floorUsed. Both worlds
    //  settle; the reading is the event, not a revert.
    // =========================================================================

    /// @dev Live deep V2 leg + a StuntV3Pool leg at (sp, lq), equal declared
    ///      weights X each; hop amountIn = 3X so the hop-0 cap pins
    ///      scaleNum == scaleDen and each leg prices exactly its declaration.
    function _deadLegHarness(uint160 sp, uint128 lq)
        private returns (MockERC20 a, MockERC20 b, address live, address dead)
    {
        a = new MockERC20("A2", "A2");
        b = new MockERC20("B2", "B2");
        MockV2Pair lp = new MockV2Pair(address(a), address(b));
        a.mint(address(lp), DEEP);
        b.mint(address(lp), DEEP);
        lp.setReserves(uint112(DEEP), uint112(DEEP));
        StuntV3Pool dp = new StuntV3Pool(address(a), address(b), address(b));
        dp.setState(sp, lq);
        b.mint(address(dp), 1e18);                 // backs the 1-wei payout
        live = address(lp);
        dead = address(dp);
    }

    /// @dev Two-leg one-hop route: live V2 leg 0 (the only nonzero quote) and
    ///      the concentrated leg 1 under test, X = 100e18 each.
    function _twoLegRoute(MockERC20 a, MockERC20 b, address live, address dead)
        private pure returns (Route memory r)
    {
        uint256 X = 100e18;
        bool zfo = address(a) < address(b);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({
            pool: live, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: X, expectedOut: 0, auxId: bytes32(0)
        });
        legs[1] = Leg({
            pool: dead, hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: X, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(a), tokenOut: address(b), amountIn: 3 * X, expectedOut: 0, legs: legs });
        r = _wrap(hops);
    }

    /// Sub-condition: `sp != 0` — dead price, NONZERO liquidity.
    /// kills: with the dead leg costed at DEFAULT (50), avgImpact is 25 and
    /// floorUsed·BPS ≥ quoted·9375 (base 9600 − 200 legShave − 25). Force
    /// `sp != 0` true and the leg is costed at BPS: avgImpact 5000 drags the
    /// floor onto the 8000 hard clamp, and floorUsed·BPS < quoted·8500 — the
    /// inequality flips. quoted > 0 is asserted so the reading cannot be
    /// vacuous.
    function test_L777_sp_deadPriceLegDoesNotWalkFloorToClamp() public {
        (MockERC20 a, MockERC20 b, address live, address dead) = _deadLegHarness(0, 1e24);
        Route memory r = _twoLegRoute(a, b, live, dead);

        uint256 amt = 300e18;
        a.mint(user, amt);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        (uint256 quoted, uint256 floorUsed) = _execProof();

        assertGt(quoted, 0, "finalHopQuote must be the live V2 leg's quote");
        assertGe(floorUsed * BPC.BPS, quoted * 8500,
            "dead-price leg must be costed at DEFAULT impact, not at BPS");
    }

    /// Sub-condition: `lq != 0` — NONZERO price, dead liquidity.
    /// kills: identical mechanism to the sp arm — outV3 returns 0 for a
    /// zero-liquidity pool, so the quote is unchanged, but neutralising
    /// `lq != 0` swaps the leg's DEFAULT (50) impact for BPS and collapses
    /// the published floor from 9375 bps to the 8000 clamp.
    function test_L777_lq_deadLiquidityLegDoesNotWalkFloorToClamp() public {
        (MockERC20 a, MockERC20 b, address live, address dead) =
            _deadLegHarness(uint160(BPC.Q96), 0);
        Route memory r = _twoLegRoute(a, b, live, dead);

        uint256 amt = 300e18;
        a.mint(user, amt);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        (uint256 quoted, uint256 floorUsed) = _execProof();

        assertGt(quoted, 0, "finalHopQuote must be the live V2 leg's quote");
        assertGe(floorUsed * BPC.BPS, quoted * 8500,
            "dead-liquidity leg must be costed at DEFAULT impact, not at BPS");
    }

    /// Sub-condition: `legAmt != 0` — LIVE pool, scaled-to-zero leg.
    ///
    /// The determining state needs legAmt == 0 with sp != 0 && lq != 0, i.e.
    /// leg.amountIn·scaleNum < scaleDen. That forces a dust-scale hop, so the
    /// output side must be a HIGH-RATE pool (1e18 : 1e30 reserves) for the
    /// impact shift to survive integer rounding into the published floor:
    /// hop input 200 wei (199 after fee), live leg declares 200_000, stunt
    /// leg declares 1_000 -> legAmt = mulDiv(1000, 199, 201000) = 0.
    /// kills: real else-arm costs the zero-scaled leg at DEFAULT with weight
    /// mulDiv(50·2, 1000, 201000) = 0, so avgImpact = 0 and floorUsed·BPS ≥
    /// quoted·9400. Force `legAmt != 0` true: impactV3FromOut(outV3(0,..)==0)
    /// == BPS with weight mulDiv(10000·2, 1000, 201000) = 99 -> avgImpact 50
    /// -> floorBps 9350, and floorUsed·BPS < quoted·9375 (quoted ≈ 1.97e14,
    /// far above the rounding slack). The 9375 threshold separates the two.
    function test_L777_legAmt_zeroScaledLiveLegKeepsDefaultImpact() public {
        MockERC20 a = new MockERC20("A3", "A3");
        MockERC20 b = new MockERC20("B3", "B3");
        bool zfo = address(a) < address(b);
        MockV2Pair lp = new MockV2Pair(address(a), address(b));
        a.mint(address(lp), 1e18);
        b.mint(address(lp), DEEP);
        lp.setReserves(zfo ? uint112(1e18) : uint112(DEEP), zfo ? uint112(DEEP) : uint112(1e18));
        StuntV3Pool dp = new StuntV3Pool(address(a), address(b), address(b));
        dp.setState(uint160(BPC.Q96), 1e24);       // LIVE state — that is the point
        b.mint(address(dp), 1e18);

        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({
            pool: address(lp), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: 200_000, expectedOut: 0, auxId: bytes32(0)
        });
        legs[1] = Leg({
            pool: address(dp), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: 1_000, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(a), tokenOut: address(b), amountIn: 200, expectedOut: 0, legs: legs });

        a.mint(user, 200);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(_wrap(hops), 200, 1, user, block.timestamp + 1);
        (uint256 quoted, uint256 floorUsed) = _execProof();

        assertGt(quoted, 1e12, "high-rate live leg must carry a macroscopic quote");
        assertGe(floorUsed * BPC.BPS, quoted * 9375,
            "a scaled-to-zero leg must be costed at DEFAULT impact, not at BPS");
    }

    // =========================================================================
    //  LINE 891 — _v4LegQuote: `tokenIn == address(0) && tokenOther == address(0)`
    //  Sub-condition: `tokenIn == address(0)`.
    //
    //  After nativeMapVerified, a token -> WETH leg arrives here as
    //  (tokenIn = tok, tokenOther = 0): the determining state — and the one
    //  direction the existing parity test (RouterV4NativeEth test (d), WETH in)
    //  never quotes through this guard.
    // =========================================================================
    /// kills: ExecutionProof.quoted must equal the live outV3 figure for the
    /// native pid, which the quote path only produces by NOT taking the
    /// fail-closed return at 891. Force `tokenIn == 0` true and the guard
    /// collapses to `tokenOther == 0` — true here — so the leg 0-quotes and
    /// the event publishes quoted == 0 (execution settles regardless: the
    /// protocol floor on a 0 quote is 0). assertGt(realQuote, 0) keeps the
    /// parity assertion from ever being vacuously 0 == 0.
    function test_L891_v4NativeOutputSide_quotesLivePool() public {
        MockV4ManagerNative mgr = new MockV4ManagerNative();
        BlazePhoenixHub h = new BlazePhoenixHub(address(this));
        h.initialize(address(this), address(mgr));
        MockWETH9 w = new MockWETH9();
        MockERC20 tok = new MockERC20("Token", "TOK");
        BlazePhoenixRouter rt = new BlazePhoenixRouter(
            address(h), address(0xBEEF), address(this), treasury1, treasury2
        );
        rt.setWeth(address(w));

        uint24 FEE = 500; int24 TS = 10; uint128 LIQ = 1e24;
        bytes32 pid = BPC.computeV4PoolId(address(0), address(tok), FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));               // sqrtP 1:1, fees 0
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));

        vm.deal(address(mgr), 1_000e18);          // mgr pays raw ETH on take()
        tok.mint(user, 100e18);
        vm.prank(user);
        tok.approve(address(rt), type(uint256).max);

        uint256 amt = 10e18;
        uint256 netIn = amt - BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        // token -> WETH: zeroForOne = false (currency0 is the native side).
        uint256 realQuote = BPC.outV3(netIn, uint160(BPC.Q96), LIQ, FEE, false, 0);
        assertGt(realQuote, 0, "sanity: the native pid must be quotable");

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0),
            kind: BPC.KIND_V4_NATIVE, fee: FEE, tickSpacing: TS,
            zeroForOne: false, stable: false,
            amountIn: amt, expectedOut: realQuote,
            auxId: bytes32(uint256(uint160(address(w))))            // WETH on the OTHER side
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(tok), tokenOut: address(w), amountIn: amt, expectedOut: realQuote, legs: legs });

        vm.recordLogs();
        vm.prank(user);
        rt.swapExactIn(_wrap(hops), amt, 1, user, block.timestamp + 1);

        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            (uint256 quoted, , , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(quoted, realQuote, "quote must resolve the live native pool, not fail closed to 0");
        }
        assertTrue(found, "ExecutionProof missing");
    }

    // =========================================================================
    //  LINE 995 — _execute: `route.hops.length == 1 && hub.isBridgeToken(tokenOut)`
    //  Sub-condition: `route.hops.length == 1`.
    // =========================================================================
    /// kills: 2-hop route A -> B -> C with BOTH B and C registered bridges —
    /// the state no existing addBridge test builds (their multi-hop
    /// destinations are non-bridge facade tokens). Real: hops.length != 1, so
    /// feeOnOut is false and the fee is charged mid-route in B (feeHop == 1).
    /// Neutralised, feeOnOut = isBridgeToken(C) == true: the in-loop charge is
    /// skipped and the fee comes out of the OUTPUT — treasuries hold C and no
    /// B. Both balance pins flip.
    function test_L995_multiHopIntoBridge_chargesOnBridgeInputNotOutput() public {
        MockERC20 a = new MockERC20("Ax", "Ax");
        MockERC20 b = new MockERC20("Bx", "Bx");   // bridge, mid-route
        MockERC20 c = new MockERC20("Cx", "Cx");   // bridge AND the tokenOut
        hub.addBridge(address(b));
        hub.addBridge(address(c));

        MockV2Pair ab = new MockV2Pair(address(a), address(b));
        MockV2Pair bc = new MockV2Pair(address(b), address(c));
        a.mint(address(ab), DEEP); b.mint(address(ab), DEEP); ab.setReserves(uint112(DEEP), uint112(DEEP));
        b.mint(address(bc), DEEP); c.mint(address(bc), DEEP); bc.setReserves(uint112(DEEP), uint112(DEEP));

        uint256 amt = 100e18;
        a.mint(user, amt);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);

        Leg[] memory l0 = new Leg[](1);
        l0[0] = Leg({ pool: address(ab), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(a) < address(b), stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0) });
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({ pool: address(bc), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(b) < address(c), stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0) });
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({ tokenIn: address(a), tokenOut: address(b), amountIn: amt, expectedOut: 0, legs: l0 });
        hops[1] = Hop({ tokenIn: address(b), tokenOut: address(c), amountIn: amt, expectedOut: 0, legs: l1 });

        vm.prank(user);
        router.swapExactIn(_wrap(hops), amt, 1, user, block.timestamp + 1);

        uint256 feeInB = b.balanceOf(treasury1) + b.balanceOf(treasury2);
        uint256 feeInC = c.balanceOf(treasury1) + c.balanceOf(treasury2);
        assertGt(feeInB, 0, "multi-hop-into-bridge fee must be charged on the bridge input (B)");
        assertEq(feeInC, 0, "fee must not come out of the output for a multi-hop route");
    }

    // =========================================================================
    //  LINE 1006 — _execute hop loop: `legs == 0 || legs > MAX_LEGS_PER_HOP`
    //  Sub-condition: `legs > MAX_LEGS_PER_HOP`.
    // =========================================================================
    /// kills: six VALID legs across six deep pools of one pair. Real:
    /// RouterE(3) at 1006. The existing G8_SixLegs control uses six all-zero
    /// legs, which still revert RouterE(3) from the homogeneity guard at 1147
    /// — same selector, different site — so it cannot see this arm. With six
    /// genuinely valid legs nothing downstream refuses: neutralise the arm
    /// (OR collapses to `legs == 0`, false) and all six execute to a
    /// successful settle, leaving the expectRevert unsatisfied.
    function test_L1006_sixValidLegs_diesAt3() public {
        uint256 amt = 6e18;
        bool zfo = address(tIn) < address(tOut);
        Leg[] memory legs = new Leg[](6);
        for (uint256 i; i < 6; ++i) {
            MockV2Pair p = new MockV2Pair(address(tIn), address(tOut));
            tIn.mint(address(p), DEEP);
            tOut.mint(address(p), DEEP);
            p.setReserves(uint112(DEEP), uint112(DEEP));
            legs[i] = Leg({
                pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                tickSpacing: 0, zeroForOne: zfo, stable: false,
                amountIn: amt / 6, expectedOut: 0, auxId: bytes32(0)
            });
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(tIn), tokenOut: address(tOut), amountIn: amt, expectedOut: 0, legs: legs });

        vm.prank(user);
        vm.expectRevert(_e(3));
        router.swapExactIn(_wrap(hops), amt, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  LINE 1225 — bridge residual sweep: `bridge != tokenIn && bridge != tokenOut`
    //  Sub-condition: `bridge != tokenIn`.
    //
    //  Circular route A -> B -> A -> C: the h == 1 intermediate's output IS
    //  the route's tokenIn. The Router is pre-seeded with mis-sent A — the
    //  balance the 48h rescue exists to return, and exactly what "the Router
    //  holds nothing at rest" hid from every earlier probe of this arm.
    // =========================================================================
    /// kills: reads the Router's residual A after the swap. It equals the
    /// pre-seed ONLY because the sweep skips bridge == tokenIn: bridgeBase[1]
    /// was never seeded (959's own guard, untouched here), so forcing THIS
    /// arm true runs the sweep on A with bb == 0 and pays the whole pre-seed
    /// out to the payer — the assertEq collapses from PRESEED to 0.
    function test_L1225_bridgeSweep_preservesMisSentTokenIn() public {
        (MockERC20 a, MockERC20 b, , Route memory r) = _circularRoute();
        hub.addBridge(address(b));                  // fee lands in B, leaving A clean
        uint256 PRESEED = 7e18;
        a.mint(address(router), PRESEED);           // mis-sent funds (rescue territory)

        uint256 amt = 1_000e18;
        a.mint(user, amt);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);

        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);

        assertEq(a.balanceOf(address(router)), PRESEED,
            "mis-sent tokenIn must survive the bridge sweep of a circular route");
    }

    /// @dev Circular route A -> B -> A -> C over deep V2 pools; hop 1's output
    ///      token is the route's tokenIn.
    function _circularRoute()
        private returns (MockERC20 a, MockERC20 b, MockERC20 c, Route memory r)
    {
        a = new MockERC20("Ac", "Ac");
        b = new MockERC20("Bc", "Bc");
        c = new MockERC20("Cc", "Cc");
        MockV2Pair ab = new MockV2Pair(address(a), address(b));
        MockV2Pair ba = new MockV2Pair(address(b), address(a));
        MockV2Pair ac = new MockV2Pair(address(a), address(c));
        a.mint(address(ab), DEEP); b.mint(address(ab), DEEP); ab.setReserves(uint112(DEEP), uint112(DEEP));
        b.mint(address(ba), DEEP); a.mint(address(ba), DEEP); ba.setReserves(uint112(DEEP), uint112(DEEP));
        a.mint(address(ac), DEEP); c.mint(address(ac), DEEP); ac.setReserves(uint112(DEEP), uint112(DEEP));

        uint256 AMT = 1_000e18;
        Leg[] memory l0 = new Leg[](1);
        l0[0] = Leg({ pool: address(ab), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(a) < address(b), stable: false, amountIn: AMT, expectedOut: AMT, auxId: bytes32(0) });
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({ pool: address(ba), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(b) < address(a), stable: false, amountIn: AMT, expectedOut: AMT, auxId: bytes32(0) });
        Leg[] memory l2 = new Leg[](1);
        l2[0] = Leg({ pool: address(ac), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(a) < address(c), stable: false, amountIn: AMT, expectedOut: AMT, auxId: bytes32(0) });
        Hop[] memory hops = new Hop[](3);
        hops[0] = Hop({ tokenIn: address(a), tokenOut: address(b), amountIn: AMT, expectedOut: AMT, legs: l0 });
        hops[1] = Hop({ tokenIn: address(b), tokenOut: address(a), amountIn: AMT, expectedOut: AMT, legs: l1 });
        hops[2] = Hop({ tokenIn: address(a), tokenOut: address(c), amountIn: AMT, expectedOut: AMT, legs: l2 });
        r = _wrap(hops);
    }

    // =========================================================================
    //  LINE 1433 — _execScaled guard:
    //  `legOut != 0 && amt != 0 && ((expectedOut != 0 && amountIn != 0) ||
    //                               (legQuote != 0 && legAmt != 0))`
    // =========================================================================

    /// Sub-condition: `legOut != address(0)`.
    ///
    /// legOut == 0 (line 1428) requires legOutRaw == the hop's tokenIn, i.e. a
    /// SAME-TOKEN hop — reachable only through a degenerate pair whose two
    /// sides are the same token (MockV2Pair(A, A) sorts to token0 == token1),
    /// which passes the 1147 homogeneity guard for a hop A -> A. No suite
    /// test ever builds it.
    /// kills: real code leaves the per-leg floor OFF for the same-token leg
    /// (fails open to the aggregate floors) and the swap settles, delivering
    /// ~99.4% of the input back in A. Neutralise `legOut != 0` (the guard's
    /// other conjuncts are true: amt != 0, legQuote != 0) and the floor block
    /// runs against balanceOf(address(0)) — a codeless read that returns 0 —
    /// so got == 0 against a nonzero coverage bound and the whole swap
    /// reverts RouterE(5): the delivered assertion can never run.
    function test_L1433_legOut_sameTokenHop_settlesWithFloorOff() public {
        MockERC20 a = new MockERC20("Aa", "Aa");
        MockV2Pair aa = new MockV2Pair(address(a), address(a));   // token0 == token1 == a
        a.mint(address(aa), DEEP);
        aa.setReserves(uint112(DEEP), uint112(DEEP));

        uint256 amt = 100e18;
        a.mint(user, amt);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(aa), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: false, stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(a), tokenOut: address(a), amountIn: amt, expectedOut: 0, legs: legs });

        vm.prank(user);
        uint256 delivered = router.swapExactIn(_wrap(hops), amt, 1, user, block.timestamp + 1);

        assertGt(delivered, 90e18, "same-token hop must settle with the per-leg floor failed open");
    }

    /// @dev Shared harness for the two disjunct arms of 1433: a hop where two
    ///      live legs carry inflated attestations (each passes its own 80%
    ///      floor but the hop FAILS Layer 1) and a dead-quoted StuntV3Pool leg
    ///      delivers real tokenOut that the real program does NOT count into
    ///      hopGot (its guard is false: expectedOut == 0 AND legQuote == 0).
    ///      Neutralising either disjunct arm turns that leg's guard ON with
    ///      attested still 0, so its delivery joins hopGot and Layer 1 passes.
    function _uncountedDeliveryRoute(uint256 payoutNum, uint256 payoutDen)
        private returns (Route memory r)
    {
        MockERC20 a = new MockERC20("A5", "A5");
        MockERC20 b = new MockERC20("B5", "B5");
        bool zfo = address(a) < address(b);
        MockV2Pair p1 = new MockV2Pair(address(a), address(b));
        MockV2Pair p2 = new MockV2Pair(address(a), address(b));
        a.mint(address(p1), DEEP); b.mint(address(p1), DEEP); p1.setReserves(uint112(DEEP), uint112(DEEP));
        a.mint(address(p2), DEEP); b.mint(address(p2), DEEP); p2.setReserves(uint112(DEEP), uint112(DEEP));
        StuntV3Pool dp = new StuntV3Pool(address(a), address(b), address(b));
        dp.setState(0, 0);                       // dead read -> legQuote == 0

        // Per-leg numbers: amountIn 300e18, fee 0.84e18, scale 299.16/300,
        // legAmt = 99.72e18 exactly; q is that legAmt's live V2 quote.
        uint256 q = BPC.outV2(99_720000000000000000, DEEP, DEEP, 30);
        uint256 E = (q * 12) / 10;               // inflated attestation: bound ≈ 1.1966·q
        uint256 payout = (q * payoutNum) / payoutDen;
        dp.setPayout(payout);
        b.mint(address(dp), payout);

        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg({ pool: address(p1), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: 100e18, expectedOut: E, auxId: bytes32(0) });
        legs[1] = Leg({ pool: address(p2), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: 100e18, expectedOut: E, auxId: bytes32(0) });
        legs[2] = Leg({ pool: address(dp), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 60,
            zeroForOne: zfo, stable: false, amountIn: 100e18, expectedOut: 0, auxId: bytes32(0) });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(a), tokenOut: address(b), amountIn: 300e18, expectedOut: 0, legs: legs });

        a.mint(user, 300e18);
        vm.prank(user);
        a.approve(address(router), type(uint256).max);
        r = _wrap(hops);
    }

    /// Sub-condition: `leg.expectedOut != 0` (first disjunct).
    ///
    /// kills: pins RouterE(5) from Layer 1 (1202). Real: each live leg
    /// delivers q against a bound of ~1.1966q — over its own 80% floor
    /// (0.957q), so no per-leg revert — and the hop aggregate fails:
    /// hopGot(2q) + slack(0.2·1.1966q) < hopAttested(2.393q). The stunt leg's
    /// q-sized delivery is NOT counted because its guard is false. Force
    /// `expectedOut != 0` true: the stunt guard becomes amt != 0 (its 1462
    /// ternary still yields bound 0, so no floor and attested 0), its
    /// delivery joins hopGot (3q + 0.239q ≥ 2.393q), Layer 1 passes and the
    /// swap SETTLES — the expectRevert is left unsatisfied.
    function test_L1433_expectedOut_uncountedDeliveryDoesNotRescueLayer1() public {
        Route memory r = _uncountedDeliveryRoute(1, 1);   // stunt pays exactly q
        vm.prank(user);
        vm.expectRevert(_e(5));
        router.swapExactIn(r, 300e18, 1, user, block.timestamp + 1);
    }

    /// Sub-condition: `legQuote != 0` (second disjunct).
    ///
    /// Same determining state as the expectedOut arm (stunt leg: expectedOut
    /// == 0 AND legQuote == 0 AND legAmt != 0), because forcing EITHER
    /// disjunct arm true flips the same guard.
    /// kills: identical Layer-1 pin, RouterE(5) real. Force `legQuote != 0`
    /// true: the stunt guard becomes legAmt != 0 (true), the 1493 gate still
    /// skips (real legQuote IS 0), attested stays 0, but got is measured and
    /// counted — 2q + 1.5q clears the 2.393q budget and the swap settles.
    function test_L1433_legQuote_uncountedDeliveryDoesNotRescueLayer1() public {
        Route memory r = _uncountedDeliveryRoute(3, 2);   // stunt pays 1.5·q
        vm.prank(user);
        vm.expectRevert(_e(5));
        router.swapExactIn(r, 300e18, 1, user, block.timestamp + 1);
    }
}
