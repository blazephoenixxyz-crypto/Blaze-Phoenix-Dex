// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  swapBestExactIn — the fully-on-chain route entry (Solver discovery inside
//  the swap tx, note 106) had ZERO direct tests before this file. Four
//  dimensions, mirroring the harness idiom of RouterExecutionProof /
//  BlazePhoenixQuoter tests:
//
//    1. entry guards — RouterE(3)/RouterE(10) fire in the documented order;
//    2. reentrancy — the token PULL happens while the transient lock is
//       already held (unlike swapExactIn, the Solver plan runs first), so the
//       most realistic vector is a token whose transferFrom reenters either
//       swapBestExactIn itself or the selfExecutePrePulled bridge;
//    3. bridge privilege — selfExecutePrePulled is deliberately NOT nrEntrant
//       (the outer entry holds the lock), so its self-only RouterE(1) check
//       is the ONLY thing standing between any caller and a pre-pulled swap;
//    4. quote↔execution parity — previewPlanExact's dry-run vs the delivered
//       amount, fuzzed. This is the protocol's core promise (the historical
//       bug class was precisely quote != execution) pinned end-to-end through
//       the same Solver plan both sides use.
//
//  forge test --match-contract SwapBestExactInHardening -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MaliciousReentrantERC20} from "./mocks/MaliciousReentrantERC20.sol";

contract SwapBestExactInHardeningTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV2Pair pair;

    address user = address(0xBEEF);

    uint112 constant R_A = 1_000_000e18;
    uint112 constant R_B = 1_600_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pair = _seedV2(address(tokenA), address(tokenB), R_A, R_B);

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _seedV2(address tX, address tY, uint256 reserveX, uint256 reserveY)
        internal returns (MockV2Pair p)
    {
        p = new MockV2Pair(tX, tY);
        MockERC20(tX).mint(address(p), reserveX);
        MockERC20(tY).mint(address(p), reserveY);
        (address t0, ) = tX < tY ? (tX, tY) : (tY, tX);
        p.setReserves(
            uint112(tX == t0 ? reserveX : reserveY),
            uint112(tX == t0 ? reserveY : reserveX)
        );
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tX, tY);
    }

    // ─── 1. entry guards ─────────────────────────────────────────────────────

    function test_Guards_ZeroAmount_Reverts3() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3));
        vm.prank(user);
        router.swapBestExactIn(address(tokenA), address(tokenB), 0, 1, user, block.timestamp + 1);
    }

    function test_Guards_OversizeAmount_Reverts3() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3));
        vm.prank(user);
        router.swapBestExactIn(
            address(tokenA), address(tokenB),
            uint256(type(uint128).max) + 1, 1, user, block.timestamp + 1);
    }

    function test_Guards_ZeroMinOut_Reverts10() public {
        // userMinOut == 0 is rejected up front: the caller must always carry
        // their own slippage bound into the on-chain-discovered route.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 10));
        vm.prank(user);
        router.swapBestExactIn(address(tokenA), address(tokenB), 1e18, 0, user, block.timestamp + 1);
    }

    function test_Guards_NoRoute_FailsClosed() public {
        // A token the Hub has never seen: findBestRoutePlan cannot build a
        // plan, and the entry must revert rather than pull funds.
        MockERC20 stray = new MockERC20("S", "S");
        stray.mint(user, 10e18);
        vm.startPrank(user);
        stray.approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.swapBestExactIn(address(stray), address(tokenB), 1e18, 1, user, block.timestamp + 1);
        vm.stopPrank();
        assertEq(stray.balanceOf(user), 10e18, "failed discovery must never move funds");
    }

    // ─── 2. reentrancy through the token pull (lock already held) ────────────

    function _seedEvilPool() internal returns (MaliciousReentrantERC20 evil) {
        evil = new MaliciousReentrantERC20();
        MockV2Pair pe = new MockV2Pair(address(evil), address(tokenB));
        evil.mint(address(pe), 500_000e18);
        tokenB.mint(address(pe), 500_000e18);
        (address t0, ) = address(evil) < address(tokenB)
            ? (address(evil), address(tokenB)) : (address(tokenB), address(evil));
        pe.setReserves(
            uint112(address(evil) == t0 ? 500_000e18 : 500_000e18),
            uint112(500_000e18)
        );
        hub.seedPool(address(pe), BPC.KIND_V2, 30, address(0), address(evil), address(tokenB));
        evil.mint(user, 10_000e18);
        vm.prank(user);
        evil.approve(address(router), type(uint256).max);
    }

    function test_Reentrancy_NestedBestEntry_BlockedByTransientLock() public {
        MaliciousReentrantERC20 evil = _seedEvilPool();
        evil.setAttack(
            address(router),
            abi.encodeCall(
                router.swapBestExactIn,
                (address(evil), address(tokenB), 1e18, 1, user, block.timestamp + 1))
        );

        vm.prank(user);
        uint256 delivered = router.swapBestExactIn(
            address(evil), address(tokenB), 100e18, 1, user, block.timestamp + 1);

        assertGt(delivered, 0, "outer swap must complete");
        assertTrue(evil.lastReentryAttempted(), "attack must actually have fired");
        assertTrue(
            evil.lastReentryReverted(),
            "nested swapBestExactIn during the pull must trip the transient lock (RouterE(7))"
        );
    }

    function test_Reentrancy_BridgeHijack_BlockedBySelfOnly() public {
        // Mid-pull, the token tries to call selfExecutePrePulled directly with
        // a crafted route: the Router already holds funds at that instant, and
        // the bridge is NOT nrEntrant — only its msg.sender == address(this)
        // check stands. Prove it holds from inside a live swap.
        MaliciousReentrantERC20 evil = _seedEvilPool();
        Route memory crafted; // empty route: RouterE(1) must fire before any decoding
        evil.setAttack(
            address(router),
            abi.encodeCall(
                router.selfExecutePrePulled,
                (crafted, 1e18, 1, address(0xBAD), block.timestamp + 1, address(0xBAD)))
        );

        vm.prank(user);
        uint256 delivered = router.swapBestExactIn(
            address(evil), address(tokenB), 100e18, 1, user, block.timestamp + 1);

        assertGt(delivered, 0, "outer swap must complete");
        assertTrue(evil.lastReentryAttempted(), "attack must actually have fired");
        assertTrue(
            evil.lastReentryReverted(),
            "selfExecutePrePulled from a non-self caller must revert RouterE(1) even mid-swap"
        );
    }

    // ─── 3. bridge privilege from cold state ─────────────────────────────────

    function test_SelfExecutePrePulled_OnlySelf_ColdState() public {
        Route memory crafted;
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        vm.prank(user);
        router.selfExecutePrePulled(crafted, 1e18, 1, user, block.timestamp + 1, user);
    }

    // ─── 4. quote ↔ execution parity (the core promise, fuzzed) ──────────────

    function testFuzz_Parity_PreviewExactVsDelivered(uint96 amtSeed) public {
        // ≤ ~10% of the A reserve keeps the walk inside the pool's sane range
        // (the Solver's capacity clamp stays out of the way, so preview and
        // execution plan over identical state).
        uint256 amountIn = bound(uint256(amtSeed), 1e15, 100_000e18);

        (, uint256 exactOut) =
            quoter.previewPlanExact(address(tokenA), address(tokenB), amountIn);
        assertGt(exactOut, 0, "preview must quote a live pool");

        uint256 userBBefore = tokenB.balanceOf(user);
        vm.prank(user);
        uint256 delivered = router.swapBestExactIn(
            address(tokenA), address(tokenB), amountIn, 1, user, block.timestamp + 1);

        // The dry-run is raw pool math; execution charges PROTOCOL_FEE_BPS
        // (28 bps) on the way out. Parity band: delivered can never exceed
        // the pool-math ceiling, and can never fall more than 1% below it
        // (28 bps fee + rounding headroom). A break on either side is a
        // real quote!=execution regression, not tolerance noise.
        assertLe(delivered, exactOut, "delivered above the pool-math ceiling");
        assertGe(
            delivered,
            BPC.mulDiv(exactOut, 9_900, BPC.BPS),
            "delivered fell >1% below the exact preview"
        );

        assertEq(
            tokenB.balanceOf(user) - userBBefore, delivered,
            "recipient must receive exactly the returned amount"
        );
    }

    /// @notice Same parity, pinned at a fixed size so a regression bisects
    ///         cleanly (fuzz shrinkage not required to reproduce).
    function test_Parity_PreviewExactVsDelivered_Pinned() public {
        uint256 amountIn = 1_000e18;
        (, uint256 exactOut) =
            quoter.previewPlanExact(address(tokenA), address(tokenB), amountIn);
        assertEq(exactOut, BPC.outV2(amountIn, R_A, R_B, 30), "preview == V2 formula");

        vm.prank(user);
        uint256 delivered = router.swapBestExactIn(
            address(tokenA), address(tokenB), amountIn, 1, user, block.timestamp + 1);

        assertLe(delivered, exactOut);
        assertGe(delivered, BPC.mulDiv(exactOut, 9_900, BPC.BPS));
    }
}
