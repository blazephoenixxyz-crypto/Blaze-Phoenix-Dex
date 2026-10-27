// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  3073-5 [743], the walk's own budget, without a fork.
//  Red against mutant [697] of .github/scripts/mutants.py at 59ecf3f; green on 59ecf3f.
//
//  The capacity rebuild of a held winning build runs in a static self-call on
//  exactly WALK_GAS (Solver, 2,500,000); a rebuild that runs out of it leaves the
//  plan at the cap. WALK_GAS was sized on the Base fork (d188006: live rebuilds
//  1.63M-1.69M, DAI->USDC 10k and 15k), and the fork test that pinned it
//  (test/fork/CapacityPromiseAsksTheVenue.t.sol) passed with WALK_GAS at 1.5M
//  once the 10-26 gas commits made that rebuild cheaper: it no longer needs
//  more than 1.5M, so it no longer tells 1.5M from 2.5M.
//
//  Here the rebuild's cost is set by the test: four held V3 books whose every
//  tick read costs four storage words plus a fixed EXTRA of gas (the cost of an
//  answer is the venue's choice, below GAS_CAP). Its measured cost sits in the
//  middle of the gap between 1.5M and WALK_GAS; the sentinel keeps it there, so
//  the test goes red rather than silently stop guarding.
//
//  MEASURED at 59ecf3f, FOUNDRY_PROFILE=release, -vvvv:
//    the rebuild frame inside the solve (staticcall on WALK_GAS)   1,916,348 gas
//      = 1.5M + 416,348, and WALK_GAS - 583,652
//    the same rebuild as its own call from the test (colder)        2,027,571 gas
//      (111,223 over the frame: hub, pools and slots the solve had already warmed)
//    with WALK_GAS at 1.5M (mutant [697]) the frame runs out and every leg keeps the cap.
//  The sentinel bounds the own call to (1.8M, 2.3M): the frame then stays above
//  1.5M by at least ~190k and under WALK_GAS by at least 200k.
//
//  forge test --match-path test/CapacityWalkNeedsItsWholeBudget.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// A V3-shaped book whose ticks() reads four storage words per tick, as UniswapV3Pool's does,
/// and then spends a fixed EXTRA of gas: an honest book whose answers cost what it chooses.
contract CostlyBookPool is MockV3Pool {
    uint256 public constant EXTRA = 10_000;
    int24 public tickSpacing;
    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => uint256[4]) internal info;

    constructor(address a, address b, uint24 f, int24 ts) MockV3Pool(a, b, f) { tickSpacing = ts; }

    function setTick(int24 t, int128 n) external {
        int24 c = t / tickSpacing;
        tickBitmap[int16(c >> 8)] |= uint256(1) << (uint256(uint24(c)) & 0xff);
        info[t] = [uint256(uint128(n)) << 128 | 1, 7, 7, 7];
    }

    function ticks(int24 t)
        external view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        uint256[4] memory w = info[t];
        uint256 g = gasleft();
        while (g - gasleft() < EXTRA) {}
        return (uint128(w[0]), int128(int256(w[0] >> 128)), w[1], w[2], int56(int256(w[3] & 1)), 0, 0, true);
    }
}

contract CapacityWalkNeedsItsWholeBudgetTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    address tIn;
    address tOut;

    uint160 constant SP   = uint160(1 << 96);   // price 1, tick 0
    uint128 constant L    = 1_000e18;
    int24   constant TS   = 60;
    uint256 constant IN   = 200e18;
    uint256 constant HELD = 100e18;             // cap 30e18 per book; a quarter of IN walks ~43.7e18

    /// Solver.WALK_GAS and the budget of mutant [697].
    uint256 constant WALK_GAS   = 2_500_000;
    uint256 constant SHORT_WALK = 1_500_000;

    /// Solver.MAX_CONC_DRAIN_BPS: a held leg's cap is this share of its pool's tokenOut holdings.
    uint256 constant MAX_CONC_DRAIN_BPS = 3_000;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        address a = address(new MockERC20("A", "A"));
        address b = address(new MockERC20("B", "B"));
        (tIn, tOut) = a < b ? (a, b) : (b, a);   // token0 in: zeroForOne
        uint24[4] memory fees = [uint24(3_000), 500, 10_000, 100];
        for (uint256 k; k < 4; ++k) {
            CostlyBookPool p = new CostlyBookPool(tIn, tOut, fees[k], TS);
            p.setState(SP, L);
            for (int24 i = 1; i <= 20; ++i) {
                p.setTick(-i * TS, int128(L / 1000));
                p.setTick(i * TS, -int128(L / 1000));
            }
            MockERC20(tIn).mint(address(p), HELD);
            MockERC20(tOut).mint(address(p), HELD);
            hub.seedPool(address(p), BPC.KIND_V3, fees[k], address(0), tIn, tOut);
        }
    }

    /// The rebuild alone, as the Solver calls itself (build 0, the direct one; the rank to
    /// beat does not change the work), from the test frame: its gas.
    function _rebuildGas() internal returns (uint256 used) {
        bytes memory cd = abi.encodePacked(
            abi.encodeCall(BlazePhoenixSolver.findBestRoutePlan, (tIn, tOut, IN)), uint256(0), uint256(0)
        );
        vm.prank(address(solver));
        uint256 g0 = gasleft();
        (bool ok, ) = address(solver).call(cd);
        used = g0 - gasleft();
        assertTrue(ok, "precondition: the rebuild completes on unbounded gas");
    }

    /// Every held leg of the split is promised its own book's walk at its committed input,
    /// above its cap: the rebuild completed on WALK_GAS. On 1.5M it runs out and every leg
    /// keeps the cap.
    function test_3073_HeldSplit_RebuildPastOnePointFiveMillion_IsPromisedItsBooks() public {
        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, IN);
        Leg[] memory legs = plan.best.hops[0].legs;
        assertEq(legs.length, 4, "precondition: the four held books split the order");
        uint256 cap = BPC.mulDiv(HELD, MAX_CONC_DRAIN_BPS, BPC.BPS);
        for (uint256 i; i < legs.length; ++i) {
            uint256 w = BPC.v4WalkOut(legs[i].pool, bytes32(0), legs[i].amountIn, 0, 0, legs[i].zeroForOne);
            assertGt(w, cap, "precondition: each book pays past its cap");
            assertEq(legs[i].expectedOut, w, "the held leg is promised its book's walk, not the cap");
        }

        // Sentinel: the rebuild's cost stays inside (SHORT_WALK, WALK_GAS) with room on both sides.
        uint256 g = _rebuildGas();
        emit log_named_uint("rebuild gas, own call", g);
        assertGt(g, SHORT_WALK + 300_000, "the rebuild no longer needs more than 1.5M: re-size EXTRA");
        assertLt(g, WALK_GAS - 200_000, "the rebuild nears WALK_GAS: re-size EXTRA");
    }
}
