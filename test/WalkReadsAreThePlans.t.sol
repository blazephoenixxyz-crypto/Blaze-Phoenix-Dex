// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE WALK'S READS ARE THE PLAN'S, COUNTED (INV-S6). The promise walk of a
//  concentrated leg (Solver._paysWhatItWalks -> Core.v3PaysOnBudget) spends one
//  V3_PAY_READS budget for the whole plan: a leg reached with five reads or
//  fewer left keeps its band. Mutant [912] (twelve reads for each leg) was held
//  only by gas: by test_3073_WalkBudget_ThreeBridgesSixBooks_Settles while the
//  cold plan ran past its share, and on gas52-main by a relative gas bound over
//  books that burn every read. Here the same property is a count: the calls the
//  plan makes to the books' tick reads (tickBitmap, ticks), recorded with
//  vm.startStateDiffRecording. A repricing moves gas, never this count.
//
//  The books hold UNHELD, so no cap binds and the search walks none of them:
//  the plan's tick reads are its promises'. Oracle: the call record, never the
//  code under test.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BurnBookPool} from "./CapacityWalkBudget.t.sol";

contract WalkReadsAreThePlansTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    address t0;
    address t1;
    address[] books;

    uint160 constant SP     = uint160(1 << 96);   // price 1, tick 0
    uint128 constant L      = 1_000e18;
    uint256 constant IN     = 200e18;
    uint256 constant UNHELD = 1_000e18;           // cap 300e18 >= the fill: no cap binds, even on one book

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        hub.setRoles(address(0xA11CE), address(solver), address(0xC0FFEE));
        t0 = address(new MockERC20("T", "T"));
        t1 = address(new MockERC20("T", "T"));
    }

    function _burnBook(uint256 k) internal {
        uint24 fee = uint24(500 + k * 1000);
        BurnBookPool p = new BurnBookPool(t0, t1, fee);
        p.setState(SP, L);
        MockERC20(t0).mint(address(p), UNHELD);
        MockERC20(t1).mint(address(p), UNHELD);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), t0, t1);
        books.push(address(p));
    }

    function _isBook(address a) internal view returns (bool) {
        for (uint256 i; i < books.length; ++i) if (books[i] == a) return true;
        return false;
    }

    /// The plan, and the calls it made to the books' tick reads (reverted ones included).
    function _plan() internal returns (RoutePlan memory plan, uint256 tickReads) {
        vm.startStateDiffRecording();
        plan = solver.findBestRoutePlan(t0, t1, IN);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; ++i) {
            if (!_isBook(acc[i].account)) continue;
            bytes4 s = bytes4(acc[i].data);
            if (s == BurnBookPool.tickBitmap.selector || s == BurnBookPool.ticks.selector) ++tickReads;
        }
    }

    /// Quantity: the tick reads of a plan over one book, then over four. The budget is the plan's,
    /// so three more books add less than one walk's V3_PAY_READS; twelve reads for each leg
    /// (mutant "DEX-01 budget [912]") walk every book. Relative, the same bound
    /// test_3073_WalkBudget_HostileBooks_OneWalkForTheWholePlan draws in gas.
    function test_WalkBudget_FourBooksReadLessThanTwoWalks() public {
        _burnBook(0);
        (RoutePlan memory one, uint256 r1) = _plan();
        for (uint256 k = 1; k < 4; ++k) _burnBook(k);
        (RoutePlan memory four, uint256 r4) = _plan();
        emit log_named_uint("tick reads of the plan, 1 book ", r1);
        emit log_named_uint("tick reads of the plan, 4 books", r4);
        assertEq(one.best.hops[0].legs.length, 1, "precondition: one book, one leg");
        assertEq(four.best.hops[0].legs.length, 4, "precondition: every book is a leg");
        uint256 cap = BPC.mulDiv(UNHELD, 3_000, BPC.BPS);
        for (uint256 i; i < 4; ++i) assertLe(four.best.hops[0].legs[i].expectedOut, cap, "precondition: no cap binds");
        assertGt(r1, 0, "the neighbour: the one leg's promise walks its book");
        // 12 is one walk's V3_PAY_READS, written by hand: read from the Core under test, the
        // bound would move with the constant it is there to hold.
        assertLt(r4, r1 + 12, "each leg of the plan walked on reads of its own");
    }
}
