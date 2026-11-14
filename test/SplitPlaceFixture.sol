// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PLACE, LINE BY LINE (2026-11-11). `Solver._placed` tries the legs of a split of three or more one
// at a time (`_onTrial`), takes the leg that does not pay for its place out of the four arrays in
// lockstep (`_leave`, `_swap`) and builds the split again. test/SplitLegPaysForItsPlace.t.sol holds
// the cases the rule was written for: one venue behind 10% beside honest ones, one trial. The lines
// a single trial never reads had no mutant: the second trial of a build, the build no leg is tried
// in, the held mark of a build whose trial is not held, the lockstep of the holdings and of the
// probe rates, the tie of the seat, and a trial on each hop of a two-hop route. Each test below
// names the mutant that turns it red (.github/scripts/mutants.py, [ATQ-mutacao-n]).
//
// The fixtures are those of SplitLegPaysForItsPlace: full-range V3 venues at price 1 whose factory
// tier is the fee they charge, and concentrated books that declare more than they hold.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver, MIN_SPLIT_IMPROVEMENT_PPM} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV3BookPool} from "./mocks/MockV3BookPool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

/// The market, the venues and the readings of a preview, shared with test/SplitPlaceKnownRed.t.sol.
abstract contract SplitPlaceFixture is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    address recipient = makeAddr("recipient");
    uint128 constant HONEST_L = 100e18;
    uint24 constant HONEST_FEE = 3000;
    uint24 constant DEAR_FEE = 100_000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        _market();
    }

    /// Fresh tokens, so a test can open a second market.
    function _market() internal {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    /// A coherent venue at price 1 on (a, b): liquidity `l`, holding `l + extra` of each token.
    function _venueOn(MockERC20 a, MockERC20 b, uint24 fee, uint128 l, uint256 extra) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(a), address(b), fee);
        p.setState(uint160(BPC.Q96), l);
        a.mint(address(p), l + extra);
        b.mint(address(p), l + extra);
        Origin.wire(hub, address(p), address(a), address(b), BPC.KIND_V3, fee);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), address(a), address(b));
    }

    function _venue(uint24 fee, uint128 l) internal returns (MockV3Pool) {
        return _venueOn(tA, tB, fee, l, 0);
    }

    /// A book behind `fee` at price 1 (spacing 60, no initialized tick): it declares a million
    /// times HONEST_L and holds `held` of each token.
    function _book(uint24 fee, uint256 held) internal returns (MockV3BookPool p) {
        p = new MockV3BookPool(address(tA), address(tB), fee, 60);
        p.setState(uint160(BPC.Q96), 1_000_000 * HONEST_L);
        tA.mint(address(p), held);
        tB.mint(address(p), held);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, fee);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), address(tA), address(tB));
    }

    function _previewOn(MockERC20 a, MockERC20 b, uint256 amt) internal returns (BlazePhoenixQuoter.Preview memory pv) {
        vm.roll(block.number + 1);
        (pv, ) = quoter.previewAndEncode(address(a), address(b), amt, recipient, block.timestamp);
    }

    function _preview(uint256 amt) internal returns (BlazePhoenixQuoter.Preview memory) {
        return _previewOn(tA, tB, amt);
    }

    function _inOf(BlazePhoenixQuoter.Preview memory pv, address p) internal pure returns (uint256 s) {
        for (uint256 h; h < pv.route.hops.length; ++h) {
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                if (pv.route.hops[h].legs[l].pool == p) s += pv.route.hops[h].legs[l].amountIn;
            }
        }
    }

    function _outOf(BlazePhoenixQuoter.Preview memory pv, address p) internal pure returns (uint256 s) {
        for (uint256 h; h < pv.route.hops.length; ++h) {
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                if (pv.route.hops[h].legs[l].pool == p) s += pv.route.hops[h].legs[l].expectedOut;
            }
        }
    }

}
