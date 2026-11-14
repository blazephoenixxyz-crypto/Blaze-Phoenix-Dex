// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  batchQuote: one item, one answer.
//
//  `batchQuote` answers up to MAX_BATCH (tIn, tOut, amountIn, userMinOut) tuples
//  in one call. The sentence its callers rely on is that an item is answered as
//  if it had been asked alone: its place in the batch, its neighbours, and a
//  neighbour that has no route change nothing about it.
//
//  What is asserted here, on a world of honest V2 pairs:
//    - the cap: a batch of exactly MAX_BATCH items answers every one of them and
//      MAX_BATCH + 1 is refused with QuoterE(4) (the cap is read from the
//      contract, not copied);
//    - place and neighbours: any item of any batch equals the same tuple asked
//      alone, and equals what `previewPlanWithMinOut` (a second door, which does
//      not go through the batch loop) answers for it;
//    - a tuple with no route leaves exactly its own slot empty.
//
//  The gas side of the same sentence (a neighbour that exhausts its gas) is a
//  separate file, BatchQuoteGasLadder.t.sol.
//
//  Matrix: sizes 1 wei .. 10% of depth; items routable / no route / floor above
//  the net; batch lengths 0, 1, MAX_BATCH, MAX_BATCH + 1 and fuzzed 1..8;
//  dimensions unit + fuzz + mutant.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// Reads the batch cap from the contract so the test never carries a copy of it.
contract BatchCapReader is BlazePhoenixQuoter {
    constructor(address hub_, address solver_) BlazePhoenixQuoter(hub_, solver_) {}
    function maxBatch() external pure returns (uint256) { return MAX_BATCH; }
}

contract BatchQuoteItemIsolationTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    uint256 cap;

    uint256 constant DEPTH = 1_000_000e18;
    uint256 constant TUPLES = 7;
    BlazePhoenixQuoter.BatchEntry[TUPLES] tuples;   // the pool of items every batch is drawn from
    uint256 constant NO_ROUTE = 5;                  // index of the tuple whose pair has no venue
    uint256 constant HIGH_FLOOR = 6;                // index of the tuple whose own floor is above its net

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        cap = new BatchCapReader(address(hub), address(solver)).maxBatch();

        // Five routable tuples on three pairs of different depth ratios, sizes from one wei to a
        // tenth of the book, one of them carrying a floor of its own.
        (address a0, address a1) = _pair(DEPTH, DEPTH);
        (address b0, address b1) = _pair(DEPTH, 3 * DEPTH);
        (address c0, address c1) = _pair(DEPTH / 1000, DEPTH / 2000);
        tuples[0] = BlazePhoenixQuoter.BatchEntry(a0, a1, 1_000e18, 0);
        tuples[1] = BlazePhoenixQuoter.BatchEntry(a1, a0, DEPTH / 10, 0);
        tuples[2] = BlazePhoenixQuoter.BatchEntry(b0, b1, 1, 0);
        tuples[3] = BlazePhoenixQuoter.BatchEntry(b1, b0, 77e18, 5e18);
        tuples[4] = BlazePhoenixQuoter.BatchEntry(c0, c1, 3e18, 0);
        // A pair nobody lists.
        tuples[NO_ROUTE] = BlazePhoenixQuoter.BatchEntry(
            address(new MockERC20("X", "X")), address(new MockERC20("Y", "Y")), 1e18, 0);
        // The same pair as tuple 0 with a floor no venue can meet.
        tuples[HIGH_FLOOR] = BlazePhoenixQuoter.BatchEntry(a0, a1, 1_000e18, type(uint128).max);
    }

    function _pair(uint256 rA, uint256 rB) private returns (address a, address b) {
        a = address(new MockERC20("A", "A"));
        b = address(new MockERC20("B", "B"));
        MockV2Pair p = new MockV2Pair(a, b);
        (uint256 r0, uint256 r1) = a < b ? (rA, rB) : (rB, rA);
        MockERC20(p.token0()).mint(address(p), r0);
        MockERC20(p.token1()).mint(address(p), r1);
        p.setReserves(uint112(r0), uint112(r1));
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), t0, t1);
    }

    function _h(BlazePhoenixQuoter.Preview memory pv) private pure returns (bytes32) {
        return keccak256(abi.encode(pv));
    }

    function _alone(uint256 k) private view returns (BlazePhoenixQuoter.Preview memory) {
        BlazePhoenixQuoter.BatchEntry[] memory one = new BlazePhoenixQuoter.BatchEntry[](1);
        one[0] = tuples[k];
        return quoter.batchQuote(one)[0];
    }

    function _empty() private pure returns (bytes32) {
        BlazePhoenixQuoter.Preview memory z;
        return _h(z);
    }

    /// The fixture reaches the regimes the sentences are about.
    function test_Fixture_TheTuplePoolHoldsRoutedUnroutedAndFloorBoundItems() public view {
        for (uint256 k; k < 5; ++k) {
            BlazePhoenixQuoter.Preview memory pv = _alone(k);
            assertGt(pv.grossOut, 0, "a routable tuple quoted nothing");
            assertEq(pv.userMinOut, tuples[k].userMinOut, "the preview does not carry the item's own floor");
        }
        assertTrue(_alone(3).canExecute, "tuple 3's own floor is under its net, it must be executable");
        assertEq(_alone(3).effectiveMinOut >= 5e18, true, "the item's floor did not tighten the effective floor");
        assertEq(_h(_alone(NO_ROUTE)), _empty(), "the unlisted pair answered something");
        assertGt(_alone(HIGH_FLOOR).grossOut, 0, "the floor-bound tuple is routable");
        assertFalse(_alone(HIGH_FLOOR).canExecute, "a floor above the net must not be executable");
    }

    function test_ABatchOfExactlyTheCapAnswersEveryItem_OneMoreIsRefusedWithCode4() public {
        assertGt(cap, 1, "the cap read from the contract is degenerate");
        BlazePhoenixQuoter.BatchEntry[] memory full = new BlazePhoenixQuoter.BatchEntry[](cap);
        for (uint256 i; i < cap; ++i) full[i] = tuples[i % 5];
        BlazePhoenixQuoter.Preview[] memory pv = quoter.batchQuote(full);
        assertEq(pv.length, cap, "one answer per item");
        for (uint256 i; i < cap; ++i) {
            assertEq(_h(pv[i]), _h(_alone(i % 5)), "an item of a full batch differs from the same tuple alone");
        }

        BlazePhoenixQuoter.BatchEntry[] memory over = new BlazePhoenixQuoter.BatchEntry[](cap + 1);
        for (uint256 i; i <= cap; ++i) over[i] = tuples[i % 5];
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixQuoter.QuoterE.selector, uint16(4)));
        quoter.batchQuote(over);
    }

    function test_AnEmptyBatchAnswersAnEmptyList() public view {
        BlazePhoenixQuoter.BatchEntry[] memory none = new BlazePhoenixQuoter.BatchEntry[](0);
        assertEq(quoter.batchQuote(none).length, 0, "an empty batch answered items");
    }

    /// Place and neighbours: every item of a random batch equals the same tuple asked alone.
    function testFuzz_AnItemAnswersTheSameAloneAndAtAnyPlaceOfAnyBatch(uint256 seed) public view {
        uint256 n = 1 + seed % 8;
        BlazePhoenixQuoter.BatchEntry[] memory batch = new BlazePhoenixQuoter.BatchEntry[](n);
        uint256[] memory pick = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            pick[i] = uint256(keccak256(abi.encode(seed, i))) % TUPLES;
            batch[i] = tuples[pick[i]];
        }
        BlazePhoenixQuoter.Preview[] memory pv = quoter.batchQuote(batch);
        assertEq(pv.length, n, "one answer per item");
        for (uint256 i; i < n; ++i) {
            assertEq(_h(pv[i]), _h(_alone(pick[i])), "an item's answer moved with its place or its neighbours");
        }
    }

    /// The second door: an item equals what `previewPlanWithMinOut` answers for the same tuple.
    function test_EveryRoutableItemEqualsTheSinglePreviewDoor() public view {
        BlazePhoenixQuoter.BatchEntry[] memory batch = new BlazePhoenixQuoter.BatchEntry[](TUPLES);
        for (uint256 i; i < TUPLES; ++i) batch[i] = tuples[TUPLES - 1 - i];   // reversed order
        BlazePhoenixQuoter.Preview[] memory pv = quoter.batchQuote(batch);
        for (uint256 i; i < TUPLES; ++i) {
            uint256 k = TUPLES - 1 - i;
            if (k == NO_ROUTE) continue;
            (BlazePhoenixQuoter.Preview memory single,,) = quoter.previewPlanWithMinOut(
                tuples[k].tIn, tuples[k].tOut, tuples[k].amountIn, tuples[k].userMinOut);
            assertEq(_h(pv[i]), _h(single), "the batch item differs from the single preview door");
        }
    }

    /// A tuple with no route empties its own slot and no other, wherever it stands.
    function test_AnItemWithNoRouteLeavesOnlyItsOwnSlotEmpty() public {
        for (uint256 at; at < 3; ++at) {
            BlazePhoenixQuoter.BatchEntry[] memory batch = new BlazePhoenixQuoter.BatchEntry[](3);
            uint256 k;
            for (uint256 i; i < 3; ++i) batch[i] = i == at ? tuples[NO_ROUTE] : tuples[k++];
            BlazePhoenixQuoter.Preview[] memory pv = quoter.batchQuote(batch);
            k = 0;
            for (uint256 i; i < 3; ++i) {
                if (i == at) assertEq(_h(pv[i]), _empty(), "the unrouted item's slot is not empty");
                else         assertEq(_h(pv[i]), _h(_alone(k++)), "a routed neighbour of an unrouted item changed");
            }
        }
        // the single door refuses the same tuple by the Solver's named error, so "empty" is the
        // batch's own translation of that refusal and not a quote of zero
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        quoter.previewPlan(tuples[NO_ROUTE].tIn, tuples[NO_ROUTE].tOut, tuples[NO_ROUTE].amountIn);
    }
}
