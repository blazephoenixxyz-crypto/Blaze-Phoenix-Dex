/*
 * Certora CVL - Router control plane: who may change configuration, renounce, rescue.
 * Target: BlazePhoenixRouter through certora/harness/RouterHarness.sol, tokA = DummyERC20A.
 *
 * Scope: parametric rules range over the LIGHT surface (setters, treasury moves, claimFee,
 * rescue, public views). The swap doors, selfExecutePrePulled, fallback/receive and
 * unlockCallback are excluded here (RouterSwap.spec covers the doors); none of them is
 * proven NOT to touch the control slots by this file.
 */

using DummyERC20A as tokA;

methods {
    function admin() external returns (address) envfree;
    function treasury1() external returns (address) envfree;
    function treasury2() external returns (address) envfree;
    function permit2() external returns (address) envfree;
    function weth() external returns (address) envfree;
    function paused() external returns (bool) envfree;
    function controlRenounced() external returns (bool) envfree;
    function rescueEta(bytes32) external returns (uint256) envfree;
    function owed(address, uint256) external returns (uint256) envfree;
    function rescueKey(address, address) external returns (bytes32) envfree;
    function tokA.balanceOf(address) external returns (uint256) envfree;

    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.balanceOf(address) external => DISPATCHER(true);
}

definition RESCUE_DELAY() returns mathint = 172800;

/// The setters gated by onlyControl.
definition CONTROL_ONLY(method f) returns bool =
    f.selector == sig:setAdmin(address).selector
    || f.selector == sig:setTreasuries(address, address).selector
    || f.selector == sig:setPermit2(address).selector
    || f.selector == sig:setWeth(address).selector
    || f.selector == sig:setPaused(bool).selector
    || f.selector == sig:renounceControl().selector
    || f.selector == sig:queueRescue(address, address).selector
    || f.selector == sig:cancelRescue(address, address).selector
    || f.selector == sig:executeRescue(address, address).selector;

/// Control-only setters, the two treasury-held doors, and every public view.
definition LIGHT(method f) returns bool =
    CONTROL_ONLY(f)
    || f.selector == sig:moveTreasury(address).selector
    || f.selector == sig:claimFee(address).selector
    || f.isView;

/// C1. A control-only setter that succeeds was called by the admin before renounce.
/// Mutants: drop onlyControl from setPermit2; `||` -> `&&` in _onlyControl.
rule controlGateOnSetters(method f, env e, calldataarg args) filtered { f -> CONTROL_ONLY(f) } {
    address a0 = admin();
    bool r0 = controlRenounced();
    f(e, args);
    assert e.msg.sender == a0 && !r0;
}

/// C2. Configuration moves only by control; a treasury slot also by its own holder.
/// Mutant: moveTreasury from treasury1 writes treasury2.
rule configOnlyByControl(method f, env e, calldataarg args) filtered { f -> LIGHT(f) } {
    address a0 = admin();
    address t10 = treasury1();
    address t20 = treasury2();
    address p0 = permit2();
    address w0 = weth();
    bool z0 = paused();
    bool r0 = controlRenounced();
    f(e, args);
    bool ctl = e.msg.sender == a0 && !r0;
    assert (admin() != a0 || permit2() != p0 || weth() != w0 || paused() != z0) => ctl;
    assert treasury1() != t10 => (ctl || e.msg.sender == t10);
    assert treasury2() != t20 => (ctl || e.msg.sender == t20);
}

/// C3. Renounce is forever (over the LIGHT surface).
/// Mutant: moveTreasury also writes controlRenounced = false.
rule renounceIsForever(method f, env e, calldataarg args) filtered { f -> LIGHT(f) } {
    require controlRenounced();
    f(e, args);
    assert controlRenounced();
}

/// C4. Renounce is refused while paused (paused-then-renounced is terminal).
/// Mutant: delete `if (paused) revert RouterE(2)` in renounceControl.
rule renounceRefusedWhilePaused(env e) {
    require paused();
    renounceControl@withrevert(e);
    assert lastReverted;
}

/// C4b. The terminal state paused && renounced is unreachable (over the LIGHT surface).
/// Mutant: same as C4.
invariant neverPausedAndRenounced()
    !(paused() && controlRenounced())
    filtered { f -> LIGHT(f) }

/// C5a. A queued rescue waits exactly 48 hours.
/// Mutant: RESCUE_DELAY 48 hours -> 47 hours.
rule queueSetsFortyEightHourEta(env e, address token, address to) {
    queueRescue(e, token, to);
    assert to_mathint(rescueEta(rescueKey(token, to))) == e.block.timestamp + RESCUE_DELAY();
}

/// C5b. A rescue executes only once queued, only after its eta, and only once.
/// Mutants: delete `|| block.timestamp < eta`; delete `delete rescueEta[k]`.
/// (`<` -> `<=` only makes the guard stricter and is not killed here.)
rule rescueTimelockAndSingleUse(env e, address token, address to) {
    bytes32 k = rescueKey(token, to);
    uint256 eta = rescueEta(k);
    executeRescue(e, token, to);
    assert eta != 0 && e.block.timestamp >= eta && rescueEta(k) == 0;
}

/// C6. A rescue never takes the treasuries' owed fees.
/// Mutant: delete `amt = amt > o ? amt - o : 0`.
rule rescueNeverTakesOwedFees(env e, address to) {
    mathint o = owed(tokA, 0) + owed(tokA, 1);
    mathint b0 = tokA.balanceOf(currentContract);
    executeRescue(e, tokA, to);
    assert tokA.balanceOf(currentContract) >= (b0 < o ? b0 : o);
}
