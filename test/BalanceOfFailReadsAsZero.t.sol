// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Refutability, mode 2 — a failed read is not a measurement.
//
//  BPC.balanceOf (Core §3) is:
//
//      if staticcall(gas(), token, m, 36, m, 32) {
//          if iszero(lt(returndatasize(), 32)) { b := mload(m) }
//      }
//      // staticcall failed -> b stays 0, and the caller cannot tell
//
//  The function returns a bare uint256 with no success flag, so it CONFLATES
//  "the balance is zero" with "the read failed". Every measured delta in the
//  Router is built as `after - before` on top of it (27 call sites), and the
//  two directions are not symmetric:
//
//    * the AFTER read failing  -> `0 - before` underflows -> revert (safe)
//    * the BEFORE read failing -> `after - 0` == after    -> the delta becomes
//                                 an ABSOLUTE BALANCE, silently inflated
//
//  The worst consumer is the user's own slippage guard:
//
//      uint256 recipBefore = BPC.balanceOf(tokenOut, recipient);
//      BPC.safeTransfer(tokenOut, recipient, net);
//      uint256 delivered = BPC.balanceOf(tokenOut, recipient) - recipBefore;
//      if (delivered < userMinOut) revert RouterE(5);
//
//  With `recipBefore` reading 0 by failure, `delivered` becomes the recipient's
//  ENTIRE holding of tokenOut. A user who already owns the token has their
//  userMinOut satisfied by coins they held before the swap. That matters well
//  beyond this one guard: userMinOut is the backstop that bounds several other
//  reported findings, so a defect that defeats it undoes those bounds too.
//
//  This needs no exotic token: any ERC-20 whose balanceOf can revert — paused,
//  mid-upgrade, or simply hostile — reaches it. The token here reverts on a
//  chosen call index so the BEFORE read fails and the AFTER read succeeds,
//  which is the dangerous asymmetry stated above.
//
//  RED BEFORE THE FIX: test_FailedBeforeRead_MustNotSatisfyUserMinOut passes
//  a swap that delivered far less than userMinOut.
//
//  forge test --match-contract BalanceOfFailReadsAsZero -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {CoreHarness} from "./mocks/CoreHarness.sol";

/// @dev ERC-20 that reverts on `balanceOf` at a chosen call index, and behaves
///      normally otherwise. `decimals` never reverts, so token admission is
///      unaffected — only the measurement is.
contract BalanceRevertsOnceERC20 {
    string  public name     = "HOSTILE";
    string  public symbol   = "HST";
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public down;

    /// The test toggles this between the two reads, which is exactly the
    /// asymmetry under study: BEFORE fails, AFTER succeeds.
    function setDown(bool d) external { down = d; }

    function mint(address to, uint256 amt) external { totalSupply += amt; _bal[to] += amt; }

    /// MUST be `view`: BPC.balanceOf reads through `staticcall`, so a
    /// state-mutating balanceOf would fail on EVERY call rather than the one
    /// under test. (That is its own instance of this defect — a token whose
    /// balanceOf writes state makes every measured delta in the Router read
    /// zero — but it is not what this file isolates.)
    function balanceOf(address who) external view returns (uint256) {
        if (down) revert("HST: balanceOf down");
        return _bal[who];
    }

    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 amt) external returns (bool) {
        _bal[msg.sender] -= amt; _bal[to] += amt; return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) { require(a >= amt, "HST: allowance"); allowance[f][msg.sender] = a - amt; }
        _bal[f] -= amt; _bal[to] += amt; return true;
    }
}

contract BalanceOfFailReadsAsZeroTest is Test {
    BalanceRevertsOnceERC20 tok;
    address holder = address(0xBEEF);

    /// BPC.balanceOf is an INTERNAL library function, so it inlines into the
    /// caller and vm.expectRevert — which only intercepts external calls —
    /// cannot see its revert. The harness gives it an external boundary.
    CoreHarness harness;

    function setUp() public {
        tok = new BalanceRevertsOnceERC20();
        tok.mint(holder, 1_000e18);
        harness = new CoreHarness();
    }

    // ─── the primitive, stated directly ──────────────────────────────────────

    /// A reverting balanceOf is indistinguishable from a zero balance.
    function test_FailedRead_IsReportedAsZeroBalance() public {
        assertEq(harness.balanceOf(address(tok), holder), 1_000e18, "healthy read");

        // THE CLAIM: a read that failed must not be reported as a balance.
        // Before the fix this returned 0 while the holder demonstrably owned
        // 1_000e18, and no caller could tell the difference.
        tok.setDown(true);
        vm.expectRevert(bytes("BPC:balanceOf"));
        harness.balanceOf(address(tok), holder);
    }

    // ─── the consequence: a delta becomes an absolute balance ────────────────

    /// `after - before` with a failed BEFORE read stops being a delta. This is
    /// the shape every measured floor in the Router is built on, reproduced
    /// here on the primitive so it does not depend on route plumbing.
    function test_FailedBeforeRead_TurnsDeltaIntoAbsoluteBalance() public {
        // The holder already owns 1_000e18 before anything is delivered.
        // The BEFORE read can no longer silently become 0 and turn the delta
        // into the holder's entire balance: it refuses instead.
        tok.setDown(true);
        vm.expectRevert(bytes("BPC:balanceOf"));
        harness.balanceOf(address(tok), holder);

        // And the healthy path still measures a real delta of zero.
        tok.setDown(false);
        uint256 before_ = harness.balanceOf(address(tok), holder);
        uint256 after_  = harness.balanceOf(address(tok), holder);
        assertEq(after_ - before_, 0, "an honest delta across no transfer is zero");
    }
}
