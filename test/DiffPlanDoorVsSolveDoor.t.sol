// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The two doors of one swap, against each other, from the same state. atq-1111, front "dif".
//
//    plan door    Quoter.previewAndEncode[WithMinOut] -> bytes -> Router.swapExactIn
//    solve door   Router.swapBestExactIn (the route is found on chain)
//
//  A caller who previews and sends the bytes and a caller who lets the Router solve must end
//  with the same tokens; what the preview says (canExecute, effectiveMinOut, estGas) is judged
//  by what the Router then does, never by another figure of the preview.
//
//  test/QuoteDelayStatistics.t.sol asks the plan door alone on V2 under drift. Here both doors
//  run on every world of the venue lattice (V2, V3, Solidly, one hop and two), with no drift,
//  so every difference is the doors' own.
//
//  Mutants: [ATQ-dif-20] .. [ATQ-dif-23] in .github/scripts/mutants.py.
//
//  forge test --match-path test/DiffPlanDoorVsSolveDoor.t.sol
// =============================================================================
import {DiffWorld, MockERC20, BlazePhoenixQuoter, BlazePhoenixRouter} from "./DiffWorld.sol";

contract DiffPlanDoorVsSolveDoorTest is DiffWorld {
    function setUp() public {
        _stack();
    }

    /// Both doors on one order: equal delivery, each door's return value equal to the balance
    /// delta it caused, and a preview that said the bytes would settle.
    function _sameDelivery(MockERC20 tIn, MockERC20 tOut, uint256 amt, string memory where) internal {
        Shot memory b = _solveOnSnapshot(tIn, tOut, amt, 1);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory cd, Shot memory p) = _planOnSnapshot(tIn, tOut, amt, 0);
        assertTrue(b.ok, string.concat("the solve door refused ", where));
        assertTrue(pv.canExecute, string.concat("the preview said no to an order the solve door executes ", where));
        assertGt(cd.length, 0, string.concat("an executable preview came without bytes ", where));
        assertTrue(p.ok, string.concat("the Router refused the bytes of an executable preview ", where));
        assertEq(p.delivered, b.delivered, string.concat("the two doors delivered different amounts ", where));
        assertEq(b.returned, b.delivered, string.concat("the solve door returned another figure than it delivered ", where));
        assertEq(p.returned, p.delivered, string.concat("the plan door returned another figure than it delivered ", where));
        assertGe(p.delivered, pv.effectiveMinOut, string.concat("the bytes delivered under the floor they carry ", where));
    }

    /// 15 lattice worlds and 3 hop worlds, two directions, five sizes: 180 orders.
    function test_Doors_ThePlanBytesDeliverExactlyWhatTheSolveDoorDelivers() public {
        uint256[5] memory a = _grid();
        for (uint256 mask = 1; mask < 16; ++mask) {
            (MockERC20 x, MockERC20 y) = _lattice(mask);
            for (uint256 i; i < 5; ++i) {
                _sameDelivery(x, y, a[i], _at("", mask, 0, a[i]));
                _sameDelivery(y, x, a[i], _at("", mask, 1, a[i]));
            }
        }
        for (uint256 mask = 1; mask < 4; ++mask) {
            (MockERC20 x, MockERC20 y) = _hopWorld(mask);
            for (uint256 i; i < 5; ++i) {
                _sameDelivery(x, y, a[i], _at("(hop world)", mask, 0, a[i]));
                _sameDelivery(y, x, a[i], _at("(hop world)", mask, 1, a[i]));
            }
        }
    }

    /// One order of the small ladder through both doors. Returns whether it settled.
    function _smallOrder(Pair memory w, uint256 kind, uint256 amt) internal returns (bool) {
        Shot memory b = _solveOnSnapshot(w.x, w.y, amt, 1);
        string memory where = _at("", kind, 0, amt);
        // Where the Solver finds no route the plan door refuses by revert, before any bytes
        // exist (test/QuoterPreviewAndEncode.t.sol, test_AnUnroutablePairRefusesBeforeAnyBytesExist):
        // that refusal must be the solve door's own, selector and code.
        uint256 snap = vm.snapshotState();
        (bool asked, bytes memory why) = address(quoter).call(
            abi.encodeCall(quoter.previewAndEncode, (address(w.x), address(w.y), amt, user, block.timestamp + 20)));
        vm.revertToState(snap);
        if (!asked) {
            assertFalse(b.ok, string.concat("the plan door refused an order the solve door executes ", where));
            assertEq(why.length, 36, string.concat("the plan door refused without a coded error ", where));
            uint256 c;
            assembly ("memory-safe") { c := mload(add(why, 36)) }
            assertEq(bytes4(why), b.sel, string.concat("the two doors refused with different errors ", where));
            assertEq(c, b.code, string.concat("the two doors refused with different codes ", where));
            assertEq(b.delivered, 0, string.concat("a refused order delivered ", where));
            return false;
        }
        (BlazePhoenixQuoter.Preview memory pv, bytes memory cd, Shot memory p) = _planOnSnapshot(w.x, w.y, amt, 0);
        assertEq(pv.canExecute, b.ok, string.concat("the preview and the solve door disagree on whether the order settles ", where));
        assertEq(cd.length != 0, pv.canExecute, string.concat("bytes and canExecute disagree ", where));
        if (b.ok) {
            assertTrue(p.ok, string.concat("the Router refused the bytes of an executable preview ", where));
            assertEq(p.delivered, b.delivered, string.concat("the two doors delivered different amounts ", where));
        } else {
            assertEq(b.delivered, 0, string.concat("a refused order delivered ", where));
        }
        return b.ok;
    }

    /// The smallest orders, where every rounding is a whole unit: 2 to 64 units on a V2 and on
    /// a V3 venue. The preview says canExecute exactly where the solve door executes, hands
    /// bytes exactly where it says so, and the bytes then deliver what the solve door delivers.
    function test_Doors_OnTheSmallestOrdersThePreviewSaysCanExecuteExactlyWhereTheSolveDoorExecutes() public {
        uint256 executed;
        for (uint256 kind; kind < 2; ++kind) {
            Pair memory w = _latticePair(kind == 0 ? 1 : 2);
            for (uint256 amt = 2; amt <= 64; ++amt) {
                if (_smallOrder(w, kind, amt)) ++executed;
            }
        }
        assertGt(executed, 0, "no order of the ladder executed: the relation was never asked");
    }

    /// One caller floor `m` asked of the plan door. Returns 1 if the preview said canExecute.
    function _previewAt(Pair memory w, uint256 tag, uint256 amt, uint256 m, uint256 k) internal returns (uint256 kept) {
        (BlazePhoenixQuoter.Preview memory pv, bytes memory cd, Shot memory p) = _planOnSnapshot(w.x, w.y, amt, m);
        string memory where = _at(string.concat("floor ", vm.toString(m)), tag, 0, amt);
        assertEq(cd.length != 0, pv.canExecute, string.concat("bytes and canExecute disagree, ", where));
        if (pv.canExecute) {
            kept = 1;
            assertGe(pv.effectiveMinOut, m, string.concat("the floor in the preview is under the caller's, ", where));
            assertTrue(p.ok, string.concat("the Router refused the bytes of an executable preview, ", where));
            assertGe(p.delivered, m, string.concat("the bytes delivered under the caller's floor, ", where));
        }
        if (k < 2) assertTrue(pv.canExecute, string.concat("the preview refused a floor its own netOut covers, ", where));
        if (k == 4) assertFalse(pv.canExecute, string.concat("the preview promised more than the venues deliver, ", where));
    }

    /// The five floors around the delivery `d` of one order, asked of the plan door.
    function _previewLine(Pair memory w, uint256 tag, uint256 amt) internal returns (uint256 kept, uint256 d) {
        (BlazePhoenixQuoter.Preview memory pv0,, Shot memory p0) = _planOnSnapshot(w.x, w.y, amt, 0);
        assertTrue(p0.ok, _at("the floorless bytes did not settle", tag, 0, amt));
        d = p0.delivered;
        uint256[5] memory floors = [uint256(1), pv0.netOut, pv0.netOut + 1, d, d + 1];
        for (uint256 k; k < 5; ++k) {
            kept += _previewAt(w, tag, amt, floors[k], k);
        }
    }

    /// The same line asked of the solve door: it settles at m = d and refuses m = d + 1.
    function _solveLine(Pair memory w, uint256 tag, uint256 amt, uint256 d) internal {
        Shot memory met = _solveOnSnapshot(w.x, w.y, amt, d);
        assertTrue(met.ok, _at("the solve door refused a floor equal to its own delivery", tag, 0, amt));
        assertEq(met.delivered, d, _at("the solve door delivered another amount under a floor it meets", tag, 0, amt));
        Shot memory over = _solveOnSnapshot(w.x, w.y, amt, d + 1);
        assertFalse(over.ok, _at("the solve door settled one unit under the caller's floor", tag, 0, amt));
        assertEq(bytes32(over.sel), bytes32(BlazePhoenixRouter.RouterE.selector), _at("a floor one unit too high was refused with a foreign error", tag, 0, amt));
        assertEq(over.code, 5, _at("a floor one unit too high was refused with another code", tag, 0, amt));
        assertEq(over.delivered, 0, _at("a refused order delivered", tag, 0, amt));
    }

    /// A caller floor m, asked of both doors around what the venues really deliver (D, measured
    /// with no floor). A preview that says canExecute hands bytes that settle and deliver at
    /// least m; no preview says canExecute for m = D + 1; the solve door settles at m = D and
    /// refuses m = D + 1 with RouterE(5). Worlds: one V2 venue, three venues of three kinds,
    /// and the pair reachable by one hop and by two.
    function test_MinOut_NoPreviewPromisesAboveTheDeliveryAndEveryPromiseIsKept() public {
        uint256[2] memory amts = [uint256(1e18), 30_000e18];
        uint256 kept;
        for (uint256 tag; tag < 3; ++tag) {
            Pair memory w = tag == 0 ? _latticePair(1) : (tag == 1 ? _latticePair(7) : _hopPair(3));
            for (uint256 i; i < 2; ++i) {
                (uint256 k, uint256 d) = _previewLine(w, tag, amts[i]);
                kept += k;
                _solveLine(w, tag, amts[i], d);
            }
        }
        assertGt(kept, 0, "no preview said canExecute: the promise was never asked");
    }

    /// What one plan says it costs and what its bytes measure.
    struct Gas {
        bool ok;
        uint256 est;
        uint256 hops;
        uint256 legs;
        uint256 measured;
    }

    function _gasOf(Pair memory w, uint256 amt) internal returns (Gas memory g) {
        (BlazePhoenixQuoter.Preview memory pv,, Shot memory s) = _planOnSnapshot(w.x, w.y, amt, 0);
        g.ok = s.ok;
        g.est = pv.estGas;
        g.hops = pv.hops;
        g.legs = pv.legs;
        g.measured = s.gasUsed;
    }

    /// estGas is only asked what a figure in other units can be asked: its ORDER. Plans made of
    /// one venue kind (V2), so no ladder between kinds is involved: one leg, two legs in one
    /// hop, one leg in each of two hops. A plan with one more leg, or one more hop, is
    /// estimated dearer and measures dearer when its bytes run.
    function test_EstGas_OrdersPlansOfOneVenueKindAsTheirMeasuredGasDoes() public {
        Pair memory single = _latticePair(1);

        Pair memory twin = _latticePair(1);
        _venue(K_V2, twin.x, twin.y, 1_000_000e18, 1_000_000e18);

        Pair memory far;
        far.x = _token("X");
        far.y = _token("Y");
        MockERC20 m = _token("M");
        hub.addBridge(address(m));
        _venue(K_V2, far.x, m, 1_000_000e18, 1_000_000e18);
        _venue(K_V2, m, far.y, 1_000_000e18, 1_000_000e18);

        uint256 amt = 30_000e18;
        _gasOf(single, amt);   // warm-up: the measured runs start from the same warm slots
        Gas memory g1 = _gasOf(single, amt);
        Gas memory g2 = _gasOf(twin, amt);
        Gas memory g3 = _gasOf(far, amt);
        assertTrue(g1.ok && g2.ok && g3.ok, "a plan of the gas ladder did not settle");
        assertEq(g1.hops, 1, "the single venue was not planned as one hop");
        assertEq(g1.legs, 1, "the single venue was not planned as one leg");
        assertEq(g2.hops, 1, "the twin venues were not planned as one hop");
        assertEq(g2.legs, 2, "the twin venues were not split in two legs");
        assertEq(g3.hops, 2, "the bridged pair was not planned as two hops");
        assertEq(g3.legs, 2, "the bridged pair was not planned as one leg per hop");

        assertGt(g2.measured, g1.measured, "the mocks are no ladder: a second leg did not measure dearer");
        assertGt(g3.measured, g1.measured, "the mocks are no ladder: a second hop did not measure dearer");
        assertGt(g2.est, g1.est, "a second leg was not estimated dearer");
        assertGt(g3.est, g1.est, "a second hop was not estimated dearer");
    }
}
