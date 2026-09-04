// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

/// @notice The refusals we did not write.
///
///         This repository inventories every `revert HubE(n)` it raises and names the test that
///         drives each one. That covers one of the two refusal surfaces a deployed contract has.
///         The other belongs to the compiler: `Panic(uint256)` handlers emitted for assumptions
///         the source did not defend itself. `panic_inventory.py` reads the artefact and reports
///         which of those codes the shipped bytecode can raise; three of them - 0x12, 0x32, 0x41 -
///         had no test in either direction, so their reachability was simply unknown.
///
///         Unknown is the part worth fixing. A panic with no test is not a bug and not a
///         guarantee; it is a path whose behaviour under an unexpected input is decided by the
///         compiler rather than by us, and nobody had checked which. This file settles 0x32 by
///         reaching it, and records what settles the other two.
///
///         0x12 and 0x41 are settled elsewhere, deliberately, because neither can be asserted
///         here without writing a test that cannot fail. 0x12 has one site a caller's route can
///         reach - `Router:_execute` divides `hopAttested / hopQuoted` under `if (hopAttested
///         != 0)` - and it is unreachable by a one-line argument: the three hop accumulators are
///         declared INSIDE the hop loop body, and `hopAttested` is the sum of exactly the
///         `legAtt` values whose non-zero-ness increments `hopQuoted`, so a non-zero sum needs a
///         non-zero term and `hopQuoted >= 1`. An argument is not evidence, so the evidence is a
///         mutant in `mutants.py` that moves the guard onto `hopGot`, an accumulator the
///         divisor is NOT built from. It dies: `test_G7_OneWeiOutput_BoundaryPasses` and
///         `test_FeeOnOut_OneWeiOutputWhollyConsumedIsRefused` both fail with `panic:
///         division or modulo by zero (0x12)`. That is the part that matters - the corpus
///         really does drive a hop whose legs execute without attesting, so the guard is
///         load-bearing rather than decorative and the argument above is tested, not asserted.
///
///         0x41 is reachable only through curator configuration: `discoverFor` sizes its array
///         from `fac.fees.length * fac.spacings.length`, both curator-writable, and gas
///         exhaustion arrives long before the allocation limit. No stranger can grow it -
///         creating pools in a listed factory does not enter that product. See `panic_sites.py`.
contract CompilerPanicSurfaceTest is Test {
    BlazePhoenixHub hub;

    /// @dev Solidity's code for "array accessed out of bounds". Asserted as the raw
    ///      `Panic(uint256)` payload because that is exactly what a caller sees: not a named
    ///      error they can interpret, four bytes of the compiler's own selector and a number.
    uint256 constant PANIC_ARRAY_OUT_OF_BOUNDS = 0x32;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    /// @notice 0x32 IS reachable, by anyone, with no privilege and no state.
    ///
    ///         `bridge(uint8 i)` reads `bridges[i]` where `bridges` is `address[MAX_BRIDGES]`,
    ///         a FIXED-size array of three, and `i` is whatever the caller passes. Every other
    ///         indexed accessor on this contract indexes a mapping, which is never bounds-checked
    ///         and cannot panic; this one is the whole of the contract's 0x32 surface.
    ///
    ///         The refusal is correct - returning a neighbouring slot would be far worse - but it
    ///         is the compiler's and not ours, so it carries no error code an integrator can
    ///         branch on. That is the fact this test pins: not that it should be different, but
    ///         that it is this, deliberately, and that a future change to `bridge` which
    ///         swallowed the index instead of refusing it would fail here.
    function test_Panic0x32_BridgeIndexOutOfRangeIsTheCompilersRefusal() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", PANIC_ARRAY_OUT_OF_BOUNDS));
        hub.bridge(3);
    }

    /// @notice And the boundary on the other side, which is what makes the test above mean
    ///         something. Index 2 is IN range and returns the zero address although no bridge
    ///         was ever added: an unset seat is not refused, only a non-existent one is. A test
    ///         that only checked the revert would still pass if the bound moved to 2, or to 200.
    function test_Panic0x32_InRangeButUnsetIsNotRefused() public view {
        assertEq(hub.bridge(2), address(0), "an unset in-range seat must answer, not revert");
        assertEq(hub.bridgeCount(), 0, "and it answers zero while the registry holds no bridge");
    }
}
