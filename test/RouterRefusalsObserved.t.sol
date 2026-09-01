// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  REFUSALS OBSERVED FIRING — Router half.
//
//  The assumptions ledger's A1 ("userMinOut != 0 is enforced at all
//  value-moving entrypoints") is what bounds several reported findings to
//  griefing instead of theft — and the DELIVERY half of that assumption,
//  `if (delivered < userMinOut) revert RouterE(5)` (Router:1345), had never
//  been observed firing: every existing RouterE(5) test dies earlier, at the
//  `amountOut < effMin` aggregate check (Router:~1305), because on a
//  non-bridge destination `delivered == amountOut`. The ONLY paths on which
//  the two checks separate are (a) a fee taken out of the OUTPUT (single-hop
//  route into a bridge coin) and (b) an output-side fee-on-transfer token.
//  This file uses (a) — the protocol's own fee, no exotic token — so the
//  guard at 1345 is the one that fires, provably: the earlier check compares
//  the GROSS amountOut, which passes, and only the delivered-net comparison
//  can refuse.
//
//  Every test in this file states its deletion-sensitivity: what happens if
//  the guard's body is removed, and why the test then fails.
//
//    test_MinOut_DeliveredShortfallIsRefused      Router:1345  RouterE(5)
//        guard deleted -> the swap completes and returns; expectRevert fails.
//    test_MinOut_Boundary_ExactNetDelivers        (control)
//        pins the exact boundary: one wei of userMinOut separates delivery
//        from refusal, and the fee-on-output arithmetic to the wei.
//    test_FeeOnOut_OneWeiOutputWhollyConsumed     Router:1328  RouterE(8)
//        guard deleted -> _payFee eats the whole 1-wei output, delivered = 0
//        < userMinOut and the tx dies RouterE(5) instead — the SELECTOR
//        assertion is what catches the deletion (a bare expectRevert would
//        not; this repo has already shipped two decorative tests that way).
//    test_Received_PermitPullDeliveringZero       Router:392   RouterE(8)
//        guard deleted -> _swapPrePulled re-checks amountIn == 0 and reverts
//        RouterE(3); the selector assertion fails. Deletion-sensitive.
//    test_Received_NativeWrapCreditingZero        Router:445   RouterE(8)
//        guard deleted -> same RouterE(3) selector flip. Deletion-sensitive.
//    test_Received_BestDoorPullDeliveringZero     Router:481   RouterE(8)
//        guard deleted -> same RouterE(3) selector flip via
//        selfExecutePrePulled -> _swapPrePulled. Deletion-sensitive.
//    test_Deadline_ExpiredRefusedAndBoundaryHolds Router:546   RouterE(4)
//        guard deleted -> the (fully valid, funded) swap SUCCEEDS on an
//        expired deadline; expectRevert fails. The boundary control pins the
//        strict `>` (deadline == block.timestamp still executes).
//    test_Control_EveryControlDoorRefusesAStranger  Router:260 RouterE(1)
//        all NINE onlyControl doors enumerated in one place; deleting the
//        modifier body makes any stranger call succeed and the test fail.
//    test_Control_RenounceFreezesTheDoorsNoOtherTestFreezes
//        completes the renounce lockout for setWeth / queueRescue /
//        cancelRescue, which the existing lockout test does not touch.
//
//  VERDICTS THAT ARE FINDINGS, NOT TESTS (do not fabricate coverage):
//
//  * Router:257 `onlyAdmin` — DEAD CODE. `grep -n onlyAdmin` over the Router
//    finds exactly one occurrence: the definition. Every privileged function
//    uses `onlyControl` (admin AND !controlRenounced). The modifier can never
//    execute; no test can cover it. The fix is deletion, not a test.
//
//  * Router:609 `if (feeH == 0) return amountIn;` — NO LONGER A FAIL-OPEN,
//    and its deletion is behaviour-neutral. Since the mulDivUp fix,
//    ceil(baseH * 28 / 10_000) == 0  <=>  baseH == 0. baseH == 0 IS still
//    reachable (h == 0 with every leg declaring amountIn == 0; or a bridge
//    hop that received nothing), but in both cases there is no value to
//    charge and the swap dies later at the terminal totalReceived == 0 check.
//    If the line were deleted, _payFee(token, 0) transfers nothing (both
//    split legs are > 0-guarded) and `feeH >= amountIn` cannot fire with
//    feeH == 0 and amountIn > 0 — the only observable difference is a
//    Fee(token, 0, 0, 0) event. A test asserting a revert or a balance here
//    would be theatre. Right answer: keep it as the cheap early-out it now
//    is, or replace with `if (baseH == 0) return amountIn;` for clarity —
//    an owner call, recorded here instead of papered over.
//
//  * Router:527 (classic-door `received == 0`) — deliberately NOT tested.
//    Unlike the permit2/native/best doors, `_swap` calls _execute directly
//    with no amountIn re-check, and a deleted guard still ends in the SAME
//    RouterE(8) at the terminal totalReceived == 0 check, with no tokens
//    moved. A test here passes with the guard deleted — theatre by this
//    file's own criterion. The refusal CLASS is pinned by the three sibling
//    doors, each of which flips selector on deletion.
//
//  forge test --match-contract RouterRefusalsObserved -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

