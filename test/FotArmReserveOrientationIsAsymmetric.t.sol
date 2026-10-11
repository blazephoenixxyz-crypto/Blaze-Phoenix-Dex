// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The fee-on-transfer arm of `_execPairAmt` reads the reserves on the RIGHT sides
//  — measured with ASYMMETRIC reserves, which no fixture in this suite ever built.
//
//  The site of the question: src/BlazePhoenixRouter.sol:1863-1867 (the arm entered
//  when the pool did not receive the amount the Router sent):
//
//      (uint256 r0b, uint256 r1b) = BPC.getReserves(leg.pool);
//      uint256 rInB  = leg.zeroForOne ? r0b : r1b;
//      uint256 realIn = balAfter - rInB;
//      if (realIn == 0) revert RouterE(8);
//      askIn = realIn;
//      if (isV2) { rIn = rInB; rOut = leg.zeroForOne ? r1b : r0b; }   // <- line 1867
//
//  Line 1867 is the only place in the file where the OUTPUT side is chosen from a
//  re-read of the reserves. Measured on this tree @754d651:
//    * `git grep setReserves -- test/` gives 246 call sites; a paren-balanced parse
//      finds the asymmetric ones, and **every suite that actually enters this arm**
//      builds its pair EQUAL on both sides — PartialFotAtPrePulledDoors.t.sol:184,
//      ClassicDoorAsymmetricFotReprice.t.sol:63, FotFloorReprice.t.sol:112/:115,
//      PathologicalTokens.t.sol:105/:106, and the regime matrices
//      (HostileVenueMatrix.t.sol:98/:104/:117) all pass the same value twice.
//    * With `r0b == r1b` the choice on line 1867 is arithmetically Inert: swapping
//      the two sides cannot change a number that is the same on both sides.
//  So a mutation of that line survived the three suites NOTA-FB-03 names AND the
//  four fee-on-transfer suites (42 and 24 tests green, both runs) — not because the
//  tests assert nothing, but because **no test in the corpus distinguishes the two
//  sides there**. This file is the fixture that does.
//
//  The fixture is a single V2 leg through a token that taxes BOTH the pull and the
//  push (`PathologicalERC20.feeOnTransferBps`, mocks/PathologicalERC20.sol:144-157
//  — one `_transfer` for both entry points), so the pool receives less than the
//  Router sent and the arm is entered. It asserts the DEFINITIONAL delivery:
//
//      delivered == outV2(realIn, rIn, rOut, fee)
//
//  with `realIn` measured from the pool's own balance in the test and `rIn`/`rOut`
//  the stored reserves on the correct sides. The assertion separates all three
//  worlds by construction: with the arm not entered the Router would quote the
//  amount it SENT (larger than what arrived) and the figure would be too big; with
//  the sides swapped it would quote the output side from the input reserve.
//
//  forge test --match-contract FotArmReserveOrientationIsAsymmetric -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";

