// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PathologicalTokens — the three token classes NO existing mock could express,
//  driven through a real Router door: REBASING (both directions, mid-route),
//  BLOCKLISTING, PAUSABLE — plus non-18 decimals at the fee-rounding threshold.
//
//  Why these break routers specifically: the Router prices every leg off a
//  BALANCE DELTA — it reads its own balance before and after each movement.
//  A balance that moves for reasons unrelated to the transfer (a rebase), or a
//  transfer that refuses mid-route (blocklist/pause), attacks that measurement
//  directly. Each pathology test has a CONTROL with the same token unmutated,
//  so a divergence is attributable to the pathology and nothing else.
//
//  The mid-transaction injection uses PathologicalERC20's one-shot triggers:
//  a rebase/pause fires inside a transfer that lands on a chosen address
//  (a treasury, or the Router itself) — the only way to mutate token state
//  BETWEEN two internal steps of a single swap.
//
//  OBSERVED BEHAVIOUR (what these tests pin):
//   1a. Negative rebase between the pull and the leg push → the last-leg clamp
//       (Router:1177-1180) stops the Router pushing more than it holds, and the
//       protocol floor — priced on the PRE-rebase quote — rejects the shrunken
//       fill: clean revert RouterE(5), fully atomic. No stranded leg.
//   1b. Negative rebase between hop 1 and hop 2 → hop 2 re-measures its real
//       balance (realIn = bal - foreignBase) and rescales: delivers ~half,
//       Router holds nothing. No over-push, no stranding.
//   2.  Positive rebase after the pull → hop 0's scale cap (scaleNum ≤ scaleDen)
//       spends only the committed amount; the holds-nothing sweep returns the
//       surplus to the PAYER (Router:1191-1194). Nothing left for a next caller.
//   3.  Blocklisted recipient / blocklisted Router → clean atomic reverts
//       ("BPC:transfer" at the payout; the token's own revert mid-pair).
//   4.  Token paused between hop 1 and hop 2 → hop 2's first transfer of the
//       bridge reverts "BPC:transfer": clean, atomic, user keeps funds.
//   5.  Decimals 0/2/6 at the 357-wei fee-rounding threshold → mulDivUp
//       (Router:627) charges exactly 1 wei — real money at low decimals —
//       and never rounds to zero.
//
//  forge test --match-contract PathologicalTokens -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract PathologicalTokensTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    // All three route positions are PathologicalERC20 with every switch OFF by
    // default — in that state it behaves as a plain ERC20 (the controls prove
    // it). Each test flips exactly one switch on exactly one token.
    PathologicalERC20 P1; // tokenIn
    PathologicalERC20 P2; // bridge
    PathologicalERC20 P3; // tokenOut

    MockV2Pair pair12;
    MockV2Pair pair23;

    address user  = address(0xBEEF);
    address recip = address(0xCAFE);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    uint256 constant RESERVE = 1_000_000e18;
    uint256 constant IN      = 100e18;
    uint256 constant START   = 1_000_000e18;

    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0
    uint128 constant LIQ      = 1_000_000e18;

    // Largest input whose FLOOR-divided fee is zero: mulDiv(357,28,1e4) == 0.
    // mulDivUp must charge 1 wei here — at 0 decimals that is 357 whole tokens.
    uint256 constant DUST_IN = 357;

    bool zfo12;
    bool zfo23;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        P1 = new PathologicalERC20("P1", "P1", 18);
        P2 = new PathologicalERC20("P2", "P2", 18);
        P3 = new PathologicalERC20("P3", "P3", 18);

        pair12 = new MockV2Pair(address(P1), address(P2));
        pair23 = new MockV2Pair(address(P2), address(P3));
        P1.mint(address(pair12), RESERVE);
        P2.mint(address(pair12), RESERVE);
        P2.mint(address(pair23), RESERVE);
        P3.mint(address(pair23), RESERVE);
        pair12.setReserves(uint112(RESERVE), uint112(RESERVE));
        pair23.setReserves(uint112(RESERVE), uint112(RESERVE));

        hub.seedPool(address(pair12), BPC.KIND_V2, 0, address(0), address(P1), address(P2));
        hub.seedPool(address(pair23), BPC.KIND_V2, 0, address(0), address(P2), address(P3));

        zfo12 = pair12.token0() == address(P1);
        zfo23 = pair23.token0() == address(P2);

        P1.mint(user, START);
        vm.prank(user);
        P1.approve(address(router), type(uint256).max);
    }

    // ─── route builders ──────────────────────────────────────────────────────

    function _v2Leg(address pool, bool zfo, uint256 amountIn) internal pure returns (Leg memory) {
        return Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 0,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
    }

    function _wrap(Hop[] memory hops) internal pure returns (Route memory r) {
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// P1 -> P2, one V2 leg.
    function _oneHop(uint256 amountIn) internal view returns (Route memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _v2Leg(address(pair12), zfo12, amountIn);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(P1), tokenOut: address(P2), amountIn: amountIn, expectedOut: 0, legs: legs});
        return _wrap(hops);
    }

    /// P1 -> P2 -> P3, one V2 leg per hop. Hop 1 commits ~99e18 of bridge —
    /// execution rescales against the measured real balance anyway.
    function _twoHop(uint256 amountIn) internal view returns (Route memory) {
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _v2Leg(address(pair12), zfo12, amountIn);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _v2Leg(address(pair23), zfo23, 99e18);
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(P1), tokenOut: address(P2), amountIn: amountIn, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(P2), tokenOut: address(P3), amountIn: 99e18, expectedOut: 0, legs: l1});
        return _wrap(hops);
    }

    function _treas(PathologicalERC20 t) internal view returns (uint256) {
        return t.balanceOf(T1) + t.balanceOf(T2);
    }

    function _routerHoldsNothing() internal view {
        // ≤1 wei: a positive rebase factor can leave a sub-share display crumb
        // after the sweep (shares round down on conversion); never real value.
        assertLe(P1.balanceOf(address(router)), 1, "router still holds tokenIn");
        assertLe(P2.balanceOf(address(router)), 1, "router still holds bridge");
        assertLe(P3.balanceOf(address(router)), 1, "router still holds tokenOut");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONTROLS — same tokens, every switch off: a plain ERC20 through a door.
    // ═════════════════════════════════════════════════════════════════════════

    function test_Control_SingleHop_Delivers() public {
        vm.prank(user);
        uint256 got = router.swapExactIn(_oneHop(IN), IN, 1, recip, block.timestamp + 1);
        console2.log("control single-hop delivered", got);
        assertGt(got, 99e18, "control: ~full delivery expected");
        assertEq(P2.balanceOf(recip), got, "recipient credited exactly");
        // Protocol fee on hop 0, in tokenIn: mulDivUp(100e18, 28, 10_000).
        assertEq(_treas(P1), BPC.mulDivUp(IN, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "fee charged in tokenIn");
        _routerHoldsNothing();
    }

    function test_Control_TwoHop_Delivers() public {
        vm.prank(user);
        uint256 got = router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);
        console2.log("control two-hop delivered", got);
        assertGt(got, 98e18, "control: ~full delivery minus two fees");
        assertEq(P3.balanceOf(recip), got, "recipient credited exactly");
        // No hub bridge configured -> the fee anchors on EVERY hop (the
        // exhaustion-immune degenerate case): both P1 and P2 treasuries paid.
        assertGt(_treas(P1), 0, "hop-0 fee in tokenIn");
        assertGt(_treas(P2), 0, "hop-1 fee in bridge");
        _routerHoldsNothing();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1a. NEGATIVE REBASE between the pull and the leg push.
    //      The trigger rides the hop-0 fee payout (Router pulls, charges the
    //      fee, THEN quotes and pushes — the rebase lands exactly in between).
    // ═════════════════════════════════════════════════════════════════════════

    function test_NegativeRebase_BetweenPullAndPush_RevertsClean() public {
        // Halve every P1 balance the moment the fee lands on treasury T1.
        P1.setRebaseOnTransferTo(T1, 1, 2);

        uint256 userBefore = P1.balanceOf(user);

        // The Router measured 100e18 a moment ago and now holds ~49.8e18.
        // The last-leg clamp stops it pushing more than it holds (so no leg is
        // ever stranded), and the protocol floor — 96% of the quote priced on
        // the PRE-rebase amount — rejects the halved fill: RouterE(5).
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(_oneHop(IN), IN, 1, recip, block.timestamp + 1);

        // Fully atomic: the pull, the fee, the half-push all unwound.
        assertEq(P1.balanceOf(user), userBefore, "user funds untouched after revert");
        assertEq(_treas(P1), 0, "no fee kept from a reverted swap");
        assertEq(P2.balanceOf(recip), 0, "nothing delivered");
        assertEq(P1.balanceOf(address(router)), 0, "nothing stranded in the router");
    }

    /// Same trigger, same rebase — but the CONTROL arms the trigger on an
    /// address the swap never pays, so the factor never fires and the swap
    /// delivers. Proves the revert above is the rebase, not the trigger plumbing.
    function test_NegativeRebase_Control_ArmedButUnfired_Delivers() public {
        P1.setRebaseOnTransferTo(address(0xDEAD), 1, 2);
        vm.prank(user);
        uint256 got = router.swapExactIn(_oneHop(IN), IN, 1, recip, block.timestamp + 1);
        assertGt(got, 99e18, "unfired trigger must not change behaviour");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1b. NEGATIVE REBASE of the BRIDGE between hop 1 and hop 2.
    //      Trigger rides hop 1's fee payout in the bridge token — after hop 0's
    //      per-leg floor has passed, before hop 1 measures its input.
    // ═════════════════════════════════════════════════════════════════════════

    function test_NegativeRebase_MidRoute_Hop2Remeasures_NothingStranded() public {
        P2.setRebaseOnTransferTo(T1, 1, 2);

        // Control first (fresh state per test makes this a separate run; here
        // we just pin the expected unmutated magnitude from the control test).
        vm.prank(user);
        uint256 got = router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);
        console2.log("mid-route negative rebase delivered", got);

        // Hop 2 re-measured its REAL bridge balance (realIn = bal - foreignBase)
        // and rescaled: it spends what exists, never what hop 1 promised.
        // ~half of the control's ~99e18 arrives; the rest evaporated in the
        // rebase — the token's doing, not the Router's.
        assertGt(got, 40e18, "delivered the post-rebase value");
        assertLt(got, 60e18, "cannot deliver more than the rebased bridge bought");
        assertEq(P3.balanceOf(recip), got, "recipient credited exactly");
        _routerHoldsNothing();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. POSITIVE REBASE mid-route: surplus appears after the pull.
    //     Does the holds-nothing sweep return it to the payer, or is it left
    //     in the Router for the next caller?
    // ═════════════════════════════════════════════════════════════════════════

    function test_PositiveRebase_SurplusSweptToPayer_NotLeftInRouter() public {
        // Double every P1 balance the moment the hop-0 fee lands on T1: the
        // Router suddenly holds ~199e18 of an input it measured at ~99.7e18.
        P1.setRebaseOnTransferTo(T1, 2, 1);

        uint256 userBefore = P1.balanceOf(user); // pre-rebase display

        vm.prank(user);
        uint256 got = router.swapExactIn(_oneHop(IN), IN, 1, recip, block.timestamp + 1);
        console2.log("positive rebase delivered", got);
        console2.log("payer P1 after", P1.balanceOf(user));

        // The swap itself spends only the committed amount (hop-0 cap:
        // scaleNum <= scaleDen), delivering the normal ~99e18.
        assertGt(got, 99e18, "delivery unchanged by the surplus");

        // THE QUESTION THE TEST EXISTS FOR: the ~99.9e18 surplus was returned
        // to the payer by the residual sweep — NOT left in the Router.
        assertLe(P1.balanceOf(address(router)), 1, "surplus must not be left for the next caller");
        // Payer got the surplus back: net P1 spent is far less than 100e18.
        // (userBefore was measured pre-rebase; the user's own holding also
        // doubled, so compare against the doubled baseline minus the pull.)
        uint256 expectedFloor = (userBefore - IN) * 2; // doubled remainder, no sweep-back
        assertGt(P1.balanceOf(user), expectedFloor + 90e18, "sweep returned the surplus to the payer");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. BLOCKLIST — recipient, and the Router itself, on a two-hop route.
    // ═════════════════════════════════════════════════════════════════════════

    function test_BlockedRecipient_TwoHop_RevertsAtomically() public {
        P3.setBlocked(recip, true);

        uint256 userBefore = P1.balanceOf(user);

        // Both hops execute, both fees are paid — then the final payout to the
        // blocked recipient refuses. safeTransfer wraps the token's revert as
        // "BPC:transfer". Everything unwinds.
        vm.prank(user);
        vm.expectRevert(bytes("BPC:transfer"));
        router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);

        assertEq(P1.balanceOf(user), userBefore, "atomic: user keeps funds");
        assertEq(_treas(P1), 0, "atomic: no fee survives the revert");
        assertEq(P3.balanceOf(address(router)), 0, "atomic: no output stranded");
    }

    function test_BlockedRouter_OnBridge_TwoHop_RevertsAtomically() public {
        // The bridge token blocklists the ROUTER: hop 1's pool cannot deliver
        // P2 to it. The pair's own transfer reverts with the token's reason
        // (the pair calls the token directly — no BPC wrapper in between).
        P2.setBlocked(address(router), true);

        uint256 userBefore = P1.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(bytes("PathologicalERC20: blocked"));
        router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);

        assertEq(P1.balanceOf(user), userBefore, "atomic: user keeps funds");
        assertEq(P2.balanceOf(address(router)), 0, "atomic: no bridge stranded");
    }

    function test_BlockedRouter_OnPull_RevertsAtEntry() public {
        // tokenIn blocklists the Router: the very first movement (the pull)
        // refuses, wrapped by safeTransferFrom as "BPC:transferFrom".
        P1.setBlocked(address(router), true);

        vm.prank(user);
        vm.expectRevert(bytes("BPC:transferFrom"));
        router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);

        assertEq(P1.balanceOf(user), START, "nothing moved");
    }

    /// Control: the same blocklist machinery armed against an uninvolved
    /// address changes nothing.
    function test_Blocklist_Control_UninvolvedAddressBlocked_Delivers() public {
        P2.setBlocked(address(0xDEAD), true);
        P3.setBlocked(address(0xDEAD), true);
        vm.prank(user);
        uint256 got = router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);
        assertGt(got, 98e18, "blocklist of a stranger must not affect the route");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  4. PAUSE between hop 1 and hop 2 of a two-hop route.
    // ═════════════════════════════════════════════════════════════════════════

    function test_PausedBetweenHops_RevertsAtomically() public {
        // The bridge pauses itself the moment hop 1's pool delivers it to the
        // Router — hop 1 completed, hop 2 has not begun. Hop 2's first attempt
        // to move P2 (the hop-1 fee payout) hits the pause: "BPC:transfer".
        P2.setPauseOnTransferTo(address(router));

        uint256 userBefore = P1.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(bytes("BPC:transfer"));
        router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);

        // Atomic: the user is refunded by revert, nothing is stranded mid-route.
        // (P2.paused() is NOT checked here: expectRevert rolls the whole tx
        // back, so the pause the trigger set inside it is unwound too. The
        // revert REASON plus the unfired control below carry the attribution.)
        assertEq(P1.balanceOf(user), userBefore, "atomic: user keeps funds");
        assertEq(P2.balanceOf(address(router)), 0, "atomic: no bridge stranded");
        assertEq(P3.balanceOf(recip), 0, "nothing delivered");
    }

    /// Control: pause armed on an address the route never pays -> full delivery.
    function test_Pause_Control_ArmedButUnfired_Delivers() public {
        P2.setPauseOnTransferTo(address(0xDEAD));
        vm.prank(user);
        uint256 got = router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);
        assertGt(got, 98e18, "unfired pause must not change behaviour");
        assertFalse(P2.paused(), "trigger never fired");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5. DECIMALS 0 / 2 / 6 through a door, at the fee-rounding threshold.
    //     357 wei is the largest base whose floor-divided fee is zero — at
    //     0 decimals that is 357 WHOLE tokens. The protocol must charge >= 1.
    // ═════════════════════════════════════════════════════════════════════════

    function _driveDecimals(uint8 d) internal returns (uint256 feePaid, uint256 got) {
        PathologicalERC20 tIn = new PathologicalERC20("D", "D", d);
        assertEq(tIn.decimals(), d, "constructor-set decimals");
        PathologicalERC20 tOut = new PathologicalERC20("O", "O", 18);
        MockV3Pool pool = new MockV3Pool(address(tIn), address(tOut), 3000);
        pool.setState(SQRT_P_1, LIQ);
        tOut.mint(address(pool), RESERVE);
        hub.seedPool(address(pool), BPC.KIND_V3, 3000, address(0), address(tIn), address(tOut));
        bool z = pool.token0() == address(tIn);

        address u2 = address(uint160(0xD0 + d));
        tIn.mint(u2, 1_000_000);
        vm.prank(u2);
        tIn.approve(address(router), type(uint256).max);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 0, zeroForOne: z, stable: false,
            amountIn: DUST_IN, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut), amountIn: DUST_IN, expectedOut: 0, legs: legs});

        vm.prank(u2);
        got = router.swapExactIn(_wrap(hops), DUST_IN, 1, u2, block.timestamp + 1);
        feePaid = tIn.balanceOf(T1) + tIn.balanceOf(T2);
    }

    function test_Decimals0_FeeAtThresholdNeverZero() public {
        (uint256 fee, uint256 got) = _driveDecimals(0);
        console2.log("d=0 fee/got", fee, got);
        assertGt(got, 0, "the dust swap delivered");
        assertEq(fee, 1, "357 whole 0-dec tokens pay exactly 1 unit of fee, never zero");
    }

    function test_Decimals2_FeeAtThresholdNeverZero() public {
        (uint256 fee, uint256 got) = _driveDecimals(2);
        assertGt(got, 0, "the dust swap delivered");
        assertEq(fee, 1, "3.57 2-dec tokens pay exactly 1 wei of fee, never zero");
    }

    function test_Decimals6_FeeAtThresholdNeverZero() public {
        (uint256 fee, uint256 got) = _driveDecimals(6);
        assertGt(got, 0, "the dust swap delivered");
        assertEq(fee, 1, "0.000357 6-dec tokens pay exactly 1 wei of fee, never zero");
    }

    /// Control: identical drive at 18 decimals — same arithmetic, same 1 wei.
    function test_Decimals18_Control_SameFee() public {
        (uint256 fee, uint256 got) = _driveDecimals(18);
        assertGt(got, 0, "the dust swap delivered");
        assertEq(fee, 1, "the fee is decimals-blind wei arithmetic: 1 at 18 too");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BONUS: a pathology COMBINES with a tax.
    //
    //  A. FoT (input tax) delivers through TWO doors and the Router still holds
    //     nothing — the tax is measured in-frame at every seam.
    //  B. FoT + BLOCKLIST together: the taxed route runs to its final payout,
    //     which the blocked recipient refuses — a clean atomic revert.
    //
    //  NOTE ON WHY NOT FoT+REBASE HERE: this topology routes all three tokens
    //  through V2 mocks whose reserves are a stored snapshot re-synced only on
    //  swap(). Rebasing a POOL token desyncs that snapshot from the real
    //  balance, and _execPairAmt's FoT recovery (realIn = balAfter - storedR)
    //  then reads the mock's staleness, not the Router. That is a MOCK limit,
    //  not a Router behaviour, so the tax-combination test uses the blocklist,
    //  which touches no reserve arithmetic. (Rebase-only is exercised, without
    //  a tax, in tests 1a/1b/2 above — there the FoT branch is never entered,
    //  so the stale snapshot is harmless.)
    // ═════════════════════════════════════════════════════════════════════════

    function test_ComboA_FeeOnTransfer_TwoDoors_Delivers_HoldsNothing() public {
        P1.setFeeOnTransferBps(300); // 3% tax on the input token, every movement

        vm.prank(user);
        uint256 got = router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);
        console2.log("combo FoT two-hop delivered", got);

        // Taxed on the pull and on the hop-0 push (~0.97^2), clean on hops 1's
        // P2/P3, minus two protocol fees. Wide band on purpose.
        assertGt(got, 80e18, "taxed delivery still in the honest band");
        assertLt(got, 97e18, "the tax was actually charged on the input token");
        assertEq(P3.balanceOf(recip), got, "recipient credited the delivered amount");
        _routerHoldsNothing();
    }

    function test_ComboB_FeeOnTransferPlusBlocklist_RevertsAtomically() public {
        P1.setFeeOnTransferBps(300);   // taxed input token
        P3.setBlocked(recip, true);    // and a recipient that refuses delivery

        uint256 userBefore = P1.balanceOf(user);

        // The taxed route runs both hops, then the payout to the blocked
        // recipient refuses; safeTransfer wraps it as "BPC:transfer".
        vm.prank(user);
        vm.expectRevert(bytes("BPC:transfer"));
        router.swapExactIn(_twoHop(IN), IN, 1, recip, block.timestamp + 1);

        assertEq(P1.balanceOf(user), userBefore, "atomic: taxed pull refunded too");
        assertEq(_treas(P1), 0, "atomic: no fee survives the revert");
        assertEq(P3.balanceOf(address(router)), 0, "atomic: nothing stranded");
    }
}
