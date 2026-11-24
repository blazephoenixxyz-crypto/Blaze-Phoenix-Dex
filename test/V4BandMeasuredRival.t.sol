// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Red at 6e5067b. LOCAL until it ships with its fix.
//
// THE PROPERTY (venue monotonicity, measured): adding a book to a hop never settles an order below
// what the same order settles for without it. The oracle is a TWIN universe, not a formula: the
// same honest V2 pair (M of each side) behind its own Hub, Solver, Router and V4 manager, which no
// attacker ever touches. `got(attacked) >= got(twin)`, to the wei, with no fee constant known here.
//
// THE ACTOR. `RivalHandler.book` is a stranger with no role in the Hub: it initializes one hookless
// V4 key (four fees x four spacings), leaves a one-sided position holding R of the bought token
// below the market (far ~1e-5, near ~0.49, or a wide spread: bids under ~0.89, asks at the market)
// and calls `Hub.claimV4`. `RivalHandler.swap` is the honest user on the production path
// (`findBestRoutePlan` then `swapExactIn(plan.best, ord, plan.best.singleOutFloor, ...)`), run in
// both universes inside a state snapshot.
//
// MATRIX. R {M-1, M, M+1, 2M, 1e24} x order {1e6, M/100, M/10, M} x both token orders x shape
// {far, near, wide spread}; mass split over eight keys; blind fuzz (pre-registered seeds
// 0xb1a2ef00, 0x1124a001, 0x1124a002, 0x1124a003); invariant with the handler.
// MUTANTS (planned): MV-1 measured rows above the base are dropped again -> every test_Macro_*;
// MV-4 the single-survivor gate runs only on two legs again -> test_Macro_* (one-leg cells).

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RivalHandler {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant ATK = address(0xA77AC);
    address constant USER = address(0xBEEF);
    uint256 constant Q96 = 2 ** 96;

    BlazePhoenixHub hub;              // the attacked universe's Hub
    MockV4TickManager mgr;            // the attacked universe's V4 manager
    BlazePhoenixSolver[2] solver;     // 0 = twin (no attacker), 1 = attacked
    BlazePhoenixRouter[2] router;
    address a;
    address b;

    uint256 public books;
    uint256 public claims;
    uint256 public settled;   // orders the twin settled
    uint256 public vetoes;    // of those, orders the attacked universe refused
    uint256 public losses;    // of those, orders the attacked universe settled for less
    uint256 public worstGot;
    uint256 public worstTwin;
    mapping(bytes32 => bool) made;

    constructor(
        BlazePhoenixHub hub_, MockV4TickManager mgr_, BlazePhoenixSolver[2] memory s, BlazePhoenixRouter[2] memory r,
        address a_, address b_
    ) {
        hub = hub_; mgr = mgr_; solver = s; router = r; a = a_; b = b_;
    }

    /// The attacker: one hookless book holding `r` of the token the victim buys, never at risk.
    function book(uint8 key, bool zfo, bool far, bool spread, uint256 r) public {
        r = 1 + r % 1e24;
        uint24 fee = [uint24(100), 500, 3000, 10000][key & 3];
        int24 ts = [int24(1), 10, 60, 200][(key >> 2) & 3];
        bytes32 pid = BPC.computeV4PoolId(a, b, fee, ts, address(0));
        if (made[pid]) return;
        int24 w = spread ? int24(600) : ts;
        int24 t = spread ? int24(1200) : far ? int24(115200) : int24(7200);
        int24 lo = zfo ? -t - w : t;
        uint160 sl = mgr.sqrtAt(lo);
        uint160 su = mgr.sqrtAt(lo + w);
        uint256 l = zfo ? BPC.mulDiv(r, Q96, su - sl) : BPC.mulDiv(BPC.mulDiv(r, sl, Q96), su, su - sl);
        if (l == 0 || l > type(uint128).max / 4) return;
        made[pid] = true;
        vm.startPrank(ATK);
        if (zfo) mgr.initialize(pid, su - 1, lo + w - 1, fee);
        else mgr.initialize(pid, sl, lo, fee);
        mgr.addPosition(pid, lo, lo + w, ts, uint128(l));
        if (spread) {
            if (zfo) mgr.addPosition(pid, 0, 600, ts, uint128(l));
            else mgr.addPosition(pid, -600, 0, ts, uint128(l));
        }
        try hub.claimV4(a, b, fee, ts) { ++claims; } catch {}
        vm.stopPrank();
        ++books;
    }

    function _run(uint256 u, address tIn, address tOut, uint256 ord) internal returns (uint256 got, bool ok) {
        try solver[u].findBestRoutePlan(tIn, tOut, ord) returns (RoutePlan memory plan) {
            if (plan.best.hops.length == 0) return (0, false);
            MockERC20(tIn).mint(USER, ord);
            vm.startPrank(USER);
            MockERC20(tIn).approve(address(router[u]), type(uint256).max);
            try router[u].swapExactIn(plan.best, ord, plan.best.singleOutFloor, USER, block.timestamp + 1)
                returns (uint256 g) { got = g; ok = true; } catch {}
            vm.stopPrank();
        } catch {}
    }

    /// The same order in both universes; nothing it does survives the call.
    function pay(uint256 ord, bool zfo) public returns (uint256 g1, uint256 g0, bool ok1, bool ok0) {
        (address tIn, address tOut) = zfo ? (a, b) : (b, a);
        uint256 s = vm.snapshotState();
        (g1, ok1) = _run(1, tIn, tOut, ord);
        (g0, ok0) = _run(0, tIn, tOut, ord);
        vm.revertToState(s);
    }

    /// The honest user.
    function swap(uint256 ord, bool zfo) public {
        ord = 1e6 + ord % 1e21;
        (uint256 g1, uint256 g0, bool ok1, bool ok0) = pay(ord, zfo);
        if (!ok0) return;
        ++settled;
        if (!ok1) { ++vetoes; return; }
        if (g1 < g0) {
            ++losses;
            if (worstTwin == 0 || g1 * worstTwin < worstGot * g0) { worstGot = g1; worstTwin = g0; }
        }
    }
}

