// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A SINGLE LEG'S PROMISE UNDER, AT AND OVER WHAT ITS POOL HOLDS
//
//  `_singleLeg` drops a reserve-shaped candidate whose promise is above the
//  pool's tokenOut holdings (`out > held`): no pool pays more than it holds, so
//  the figure is forged. A V2 row cannot stand on that edge: the Core does not
//  quote a pair that declares more than it holds (`heldBy`), and x*y=k promises
//  less than the reserve. A Solidly row can: its promise is the pair's own
//  `getAmountOut` less one wei, and a pair may answer any figure while it holds
//  what it declares.
//
//  Oracle: the holdings are minted by hand (1e24) and the pair is told what to
//  answer for the whole order: the holdings, one wei more, two wei more. The
//  promise is then the holdings less one wei, the holdings, the holdings plus
//  one wei. A promise the pool can pay to the wei is kept; one wei more is
//  dropped, and where the row is the only one the Solver refuses by SolverE(5).
//
//  Matrix (range x vector x dimension):
//    - range: the promise one wei under, at, and one wei over the holdings;
//    - vector: a Solidly pair with honest reserves whose answer for the order
//      is forged;
//    - dimension: a lone candidate (its holdings are read after its quote) and
//      a candidate beside an honest pool (its holdings are the probe pass's
//      reading, and the split gate is what asks the single).
//
//  Guards of a line that had no mutant (no fix: green before and after). Red
//  under (mutants.py): [morf-SQ2-15] the single also refuses a promise equal to
//  the holdings (`>=`); [morf-SQ2-16] the single's holdings check removed.
//
//  forge test --match-path test/SingleLegPromiseAtItsHoldings.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// A Solidly pair that answers a chosen figure for one chosen size, and its curve for every other.
contract ForgedAnswerSolidlyPair is MockSolidlyPair {
    uint256 public forgedIn;
    uint256 public forgedOut;

    constructor(address a, address b) MockSolidlyPair(a, b, false) {}

    function answer(uint256 amountIn, uint256 out) external { forgedIn = amountIn; forgedOut = out; }

    function getAmountOut(uint256 amountIn, address tokenIn) public view override returns (uint256) {
        if (amountIn == forgedIn) return forgedOut;
        return super.getAmountOut(amountIn, tokenIn);
    }
}

contract SingleLegPromiseAtItsHoldingsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 A;
    MockERC20 B;
    ForgedAnswerSolidlyPair pair;

    uint256 constant ORDER = 1e21;
    uint256 constant HELD = 1e24;   // what each pool declares, and holds, of each token

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        pair = new ForgedAnswerSolidlyPair(address(A), address(B));
        A.mint(address(pair), HELD);
        B.mint(address(pair), HELD);
        pair.setReserves(uint112(HELD), uint112(HELD));
        hub.seedPool(address(pair), BPC.KIND_SOLIDLY, 30, address(0), pair.token0(), pair.token1());
    }

    /// An honest V2 pool of the same depth on the same pair: the hop has two candidates, so the
    /// probe pass reads the holdings and the split gate asks each single at full size.
    function _honestRival() internal {
        MockV2Pair p = new MockV2Pair(address(A), address(B));
        A.mint(address(p), HELD);
        B.mint(address(p), HELD);
        p.setReserves(uint112(HELD), uint112(HELD));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(A), address(B));
    }

    function _solve() internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(solver).staticcall(
            abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (address(A), address(B), ORDER)));
    }

    /// The legs of the one hop of the plan's best route.
    function _legs() internal view returns (Leg[] memory legs) {
        (bool ok, bytes memory ret) = _solve();
        assertTrue(ok, "the row has no route");
        RoutePlan memory plan = abi.decode(ret, (RoutePlan));
        assertEq(plan.best.hops.length, 1, "setup: a direct pair, one hop");
        legs = plan.best.hops[0].legs;
    }

    function _assertTheForgedSingle(uint256 promised, string memory what) internal view {
        Leg[] memory legs = _legs();
        assertEq(legs.length, 1, "the hop is not one leg");
        assertEq(legs[0].pool, address(pair), "the leg is not the pair under test");
        assertEq(legs[0].expectedOut, promised, what);
    }

    // ─── a lone candidate: the holdings are read after the quote ─────────────

    function test_ALonePoolPromisingExactlyItsHoldings_IsKept() public {
        pair.answer(ORDER, HELD);
        _assertTheForgedSingle(HELD - 1, "the neighbour: a promise one wei under the holdings is kept");
        pair.answer(ORDER, HELD + 1);
        _assertTheForgedSingle(HELD, "a promise the pool can pay to the wei was dropped");
    }

    function test_ALonePoolPromisingOneWeiOverItsHoldings_IsRefused() public {
        pair.answer(ORDER, HELD + 1);
        _assertTheForgedSingle(HELD, "the neighbour: at the holdings the same row routes");
        pair.answer(ORDER, HELD + 2);
        (bool ok, bytes memory ret) = _solve();
        assertFalse(ok, "a promise above what the pool holds was routed");
        assertEq(ret, abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)), "refused by SolverE(5)");
    }

    // ─── beside an honest pool: the holdings are the probe pass's reading ────

    function test_BesideAnHonestPool_APromiseOfExactlyTheHoldings_IsTheSingleKept() public {
        _honestRival();
        pair.answer(ORDER, HELD + 1);
        _assertTheForgedSingle(HELD, "the gate did not keep the single that promises its whole holdings");
    }

    function test_BesideAnHonestPool_APromiseOverTheHoldings_ReachesNoLeg() public {
        _honestRival();
        pair.answer(ORDER, HELD + 1);
        _assertTheForgedSingle(HELD, "the neighbour: at the holdings the single is the plan");
        pair.answer(ORDER, HELD + 2);
        Leg[] memory legs = _legs();
        for (uint256 i; i < legs.length; ++i) {
            assertLe(legs[i].expectedOut, HELD, "a leg is promised more than its pool holds");
        }
    }
}
