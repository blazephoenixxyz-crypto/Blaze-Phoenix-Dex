// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// HD-01 (audit 2026-11-06, area x-hops2-delta-final): with MAX_HOPS 2 and TOPOLOGIES 4 every
// route of a pair with no direct pool crosses exactly one bridge, so ONE poisoned pair per
// bridge, on whichever side of the bridge is thinner, reaches every route (no three-hop rescue).
//
// FIXTURE. X, Y (not bridges), bridges B1, B2, all 18 decimals. Addresses are sorted so that
// X < B1 < B2 < Y: on both poisoned pairs the victim sells token0. Honest V2 pairs, in value:
// X/B1 500k a side, B1/B2 5M a side, B2/Y 500k a side (the deep chain); X/B2 5k a side and
// B1/Y 2.5k a side (the thin sides). There is no X/Y pair. `k` is the unit gap: one X is worth
// k of a bridge token and one bridge token k of Y (k = 1: every token at par).
// THE BOOK (no privilege: Hub.claimV4 with a bridge side, hookless): a one-tick V4 position
// (spacing 1) at the top of tick -69078 (price token1/token0 ~ 1e-3), on (X,B2) and on (B1,Y).
// It holds only token1, the token the victim buys on that pair: ~1.58e-6 of its liquidity.
//
// WHAT WAS WRONG (MAT-01/MAT-02 behind HD-01). The funnel (`Solver._dropDust`) measured the book by
// its virtual depth and the honest row by its short side, a count of the DEAR token: with a unit gap a book
// holding 0.13 % of the bought token the honest row holds dropped it before it was quoted.
// WHAT IS LEFT, BY DESIGN. Mass is the bought token a row holds. A book holding MORE of it than
// the honest rows of its pair is the pair's majority and takes the band's base (the 50 %
// breakdown point, test/BandBaseBreakdownPoint.t.sol): the par fixture below pins that limit on
// the thin side of each bridge, where the majority is cheapest.
// MEASURED VS MODELLED THIN ROWS (2026-11-24). `BlazePhoenixMath._measuredAbove` keeps in the band
// a row above the base whose rate the contract measures (attested V2 reserves, hook-free singleton
// books). With the thin rows as V2 pairs the books' base no longer drops them and the plan pays the
// clean price to the wei: HD-01 is closed for measured rows (the `MeasuredThinRows` test). The limit
// stands where the thin rows are rows the contract only models (hooked V4 books of the same depth),
// which the band's upper edge still drops.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, RoutePlan, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract HD01OneCutPerBridgeTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;

    address X;
    address B1;
    address B2;
    address Y;

    address constant ATK = address(0xA77AC);
    uint24 constant FEE = 101;
    int24 constant TS = 1;
    int24 constant TLO = -69078;           // 1.0001^-69078 ~ 1.0003e-3
    uint256 constant THIN_XB2 = 5_000e18;  // the thin rows, in bridge tokens
    uint256 constant THIN_B1Y = 2_500e18;
    address constant HOOK = address(uint160(0x1000)); // a listed hook: its rows are modelled
    int24 constant HTS = 60;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));

        address[4] memory t;
        for (uint256 i; i < 4; ++i) t[i] = address(new PathologicalERC20("T", "T", 18));
        for (uint256 i; i < 4; ++i)
            for (uint256 j = i + 1; j < 4; ++j)
                if (t[j] < t[i]) (t[i], t[j]) = (t[j], t[i]);
        (X, B1, B2, Y) = (t[0], t[1], t[2], t[3]);

        hub.addBridge(B1);
        hub.addBridge(B2);
    }

    /// The honest market, with one X worth `k` bridge tokens and one bridge token worth `k` Y.
    function _market(uint256 k) internal {
        _deepRows(k);
        _pair(X, B2, THIN_XB2 / k, THIN_XB2);
        _pair(B1, Y, THIN_B1Y, THIN_B1Y * k);
    }

    /// The deep chain X/B1, B1/B2, B2/Y: V2 pairs, as in `_market`.
    function _deepRows(uint256 k) internal {
        _pair(X, B1, 500_000e18 / k, 500_000e18);
        _pair(B1, B2, 5_000_000e18, 5_000_000e18);
        _pair(B2, Y, 500_000e18, 500_000e18 * k);
    }

    /// The par market with the thin rows as rows the contract only models: a full-range V4 book
    /// at par behind a listed hook, fee 0.3 %, of the V2 pair's depth on each thin side. Above
    /// the books' base it falls past the band's upper edge, as every row did before
    /// `BlazePhoenixMath._measuredAbove`.
    function _marketWithModelledThinRows() internal {
        _deepRows(1);
        _hooked(X, B2, uint128(THIN_XB2));
        _hooked(B1, Y, uint128(THIN_B1Y));
    }

    function _hooked(address c0, address c1, uint128 liq) internal {
        require(c0 < c1, "fixture: sorted pair");
        PathologicalERC20(c0).mint(address(mgr), liq);
        PathologicalERC20(c1).mint(address(mgr), liq);
        hub.allowHook(HOOK, true);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, 3000, HTS, HOOK);
        mgr.initialize(pid, mgr.sqrtAt(0), 0, 3000);
        mgr.addPosition(pid, -887220, 887220, HTS, liq);
        hub.addV4(c0, c1, 3000, HTS, HOOK);
    }

    /// Precondition: besides the book, the pair's rows are what `modelled` names: only the hooked
    /// book (modelled), or only a V2 pair, whose reserves the contract reads (measured).
    function _thinRowIs(address c0, address c1, bool modelled) internal view {
        PoolInfo[] memory rows = hub.getActivePools(c0, c1);
        uint256 seen;
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].hooks == address(0) && rows[i].fee == FEE) continue; // the book
            ++seen;
            if (modelled) assertEq(rows[i].hooks, HOOK, "precondition: a thin row the contract measures");
            else assertTrue(rows[i].kind == BPC.KIND_V2 && rows[i].hooks == address(0),
                "precondition: a thin row the contract does not measure");
        }
        assertEq(seen, 1, "precondition: one thin row beside the book");
    }

    function _pair(address a, address b, uint256 sideA, uint256 sideB) internal {
        MockV2Pair p = new MockV2Pair(a, b);
        PathologicalERC20(a).mint(address(p), sideA);
        PathologicalERC20(b).mint(address(p), sideB);
        p.setReserves(uint112(sideA), uint112(sideB));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), a, b);
    }

    /// One tick of liquidity `liq` at the top of TLO: the book holds only token1.
    function _poison(address t0, address t1, uint128 liq) internal returns (bytes32 pid, uint256 held) {
        require(t0 < t1, "fixture: sorted pair");
        pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(TLO + 1) - 1, TLO, FEE);
        mgr.addPosition(pid, TLO, TLO + 1, TS, liq);
        (, held, ) = BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, TS, true, type(uint256).max);
        PathologicalERC20(t1).mint(address(mgr), held + 1);
        vm.prank(ATK);
        hub.claimV4(t0, t1, FEE, TS);
    }

    function _virtual(address t0, address t1, bytes32 pid) internal view returns (uint256) {
        return BPC.registryDepth18(address(uint160(uint256(pid))), BPC.KIND_V4, t0, t1, address(mgr), pid);
    }

    function _plan(uint256 amount) internal view returns (uint256 out) {
        try solver.findBestRoutePlan(X, Y, amount) returns (RoutePlan memory p) {
            return p.best.totalOut;
        } catch {
            return 0;
        }
    }

    /// A unit gap of 3,000 on both bridges. Each book's virtual depth is over 40,000 times the
    /// short side of the honest row beside it, and it holds under 1 % of the token that row
    /// pays in. Both honest rows stay in the plan and the victim is paid the clean price.
    function test_HD01_OneCheapCutPerBridgeAcrossAUnitGapDoesNotTakeTheVictimsInput() public {
        uint256 k = 3_000;
        uint256 amount = 100e18 / k;
        _market(k);
        uint256 clean = _plan(amount);
        assertGt(clean, 95e18 * k, "control: the clean plan routes 100 of value at > 95");

        (bytes32 p1, uint256 h1) = _poison(X, B2, 4e24);
        (bytes32 p2, uint256 h2) = _poison(B1, Y, 6e27);
        assertLt(THIN_XB2 / k * 1e6, 25 * _virtual(X, B2, p1), "fixture: X/B2 virtual depth over 40,000 short sides");
        assertLt(THIN_B1Y * 1e6, 25 * _virtual(B1, Y, p2), "fixture: B1/Y virtual depth over 40,000 short sides");
        assertLt(h1 * 100, THIN_XB2, "fixture: the X/B2 book holds under 1 % of the honest row's B2");
        assertLt(h2 * 100, THIN_B1Y * k, "fixture: the B1/Y book holds under 1 % of the honest row's Y");

        assertGe(_plan(amount), clean * 99 / 100, "one cheap cut per bridge took the route across a unit gap");
    }

    /// THE DESIGNED LIMIT, pinned. At par each book holds ~1.58e22 of the bought token against
    /// the 5e21 and 2.5e21 of the honest thin rows: it is the majority of its pair's mass, and
    /// the majority is the market. With two hops and no direct pool there is no third route.
    /// History (2026-11-24): the thin rows were V2 pairs. Since `BlazePhoenixMath._measuredAbove`
    /// keeps a measured row above the base, those pairs stay beside the books and the plan pays
    /// the clean price to the wei (97438603280857971576 against a limit of 974386032808579715):
    /// HD-01 is closed for measured rows (test_HD01_MeasuredThinRows_ABookHoldingMost...). The
    /// limit stands where the thin rows are modelled, so they are seated as hooked V4 books of
    /// the same depth; every assertion and number is unchanged.
    function test_limit_HD01_ABookHoldingMostOfTheBoughtTokenOnEachThinSideTakesTheRoute() public {
        _marketWithModelledThinRows();
        uint256 clean = _plan(100e18);
        assertGt(clean, 95e18, "control: the clean plan routes 100 X at > 95 Y");

        (, uint256 h1) = _poison(X, B2, 1e28);
        (, uint256 h2) = _poison(B1, Y, 1e28);
        _thinRowIs(X, B2, true);
        _thinRowIs(B1, Y, true);
        assertLe(BPC.outSide18(uint128(THIN_XB2), mgr.sqrtAt(0), true, 18), THIN_XB2,
            "fixture: the hooked X/B2 row holds no more B2 than the V2 pair did");
        assertLe(BPC.outSide18(uint128(THIN_B1Y), mgr.sqrtAt(0), true, 18), THIN_B1Y,
            "fixture: the hooked B1/Y row holds no more Y than the V2 pair did");
        assertGt(h1, THIN_XB2, "fixture: the X/B2 book holds more B2 than the honest row");
        assertGt(h2, THIN_B1Y, "fixture: the B1/Y book holds more Y than the honest row");

        uint256 got = _plan(100e18);
        assertGt(got, 0, "fixture: the plan routes through the books, it does not revert");
        assertLt(got, clean / 100, "limit moved: a majority of held mass no longer takes the base");
    }

    /// HD-01 closed for measured rows. The same par market and the same books as the limit above,
    /// with the thin rows as V2 pairs: the contract reads their reserves, so
    /// `BlazePhoenixMath._measuredAbove` keeps them in the band above the books' base, and the
    /// plan pays the clean price to the wei. Red when the band's union with the measured rows is
    /// removed (MV-1): the upper edge drops the pairs and the route crosses the books at ~1e-3.
    function test_HD01_MeasuredThinRows_ABookHoldingMostOfTheBoughtTokenOnEachThinSideDoesNotTakeTheRoute() public {
        _market(1);
        uint256 clean = _plan(100e18);
        assertGt(clean, 95e18, "control: the clean plan routes 100 X at > 95 Y");

        (, uint256 h1) = _poison(X, B2, 1e28);
        (, uint256 h2) = _poison(B1, Y, 1e28);
        _thinRowIs(X, B2, false);
        _thinRowIs(B1, Y, false);
        assertGt(h1, THIN_XB2, "fixture: the X/B2 book holds more B2 than the honest row");
        assertGt(h2, THIN_B1Y, "fixture: the B1/Y book holds more Y than the honest row");

        assertEq(_plan(100e18), clean, "a measured thin row above the books' base was dropped");
    }
}
