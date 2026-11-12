// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// HD-01, AT THE USER'S DOORS: what the caller's `userMinOut` does on the designed limit.
//
// test/Hd01OneCutPerBridge.t.sol pins the limit on the Solver alone: at par, a one-tick V4 book
// on the thin side of each bridge, holding most of the token the victim buys on that pair, is
// the pair's majority and takes the plan (100 X: ~96.46 Y clean, ~0.0997 Y with the books).
// This file asks the next question on the path a user actually takes - the Quoter's
// `previewPlanExact`, then the Router - in the two orders the books and the quote can come in.
//
//   BOOKS AFTER THE QUOTE. The floor is derived from the clean quote (99.5 % of it).
//     T1  the solving door (`swapBestExactIn`) re-solves in the transaction, meets the books
//         and is refused at the caller's floor: RouterE(5), the input never leaves the user.
//     T1b the calldata door (`swapExactIn`) carries the clean route, whose venues the books do
//         not touch: it pays the clean quote, to the wei.
//   BOOKS BEFORE THE QUOTE.
//     T2  the quote already prices the books; delivery equals the quote on both doors, to the
//         wei. The quote is honest, and a floor derived from it protects nothing that the quote
//         gave away: this is the limit, pinned (`test_limit_`), not a guard.
//   THE FLOOR'S EDGE.
//     T3  a floor equal to the delivery settles; one wei above it is refused with RouterE(5),
//         on both doors.
//   THE GRID. Order 1, 100 and 10,000 X; books of L = 1e26, 1e27, 3e27, 5e27 and 1e28. Each
//   holds ~1.58e-6 of L in the bought token: 1.6e20 and 1.6e21 are under both thin rows (5e21 of
//   B2, 2.5e21 of Y), 4.7e21 is over the B1/Y row only, 7.9e21 and 1.6e22 are over both.
//     T4  with a clean-quote floor, the solving door either refuses with RouterE(5) or pays at
//         least the floor; the calldata door pays the clean quote in every cell.
//
// What changes this file's verdicts: the solving door forwarding something other than the
// caller's floor to the settlement (mutant "swapBestExactIn settles against a floor of 1 wei",
// .github/scripts/mutants.py, paired with T1).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract Hd01MinOutGuardTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    address X;
    address B1;
    address B2;
    address Y;

    address constant ATK = address(0xA77AC);
    address constant USER = address(0xBEEF);
    uint24 constant FEE = 101;
    int24 constant TS = 1;
    int24 constant TLO = -69078;           // 1.0001^-69078 ~ 1.0003e-3
    uint128 constant L_LIMIT = 1e28;       // the limit fixture's book (Hd01OneCutPerBridge)
    uint256 constant ORDER = 100e18;
    uint256 constant SLIP_BPS = 50;        // the caller's floor: 99.5 % of the quote

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        address[4] memory t;
        for (uint256 i; i < 4; ++i) t[i] = address(new PathologicalERC20("T", "T", 18));
        for (uint256 i; i < 4; ++i)
            for (uint256 j = i + 1; j < 4; ++j)
                if (t[j] < t[i]) (t[i], t[j]) = (t[j], t[i]);
        (X, B1, B2, Y) = (t[0], t[1], t[2], t[3]);

        hub.addBridge(B1);
        hub.addBridge(B2);

        // The par market of Hd01OneCutPerBridge: a deep chain and two thin sides, no X/Y pair.
        _pair(X, B1, 500_000e18);
        _pair(B1, B2, 5_000_000e18);
        _pair(B2, Y, 500_000e18);
        _pair(X, B2, 5_000e18);
        _pair(B1, Y, 2_500e18);

        PathologicalERC20(X).mint(USER, 100_000e18);
        vm.prank(USER);
        PathologicalERC20(X).approve(address(router), type(uint256).max);
    }

    // ---- fixture ----------------------------------------------------------------------------

    function _pair(address a, address b, uint256 side) internal {
        MockV2Pair p = new MockV2Pair(a, b);
        PathologicalERC20(a).mint(address(p), side);
        PathologicalERC20(b).mint(address(p), side);
        p.setReserves(uint112(side), uint112(side));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), a, b);
    }

    /// One tick of liquidity `liq` at the top of TLO on (t0, t1): the book holds only token1, the
    /// token the victim buys on that pair. Claimed through the permissionless door.
    function _book(address t0, address t1, uint128 liq) internal returns (uint256 held) {
        require(t0 < t1, "fixture: sorted pair");
        bytes32 pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(TLO + 1) - 1, TLO, FEE);
        mgr.addPosition(pid, TLO, TLO + 1, TS, liq);
        (, held, ) = BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, TS, true, type(uint256).max);
        PathologicalERC20(t1).mint(address(mgr), held + 1);
        vm.prank(ATK);
        hub.claimV4(t0, t1, FEE, TS);
    }

    /// The books of HD-01: one on the thin side of each bridge, on mixed sides.
    function _books(uint128 liq) internal returns (uint256 hXB2, uint256 hB1Y) {
        hXB2 = _book(X, B2, liq);
        hB1Y = _book(B1, Y, liq);
    }

    function _quote(uint256 amount) internal returns (Route memory route, uint256 exactOut) {
        (route, exactOut) = quoter.previewPlanExact(X, Y, amount);
    }

    function _floor(uint256 q) internal pure returns (uint256) {
        return q * (10_000 - SLIP_BPS) / 10_000;
    }

    function _err(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// The solving door: the route is found inside the transaction. Returns success, the revert
    /// data, and the Y the user received.
    function _best(uint256 amount, uint256 minOut) internal returns (bool ok, bytes memory ret, uint256 got) {
        uint256 y0 = PathologicalERC20(Y).balanceOf(USER);
        bytes memory cd = abi.encodeCall(
            BlazePhoenixRouter.swapBestExactIn, (X, Y, amount, minOut, USER, vm.getBlockTimestamp() + 1)
        );
        vm.prank(USER);
        (ok, ret) = address(router).call(cd);
        got = PathologicalERC20(Y).balanceOf(USER) - y0;
    }

    /// The calldata door: the route the Quoter returned, as the user submits it.
    function _exactIn(Route memory route, uint256 amount, uint256 minOut)
        internal returns (bool ok, bytes memory ret, uint256 got)
    {
        uint256 y0 = PathologicalERC20(Y).balanceOf(USER);
        bytes memory cd = abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (route, amount, minOut, USER, vm.getBlockTimestamp() + 1)
        );
        vm.prank(USER);
        (ok, ret) = address(router).call(cd);
        got = PathologicalERC20(Y).balanceOf(USER) - y0;
    }

    /// What a door would pay with no floor of the caller's (1 wei), executed and undone.
    function _bestUnbound(uint256 amount) internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        bool ok;
        bytes memory ret;
        (ok, ret, got) = _best(amount, 1);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        vm.revertToState(snap);
    }

    function _exactInUnbound(Route memory route, uint256 amount) internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        bool ok;
        bytes memory ret;
        (ok, ret, got) = _exactIn(route, amount, 1);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        vm.revertToState(snap);
    }

    // ---- T1: books after the quote ---------------------------------------------------------

    /// The user quotes the clean market and signs 99.5 % of it; the books land before the
    /// transaction. The solving door re-solves into the books and the caller's floor refuses
    /// the fill: RouterE(5), and the user keeps every X.
    function test_HD01_BooksAfterTheQuote_TheSolvingDoorIsRefusedAtTheCallersFloor() public {
        (, uint256 q) = _quote(ORDER);
        emit log_named_uint("clean quote, exactOut (Y wei)", q);
        assertGt(q, 95e18, "control: the clean quote routes 100 X at > 95 Y");

        (uint256 h1, uint256 h2) = _books(L_LIMIT);
        assertGt(h1, 5_000e18, "fixture: the X/B2 book holds more B2 than the honest row");
        assertGt(h2, 2_500e18, "fixture: the B1/Y book holds more Y than the honest row");

        uint256 unbound = _bestUnbound(ORDER);
        emit log_named_uint("solving door with the books, floor 1 wei (Y wei)", unbound);
        assertLt(unbound, _floor(q), "fixture: with the books the solving door pays under the floor");

        uint256 x0 = PathologicalERC20(X).balanceOf(USER);
        (bool ok, bytes memory ret, uint256 got) = _best(ORDER, _floor(q));
        assertFalse(ok, "the solving door settled under the caller's floor");
        assertEq(ret, _err(5), "refused by the floor, RouterE(5)");
        assertEq(got, 0, "no Y moved");
        assertEq(PathologicalERC20(X).balanceOf(USER), x0, "the user keeps the input");
    }

    /// The same order of events on the calldata door: the signed route names the clean venues,
    /// and the books are not on it. It pays the clean quote to the wei.
    function test_HD01_BooksAfterTheQuote_TheCalldataDoorPaysTheCleanQuote() public {
        (Route memory route, uint256 q) = _quote(ORDER);
        _books(L_LIMIT);
        (bool ok, , uint256 got) = _exactIn(route, ORDER, _floor(q));
        emit log_named_uint("calldata door, clean route, books present (Y wei)", got);
        assertTrue(ok, "the clean route settles");
        assertEq(got, q, "the clean route pays the clean quote");
    }

    // ---- T2: books before the quote --------------------------------------------------------

    /// THE LIMIT, at the doors. Books first: the quote already carries them and delivery equals
    /// it to the wei on both doors. The quote is honest; a floor derived from it binds the
    /// delivery to the books' price and says nothing about the clean market.
    function test_limit_HD01_BooksBeforeTheQuote_TheQuoteIsTheBooksPriceAndDeliveryEqualsIt() public {
        (, uint256 clean) = _quote(ORDER);
        _books(L_LIMIT);
        (Route memory route, uint256 q) = _quote(ORDER);
        emit log_named_uint("clean quote (Y wei)", clean);
        emit log_named_uint("quote with the books (Y wei)", q);
        assertLt(q, clean / 100, "limit moved: the quote no longer carries the books");
        assertGt(q, 0, "fixture: the books still pay something");

        uint256 a = _exactInUnbound(route, ORDER);
        uint256 b = _bestUnbound(ORDER);
        emit log_named_uint("calldata door delivered (Y wei)", a);
        emit log_named_uint("solving door delivered (Y wei)", b);
        assertEq(a, q, "calldata door: delivery equals the quote");
        assertEq(b, q, "solving door: delivery equals the quote");

        (bool ok, , uint256 got) = _exactIn(route, ORDER, _floor(q));
        assertTrue(ok, "a floor derived from the poisoned quote settles");
        assertEq(got, q);
    }

    // ---- T3: the floor's edge --------------------------------------------------------------

    function test_HD01_FloorEqualToTheDeliverySettles_OneWeiAboveIsRefused_CalldataDoor() public {
        _books(L_LIMIT);
        (Route memory route, ) = _quote(ORDER);
        uint256 d = _exactInUnbound(route, ORDER);

        uint256 snap = vm.snapshotState();
        (bool ok, , uint256 got) = _exactIn(route, ORDER, d);
        assertTrue(ok, "a floor equal to the delivery settles");
        assertEq(got, d);
        vm.revertToState(snap);

        bytes memory ret;
        (ok, ret, got) = _exactIn(route, ORDER, d + 1);
        assertFalse(ok, "one wei above the delivery settled");
        assertEq(ret, _err(5));
        assertEq(got, 0);
    }

    function test_HD01_FloorEqualToTheDeliverySettles_OneWeiAboveIsRefused_SolvingDoor() public {
        _books(L_LIMIT);
        uint256 d = _bestUnbound(ORDER);

        uint256 snap = vm.snapshotState();
        (bool ok, , uint256 got) = _best(ORDER, d);
        assertTrue(ok, "a floor equal to the delivery settles");
        assertEq(got, d);
        vm.revertToState(snap);

        bytes memory ret;
        (ok, ret, got) = _best(ORDER, d + 1);
        assertFalse(ok, "one wei above the delivery settled");
        assertEq(ret, _err(5));
        assertEq(got, 0);
    }

    // ---- T4: the grid ----------------------------------------------------------------------

    /// Order size x book size, books after a clean quote. In every cell the solving door either
    /// refuses with RouterE(5) or pays at least the caller's floor, and the calldata door pays
    /// the clean quote. The cells and their outcome are logged.
    function test_HD01_Grid_ACleanQuoteFloorIsNeverUndercutOnEitherDoor() public {
        uint256[3] memory orders = [uint256(1e18), 100e18, 10_000e18];
        uint128[5] memory liqs = [uint128(1e26), 1e27, 3e27, 5e27, 1e28];
        uint256 refused;
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 5; ++j) {
                uint256 snap = vm.snapshotState();
                (Route memory route, uint256 q) = _quote(orders[i]);
                (uint256 h1, uint256 h2) = _books(liqs[j]);
                uint256 floor_ = _floor(q);

                uint256 s2 = vm.snapshotState();
                uint256 unbound = _bestUnbound(orders[i]);
                (bool ok, bytes memory ret, uint256 got) = _best(orders[i], floor_);
                vm.revertToState(s2);
                (bool okA, , uint256 gotA) = _exactIn(route, orders[i], floor_);

                emit log_named_uint("order (X wei)", orders[i]);
                emit log_named_uint("  book L", liqs[j]);
                emit log_named_uint("  book (X,B2) holds B2", h1);
                emit log_named_uint("  book (B1,Y) holds Y", h2);
                emit log_named_uint("  clean quote", q);
                emit log_named_uint("  solving door, floor 1 wei", unbound);
                emit log_named_uint("  solving door, clean floor (0 = refused)", ok ? got : 0);
                emit log_named_uint("  calldata door, clean route", gotA);

                if (ok) {
                    assertGe(got, floor_, "the solving door settled under the caller's floor");
                } else {
                    assertEq(ret, _err(5), "a refusal that is not the floor's");
                    assertLt(unbound, floor_, "refused although the solve pays the floor");
                    ++refused;
                }
                assertTrue(okA, "the clean route did not settle");
                assertEq(gotA, q, "the clean route did not pay the clean quote");
                vm.revertToState(snap);
            }
        }
        emit log_named_uint("cells refused by the floor", refused);
        assertGt(refused, 0, "fixture: no cell reached the books");
    }
}
