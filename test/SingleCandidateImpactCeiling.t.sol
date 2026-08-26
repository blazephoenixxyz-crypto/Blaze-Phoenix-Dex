// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice THE MEASURED IMPACT WAS PUBLISHED BUT NEVER ENFORCED.
///
///         A pool with a fair spot price and a dust-sized book prices a large
///         order truthfully — at ~99.9% impact — and every guard downstream
///         agreed with it, because every guard was relative to that same quote:
///         the Iron-Law floor retains 80% OF THE QUOTE, and the Quoter's
///         `canExecute` compares the quote against a floor derived from it. A
///         collapsed quote floors itself. That is the circularity I3 warns
///         about ("the bound comes from the pool's curvature, never from
///         beta*quote"), and the Solver was measuring the impact all along —
///         publishing it as `expectedImpactBps` and using it only to LOOSEN the
///         floor.
///
///         Reported externally 2026-08-26 (T15). The cure is one absolute
///         ceiling, the only bound in the engine that is not relative to the
///         route's own promise.
///
///         The tests come in POSITIVE/NEGATIVE pairs. The negatives matter as
///         much as the positives here: the first attempt at this fix used the
///         capacity clamp instead, and a regression test from an earlier bounty
///         round caught it cutting a legitimate full-reserve fill down to a
///         third. A guard that fires on honest trades is not a stricter guard —
///         it is a broken one.
contract SingleCandidateImpactCeilingTest is Test {
    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    BlazePhoenixQuoter internal quoter;
    MockERC20 internal usdA;
    MockERC20 internal usdB;

    address internal user = address(0xBEEF);
    uint256 internal constant USER_INPUT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        usdA = new MockERC20("Dollar A", "USDA");
        usdB = new MockERC20("Dollar B", "USDB");
        usdA.mint(user, USER_INPUT * 4);
        vm.prank(user);
        usdA.approve(address(router), type(uint256).max);
    }

    function _seedPair(uint256 reserve) internal returns (MockV2Pair pair) {
        pair = new MockV2Pair(address(usdA), address(usdB));
        MockV2Factory f = new MockV2Factory();
        f.setPair(address(usdA), address(usdB), address(pair));
        usdA.mint(address(pair), reserve);
        usdB.mint(address(pair), reserve);
        pair.setReserves(uint112(reserve), uint112(reserve));
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
    }

    // ───────────────────────── POSITIVE ─────────────────────────

    /// RED BEFORE THE FIX: the sole thin candidate was surfaced as executable
    /// and swallowed the order. The Solver must now return no route at all.
    function test_POSITIVE_SoleThinCandidateYieldsNoRoute() public {
        _seedPair(1e18); // one token per side against a thousand-token order

        // The Solver's canonical "no path" answer: it refuses rather than
        // returning a route it has itself measured as destructive.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        solver.findBestRoutePlan(address(usdA), address(usdB), USER_INPUT);
    }

    /// The preview must agree with the engine: no executable route, and the
    /// self-referential `canExecute` can no longer say otherwise.
    function test_POSITIVE_PreviewRefusesTheDegenerateRoute() public {
        _seedPair(1e18);

        // The preview inherits the refusal instead of publishing a green
        // `canExecute` derived from the collapsed quote.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        quoter.previewPlan(address(usdA), address(usdB), USER_INPUT);
    }

    /// And the trustless door refuses rather than filling at 99.9% impact.
    function test_POSITIVE_TrustlessDoorRefusesInsteadOfFilling() public {
        _seedPair(1e18);

        vm.prank(user);
        vm.expectRevert();
        router.swapBestExactIn(
            address(usdA), address(usdB), USER_INPUT, 1, user, block.timestamp + 1
        );
        assertEq(usdA.balanceOf(user), USER_INPUT * 4, "the caller keeps every token");
    }

    // ───────────────────────── NEGATIVE ─────────────────────────

    /// A deep pool is untouched — the ordinary case must not notice the ceiling.
    function test_NEGATIVE_DeepPoolFillsInFull() public {
        _seedPair(1_000_000e18);

        vm.prank(user);
        uint256 delivered = router.swapBestExactIn(
            address(usdA), address(usdB), USER_INPUT, 1, user, block.timestamp + 1
        );
        assertGt(delivered, 990e18, "a deep pool must fill in full");
    }

    /// THE REGRESSION THAT KILLED THE FIRST ATTEMPT, pinned as a test. An order
    /// equal to the pool's entire reserve is aggressive — ~50% impact — and it
    /// is HONEST: constant product delivers about half, the pool pays it, and
    /// the trader chose the size. The ceiling must let it through.
    function test_NEGATIVE_FullReserveOrderIsStillAllowed() public {
        _seedPair(USER_INPUT); // reserves == the order: ~5,000 bps of impact

        RoutePlan memory plan =
            solver.findBestRoutePlan(address(usdA), address(usdB), USER_INPUT);
        assertGt(plan.best.hops.length, 0, "an aggressive but honest fill must survive");
        assertGt(plan.best.totalOut, 400e18, "and must keep the pool's real output");
    }

    /// The boundary is a ceiling, not a slope: a pool one notch healthier than
    /// the degenerate case must still route, so the guard cannot be a silent
    /// tax on thin-but-usable liquidity.
    function test_NEGATIVE_ThinButUsablePoolStillRoutes() public {
        _seedPair(500e18); // half the order: aggressive, well inside the ceiling

        RoutePlan memory plan =
            solver.findBestRoutePlan(address(usdA), address(usdB), USER_INPUT);
        assertGt(plan.best.hops.length, 0, "thin-but-usable liquidity must remain routable");
    }
}