contract V4BandMeasuredRivalTest is Test {
    uint256 constant M = 1e21;
    uint8 constant MODE_V4_DERIVE = 9;

    RivalHandler h;
    address a;
    address b;

    function _stack() internal returns (BlazePhoenixHub hub, MockV4TickManager mgr, BlazePhoenixSolver solver, BlazePhoenixRouter router) {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), new uint24[](0), new int24[](0));
        hub.addBridge(b);
        MockV2Pair pair = new MockV2Pair(a, b);
        MockERC20(a).mint(address(pair), M);
        MockERC20(b).mint(address(pair), M);
        pair.setReserves(uint112(M), uint112(M));
        hub.seedPool(address(pair), BPC.KIND_V2, 30, address(0), a, b);
        MockERC20(a).mint(address(mgr), 1e30);
        MockERC20(b).mint(address(mgr), 1e30);
    }

    function setUp() public {
        address x = address(new MockERC20("TKN", "TKN"));
        address y = address(new MockERC20("TKN", "TKN"));
        (a, b) = x < y ? (x, y) : (y, x);
        BlazePhoenixSolver[2] memory s;
        BlazePhoenixRouter[2] memory r;
        (, , s[0], r[0]) = _stack();
        BlazePhoenixHub hub;
        MockV4TickManager mgr;
        (hub, mgr, s[1], r[1]) = _stack();
        h = new RivalHandler(hub, mgr, s, r, a, b);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](2);
        sel[0] = RivalHandler.book.selector;
        sel[1] = RivalHandler.swap.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    uint256 nL;
    uint256 nBoth;
    uint256 nClaim;

    function _cell(uint8 key, bool zfo, bool far, bool spread, uint256 r, uint256 ord) internal {
        uint256 s = vm.snapshotState();
        h.book(key, zfo, far, spread, r - 1);
        uint256 c = h.claims();
        (uint256 g1, uint256 g0, bool ok1, bool ok0) = h.pay(ord, zfo);
        vm.revertToState(s);
        nClaim += c;
        if (ok0 && ok1) {
            ++nBoth;
            if (g1 < g0) {
                ++nL;
                emit log_named_uint(string.concat("L zfo=", zfo ? "1" : "0", " R=", vm.toString(r), " ord=", vm.toString(ord), " twin=", vm.toString(g0), " got"), g1);
            }
        }
    }

    function _grid(bool far, bool spread) internal {
        uint256[5] memory rs = [M - 1, M, M + 1, 2 * M, 1e24];
        uint256[4] memory ords = [uint256(1e6), M / 100, M / 10, M];
        for (uint256 z; z < 2; ++z)
            for (uint256 i; i < rs.length; ++i)
                for (uint256 j; j < ords.length; ++j) _cell(10, z == 1, far, spread, rs[i], ords[j]);
        assertGt(nClaim, 0, "vacuous: no book was claimed");
        assertEq(nBoth, 40, "vacuous: a cell did not settle in both universes");
        assertEq(nL, 0, "a book holding the bought token it never risks settled an order below the twin without it");
    }

    function test_Macro_FarOneSidedBookNeverLowersTheOrder() public { _grid(true, false); }
    function test_Macro_NearOneSidedBookNeverLowersTheOrder() public { _grid(false, false); }
    function test_Macro_WideSpreadBookNeverLowersTheOrder() public { _grid(false, true); }

    /// The majority split over eight keys: no single book outweighs the pair, their sum does.
    function test_Macro_MassSplitOverManyBooksNeverLowersTheOrder() public {
        for (uint256 z; z < 2; ++z) {
            uint256 s = vm.snapshotState();
            for (uint8 k; k < 8; ++k) h.book(k, z == 1, true, false, M / 4);
            assertEq(h.claims(), 8, "vacuous: a book was not claimed");
            (uint256 g1, uint256 g0, bool ok1, bool ok0) = h.pay(M / 100, z == 1);
            vm.revertToState(s);
            assertTrue(ok0 && ok1, "vacuous: the order did not settle in both universes");
            assertGe(g1, g0, "eight books that together outweigh the pair settled the order below the twin");
        }
    }

    function testFuzz_Macro_BlindRisklessBook(uint256 r, uint256 ord, uint8 key, bool zfo, bool far, bool spread) public {
        h.book(key, zfo, far, spread, r);
        (uint256 g1, uint256 g0, bool ok1, bool ok0) = h.pay(bound(ord, 1e6, M), zfo);
        if (ok0 && ok1) assertGe(g1, g0, "a stranger's book settled the order below the twin without it");
    }

    function invariant_NoBookLowersAnOrderBelowTheTwin() public view {
        assertEq(h.losses(), 0, "an order settled below the twin universe that holds no attacker book");
    }
}
