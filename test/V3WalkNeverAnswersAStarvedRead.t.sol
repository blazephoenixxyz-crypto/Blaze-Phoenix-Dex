// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A V3 WALK NEVER ANSWERS OFF A READ ITS FRAME STARVED (DEX-01, R1).
//
//  `Core.v3PaysOnBudget` reads a V3 book through `_fedRead`, which holds ASK_GAS_FLOOR before
//  each read so that the read gets its whole GAS_CAP; a frame that cannot forward it reverts
//  empty, the house out-of-gas signature. Without that guard a read handed less is made
//  anyway, a pool that refuses it is read as zero by `_v3Get`, and the walk answers off the
//  gas its caller attached instead of off the book: a liquidityNet read as zero walks on past
//  the thick range at its depth, and the promise rises.
//
//  The pool is MockV3TickPool with burnOnRead: slot0() and ticks() cost 60,000 gas each and
//  refuse when handed less than a GAS_CAP read leaves them after dispatch, as a pool whose
//  code reads gasleft() would. The sweep follows SolidlyPairWithoutStableGetter's pattern:
//  every gas from 150,000 to 450,000 in steps of 499, each from a cold pool.
//
//  MEASURED (FOUNDRY_PROFILE=release): 395 refusals, 207 answers, the first at gas 347,105.
//
//  The walk is new in DEX-01, so there is no base to be red at: the red is mutant [913] of
//  .github/scripts/mutants.py, the guard removed.
//
//  forge test --match-path test/V3WalkNeverAnswersAStarvedRead.t.sol -vv
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV3TickPool} from "./mocks/MockV3TickPool.sol";

contract V3WalkNeverAnswersAStarvedRead is Test {
    MockV3TickPool pool;

    uint24  constant FEE   = 3000;
    int24   constant TS    = 60;
    uint128 constant THICK = 1e21;    // the range around the price
    uint128 constant THIN  = 1e17;    // the book beyond it
    uint256 constant AMT   = 1e18;    // an order that leaves the thick range
    uint256 constant BURN  = 60_000;  // what each slot0() and ticks() read costs

    /// The order sells token0: the price sits one tick inside [0, 60), so the thick range
    /// ends one tick ahead (an initialized tick whose liquidityNet the walk must read) and
    /// only the thin book is beyond it.
    function setUp() public {
        pool = new MockV3TickPool(address(0xA), address(0xB), FEE, TS);
        pool.initialize(1);
        pool.addPosition(0, 60, THICK);
        pool.addPosition(-887220, 887220, THIN);
        pool.burnOnRead(BURN);
    }

    /// At every gas the walk is handed, it pays what the book pays or it refuses with the
    /// out-of-gas signature; it never answers off a read its frame starved.
    function test_AWalkUnderEveryGas_PaysWhatTheBookPaysOrNothing() public {
        uint256 truth = this.walk();
        (, uint256 pays, , , ) = pool.specSwap(AMT, true, BPC.MIN_SQRT_PRICE_PLUS_ONE);
        assertApproxEqAbs(truth, pays, 4, "premise: handed plenty, the walk is what the pool pays");
        assertLt(truth, AMT / 2, "premise: past the thick range the book pays far less than through it");
        uint256 oks;
        uint256 refusals;
        uint256 first;
        for (uint256 g = 150_000; g <= 450_000; g += 499) {
            vm.cool(address(pool));
            try this.walk{gas: g}() returns (uint256 q) {
                assertEq(q, truth, string.concat("the walk answered off a starved read, at gas ", vm.toString(g)));
                if (oks++ == 0) first = g;
            } catch (bytes memory err) {
                assertEq(err.length, 0, "a refusal is the out-of-gas signature");
                ++refusals;
            }
        }
        console2.log("refusals, answers, first answer at gas:", refusals, oks, first);
        assertGt(oks, 0, "the sweep reaches the gas that walks the book");
        assertGt(refusals, 0, "the sweep starts below the gas a walk needs");
    }

    /// The walk on the whole read budget, against no band: its own figure.
    function walk() external view returns (uint256 q) {
        (q, ) = BPC.v3PaysOnBudget(address(pool), AMT, true, type(uint256).max, BPC.V3_PAY_READS);
    }
}
