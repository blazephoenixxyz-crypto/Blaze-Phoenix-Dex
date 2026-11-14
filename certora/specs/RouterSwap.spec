/*
 * Certora CVL - Router swap doors: refusals, pause, delivery, holds-nothing.
 * Target: BlazePhoenixRouter through certora/harness/RouterHarness.sol;
 * tokA = DummyERC20A (tokenIn), tokB = DummyERC20B (tokenOut).
 * Run one rule per job (`--rule`, see .github/workflows/security.yml).
 *
 * Venue model: every external call the scene cannot resolve (pools, the V4 PoolManager,
 * WETH, Permit2) is HAVOC_ECF: it may change the storage of any OTHER contract, token
 * balances included, and it cannot reenter the Router. Hub calls are NONDET (views and the
 * recordSwap telemetry). A NONDET venue would be vacuous here: it never delivers tokB, so
 * every swap with userMinOut > 0 reverts at `amountOut < effMin`.
 * Known model artifact: the havoc can debit the recipient's tokB without an allowance,
 * which no ERC20 allows. A counterexample to S4 of that shape is the model, not the Router.
 */

using DummyERC20A as tokA;
using DummyERC20B as tokB;

methods {
    function paused() external returns (bool) envfree;
    function weth() external returns (address) envfree;
    function owed(address, uint256) external returns (uint256) envfree;
    function tokA.balanceOf(address) external returns (uint256) envfree;
    function tokB.balanceOf(address) external returns (uint256) envfree;

    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.transferFrom(address, address, uint256) external => DISPATCHER(true);
    function _.balanceOf(address) external => DISPATCHER(true);

    function _.recordSwap(address, uint8, uint24, address, address, address, uint256, uint256, uint256) external => NONDET;
    function _.v4PoolManager() external => NONDET;
    function _.isHookLive(address) external => NONDET;
    function _.hookPaused(address) external => NONDET;
    function _.bridge(uint8) external => NONDET;
    function _.isBridgeToken(address) external => NONDET;

    unresolved external in _._ => DISPATCH [] default HAVOC_ECF;
}

/// Methods that are not swap doors: control plane, views, callbacks.
definition NOT_A_DOOR(method f) returns bool =
    f.isView || f.isFallback
    || f.selector == sig:unlockCallback(bytes).selector
    || f.selector == sig:setAdmin(address).selector
    || f.selector == sig:setTreasuries(address, address).selector
    || f.selector == sig:moveTreasury(address).selector
    || f.selector == sig:claimFee(address).selector
    || f.selector == sig:setPermit2(address).selector
    || f.selector == sig:setWeth(address).selector
    || f.selector == sig:setPaused(bool).selector
    || f.selector == sig:renounceControl().selector
    || f.selector == sig:queueRescue(address, address).selector
    || f.selector == sig:cancelRescue(address, address).selector
    || f.selector == sig:executeRescue(address, address).selector;

/// S1. A zero userMinOut with a non-zero input is refused at every door that takes userMinOut.
/// Mutants: delete Router:482 (swapExactIn), :549 (Native), :586 (Best).
rule zeroMinOutRefused(env e, uint8 door, RouterHarness.Route route, uint256 amountIn,
                       address tokenIn, address tokenOut, address recipient, uint256 deadline) {
    if (door == 0) {
        require amountIn > 0;
        swapExactIn@withrevert(e, route, amountIn, 0, recipient, deadline);
    } else if (door == 1) {
        require e.msg.value > 0;
        swapExactInNative@withrevert(e, route, 0, recipient, deadline);
    } else {
        require amountIn > 0;
        swapBestExactIn@withrevert(e, tokenIn, tokenOut, amountIn, 0, recipient, deadline);
    }
    assert lastReverted;
}

/// S2. An input above 2^128 - 1 is refused.
/// Mutants: delete Router:481 (swapExactIn), the `amountIn > type(uint128).max` term at
/// :548 (Native) and :585 (Best).
rule amountInAboveU128Refused(env e, uint8 door, RouterHarness.Route route, uint256 amountIn,
                              uint256 minOut, address tokenIn, address tokenOut,
                              address recipient, uint256 deadline) {
    if (door == 0) {
        require amountIn > max_uint128;
        swapExactIn@withrevert(e, route, amountIn, minOut, recipient, deadline);
    } else if (door == 1) {
        require e.msg.value > max_uint128;
        swapExactInNative@withrevert(e, route, minOut, recipient, deadline);
    } else {
        require amountIn > max_uint128;
        swapBestExactIn@withrevert(e, tokenIn, tokenOut, amountIn, minOut, recipient, deadline);
    }
    assert lastReverted;
}

/// S3. While paused every swap door reverts (selfExecutePrePulled is refused to any caller
/// but the Router itself). Mutant: drop whenLive from one door.
rule pausedBlocksEverySwapDoor(method f, env e, calldataarg args) filtered { f -> !NOT_A_DOOR(f) } {
    require paused();
    require e.msg.sender != currentContract;
    f@withrevert(e, args);
    assert lastReverted;
}

/// S4. A tokA -> tokB swap of one or two hops pays the recipient at least userMinOut, or reverts.
/// Mutant: delete BOTH `if (delivered < userMinOut) revert RouterE(5)` (Router:1689) and
/// `if (amountOut < effMin) revert RouterE(5)` (Router:1649); either alone covers an untaxed tokB.
rule deliveryAtLeastMinOutOrRevert(env e, RouterHarness.Route route, uint256 amountIn,
                                   uint256 minOut, address recipient, uint256 deadline) {
    require route.hops.length >= 1 && route.hops.length <= 2;
    require route.hops[0].tokenIn == tokA;
    uint256 last = require_uint256(route.hops.length - 1);
    require route.hops[last].tokenOut == tokB;
    require recipient != currentContract;
    mathint before = tokB.balanceOf(recipient);
    swapExactIn(e, route, amountIn, minOut, recipient, deadline);
    assert tokB.balanceOf(recipient) >= before + minOut;
}

/// S5. A swap never leaves tokA or tokB at the Router beyond the treasuries' owed fees.
/// Mutant: delete the tokenIn residue sweep after the hop loop (Router:1502-1503).
rule routerHoldsNothing(env e, RouterHarness.Route route, uint256 amountIn, uint256 minOut,
                        address recipient, uint256 deadline) {
    require e.msg.sender != currentContract && recipient != currentContract;
    mathint a0 = tokA.balanceOf(currentContract) - owed(tokA, 0) - owed(tokA, 1);
    mathint b0 = tokB.balanceOf(currentContract) - owed(tokB, 0) - owed(tokB, 1);
    swapExactIn(e, route, amountIn, minOut, recipient, deadline);
    assert tokA.balanceOf(currentContract) - owed(tokA, 0) - owed(tokA, 1) <= a0;
    assert tokB.balanceOf(currentContract) - owed(tokB, 0) - owed(tokB, 1) <= b0;
}
