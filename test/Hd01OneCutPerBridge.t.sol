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

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
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
        _pair(X, B1, 500_000e18 / k, 500_000e18);
        _pair(B1, B2, 5_000_000e18, 5_000_000e18);
        _pair(B2, Y, 500_000e18, 500_000e18 * k);
        _pair(X, B2, THIN_XB2 / k, THIN_XB2);
        _pair(B1, Y, THIN_B1Y, THIN_B1Y * k);
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
    function test_limit_HD01_ABookHoldingMostOfTheBoughtTokenOnEachThinSideTakesTheRoute() public {
        _market(1);
        uint256 clean = _plan(100e18);
        assertGt(clean, 95e18, "control: the clean plan routes 100 X at > 95 Y");

        (, uint256 h1) = _poison(X, B2, 1e28);
        (, uint256 h2) = _poison(B1, Y, 1e28);
        assertGt(h1, THIN_XB2, "fixture: the X/B2 book holds more B2 than the honest row");
        assertGt(h2, THIN_B1Y, "fixture: the B1/Y book holds more Y than the honest row");

        assertLt(_plan(100e18), clean / 100, "limit moved: a majority of held mass no longer takes the base");
    }
}
