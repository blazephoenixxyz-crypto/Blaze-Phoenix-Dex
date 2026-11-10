// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE MASS OF A ROW ON A HOP IS THE BOUGHT TOKEN IT HOLDS (MAT-01, MAT-02; audit 2026-11-06).
// The funnel (`Solver._dropDust`), the band's vote (`Math._depthWeightedMedian`) and the
// weights (`Math._weights`) add and compare the masses of different rows, and a sum has a
// meaning only when every term counts the same token. For the hop tIn -> tOut the mass is
//     m = min(declared tokenOut side at the row's own price, tokenOut the row holds),
// normalised to 18 decimals. The three rules are homogeneous of degree zero in the mass, so
// restating tOut in another unit moves no decision; and m <= held, so out-massing the honest
// rows costs more of the bought token than they hold.
//
// This file: the funnel, and the one formula it shares with the vote (`Core.hopMass18` beside
// `Core.universalProbe`). The vote is test/Mat02BandVoteIsOneUnit.t.sol, the singleton book's
// virtual depth test/Mat01FunnelMassIsHeld.t.sol, two hops test/Hd01*.t.sol.
//
// Observable for "quoted": a Solidly row is quoted by asking the pool itself
// (getAmountOutWithTotalFee 0x0ea099c1, then getAmountOut 0xf140a35a).

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan, QuoteCtx} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {PhantomBook} from "./ConcentratedMassCap.t.sol";

contract HopMassIsTokenOutHeldTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockV4TickManager mgr;
    PathologicalERC20 a;   // token0
    PathologicalERC20 b;   // token1

    uint256 constant Q96 = uint256(1) << 96;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
    }

    // ---- fixtures ---------------------------------------------------------------------------

    function _tokens(uint8 dA, uint8 dB) internal {
        a = new PathologicalERC20("A", "A", dA);
        do { b = new PathologicalERC20("B", "B", dB); } while (address(b) < address(a));
    }

    function _v2(uint256 sideA, uint256 sideB) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), sideA);
        b.mint(address(p), sideB);
        p.setReserves(uint112(sideA), uint112(sideB));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(b));
    }

    function _solidly(uint256 sideA, uint256 sideB) internal returns (MockSolidlyPair s) {
        s = new MockSolidlyPair(address(a), address(b), false);
        a.mint(address(s), sideA);
        b.mint(address(s), sideB);
        s.setReserves(uint112(sideA), uint112(sideB));
        hub.seedPool(address(s), BPC.KIND_SOLIDLY, 30, address(0), address(a), address(b));
    }

    /// A singleton book at tick 0 with `liq` over [-20_040, 20_040].
    function _v4(uint24 fee, int24 ts, uint128 liq) internal returns (bytes32 pid) {
        return _v4At(fee, ts, 0, liq);
    }

    function _v4At(uint24 fee, int24 ts, int24 tick, uint128 liq) internal returns (bytes32 pid) {
        pid = BPC.computeV4PoolId(address(a), address(b), fee, ts, address(0));
        mgr.initialize(pid, BPC.sqrtPriceAtTick(tick), tick, fee);
        mgr.addPosition(pid, -20_040, 20_040, ts, liq);
        a.mint(address(mgr), liq);
        b.mint(address(mgr), liq);
        hub.addV4(address(a), address(b), fee, ts, address(0));
    }

    function _routes(Route memory r, address pool) internal pure returns (bool) {
        for (uint256 x; x < r.hops.length; ++x)
            for (uint256 y; y < r.hops[x].legs.length; ++y)
                if (r.hops[x].legs[y].pool == pool) return true;
        return false;
    }

    function _routed(address tIn, address tOut, uint256 amt, address pool) internal view returns (bool) {
        try solver.findBestRoutePlan(tIn, tOut, amt) returns (RoutePlan memory p) {
            return _routes(p.best, pool);
        } catch {
            return false;
        }
    }

    function _planCalls(address tIn, address tOut, uint256 amt) internal returns (VmSafe.AccountAccess[] memory acc) {
        vm.startStateDiffRecording();
        solver.findBestRoutePlan(tIn, tOut, amt);
        acc = vm.stopAndReturnStateDiff();
    }

    function _asks(VmSafe.AccountAccess[] memory acc, address pool) internal pure returns (uint256 n) {
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].account != pool || acc[i].data.length < 4) continue;
            bytes4 sel = bytes4(acc[i].data);
            if (sel == bytes4(0x0ea099c1) || sel == bytes4(0xf140a35a)) ++n;
        }
    }

    // ---- a concentrated book holding only the token being SOLD ------------------------------

    /// Honest pair: 50 A + 150,000 B (3,000 B per A). A V3-shaped book declares 1e33 of
    /// liquidity and holds 2,100,000 B and no A. The order sells B for A: the book holds
    /// nothing of the bought token, so it is no mass on this hop and the honest pair stays.
    /// (The registry's depth capped the book by its larger held side, 2.1e24 of B, against
    /// the pair's short side, 5e19 of A: 5e25 < 5.25e25, and the pair was dropped.)
    function _aBookHoldingOnlyTheSoldToken(uint8 dA, uint8 dB) internal {
        _tokens(dA, dB);
        uint256 uA = 10 ** dA;
        uint256 uB = 10 ** dB;
        MockV2Pair honest = _v2(50 * uA, 150_000 * uB);
        PhantomBook book = new PhantomBook(address(a), address(b), 3000);
        Origin.wire(hub, address(book), address(a), address(b), BPC.KIND_V3, 3000);
        book.setState(uint160(Q96), 1e33);
        b.mint(address(book), 2_100_000 * uB);
        assertTrue(_routed(address(b), address(a), 3_000 * uB, address(honest)),
            "a book holding none of the bought token dropped the honest pair");
        assertFalse(_routed(address(b), address(a), 3_000 * uB, address(book)),
            "a book holding none of the bought token was routed");
    }

    function test_Funnel_ABookHoldingOnlyTheSoldTokenDoesNotDropTheHonestPair_18_18() public {
        _aBookHoldingOnlyTheSoldToken(18, 18);
    }

    function test_Funnel_ABookHoldingOnlyTheSoldTokenDoesNotDropTheHonestPair_18_6() public {
        _aBookHoldingOnlyTheSoldToken(18, 6);
    }

    function test_Funnel_ABookHoldingOnlyTheSoldTokenDoesNotDropTheHonestPair_8_6() public {
        _aBookHoldingOnlyTheSoldToken(8, 6);
    }

    function test_Funnel_ABookHoldingOnlyTheSoldTokenDoesNotDropTheHonestPair_6_18() public {
        _aBookHoldingOnlyTheSoldToken(6, 18);
    }

    // ---- a singleton book counts what it holds: dust beside it is still dust ----------------

    /// A singleton book priced at par (one A for one B), L = 1e6 * sqrt(unit A * unit B) over
    /// +-20,040 ticks, declares 1,000,000 of either token and holds ~633,000. Beside it and a
    /// pair of 100,000 a side, a row of 10 a side is over 25 ppm of the pair alone (2.5) and
    /// under 25 ppm of the pair plus what the book holds (18.3): it is dropped before any
    /// quote, in both directions.
    function _dustBesideADeepBook(uint8 dA, uint8 dB) internal {
        _tokens(dA, dB);
        uint256 uA = 10 ** dA;
        uint256 uB = 10 ** dB;
        int24 par = (int24(int8(dB)) - int24(int8(dA))) * 23_027 / 60 * 60;
        bytes32 pid = BPC.computeV4PoolId(address(a), address(b), 3000, 60, address(0));
        mgr.initialize(pid, BPC.sqrtPriceAtTick(par), par, 3000);
        mgr.addPosition(pid, par - 20_040, par + 20_040, 60, uint128(1e6 * 10 ** ((dA + dB) / 2)));
        a.mint(address(mgr), 1e7 * uA);
        b.mint(address(mgr), 1e7 * uB);
        hub.addV4(address(a), address(b), 3000, 60, address(0));
        MockSolidlyPair kept = _solidly(100_000 * uA, 100_000 * uB);
        MockSolidlyPair dust = _solidly(10 * uA, 10 * uB);
        VmSafe.AccountAccess[] memory acc = _planCalls(address(a), address(b), 1_000 * uA);
        assertGt(_asks(acc, address(kept)), 0, "control: a row above 25 ppm of its pair is quoted");
        assertEq(_asks(acc, address(dust)), 0, "selling token0: dust beside a deep singleton book was quoted");
        acc = _planCalls(address(b), address(a), 1_000 * uB);
        assertGt(_asks(acc, address(kept)), 0, "control: a row above 25 ppm of its pair is quoted");
        assertEq(_asks(acc, address(dust)), 0, "selling token1: dust beside a deep singleton book was quoted");
    }

    function test_Funnel_DustBesideADeepSingletonBookIsStillDropped_18_18() public {
        _dustBesideADeepBook(18, 18);
    }

    function test_Funnel_DustBesideADeepSingletonBookIsStillDropped_18_6() public {
        _dustBesideADeepBook(18, 6);
    }

    function test_Funnel_DustBesideADeepSingletonBookIsStillDropped_8_6() public {
        _dustBesideADeepBook(8, 6);
    }

    function test_Funnel_DustBesideADeepSingletonBookIsStillDropped_6_18() public {
        _dustBesideADeepBook(6, 18);
    }

    /// The same row beside a book whose liquidity sits where the order cannot reach it (the
    /// book holds none of the bought token) is measured against the pair alone and stays.
    function test_Funnel_ASingletonBookHoldingNoneOfTheBoughtTokenDropsNoRow() public {
        _tokens(18, 18);
        bytes32 pid = BPC.computeV4PoolId(address(a), address(b), 3000, 60, address(0));
        mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, 3000);
        mgr.addPosition(pid, 0, 60, 60, 1e28);   // at the bottom of its range: all token0
        a.mint(address(mgr), 1e26);
        hub.addV4(address(a), address(b), 3000, 60, address(0));
        MockSolidlyPair kept = _solidly(100_000e18, 100_000e18);
        MockSolidlyPair small = _solidly(10e18, 10e18);
        VmSafe.AccountAccess[] memory acc = _planCalls(address(a), address(b), 1_000e18);
        assertGt(_asks(acc, address(kept)), 0, "a book holding none of the bought token dropped an honest row");
        assertGt(_asks(acc, address(small)), 0, "a book holding none of the bought token dropped a row over 25 ppm");
    }

    // ---- a singleton book is never dropped by a walk dust can cut ---------------------------

    /// A pair of 1,000,000 a side, a singleton book of 2.5e22 at a lower fee, and forty one-wei
    /// positions on the ticks the order walks: sixteen stretches then read ~20 of the 25,000 the
    /// book declares, under 25 ppm of the pair (25). A third row between the two bounds makes the
    /// funnel read what the book holds. The book keeps its seat and the order is split onto it.
    function test_Funnel_ASingletonBookWhoseWalkDustCutKeepsItsSeat() public {
        _tokens(18, 18);
        _v2(1_000_000e18, 1_000_000e18);
        bytes32 pid = _v4(100, 1, 2.5e22);
        for (int24 t = -40; t < 0; ++t) mgr.addPosition(pid, t, t + 1, 1, 1);
        (, uint256 held, ) = BPC.v4WalkRank(address(mgr), pid, type(uint256).max, 0, 1, true, type(uint256).max);
        assertLt(held * 1e6, 25 * 1_000_000e18, "fixture: the cut walk reads under 25 ppm of the pair");
        _solidly(25.1e18, 25.1e18);
        assertTrue(_routed(address(a), address(b), 100e18, address(uint160(uint256(pid)))),
            "a singleton book was dropped by the sixteen stretches dust can cut");
    }

    /// Two singleton books alone on a pair, one of them a billionth of the other: with no
    /// other row the small one is measured against what the deep one holds. It is dropped and
    /// the order is routed through the deep book.
    function test_Funnel_TwoSingletonBooksAloneOnAPairStillRoute() public {
        _tokens(18, 18);
        bytes32 deep = _v4(3000, 60, 1e24);
        _v4(500, 10, 1e15);
        assertTrue(_routed(address(a), address(b), 1_000e18, address(uint160(uint256(deep)))),
            "selling token0: two singleton books alone on a pair left it without a plan");
        assertTrue(_routed(address(b), address(a), 1_000e18, address(uint160(uint256(deep)))),
            "selling token1: two singleton books alone on a pair left it without a plan");
    }

    // ---- one formula: the funnel reads the mass the vote is given ---------------------------

    /// The mass the band's vote is given for a row - `universalProbe`, capped by the tokenOut
    /// the venue holds as `Solver._buildHop` caps it (a singleton book's cap is its walk) -
    /// and the mass the funnel reads for the same row.
    function _voteAndFunnel(uint8 kind, address pool, uint24 fee, int24 ts, bytes32 pid, bool sellA)
        internal view returns (uint256 vote, uint256 funnel)
    {
        (PathologicalERC20 tIn, PathologicalERC20 tOut) = sellA ? (a, b) : (b, a);
        QuoteCtx memory c;
        c.kind = kind;
        c.pool = pool;
        c.zeroForOne = sellA;
        c.fee = fee;
        c.tickSpacing = ts;
        c.tokenIn = address(tIn);
        c.tokenOther = address(tOut);
        c.v4Manager = address(mgr);
        c.hub = address(hub);
        c.decIn1 = tIn.decimals() + 1;
        c.decOther1 = tOut.decimals() + 1;
        (vote, , , ) = BPC.universalProbe(c, 10 ** tIn.decimals());
        if (pid == bytes32(0)) {
            uint256 held = BPC.to18(tOut.balanceOf(pool), tOut.decimals());
            if (held < vote) vote = held;
        }
        funnel = BPC.hopMass18(pool, kind, address(tIn), address(tOut), sellA, tOut.decimals(), address(mgr), pid);
    }

    /// `sellingA` / `sellingB`: the mass expected on each direction, 18 decimals.
    function _oneFormula(
        uint8 kind, address pool, uint24 fee, int24 ts, bytes32 pid, uint256 sellingA, uint256 sellingB,
        string memory family
    ) internal view {
        (uint256 vote, uint256 funnel) = _voteAndFunnel(kind, pool, fee, ts, pid, true);
        assertEq(funnel, sellingA, string.concat(family, ": the funnel's mass selling token0"));
        assertEq(vote, sellingA, string.concat(family, ": the vote's mass selling token0"));
        (vote, funnel) = _voteAndFunnel(kind, pool, fee, ts, pid, false);
        assertEq(funnel, sellingB, string.concat(family, ": the funnel's mass selling token1"));
        assertEq(vote, sellingB, string.concat(family, ": the vote's mass selling token1"));
    }

    /// Every native family, both directions. Pair shapes: 50 A + 150,000 B, held in full: the
    /// mass is the reserve of the bought token. Concentrated books: L = 1e15 at a price of 4
    /// (sqrt 2) declare 2e15 of token1 and 5e14 of token0; the V3 and Algebra pools hold 7e14
    /// of token1 (the cap binds) and 9e14 of token0 (the declared side binds). The singleton
    /// book: the side it declares at tick 13,860.
    function _hopMassIsOneFormula(uint8 dA, uint8 dB) internal {
        _tokens(dA, dB);
        uint256 to18A = 10 ** (18 - dA);
        uint256 to18B = 10 ** (18 - dB);

        MockV2Pair v2 = _v2(50 * 10 ** dA, 150_000 * 10 ** dB);
        _oneFormula(BPC.KIND_V2, address(v2), 30, 0, 0, 150_000e18, 50e18, "V2");
        MockSolidlyPair sol = _solidly(50 * 10 ** dA, 150_000 * 10 ** dB);
        _oneFormula(BPC.KIND_SOLIDLY, address(sol), 30, 0, 0, 150_000e18, 50e18, "Solidly");

        PhantomBook v3 = new PhantomBook(address(a), address(b), 3000);
        v3.setState(uint160(2 * Q96), 1e15);
        a.mint(address(v3), 9e14);
        b.mint(address(v3), 7e14);
        _oneFormula(BPC.KIND_V3, address(v3), 3000, 0, 0, 7e14 * to18B, 5e14 * to18A, "V3");
        MockAlgebraPool alg = new MockAlgebraPool(address(a), address(b), 500);
        alg.setState(uint160(2 * Q96), 1e15);
        a.mint(address(alg), 9e14);
        b.mint(address(alg), 7e14);
        _oneFormula(BPC.KIND_ALGEBRA, address(alg), 0, 0, 0, 7e14 * to18B, 5e14 * to18A, "Algebra");

        bytes32 pid = _v4At(3000, 60, 13_860, 1e15);
        uint256 sp = BPC.sqrtPriceAtTick(13_860);
        _oneFormula(BPC.KIND_V4, address(uint160(uint256(pid))), 3000, 60, pid,
            (1e15 * sp / Q96) * to18B, (1e15 * Q96 / sp) * to18A, "V4");
    }

    function test_HopMass_TheFunnelAndTheVoteReadOneFormula_18_18() public {
        _hopMassIsOneFormula(18, 18);
    }

    function test_HopMass_TheFunnelAndTheVoteReadOneFormula_18_6() public {
        _hopMassIsOneFormula(18, 6);
    }

    function test_HopMass_TheFunnelAndTheVoteReadOneFormula_8_6() public {
        _hopMassIsOneFormula(8, 6);
    }

    function test_HopMass_TheFunnelAndTheVoteReadOneFormula_6_18() public {
        _hopMassIsOneFormula(6, 18);
    }

    /// A pair that declares one wei more than it holds, on either side, is no mass in either
    /// direction (the probe prices it dead: bounty #85).
    function test_HopMass_APairDeclaringMoreThanItHoldsIsNoMass() public {
        _tokens(18, 6);
        MockV2Pair p = _v2(50e18, 150_000e6);
        (, uint256 m) = _voteAndFunnel(BPC.KIND_V2, address(p), 30, 0, 0, true);
        assertEq(m, 150_000e18, "control: a pair holding its reserves is mass");
        p.setReserves(uint112(50e18 + 1), uint112(150_000e6));
        (, m) = _voteAndFunnel(BPC.KIND_V2, address(p), 30, 0, 0, true);
        assertEq(m, 0, "selling token0: one wei over on the sold side is mass");
        (, m) = _voteAndFunnel(BPC.KIND_V2, address(p), 30, 0, 0, false);
        assertEq(m, 0, "selling token1: one wei over on the bought side is mass");
        p.setReserves(uint112(50e18), uint112(150_000e6 + 1));
        (, m) = _voteAndFunnel(BPC.KIND_V2, address(p), 30, 0, 0, true);
        assertEq(m, 0, "selling token0: one wei over on the bought side is mass");
        (, m) = _voteAndFunnel(BPC.KIND_V2, address(p), 30, 0, 0, false);
        assertEq(m, 0, "selling token1: one wei over on the sold side is mass");
    }

    /// A Gate wrapper is not read by the funnel, whatever it answers: a kind with no reader
    /// measures 0 even when the contract behind it answers slot0 and liquidity and holds the
    /// bought token.
    function test_HopMass_AGateWrapperIsNotReadByTheFunnel() public {
        _tokens(18, 18);
        PhantomBook w = new PhantomBook(address(a), address(b), 3000);
        w.setState(uint160(Q96), 1e24);
        a.mint(address(w), 1e24);
        b.mint(address(w), 1e24);
        assertEq(BPC.hopMass18(address(w), BPC.KIND_V3, address(a), address(b), true, 18, address(mgr), 0), 1e24,
            "control: the same contract read as a V3 pool is mass");
        assertEq(BPC.hopMass18(address(w), BPC.KIND_EXTERNAL, address(a), address(b), true, 18, address(mgr), 0), 0,
            "a Gate wrapper was read as a V3 pool");
    }

    /// A book whose price reads zero (a pool nobody initialised, or one that answers zero) is no
    /// mass in either direction, and the pair beside it is still planned.
    function test_HopMass_ABookAtPriceZeroIsNoMass() public {
        _tokens(18, 6);
        MockV2Pair honest = _v2(50e18, 150_000e6);
        PhantomBook book = new PhantomBook(address(a), address(b), 3000);
        Origin.wire(hub, address(book), address(a), address(b), BPC.KIND_V3, 3000);
        book.setState(0, 1e33);
        a.mint(address(book), 1e24);
        b.mint(address(book), 1e24);
        bytes32 pid = BPC.computeV4PoolId(address(a), address(b), 3000, 60, address(0));
        address v4 = address(uint160(uint256(pid)));
        assertEq(BPC.hopMass18(address(book), BPC.KIND_V3, address(a), address(b), true, 6, address(mgr), 0), 0,
            "selling token0: a V3 book at price zero is mass");
        assertEq(BPC.hopMass18(address(book), BPC.KIND_V3, address(b), address(a), false, 18, address(mgr), 0), 0,
            "selling token1: a V3 book at price zero is mass");
        assertEq(BPC.hopMass18(v4, BPC.KIND_V4, address(a), address(b), true, 6, address(mgr), pid), 0,
            "selling token0: a singleton book nobody initialised is mass");
        assertEq(BPC.hopMass18(v4, BPC.KIND_V4, address(b), address(a), false, 18, address(mgr), pid), 0,
            "selling token1: a singleton book nobody initialised is mass");
        assertTrue(_routed(address(a), address(b), 1e18, address(honest)),
            "selling token0: a book at price zero stopped the plan");
        assertTrue(_routed(address(b), address(a), 3_000e6, address(honest)),
            "selling token1: a book at price zero stopped the plan");
    }
}
