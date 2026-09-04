// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";

/// @notice The size limit, checked where nothing can stop it running.
///
///         This repository already had a size guard: a CI job that parses `forge build --sizes`
///         and fails on `runtime >= 24000`. On 2026-09-04 the Router reached 24,015 and shipped
///         to `main` anyway, because every CI job on that commit carried the annotation "the job
///         was not started because your account is locked due to a billing issue". The job list
///         had no steps. A guard that cannot run is not a guard, and the local green that had
///         been reported against three merged pull requests never included it.
///
///         So the same property is asserted here, in the suite, by DEPLOYING each contract and
///         measuring `address(...).code.length`. No parsing, no separate job, no external
///         service: if this can run at all, the check ran.
///
///         WHY THE NUMBER IS TRUSTWORTHY HERE. A size measured under the test profile is only
///         the shipped size while the profiles agree, and this repository has already been bitten
///         by exactly that gap - a suite that was green at 1000 optimizer runs against a size
///         guard that ran at 800, so 1000+ tests certified a binary that exceeded EIP-170 by 406
///         bytes. `foundry.toml` now pins `optimizer_runs` identically in `default` and `release`,
///         and `profile_parity.py` fails the build if they diverge. This test is meaningful
///         because of that guard, not instead of it.
///
///         `BlazePhoenixCore` is absent because it is a DELEGATECALL-linked library and has no
///         constructor to call here; the CI table still covers it, and it sits far from the
///         limit (6,477 of 24,576).
contract DeployedSizeGateTest is Test {
    /// @dev The hard protocol limit. Not a policy choice.
    uint256 constant EIP_170_LIMIT = 24_576;

    /// @dev The project's own margin, and a SECOND PRODUCER of this number: the first is
    ///      `.github/workflows/ci.yml`, which sets `limit = 24000` in the size-guard step. Two
    ///      producers of one quantity is the defect shape this codebase spends most of its
    ///      effort on, so it is named rather than hidden - if the CI figure moves and this one
    ///      does not, the gates disagree and the looser one wins silently.
    uint256 constant PROJECT_GATE = 24_000;

    address constant TREASURY_1 = address(0xFEE1);
    address constant TREASURY_2 = address(0xFEE2);

    function _check(string memory name, address deployed) private {
        uint256 size = deployed.code.length;
        emit log_named_uint(string.concat(name, " runtime bytes"), size);
        assertGt(size, 0, string.concat(name, ": nothing was deployed, so nothing was measured"));
        assertLt(size, PROJECT_GATE,
            string.concat(name, " is at or over the project's own size gate"));
        assertLt(size, EIP_170_LIMIT,
            string.concat(name, " exceeds EIP-170 and cannot be deployed at all"));
    }

    function test_EveryShippedContractIsUnderTheSizeGate() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        BlazePhoenixRouter router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), TREASURY_1, TREASURY_2);
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(this));

        _check("Hub", address(hub));
        _check("Solver", address(solver));
        _check("Router", address(router));
        _check("Quoter", address(quoter));
    }

    /// @dev The margin, published rather than merely respected. A number that only has to stay
    ///      under a line tells you nothing about how close it came; this one prints the distance
    ///      so a commit that eats 300 bytes is visible in the log before it is fatal.
    function test_TheRemainingMarginIsPublished() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        BlazePhoenixRouter router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), TREASURY_1, TREASURY_2);

        uint256 routerSize = address(router).code.length;
        uint256 hubSize = address(hub).code.length;
        emit log_named_uint("Router: bytes left to the project gate", PROJECT_GATE - routerSize);
        emit log_named_uint("Router: bytes left to EIP-170", EIP_170_LIMIT - routerSize);
        emit log_named_uint("Hub:    bytes left to the project gate", PROJECT_GATE - hubSize);
        emit log_named_uint("Hub:    bytes left to EIP-170", EIP_170_LIMIT - hubSize);

        // The two that bind. Stated as an assertion and not only a log, because a log nobody
        // reads is not a guard either.
        assertLt(routerSize, PROJECT_GATE, "the Router is the binding contract; it must have room");
        assertLt(hubSize, PROJECT_GATE, "the Hub is the other one");
    }
}
