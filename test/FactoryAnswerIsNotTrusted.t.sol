// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ONE POOL'S LYING factory() ANSWER CANNOT TAKE A PAIR'S PLANNING DOWN.
//
//  A Solidly pool without a usable getAmountOut is priced on its replicated
//  curve at the fee its factory reports (`Core.readDynamicFee`). The answer to
//  factory() was length-checked and then ABI-decoded as an address, and the
//  decoder reverts on a word whose upper bits are set. That revert is raised
//  inside the planner's per-candidate quote, which nothing contains: one
//  registered pool answering a dirty word reverted the plan for the whole pair,
//  its honest venues included (ninth wave, mohaseenbasha #15). A pool that lies
//  about its origin is now unquotable - priced at zero - and the rest of the
//  pair is planned as before. The answer is read as a word, with the quote
//  path's bounds (`Core._askWord`).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @dev A Solidly-shaped pair whose factory() answers a word that is not an address.
contract DirtyFactoryPair is MockSolidlyPair {
    constructor(address a, address b) MockSolidlyPair(a, b, false) {}
    function factory() external pure returns (uint256) { return type(uint256).max; }
}

/// @dev A Solidly pair whose factory() answer the test chooses: revert, nothing, or a word.
contract AnsweringPair is MockSolidlyPair {
    uint8 public mode;
    uint256 public word;
    constructor(address a, address b) MockSolidlyPair(a, b, false) {}
    function setAnswer(uint8 m, uint256 w) external { mode = m; word = w; }
    function factory() external view returns (uint256) {
        if (mode == 0) revert("no factory");
        if (mode == 1) { assembly { return(0, 0) } }
        return word;
    }
}

/// @dev A factory whose getFee answer the test chooses, per stable flag.
contract AnsweringFactory {
    uint8 public mode;
    uint256 public stableFee;
    uint256 public volatileFee;
    function setAnswer(uint8 m, uint256 sf, uint256 vf) external { mode = m; stableFee = sf; volatileFee = vf; }
    function getFee(address, bool st) external view returns (uint256) {
        if (mode == 0) revert("no fee");
        if (mode == 1) { assembly { return(0, 0) } }
        return st ? stableFee : volatileFee;
    }
}

contract FactoryAnswerIsNotTrustedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;
    DirtyFactoryPair liar;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        (address t0, address t1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));

        // The honest venue: a V2 pair at price 1.
        MockV2Pair honest = new MockV2Pair(t0, t1);
        MockERC20(t0).mint(address(honest), 1e24);
        MockERC20(t1).mint(address(honest), 1e24);
        honest.setReserves(uint112(1e24), uint112(1e24));
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), t0, t1);

        // The liar: a better-looking curve (10% more of either side's counterpart), no
        // getAmountOut, so its quote goes through the factory's fee - and a dirty factory().
        liar = new DirtyFactoryPair(t0, t1);
        MockERC20(t0).mint(address(liar), 11e23);
        MockERC20(t1).mint(address(liar), 11e23);
        liar.setReserves(uint112(11e23), uint112(11e23));
        liar.setHideGetAmountOut(true);
        hub.seedPool(address(liar), BPC.KIND_SOLIDLY, 30, address(0), t0, t1);
    }

    function test_ALyingFactoryAnswerCannotTakeThePairsPlanningDown() public {
        try solver.findBestRoutePlan(address(A), address(B), 1e21) returns (RoutePlan memory plan) {
            assertGt(plan.best.totalOut, 0, "the honest venue was not planned");
            for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
                assertTrue(plan.best.hops[0].legs[i].pool != address(liar),
                    "a pool that lied about its factory was given part of the order");
            }
        } catch {
            assertTrue(false, "one pool's factory() answer reverted the planning of the whole pair");
        }
    }

    /// The pricing primitive itself: a dirty factory() answer prices the pool at zero, it
    /// does not revert, whichever curve it claims.
    function test_ADirtyFactoryWordPricesThePoolAtZero() public view {
        (uint256 r0, uint256 r1, ) = liar.getReserves();
        assertEq(BPC.solidlyCurveOut(address(liar), 1e18, r0, r1, false, 30, address(A)), 0,
            "a pool whose factory() is not an address was priced");
    }

    /// Every shape of answer resolves to the fee it means. No factory, an empty answer or the
    /// zero address leave the declaration (under its ceiling); a word that is not an address
    /// makes the pool unquotable; a clean factory decides only when its getFee answers a fee
    /// strictly between 0 and 100%, and it is asked with the pool's own stable flag.
    function test_EveryFactoryAnswerResolvesToTheFeeItMeans() public {
        AnsweringPair p = new AnsweringPair(address(A), address(B));
        AnsweringFactory f = new AnsweringFactory();
        uint256 full = BPC.BPS;
        p.setAnswer(0, 0);
        assertEq(BPC.readDynamicFee(address(p), false, 25), 25, "no factory: the declaration");
        assertEq(BPC.readDynamicFee(address(p), false, 0), 30, "no declaration: the house default");
        assertEq(BPC.readDynamicFee(address(p), false, 9_900), 30, "a declaration above the ceiling: the default");
        p.setAnswer(1, 0);
        assertEq(BPC.readDynamicFee(address(p), true, 25), 25, "an empty answer: the declaration");
        p.setAnswer(2, 0);
        assertEq(BPC.readDynamicFee(address(p), true, 25), 25, "the zero address: the declaration");
        p.setAnswer(2, type(uint256).max);
        assertEq(BPC.readDynamicFee(address(p), true, 25), full, "a word that is not an address: unquotable");
        p.setAnswer(2, uint256(uint160(address(f))) | (uint256(1) << 160));
        assertEq(BPC.readDynamicFee(address(p), false, 25), full, "one stray bit above the address: unquotable");
        p.setAnswer(2, uint256(uint160(address(f))));
        f.setAnswer(0, 0, 0);
        assertEq(BPC.readDynamicFee(address(p), false, 25), 25, "getFee reverts: the declaration");
        f.setAnswer(1, 0, 0);
        assertEq(BPC.readDynamicFee(address(p), false, 25), 25, "getFee answers nothing: the declaration");
        f.setAnswer(2, 5, 17);
        assertEq(BPC.readDynamicFee(address(p), true, 25), 5, "the live fee for the stable flag");
        assertEq(BPC.readDynamicFee(address(p), false, 25), 17, "and for the volatile one");
        f.setAnswer(2, 0, 0);
        assertEq(BPC.readDynamicFee(address(p), false, 25), 25, "zero is not a fee");
        f.setAnswer(2, full, full);
        assertEq(BPC.readDynamicFee(address(p), false, 25), 25, "100% is not a fee");
    }
}
