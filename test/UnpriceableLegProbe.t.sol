// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PROBE — is the unpriceable leg reachable, and what does it do to Layer 1?
//
//  The measurement guard reads, at Router:1590:
//
//      bool guard = legOut != address(0) && amt != 0
//          && ((leg.expectedOut != 0 && leg.amountIn != 0)
//              || (legQuote != 0 && legAmt != 0));
//
//  A leg with no caller attestation AND no in-frame quote is therefore never
//  measured: `_execScaled` returns without reading the balance, `hopGot` does not
//  grow by it, and the aggregate floor compares what remains with itself. The
//  in-frame quote is missing whenever the quote loop could not price the leg —
//  Router:812-816 only grows `quoteAcc` inside the branches that priced one.
//
//  This file does not assert that this is a defect. It asks the two questions a
//  verdict needs and records what comes back: can a route reach that state at
//  all, and if it can, does the hop still pass. A probe that says REFUSED buys a
//  pin; a probe that says OPEN buys a finding. Either is worth more than an
//  assertion written from what we already believe.
//
//  Reported by Seavia Resources, ninth bounty wave.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract UnpriceableLegProbe is Test {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    function setUp() public {
        tokenA = new MockERC20("Dollar A", "USDA");
        tokenB = new MockERC20("Dollar B", "USDB");
    }

    /// @dev PROBE 1 — can a pair hold reserves on one side only? That is the
    ///      cheapest shape that makes `rIn == 0` true and so leaves `legQuotes[l]`
    ///      at zero while the leg is still a legal route entry.
    function test_Probe_PairWithZeroInputSideReserve() public {
        MockV2Pair p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenB.mint(address(p), 1_000e18);          // output side only
        (uint256 r0, uint256 r1, ) = p.getReserves();
        emit log_named_uint("reserve0", r0);
        emit log_named_uint("reserve1", r1);
        if (r0 == 0 || r1 == 0) {
            emit log("OPEN: a pair can carry a zero reserve on one side");
        } else {
            emit log("REFUSED: the mock refuses a one-sided pair");
        }
    }

    /// @dev PROBE 2 — the arithmetic of the guard itself, stated as data rather
    ///      than reasoned about. These are the four combinations of "the caller
    ///      attested" and "the frame could price it"; only the last leaves a leg
    ///      unmeasured, and the question is whether a caller can present it.
    function test_Probe_TheGuardsFourCombinations() public {
        emit log_named_string("attested + priceable  ", _guard(1, 1) ? "measured" : "UNMEASURED");
        emit log_named_string("attested + unpriceable", _guard(1, 0) ? "measured" : "UNMEASURED");
        emit log_named_string("bare + priceable      ", _guard(0, 1) ? "measured" : "UNMEASURED");
        emit log_named_string("bare + unpriceable    ", _guard(0, 0) ? "measured" : "UNMEASURED");
    }

    /// @dev The predicate copied from Router:1590, with the two address/amount
    ///      terms held true so the two that decide are the ones varying. Copied
    ///      rather than called because the Router's is private; the copy is the
    ///      thing under discussion, and if it ever drifts from the original this
    ///      file is wrong in a way the next reader can see.
    function _guard(uint256 expectedOut, uint256 legQuote) private pure returns (bool) {
        uint256 amt = 1e18;
        uint256 legAmt = 1e18;
        uint256 legAmountIn = 1e18;
        return amt != 0
            && ((expectedOut != 0 && legAmountIn != 0) || (legQuote != 0 && legAmt != 0));
    }
}
