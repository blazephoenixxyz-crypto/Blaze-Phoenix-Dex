// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  WHAT A gasleft() DELTA MEASURES HERE: the instrument, made observable.
//
//  A bench reads gasleft() before and after an external call. Under `isolate`
//  (foundry.toml) every top-level call of a test runs as its own transaction,
//  and that delta is what the transaction is charged in TOTAL: 21000, the
//  calldata's intrinsic price and the execution. Without isolate the delta is
//  the EXECUTION alone. A BENCH line that does not say which invites a reader
//  to add 21000 and the calldata price to a total that already holds them.
//
//  The one part of the cost that tells a zero byte from a nonzero one is the
//  intrinsic calldata price (EIP-2028: 4 against 16 gas). Inside execution,
//  CALLDATACOPY and CALL charge by length alone. So the same call carrying n
//  more zero bytes and n more nonzero bytes differs by EXACTLY 12n in total
//  mode and by exactly 0 in execution mode. Any other difference is an
//  instrument nobody declared (a floor price from another fork, a profiler, a
//  forge release that measures differently) and is red. The mode is printed
//  as BENCH|mode|total or BENCH|mode|exec: a bench run with this file in its
//  --match-path is labelled by it. (EquationBench.t.sol does not import it: code
//  added to a bench file recompiles that harness and moves its readings.)
//
//  Cross-checks, so a wrong label cannot pass: the measured mode is the one
//  vm.isIsolateMode() reports for the run; a call carrying only a selector
//  costs at least 21000 in total mode and less than 21000 in execution mode;
//  and transient storage written by one top-level call is gone in the next
//  exactly when each top-level call is its own transaction (total mode). That
//  last one is the rule the transient-lock tests are written on: a lock's
//  cleanup is only observable from two operations inside ONE top-level call.
// =============================================================================
import {Test, console2} from "forge-std/Test.sol";

/// A call target whose execution reads none of its calldata: only the length can reach its cost.
contract GasInstrumentSink {
    fallback() external {}
}

/// One transient slot behind two calls: written by one, read by the next.
contract GasInstrumentTransientCell {
    function put(uint256 v) external {
        assembly { tstore(0, v) }
    }

    function get() external view returns (uint256 v) {
        assembly { v := tload(0) }
    }
}

/// The probe: which gas does a gasleft() delta around a top-level call hold?
abstract contract GasInstrumentProbe is Test {
    uint256 internal constant GAS_PROBE_BYTES = 1024;

    function _gasOf(address to, bytes memory cd) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        (bool ok, ) = to.call(cd);
        used = g0 - gasleft();
        require(ok, "gas instrument: the probe call failed");
    }

    /// "total" when the delta is what the call's transaction is charged, "exec" when it is
    /// execution alone. Reverts on any other difference: an instrument nobody declared.
    function _gasMode() internal returns (string memory mode, uint256 selectorOnly, uint256 diff) {
        address sink = address(new GasInstrumentSink());
        bytes memory sel = hex"a1b2c3d4";
        bytes memory zeros = abi.encodePacked(sel, new bytes(GAS_PROBE_BYTES));
        bytes memory ones = new bytes(GAS_PROBE_BYTES + 4);
        for (uint256 i; i < ones.length; ++i) ones[i] = bytes1(uint8(0xa5));
        for (uint256 i; i < 4; ++i) ones[i] = sel[i];
        _gasOf(sink, sel); // warm-up: without isolate the first call pays the cold account, once
        selectorOnly = _gasOf(sink, sel);
        uint256 gz = _gasOf(sink, zeros);
        uint256 gn = _gasOf(sink, ones);
        require(gn >= gz, "gas instrument: nonzero calldata measured cheaper than zero calldata");
        diff = gn - gz;
        if (diff == 12 * GAS_PROBE_BYTES) mode = "total";
        else if (diff == 0) mode = "exec";
        else revert(string.concat("gas instrument: +n nonzero vs +n zero bytes differ by ", vm.toString(diff),
            ", neither 12n (total) nor 0 (exec)"));
    }
    /// The mode alone, for a bench that labels its lines. Call it from a test of its own in the
    /// same run (isolate is per run), never between measurements: the probe's memory grows the
    /// caller's frame, and every later delta in that frame pays the larger memory.
    function _gasModeLabel() internal returns (string memory mode) {
        (mode, , ) = _gasMode();
    }
}

contract GasInstrumentModeTest is GasInstrumentProbe {
    /// Quantity: what a gasleft() delta around a top-level call holds, read from the one part of
    /// the cost that depends on calldata content.
    function test_gasInstrument_mode() public {
        (string memory mode, uint256 selectorOnly, uint256 diff) = _gasMode();
        bool total = keccak256(bytes(mode)) == keccak256("total");
        assertEq(total, vm.isIsolateMode(), "the measured mode is the isolate flag this run was configured with");
        if (total) assertGe(selectorOnly, 21_000, "total mode: a top-level call costs at least the transaction base");
        else assertLt(selectorOnly, 21_000, "exec mode: a call that runs nothing costs less than a transaction");

        GasInstrumentTransientCell cell = new GasInstrumentTransientCell();
        cell.put(7);
        uint256 seen = cell.get();
        if (total) assertEq(seen, 0, "total mode: each top-level call is its own transaction, transient storage resets");
        else assertEq(seen, 7, "exec mode: one transaction, transient storage survives the next top-level call");

        console2.log(string.concat("BENCH|mode|", mode));
        console2.log("BENCH|mode_selector_only_gas", selectorOnly);
        console2.log("BENCH|mode_nonzero_minus_zero_gas", diff);
    }
}