contract FotArmReserveOrientationIsAsymmetricTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    PathologicalERC20 tokenIn; // taxes the pull AND the push (one _transfer for both)
    MockERC20 tokenOut;
    MockV2Pair pair;

    address user = address(0xBEEF);

    uint256 constant R0 = 4_000_000e18; // the two sides are 4x apart: orientation is visible
    uint256 constant R1 = 1_000_000e18;
    uint256 constant N  = 1_000e18;     // nominal input the Solver plans with
    uint16  constant TAX = 100;         // 1% on every move, both directions

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        tokenIn = new PathologicalERC20("Tax In", "TIN", 18);
        tokenOut = new MockERC20("Out", "OUT");

        pair = new MockV2Pair(address(tokenIn), address(tokenOut));

        // Put the reserves on the side each token actually is, and make them unequal.
        bool inIs0 = pair.token0() == address(tokenIn);
        pair.setReserves(uint112(inIs0 ? R0 : R1), uint112(inIs0 ? R1 : R0));
        tokenIn.mint(address(pair), R0);
        tokenOut.mint(address(pair), R1);
        tokenIn.setFeeOnTransferBps(TAX);

        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), address(tokenIn), address(tokenOut));

        tokenIn.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    /// @dev The stored reserves, on the side each token is — the pair's own answer.
    function _storedReserves() private view returns (uint256 rIn, uint256 rOut) {
        (uint256 a, uint256 b) = (pair.reserve0(), pair.reserve1());
        bool inIs0 = pair.token0() == address(tokenIn);
        rIn  = inIs0 ? a : b;
        rOut = inIs0 ? b : a;
    }

    /// @dev One leg, exactly as the Solver emits it: priced on the NOMINAL amount
    ///      (the Solver cannot see a tax), floor left to the protocol.
    function _route(uint256 nominalQuote) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: pair.token0() == address(tokenIn),
            stable: false, amountIn: N, expectedOut: nominalQuote, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: N, expectedOut: nominalQuote, legs: legs
        });
        r = Route({
            hops: hops, totalOut: nominalQuote, singleOut: nominalQuote, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// @notice The delivery equals the definitional quote on the MEASURED arrival and
    ///         the stored reserves on their own sides — with 4x apart, which is what
    ///         makes the two sides distinguishable at all.
    function test_TheTaxedArmQuotesOnTheReserveOfEachSide() public {
        (uint256 rIn, uint256 rOut) = _storedReserves();
        assertGt(rIn, rOut, "precondition: the fixture is asymmetric, input side deep");

        uint256 nominalQuote = BPC.outV2(N, rIn, rOut, 30);
        uint256 poolBefore = tokenIn.balanceOf(address(pair));

        Route memory r = _route(nominalQuote);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(r, N, 1, user, block.timestamp + 1);

        // What the pool actually received: measured here, not derived — the arm's own
        // `realIn` is `balAfter - rInB`, and in this fixture the pool's balance before
        // the push IS its stored reserve, so the two are the same number.
        uint256 arrived = tokenIn.balanceOf(address(pair)) - poolBefore;
        assertGt(arrived, 0, "precondition: the taxed push arrived at all");
        assertLt(arrived, N, "precondition: the pool received LESS than was sent (the arm is entered)");

        emit log_named_uint("measured arrival (arrived)", arrived);
        emit log_named_uint("delivered (the Router's own figure)", delivered);
        emit log_named_uint("definitional outV2(arrived, rIn, rOut)", BPC.outV2(arrived, rIn, rOut, 30));

        assertEq(
            delivered,
            BPC.outV2(arrived, rIn, rOut, 30),
            "the arm must quote the measured arrival against the reserve of each side"
        );
        assertEq(tokenOut.balanceOf(user), delivered, "the recipient got exactly the returned amount");
        assertEq(tokenOut.balanceOf(address(router)), 0, "the router holds no tokenOut");

        // SELF-FALSIFICATION — the third of the three obligatory tests of the house note
        // (`CONHECIMENTO.md` Camada 1, extract of
        // `~/.claude/projects/-home-blaze-cofre/memory/reference_poc_against_deployed_bytecode.md:30-50`,
        // test 3): assert the ABSENCE of the figure that would appear if the pool had been
        // quoted on what the Router SENT instead of on what ARRIVED. Without this, the
        // equality above could hold while the tax were invisible for some other reason.
        assertNotEq(delivered, BPC.outV2(N, rIn, rOut, 30),
            "the delivery must NOT be the tax-blind figure (sent amount as the quote base)");
    }

    /// @notice POSITIVE CONTROL -- the second of the three obligatory tests of the house note
    ///         (`CONHECIMENTO.md` Camada 1, extract of
    ///         `reference_poc_against_deployed_bytecode.md:30-50`, test 2): prove that the
    ///         validation path RUNS and REJECTS something, with OUR selector. The earlier
    ///         version of this control only compared two formula evaluations, which is
    ///         exactly the shape the note calls "accepts 256/256 may just mean there is no
    ///         validation on this path". Here the Router's own min-out gate must reject the
    ///         tax-blind figure (`RouterE(5)`, `src/BlazePhoenixRouter.sol:1571`), and the
    ///         separation must be a real margin, not 1 wei.
    function test_Control_TheTaxBlindFigureIsRejectedByOurOwnMinOutGate() public {
        (uint256 rIn, uint256 rOut) = _storedReserves();
        assertGt(rIn, rOut, "precondition: the fixture is asymmetric, input side deep");

        uint256 taxBlind = BPC.outV2(N, rIn, rOut, 30);                       // as if no tax
        uint256 taxAware  = BPC.outV2(N - (N * TAX) / 10_000, rIn, rOut, 30); // one tax, one side
        assertGt(taxBlind, taxAware, "control: the two worlds must be apart");
        assertGe(taxBlind - taxAware, N / 1000,
            "control: the separation must be a real margin, not a rounding artefact");

        // The gate RUNS and REJECTS, with our code: the honest path delivers strictly less
        // than the tax-blind promise, so demanding that promise must revert.
        Route memory r = _route(taxBlind);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(r, N, taxBlind, user, block.timestamp + 1);
    }
}
