// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  H-02 — the output side must measure a DELTA, never a raw balance.
//
//  WHY this test exists: _execute always took a pre-swap baseline on the INPUT
//  side (tinStart) but read the raw tokenOut balance on the output side. The
//  two sides therefore disagreed about what "this swap produced". Any tokenOut
//  the Router already held — a mis-sent transfer, an airdrop, dust from a
//  non-conforming pool — was counted as this swap's proceeds and, sitting above
//  the on-chain quote, was classified as SURPLUS: fee-exempt and paid out whole
//  to whoever swapped first. The Router holds no user funds at rest, so the ONLY
//  thing that balance can be is someone else's money, and the 48h timelocked
//  rescue (queueRescue / executeRescue, see test/RouterRescue.t.sol) exists
//  precisely to give it back. A raw-balance read made that rescue unexecutable
//  for any token anyone routes through: the first swapper always drained it
//  first. That is why this is a fund-loss finding and not an accounting nit.
//
//  The fix introduced toutStart and measures totalReceived as a delta. Both
//  tests below are written so the load-bearing assertion IS the behavioural
//  difference — they fail against the pre-fix revision and pass with it.
//
//  forge test --match-contract RouterOutputDeltaNotBalance -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RouterOutputDeltaNotBalanceTest is Test {
    // Harness mirrors test/BlazePhoenixRouter.t.sol / test/RouterExecutionProof.t.sol.
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);
    address rescueTo = address(0xD00D);

    // Deep pools on purpose: with ~0.1% impact per hop the A->B->A round trip in
    // test 2 returns visibly LESS than it consumed, so "user got back more than
    // they put in" is an unambiguous signal that a foreign balance leaked out.
    uint112 internal constant RESERVE = 1_000_000e18;
    uint256 internal constant AMOUNT_IN = 1_000e18;
    // Someone else's money, already sitting in the Router before anyone swaps.
    uint256 internal constant STUCK = 250e18;
    uint16 internal constant PROTOCOL_FEE_BPS = 28;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );

        tokenIn.mint(address(pair), RESERVE);
        tokenOut.mint(address(pair), RESERVE);
        pair.setReserves(RESERVE, RESERVE);

        tokenIn.mint(user, 3_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _buildRoute(uint256 amountIn, uint256 claimedTotalOut) private view returns (Route memory route) {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: amountIn, expectedOut: claimedTotalOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: claimedTotalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedTotalOut, singleOut: claimedTotalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @dev A Surplus event is the exact mechanism by which the stray balance
    ///      escaped: anything above the on-chain quote is fee-exempt and paid
    ///      out in full. An honest single-hop V2 swap quotes and realises the
    ///      SAME number (_execV2Amt and _hopScaleImpactAndQuote both call
    ///      BPC.outV2 on the same pre-transfer reserves), so a truthful surplus
    ///      here is exactly zero — any Surplus log is the leak itself.
    function _surplusLogged(Vm.Log[] memory logs, address token) private pure returns (uint256 amount) {
        bytes32 sig = keccak256("Surplus(address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != token) continue;
            amount += abi.decode(logs[i].data, (uint256));
        }
    }

    // =========================================================================
    //  1. The regression proper
    // =========================================================================

    /// @notice A tokenOut balance the Router already held must NOT be paid to
    ///         the next swapper. The user takes home their own swap's output
    ///         and nothing else; the stray balance is still there afterwards,
    ///         to the wei, waiting for the rescue path that owns it.

    /// @dev A fee do protocolo passou a ser cobrada na ENTRADA (2026-08-21): 28 bps do input
    ///      comprometido, em tokenIn, antes de a rota comecar. Logo a rota preca sobre o LIQUIDO.
    ///      Ver test/FeeEscapeViaBridgeResidual.t.sol para a razao da mudanca.
    function _netIn(uint256 a) internal pure returns (uint256) { return a - (a * 28) / 10_000; }

    function test_PreExistingTokenOut_IsNotPaidToTheNextSwapper() public {
        // Someone mis-sends tokenOut to the Router (or a token airdrops it).
        // The Router holds nothing at rest, so this is by definition not ours.
        tokenOut.mint(address(router), STUCK);

        // An entirely ordinary, honest swap — no crafted route, no hostile
        // pool. The attack needs nothing more than being first.
        uint256 realQuote = BPC.outV2(_netIn(AMOUNT_IN), RESERVE, RESERVE, 30);
        assertGt(realQuote, 0);
        Route memory route = _buildRoute(AMOUNT_IN, realQuote);

        vm.recordLogs();
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, AMOUNT_IN, 1, user, block.timestamp + 1);

        // The fee is charged on the on-chain quote of the legs as executed,
        // which for this route equals the realised output exactly.
        // A fee ja foi cobrada na ENTRADA: a saida nao leva corte nenhum.
        uint256 expectedFee = 0;

        // (a) The user receives ONLY the output of their own swap.
        assertEq(delivered, realQuote - expectedFee, "user paid from a foreign balance");
        assertEq(tokenOut.balanceOf(user), realQuote - expectedFee, "recipient balance must match");

        // (b) The Router still holds the pre-existing amount — not a wei more
        //     (nothing of this swap stranded), not a wei less (nothing of the
        //     stray balance leaked). This is the assertion the pre-fix revision
        //     cannot satisfy: reading the raw balance paid everything out and
        //     left the Router on zero.
        assertEq(tokenOut.balanceOf(address(router)), STUCK, "stray balance must be untouched");

        // Fee accounting is unchanged by the fix: the fee base was already
        // clamped to the on-chain quote, so the stray balance was pure
        // fee-EXEMPT surplus. Pinning it here proves the fix narrowed the
        // payout without quietly widening the fee.
        assertEq(tokenOut.balanceOf(treasury1) + tokenOut.balanceOf(treasury2), expectedFee, "fee unchanged");

        // No surplus exists on an honest swap; under the bug the stray balance
        // was emitted here and handed over untaxed.
        assertEq(
            _surplusLogged(vm.getRecordedLogs(), address(tokenOut)), 0,
            "no fee-exempt surplus may be conjured"
        );

        // Spell out what the pre-fix revision would have delivered, so this
        // test documents the bug and not merely the current numbers.
        uint256 preFixDelivered = realQuote + STUCK - expectedFee;
        assertLt(delivered, preFixDelivered, "must not deliver the pre-fix, balance-based amount");

        // The whole point: the 48h rescue is executable again, and it returns
        // exactly the mis-sent amount to its owner.
        router.queueRescue(address(tokenOut), rescueTo);
        vm.warp(block.timestamp + 48 hours);
        router.executeRescue(address(tokenOut), rescueTo);
        assertEq(tokenOut.balanceOf(rescueTo), STUCK, "rescue must recover the full mis-sent amount");
        assertEq(tokenOut.balanceOf(address(router)), 0, "Router holds nothing at rest");
    }

    // =========================================================================
    //  2. The degenerate case: tokenIn == tokenOut
    // =========================================================================

    /// @notice Round trip A -> B -> A, so the entry token and the exit token
    ///         are the same. This is the case a naive delta breaks on: at the
    ///         time the baseline is taken the Router's A balance ALREADY holds
    ///         this swap's amountIn, so a raw `balanceOf(tokenOut)` baseline
    ///         would count amountIn on both sides — subtracting it twice — and
    ///         the checked subtraction at the end would revert on underflow the
    ///         moment the round trip returns less A than it consumed, which is
    ///         always (two pool fees). The fix reuses the same pre-existing
    ///         remainder the input sweep uses, `tinStart - amountIn`, so the
    ///         stray balance is subtracted exactly once and the input sweep is
    ///         skipped for this token.
    function test_Degenerate_TokenInEqualsTokenOut_NoDoubleSubtractNoUnderflow() public {
        // Here tokenOut is only the BRIDGE; the route's exit token is tokenIn,
        // so that is where the stray balance has to sit to exercise the branch.
        tokenIn.mint(address(router), STUCK);

        // Second pool for the return leg, so each hop prices against clean
        // reserves. Both pools are (tokenIn, tokenOut); MockV2Pair sorts its
        // own token0/token1, and symmetric reserves make the ordering moot.
        MockV2Pair pairBack = new MockV2Pair(address(tokenIn), address(tokenOut));
        tokenIn.mint(address(pairBack), RESERVE);
        tokenOut.mint(address(pairBack), RESERVE);
        pairBack.setReserves(RESERVE, RESERVE);

        bool zfo0 = address(tokenIn) == pair.token0();
        bool zfo1 = address(tokenOut) == pairBack.token0();

        Leg[] memory legs0 = new Leg[](1);
        legs0[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo0, stable: false,
            amountIn: AMOUNT_IN, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs1 = new Leg[](1);
        legs1[0] = Leg({
            pool: address(pairBack), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo1, stable: false,
            amountIn: AMOUNT_IN, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: AMOUNT_IN, expectedOut: 0, legs: legs0
        });
        hops[1] = Hop({
            tokenIn: address(tokenOut), tokenOut: address(tokenIn),
            amountIn: AMOUNT_IN, expectedOut: 0, legs: legs1
        });
        // expectedOut left at 0 on both hops so the per-leg floor fails open
        // (same convention as test/RouterAdversarialMultiHopFromV1.t.sol): this
        // test is about the baseline arithmetic, and an attested quote here
        // would only add a second, unrelated reason to revert. The on-chain
        // protocol floor and userMinOut still apply.
        Route memory route = Route({
            hops: hops, totalOut: 0, singleOut: 0,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        uint256 userBefore = tokenIn.balanceOf(user);

        // Two distinct failure modes are pinned by this one call. The pre-fix
        // revision RETURNS, but hands the user the stray balance on top (caught
        // by the assertions below). A fix that added toutStart WITHOUT the
        // tokenIn == tokenOut branch would instead REVERT here: its baseline
        // would include this swap's own amountIn, and the round trip always
        // comes back under that, underflowing the checked subtraction. So
        // reaching the next line at all is already half the assertion.
        vm.recordLogs();
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, AMOUNT_IN, 1, user, block.timestamp + 1);

        // The stray balance survived the round trip untouched — the reason this
        // case needs its own branch at all.
        assertEq(tokenIn.balanceOf(address(router)), STUCK, "stray balance must be untouched");
        assertEq(tokenOut.balanceOf(address(router)), 0, "bridge token fully consumed");

        // A round trip through two fee-charging pools can only LOSE value. If
        // the user comes out ahead, the surplus came from the stray balance:
        // this is the pre-fix behaviour, expressed without depending on the
        // exact pool math.
        assertGt(delivered, 0, "round trip must produce output");
        assertLt(delivered, AMOUNT_IN, "a round trip cannot be profitable");
        assertEq(tokenIn.balanceOf(user), userBefore - AMOUNT_IN + delivered, "user delta must be the swap alone");

        // Neither the stray balance nor a double-counted amountIn may surface
        // as fee-exempt surplus.
        assertEq(
            _surplusLogged(vm.getRecordedLogs(), address(tokenIn)), 0,
            "no fee-exempt surplus may be conjured on the degenerate route"
        );

        // And the rescue path still owns the stray balance afterwards.
        router.queueRescue(address(tokenIn), rescueTo);
        vm.warp(block.timestamp + 48 hours);
        router.executeRescue(address(tokenIn), rescueTo);
        assertEq(tokenIn.balanceOf(rescueTo), STUCK, "rescue must recover the full mis-sent amount");
    }
}