/// @dev A "WETH" whose deposit() swallows ETH and credits nothing — the
///      exact shape Router:445 exists to refuse: the wrap succeeded as a
///      call, the measured balance delta is zero.
contract ZeroCreditWETH {
    function deposit() external payable {}
    function balanceOf(address) external pure returns (uint256) { return 0; }
}

contract RouterRefusalsObservedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;      // honest input token
    MockERC20 tokenB;      // destination AND a registered bridge coin
    MockERC20 taxAll;      // 100% fee-on-transfer: every transfer delivers 0
    MockV3Pool pool;       // tokenA/tokenB, price 1.0
    MockV2Pair pairTiny;   // tokenA/tokenB, reserves (2, 2) — prices to 1 wei
    MockV2Pair pairFot;    // taxAll/tokenB — gives the Solver a plan to find
    MockPermit2 permit2;
    ZeroCreditWETH badWeth;

    address user     = address(0xBEEF);
    address stranger = address(0xBAD);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    // Pinned from BPC (blind-constant law: the thresholds below derive from
    // these and this file must break if either silently changes).
    uint256 constant PROTOCOL_FEE_BPS = BPC.PROTOCOL_FEE_BPS; // 28
    uint256 constant BPS              = BPC.BPS;              // 10_000

    uint128 constant LIQ       = 1_000_000e18;
    uint24  constant POOL_FEE  = 3000;
    uint256 constant AMT       = 10_000e18;

    bool zfoV3;
    bool zfoTiny;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        taxAll = new MockERC20("TAX", "TAX");

        // tokenB is a bridge coin: a single-hop route INTO it takes the fee
        // out of the OUTPUT (feeOnOut), which is the only honest-token path
        // on which `delivered` and `amountOut` differ — see the header.
        hub.addBridge(address(tokenB));

        pool = new MockV3Pool(address(tokenA), address(tokenB), POOL_FEE);
        pool.setState(uint160(BPC.Q96), LIQ); // price 1.0
        tokenB.mint(address(pool), 1_000_000e18);
        hub.seedPool(address(pool), BPC.KIND_V3, POOL_FEE, address(0), address(tokenA), address(tokenB));
        zfoV3 = pool.token0() == address(tokenA);

        // Reserves of (2, 2): outV2 can deliver at most 1 wei, whatever goes in.
        pairTiny = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(pairTiny), 2);
        tokenB.mint(address(pairTiny), 2);
        pairTiny.setReserves(2, 2);
        zfoTiny = pairTiny.token0() == address(tokenA);

        // A real, healthy pair for the FoT token so the on-chain Solver finds
        // a plan — the refusal under test is at the PULL, after the plan.
        pairFot = new MockV2Pair(address(taxAll), address(tokenB));
        taxAll.mint(address(pairFot), 1_000_000e18);
        tokenB.mint(address(pairFot), 1_000_000e18);
        // Symmetric reserves, so the (token0, token1) sort cannot mis-assign.
        pairFot.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        hub.seedPool(address(pairFot), BPC.KIND_V2, 30, address(0), address(taxAll), address(tokenB));

        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));
        badWeth = new ZeroCreditWETH();
        router.setWeth(address(badWeth));

        tokenA.mint(user, 10_000_000e18);
        taxAll.mint(user, 1_000_000e18);
        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        taxAll.approve(address(router), type(uint256).max);
        taxAll.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        // Minting is a direct balance write, so the 100% tax is armed only
        // AFTER all funding above. From here on, every transfer of taxAll
        // (transfer and transferFrom alike) returns true and delivers zero.
        taxAll.setFeeOnTransferBps(uint16(BPS));
    }

    // ─── route builders ──────────────────────────────────────────────────────

    function _oneLegRoute(
        address tIn, address tOut, address p, uint8 kind, uint24 fee, bool zfo, uint256 amountIn
    ) internal pure returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: p, hooks: address(0), kind: kind, fee: fee,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: tIn, tokenOut: tOut,
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _v3Route(uint256 amountIn) internal view returns (Route memory) {
        return _oneLegRoute(address(tokenA), address(tokenB), address(pool),
            BPC.KIND_V3, POOL_FEE, zfoV3, amountIn);
    }

    /// @dev Gross output, fee-on-output and net — computed with the SAME
    ///      formulas the pool mock and the Router use, so the numbers are
    ///      exact, not approximate.
    function _grossFeeNet(uint256 amountIn)
        internal view returns (uint256 gross, uint256 fOut, uint256 net)
    {
        gross = BPC.outV3(amountIn, uint160(BPC.Q96), LIQ, POOL_FEE, zfoV3, 0);
        fOut  = BPC.mulDivUp(gross, PROTOCOL_FEE_BPS, BPS);
        net   = gross - fOut;
    }

    // =========================================================================
    //  1. Router:1345 — `delivered < userMinOut` (A1, the delivery half)
    // =========================================================================

    /// The user's own slippage bound, enforced on what the recipient ACTUALLY
    /// receives. Route: tokenA -> tokenB where tokenB is a bridge, so the
    /// protocol fee comes out of the OUTPUT after the aggregate floor already
    /// passed on the gross amount. userMinOut = net + 1: one wei more than
    /// what can be delivered.
    ///
    /// WHY THIS FIRES 1345 AND NOT THE EARLIER RouterE(5): the aggregate
    /// check compares amountOut (gross) >= effMin (net + 1), which holds as
    /// long as fOut >= 1. The only comparison left that can refuse is the
    /// delivered-net one.
    ///
    /// DELETION-SENSITIVE: with Router:1345 removed, the swap completes and
    /// returns `delivered`; expectRevert fails. This is the test A1 never had.
    function test_MinOut_DeliveredShortfallIsRefused() public {
        (uint256 gross, uint256 fOut, uint256 net) = _grossFeeNet(AMT);
        assertGt(fOut, 1, "sanity: the output-side fee is real");
        assertGt(net, 0, "sanity: something is deliverable");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(_v3Route(AMT), AMT, net + 1, user, block.timestamp + 1);

        // Nothing moved: refusal means refusal.
        assertEq(tokenB.balanceOf(user), 0, "a refused swap must deliver nothing");
        assertEq(gross - fOut, net, "arithmetic identity, pinned");
    }

    /// The boundary, from the other side: userMinOut == net delivers, exactly
    /// net, and the treasuries receive exactly fOut — in tokenB, with not one
    /// wei charged on the input side. One wei of userMinOut is the whole
    /// distance between this test and the refusal above.
    ///
    /// DELETION-SENSITIVE in the opposite direction: if the guard's `<` ever
    /// became `<=` (or the fee arithmetic drifted by a wei), this exact-value
    /// control breaks.
    function test_MinOut_Boundary_ExactNetDelivers() public {
        (, uint256 fOut, uint256 net) = _grossFeeNet(AMT);

        vm.prank(user);
        uint256 got = router.swapExactIn(_v3Route(AMT), AMT, net, user, block.timestamp + 1);

        assertEq(got, net, "the returned amount is the delivered net");
        assertEq(tokenB.balanceOf(user), net, "the user holds exactly the net");
        assertEq(tokenB.balanceOf(T1) + tokenB.balanceOf(T2), fOut,
            "the treasuries hold exactly the output-side fee");
        assertEq(tokenA.balanceOf(T1) + tokenA.balanceOf(T2), 0,
            "feeOnOut means NO input-side charge - one fee, one side");
    }

    // =========================================================================
    //  2. Router:1328 — `fOut >= amountOut` (fee would consume the output)
    // =========================================================================

    /// A route into a bridge coin that produces exactly 1 wei of output:
    /// reserves (2, 2) price ANY input to at most 1 wei, and
    /// mulDivUp(1, 28, 10_000) == 1 — the protocol fee IS the entire output.
    /// The Router must refuse rather than deliver zero or pay itself the
    /// user's whole proceeds.
    ///
    /// DELETION-SENSITIVE VIA THE SELECTOR: with Router:1328 removed, _payFee
    /// takes the 1 wei, net becomes 0, and the delivered-vs-userMinOut guard
    /// (1345) kills the tx with RouterE(5) instead. Only the selector-specific
    /// assertion distinguishes the two — a bare expectRevert would pass either
    /// way, which is exactly why the house bans it.
    function test_FeeOnOut_OneWeiOutputWhollyConsumedIsRefused() public {
        // The arithmetic, stated plainly.
        assertEq(BPC.outV2(1000, 2, 2, 30), 1, "reserves (2,2) price 1000 wei in to 1 wei out");
        assertEq(BPC.mulDivUp(1, PROTOCOL_FEE_BPS, BPS), 1, "the fee on 1 wei is the whole wei");

        Route memory r = _oneLegRoute(address(tokenA), address(tokenB),
            address(pairTiny), BPC.KIND_V2, 30, zfoTiny, 1000);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8));
        router.swapExactIn(r, 1000, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  3. received == 0 — three doors, each with a selector-flipping deletion
    // =========================================================================

    /// Permit2 door (Router:392). The pull "succeeds" (transferFrom returns
    /// true) and delivers nothing — a 100% fee-on-transfer token. The door
    /// must refuse with RouterE(8) BEFORE executing a zero-value route.
    ///
    /// DELETION-SENSITIVE: without the guard, _noteFot(0) runs and
    /// _swapPrePulled refuses the zero amountIn with RouterE(3) — a different
    /// selector, so this assertion fails.
    function test_Received_PermitPullDeliveringZeroIsRefused() public {
        Route memory r = _oneLegRoute(address(taxAll), address(tokenB),
            address(pairFot), BPC.KIND_V2, 30, pairFot.token0() == address(taxAll), AMT);
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(taxAll), amount: AMT }),
            nonce: 0,
            deadline: block.timestamp + 1
        });

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8));
        router.swapExactInWithPermit2(r, AMT, 1, user, block.timestamp + 1, permit, "");
    }

    /// Native door (Router:445). deposit() accepted the ETH; the measured
    /// WETH delta is zero. The user's ETH is gone into the "WETH" — the swap
    /// must NOT proceed on a zero balance and must say so as a swap failure.
    ///
    /// DELETION-SENSITIVE: without the guard, _swapPrePulled refuses the zero
    /// amountIn with RouterE(3); the selector assertion fails.
    function test_Received_NativeWrapCreditingZeroIsRefused() public {
        Route memory r = _oneLegRoute(address(badWeth), address(tokenB),
            address(pool), BPC.KIND_V3, POOL_FEE, true, 1 ether);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8));
        router.swapExactInNative{value: 1 ether}(r, 1, user, block.timestamp + 1);
    }

    /// Fully-on-chain door (Router:481). The Solver finds a real plan for the
    /// taxed token (the pair is healthy; planning only reads), and the pull
    /// then delivers zero. The refusal must land at the measured receive.
    ///
    /// DELETION-SENSITIVE: without the guard, selfExecutePrePulled ->
    /// _swapPrePulled refuses the zero amountIn with RouterE(3); the selector
    /// assertion fails.
    function test_Received_BestDoorPullDeliveringZeroIsRefused() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8));
        router.swapBestExactIn(address(taxAll), address(tokenB), AMT, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  4. Router:546 — deadline, both sides of the strict inequality
    // =========================================================================

    /// DELETION-SENSITIVE: the route is fully valid and funded, so with the
    /// guard removed the expired swap SUCCEEDS and expectRevert fails. (The
    /// existing suite asserts the expired half on a hub with no roles wired;
    /// this one also pins the boundary: `>` is strict, so a deadline of
    /// exactly block.timestamp still executes.)
    function test_Deadline_ExpiredRefusedAndBoundaryHolds() public {
        vm.warp(1000);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 4));
        router.swapExactIn(_v3Route(AMT), AMT, 1, user, 999);

        // Boundary: deadline == now is NOT expired.
        vm.prank(user);
        uint256 got = router.swapExactIn(_v3Route(AMT), AMT, 1, user, 1000);
        assertGt(got, 0, "deadline == block.timestamp must still execute (strict >)");
    }

    // =========================================================================
    //  5. Router:260 — the control surface, enumerated ONCE, completely
    // =========================================================================

    /// Every onlyControl door refuses a stranger with RouterE(1). One test,
    /// all nine doors, so an access-control regression on ANY of them cannot
    /// pass the suite silently. (Router:257 `onlyAdmin` is not here because
    /// it CANNOT be here: it has no call site — see the file header.)
    ///
    /// DELETION-SENSITIVE: remove the modifier's body and the stranger's call
    /// succeeds; the corresponding expectRevert fails.
    function test_Control_EveryControlDoorRefusesAStranger() public {
        bytes memory e1 = abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1);
        vm.startPrank(stranger);

        vm.expectRevert(e1); router.setAdmin(stranger);
        vm.expectRevert(e1); router.setTreasuries(stranger, stranger);
        vm.expectRevert(e1); router.setPermit2(stranger);
        vm.expectRevert(e1); router.setWeth(stranger);
        vm.expectRevert(e1); router.setPaused(true);
        vm.expectRevert(e1); router.renounceControl();
        vm.expectRevert(e1); router.queueRescue(address(tokenA), stranger);
        vm.expectRevert(e1); router.cancelRescue(address(tokenA), stranger);
        vm.expectRevert(e1); router.executeRescue(address(tokenA), stranger);

        vm.stopPrank();

        // And the privileged caller is NOT refused — the positive halves for
        // setWeth/setPermit2 are already proven live by this file's own setUp
        // (the native and permit2 door tests only work because those calls
        // took effect); setAdmin/setTreasuries/setPaused positives live in
        // BlazePhoenixRouter.t.sol. Here: the rescue trio end-to-end.
        router.queueRescue(address(tokenA), address(0xD0));
        router.cancelRescue(address(tokenA), address(0xD0));
    }

    /// renounceControl must freeze the WHOLE control surface. The existing
    /// lockout test covers setAdmin/setTreasuries/setPermit2/setPaused/
    /// renounceControl; these three doors were left out of it, and a door
    /// missing from the lockout test is a door whose regression ships.
    function test_Control_RenounceFreezesTheDoorsNoOtherTestFreezes() public {
        router.renounceControl();
        bytes memory e1 = abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1);

        vm.expectRevert(e1); router.setWeth(address(0xD1));
        vm.expectRevert(e1); router.queueRescue(address(tokenA), address(0xD1));
        vm.expectRevert(e1); router.cancelRescue(address(tokenA), address(0xD1));
    }
}
