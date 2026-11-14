// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  VENUE LEG GAS — one leg of each venue kind through the explicit door
//  (swapExactIn), the Core's quote of each kind, and what a second leg or a
//  second hop adds.
//
//  THE INSTRUMENT
//   - One snapshot group per test function, named after the function, so a
//     partial run (--match-test) never drops another test's entries.
//   - A `*_tx` entry is one non-view top-level call, read by
//     vm.snapshotGasLastFrame right after it, so nothing of the test's own
//     frame is in it. This file runs in isolation mode (`isolate = true` in
//     foundry.toml, asserted in setUp), where that call is its own
//     transaction: 21 000 intrinsic gas, calldata, the Router, and the mock
//     venue's own code.
//   - Every door window runs one block after a priming swap through the same
//     venues, and each one starts from the same state (snapshotState /
//     revertToState). The registry rows, the venues' balances and the fee
//     recipients' balances already exist, as they do on a live chain.
//   - Legs are attested the way the Solver attests them: `expectedOut` is the
//     Core's own quote (universalQuote) for the leg's declared input, and a
//     later hop is declared at what the hop before it is attested to pay. The
//     route-level figures stay at zero, because the Router reads only
//     `singleOutFloor` from them.
//   - A view entry is the frame of one top-level STATICCALL into
//     CoreQuoteProbe below, which delegates to the library, read the same
//     way. It carries no intrinsic gas. Under isolation a top-level
//     STATICCALL finds every account and slot cold again, as a fresh
//     transaction would.
//   - The V3 door prices a leg from slot0 and the in-range liquidity, and the
//     mock's swap neither reads the book nor moves the price, so the book
//     test records one door entry for every depth. The book is read by the
//     planner's walk (Core.v4WalkOut with a zero poolId), and the walk
//     entries measure that read.
//   - A Solidly pair that answers getAmountOut prices its leg in its own
//     frame. The curve-fallback test hides that answer, so the Router prices
//     the leg with the Core's replicated stable curve, the src path a pair
//     without the getter takes.
//   - The budget is equality with the recorded snapshot: with
//     FORGE_SNAPSHOT_CHECK=true any change fails the run. This file sets no
//     ceiling of its own.
//
//  forge test --match-path test/gas/VenueLegGas.t.sol
//  FORGE_SNAPSHOT_CHECK=true forge test --match-path test/gas/VenueLegGas.t.sol
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, QuoteCtx} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";
import {MockAlgebraPool} from "../mocks/MockAlgebraPool.sol";
import {MockSolidlyPair} from "../mocks/MockSolidlyPair.sol";
import {MockV4TickManager} from "../mocks/MockV4TickManager.sol";
import {HeavyBookPool} from "../CapacityWalkBudget.t.sol";
import {MockWETH9} from "../RouterV4NativeEth.t.sol";
import {SolidlyPairWithFactory, SettableFeeFactory} from "../ConditionAdequacyCore.t.sol";

/// External view doors onto the Core's quote producers. A window around one of them is one
/// STATICCALL frame, and the probe's own frame is inside the figure.
contract CoreQuoteProbe {
    function universalQuote(QuoteCtx memory c, uint256 amountIn)
        external view returns (uint256 out, uint256 depthWad)
    {
        (out, depthWad, , ) = BPC.universalQuoteRank(c, amountIn, type(uint256).max, false);
    }

    function v4LegOut(
        address manager, bytes32 poolId, uint256 amountIn, uint24 keyFee, int24 tickSpacing, bool zeroForOne
    ) external view returns (uint256) {
        return BPC.v4LegOut(manager, poolId, amountIn, keyFee, tickSpacing, zeroForOne);
    }

    function solidlyGetAmountOut(address pool, uint256 amountIn, address tokenIn) external view returns (uint256) {
        return BPC.solidlyGetAmountOut(pool, amountIn, tokenIn);
    }

    function readDynamicFee(address pool, bool stable, uint256 cfgFee) external view returns (uint256) {
        return BPC.readDynamicFee(pool, stable, cfgFee);
    }

    /// The planner's read of a V3 book: the V4 walk with a zero poolId.
    function v3BookWalkOut(address pool, uint256 amountIn, bool zeroForOne) external view returns (uint256) {
        return BPC.v4WalkOut(pool, bytes32(0), amountIn, 0, 0, zeroForOne);
    }
}

contract VenueLegGasTest is Test {
    /// What a venue is to a leg: everything but the amounts and the direction.
    struct Venue {
        uint8 kind;
        address pool;
        uint24 fee;
        int24 tickSpacing;
        bool stable;
    }

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockV4TickManager mgr;
    MockWETH9 weth;
    CoreQuoteProbe probe;
    /// Sorted by address (tA < tB < tC), so tA -> tB and tB -> tC are zeroForOne everywhere.
    address tA;
    address tB;
    address tC;
    address constant USER = address(0xBEEF);

    /// The order of every door window, and the depth of every venue: one leg here moves its
    /// venue's price by about one part in a thousand.
    uint256 constant AMT = 1_000e18;
    uint256 constant DEPTH = 1_000_000e18;
    uint128 constant LIQ = uint128(DEPTH);
    /// The pair families' fee, in basis points (MockSolidlyPair charges the same 30).
    uint24 constant V2_FEE = 30;
    /// The concentrated families' fee, in hundredths of a basis point, with the spacing
    /// Uniswap pairs with it.
    uint24 constant V3_FEE = 3_000;
    int24 constant V3_TS = 60;
    /// The second V4 pool of the pair: 0.05% with the spacing Uniswap pairs with it.
    uint24 constant V4_FEE_2 = 500;
    int24 constant V4_TS_2 = 10;
    /// Bounds of the one V4 position, +/-: one spacing of the 0.30% pool, six of the 0.05% one.
    /// No window here takes a V4 price below tick -40 (2 000e18 in, priming included, against
    /// 1e24 of liquidity at price 1: 1/sqrt(P) = 1.002, P = 0.99601), so no leg leaves the
    /// position. The bound is also as near as a spacing allows, because the mock manager's swap
    /// scans the book one compressed tick at a time: a bound at +/-18 000 put 1 800 scan steps
    /// and 2.4M gas into the 0.05% leg's window, where the real PoolManager reads a bitmap word
    /// (256 compressed ticks) at a time.
    int24 constant V4_RANGE = V3_TS;
    /// Each initialized tick of the book takes a thousandth of the liquidity away (the book
    /// shape of CapacityWalkBudget).
    int128 constant BOOK_NET = int128(LIQ / 1000);
    /// Enough input to cross all four ticks of the book (the lowest at -240) at the price-1
    /// state: at constant L, reaching tick -240 takes L * (1.0001^120 - 1) ~= 0.01207 L, and
    /// 15 000e18 is 0.015 L, 0.01496 L after the 0.30% fee. Crossings only lower L, and a
    /// lower L needs less input for the same price move.
    uint256 constant BOOK_IN = 15_000e18;
    /// A factory fee unlike the configured one, so the answer shows which source won.
    uint256 constant FACTORY_FEE = 4;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        // No Quoter in this file: its role goes to a placeholder.
        hub.setRoles(address(router), address(solver), address(0xC0FFEE));
        weth = new MockWETH9();
        router.setWeth(address(weth));
        probe = new CoreQuoteProbe();

        address[3] memory t = [
            address(new MockERC20("A", "A")), address(new MockERC20("B", "B")), address(new MockERC20("C", "C"))
        ];
        if (t[0] > t[1]) (t[0], t[1]) = (t[1], t[0]);
        if (t[1] > t[2]) (t[1], t[2]) = (t[2], t[1]);
        if (t[0] > t[1]) (t[0], t[1]) = (t[1], t[0]);
        (tA, tB, tC) = (t[0], t[1], t[2]);

        for (uint256 i; i < 3; ++i) {
            MockERC20(t[i]).mint(USER, DEPTH);
            MockERC20(t[i]).mint(address(mgr), DEPTH);
            vm.prank(USER);
            MockERC20(t[i]).approve(address(router), type(uint256).max);
        }
        // WETH for the native leg; direct mints carry no ETH, so the backing is dealt.
        weth.mint(USER, DEPTH);
        vm.deal(address(weth), DEPTH);
        vm.prank(USER);
        weth.approve(address(router), type(uint256).max);
    }

    // ─── One leg, two legs ──────────────────────────────────────────────────

    function test_Gas_Leg_V2_OneAndTwoLegs() public {
        Venue memory a = Venue(BPC.KIND_V2, _v2(tA, tB), V2_FEE, 0, false);
        Venue memory b = Venue(BPC.KIND_V2, _v2(tA, tB), V2_FEE, 0, false);
        _oneAndTwoLegs("test_Gas_Leg_V2_OneAndTwoLegs", a, b);
    }

    function test_Gas_Leg_V3_NoTickCrossed_OneAndTwoLegs() public {
        Venue memory a = Venue(BPC.KIND_V3, _v3(tA, tB), V3_FEE, 0, false);
        Venue memory b = Venue(BPC.KIND_V3, _v3(tA, tB), V3_FEE, 0, false);
        _oneAndTwoLegs("test_Gas_Leg_V3_NoTickCrossed_OneAndTwoLegs", a, b);
    }

    function test_Gas_Leg_V4_OneAndTwoLegs() public {
        bytes32 p1 = _v4(tA, tB, V3_FEE, V3_TS);
        bytes32 p2 = _v4(tA, tB, V4_FEE_2, V4_TS_2);
        Venue memory a = Venue(BPC.KIND_V4, address(uint160(uint256(p1))), V3_FEE, V3_TS, false);
        Venue memory b = Venue(BPC.KIND_V4, address(uint160(uint256(p2))), V4_FEE_2, V4_TS_2, false);
        _oneAndTwoLegs("test_Gas_Leg_V4_OneAndTwoLegs", a, b);
    }

    function test_Gas_Leg_Algebra_OneAndTwoLegs() public {
        // The registry's Algebra fee is 0: the live fee is measured from globalState().
        Venue memory a = Venue(BPC.KIND_ALGEBRA, _algebra(tA, tB), 0, 0, false);
        Venue memory b = Venue(BPC.KIND_ALGEBRA, _algebra(tA, tB), 0, 0, false);
        _oneAndTwoLegs("test_Gas_Leg_Algebra_OneAndTwoLegs", a, b);
    }

    function test_Gas_Leg_SolidlyVolatile_OneAndTwoLegs() public {
        Venue memory a = Venue(BPC.KIND_SOLIDLY, _solidly(tA, tB, false), V2_FEE, 0, false);
        Venue memory b = Venue(BPC.KIND_SOLIDLY, _solidly(tA, tB, false), V2_FEE, 0, false);
        _oneAndTwoLegs("test_Gas_Leg_SolidlyVolatile_OneAndTwoLegs", a, b);
    }

    function test_Gas_Leg_SolidlyStable_OneAndTwoLegs() public {
        Venue memory a = Venue(BPC.KIND_SOLIDLY, _solidly(tA, tB, true), V2_FEE, 0, true);
        Venue memory b = Venue(BPC.KIND_SOLIDLY, _solidly(tA, tB, true), V2_FEE, 0, true);
        _oneAndTwoLegs("test_Gas_Leg_SolidlyStable_OneAndTwoLegs", a, b);
    }

    /// A stable pair whose getAmountOut answers 0: the Router prices the leg with the Core's
    /// replicated curve (solidlyAskOut, and the floor in legQuoteImpact), in its own frame. A
    /// pair that answers 0 leaves the curve as the only producer, so a door that pays ran it.
    function test_Gas_Leg_SolidlyStable_CurveFallback_OneLeg() public {
        address p = _solidly(tA, tB, true);
        MockSolidlyPair(p).setHideGetAmountOut(true);
        Venue memory v = Venue(BPC.KIND_SOLIDLY, p, V2_FEE, 0, true);
        _prime(_route(_single(v, tA, tB, AMT)), AMT);
        _door("test_Gas_Leg_SolidlyStable_CurveFallback_OneLeg", "one_leg_tx", _route(_single(v, tA, tB, AMT)), AMT);
    }

    // ─── Native ETH in ──────────────────────────────────────────────────────

    /// WETH in, a native-ETH V4 pool, the token out: the route speaks WETH and the Router
    /// unwraps exactly what the pool is owed inside the unlock.
    function test_Gas_Leg_V4Native_EthIn_OneLeg() public {
        bytes32 pid = _v4(address(0), tA, V3_FEE, V3_TS);
        Venue memory v = Venue(BPC.KIND_V4_NATIVE, address(uint160(uint256(pid))), V3_FEE, V3_TS, false);
        _prime(_route(_single(v, address(weth), tA, AMT)), AMT);
        _door("test_Gas_Leg_V4Native_EthIn_OneLeg", "one_leg_tx", _route(_single(v, address(weth), tA, AMT)), AMT);
        // The deepest V4 window of the file (2 000e18 into one pool) ends inside the position.
        (, int24 tick) = mgr.slot0(pid);
        assertGt(tick, -V4_RANGE, "no leg here leaves the V4 position");
    }

    // ─── A book of ticks ────────────────────────────────────────────────────

    /// One V3 pool whose book gains initialized ticks below the price: one, then two, then
    /// four. At each depth the planner's walk reads the book once. The door swaps once, on the
    /// four-tick book: it reads neither the book nor a moved price, so one entry stands for all.
    function test_Gas_Leg_V3Book_CrossesOneTwoFourTicks() public {
        string memory g = "test_Gas_Leg_V3Book_CrossesOneTwoFourTicks";
        HeavyBookPool p = _heavy();
        Venue memory v = Venue(BPC.KIND_V3, address(p), V3_FEE, 0, false);
        _prime(_route(_single(v, tA, tB, BOOK_IN)), BOOK_IN);
        // With no tick crossed, the walk would pay the single-range figure.
        uint256 prev = BPC.outV3(BOOK_IN, uint160(BPC.Q96), LIQ, V3_FEE, true, 0);
        prev = _bookStep(g, p, 1, "walk_1tick", prev);
        prev = _bookStep(g, p, 2, "walk_2ticks", prev);
        _bookStep(g, p, 4, "walk_4ticks", prev);
        _door(g, "door_tx", _route(_single(v, tA, tB, BOOK_IN)), BOOK_IN);
    }

    // ─── Two hops ───────────────────────────────────────────────────────────

    function test_Gas_Leg_TwoHops_V2ThenV3() public {
        string memory g = "test_Gas_Leg_TwoHops_V2ThenV3";
        Venue memory first = Venue(BPC.KIND_V2, _v2(tA, tB), V2_FEE, 0, false);
        Venue memory second = Venue(BPC.KIND_V3, _v3(tB, tC), V3_FEE, 0, false);
        _prime(_twoHops(first, second), AMT);
        uint256 s = vm.snapshotState();
        uint256 one = _door(g, "one_hop_v2_tx", _route(_single(first, tA, tB, AMT)), AMT);
        vm.revertToState(s);
        uint256 two = _door(g, "two_hops_tx", _twoHops(first, second), AMT);
        vm.snapshotValue(g, "marginal_hop_v3", two - one);
    }

    // ─── The Core's quote, per kind ─────────────────────────────────────────

    function test_Gas_CoreQuote_PerKind() public {
        string memory g = "test_Gas_CoreQuote_PerKind";
        Venue memory vol = Venue(BPC.KIND_SOLIDLY, _solidly(tA, tB, false), V2_FEE, 0, false);
        Venue memory stb = Venue(BPC.KIND_SOLIDLY, _solidly(tA, tB, true), V2_FEE, 0, true);
        bytes32 pid = _v4(tA, tB, V3_FEE, V3_TS);

        _quote(g, "universalQuote_v2", Venue(BPC.KIND_V2, _v2(tA, tB), V2_FEE, 0, false));
        _quote(g, "universalQuote_v3", Venue(BPC.KIND_V3, _v3(tA, tB), V3_FEE, 0, false));
        _quote(g, "universalQuote_algebra", Venue(BPC.KIND_ALGEBRA, _algebra(tA, tB), 0, 0, false));
        _quote(g, "universalQuote_solidly_volatile", vol);
        _quote(g, "universalQuote_solidly_stable", stb);
        _quote(g, "universalQuote_v4", Venue(BPC.KIND_V4, address(uint160(uint256(pid))), V3_FEE, V3_TS, false));

        bytes memory r = _view(g, "v4LegOut", abi.encodeCall(probe.v4LegOut, (address(mgr), pid, AMT, V3_FEE, V3_TS, true)));
        assertGt(abi.decode(r, (uint256)), 0, "v4LegOut prices the pool");
        r = _view(g, "solidlyGetAmountOut_volatile", abi.encodeCall(probe.solidlyGetAmountOut, (vol.pool, AMT, tA)));
        assertGt(abi.decode(r, (uint256)), 0, "the volatile pair answers getAmountOut");
        r = _view(g, "solidlyGetAmountOut_stable", abi.encodeCall(probe.solidlyGetAmountOut, (stb.pool, AMT, tA)));
        assertGt(abi.decode(r, (uint256)), 0, "the stable pair answers getAmountOut");

        r = _view(g, "readDynamicFee_noFactory", abi.encodeCall(probe.readDynamicFee, (vol.pool, false, uint256(V2_FEE))));
        assertEq(abi.decode(r, (uint256)), V2_FEE, "with no factory the configured fee stands");
        SettableFeeFactory fac = new SettableFeeFactory();
        fac.set(FACTORY_FEE);
        address withFactory = address(new SolidlyPairWithFactory(address(fac)));
        r = _view(g, "readDynamicFee_factory", abi.encodeCall(probe.readDynamicFee, (withFactory, false, uint256(V2_FEE))));
        assertEq(abi.decode(r, (uint256)), FACTORY_FEE, "the factory's fee wins over the configured one");
    }

    // ─── Windows ────────────────────────────────────────────────────────────

    /// The door with one leg on `a`, then, from the same state, the order split across `a` and
    /// `b`. The second leg's cost is published as `marginal_leg`.
    function _oneAndTwoLegs(string memory g, Venue memory a, Venue memory b) internal {
        _prime(_route(_split(a, b)), AMT);
        uint256 s = vm.snapshotState();
        uint256 one = _door(g, "one_leg_tx", _route(_single(a, tA, tB, AMT)), AMT);
        vm.revertToState(s);
        uint256 two = _door(g, "two_legs_tx", _route(_split(a, b)), AMT);
        vm.snapshotValue(g, "marginal_leg", two - one);
    }

    /// Initializes the book's ticks down to the n-th below the price, then reads the book
    /// with the planner's walk.
    function _bookStep(string memory g, HeavyBookPool p, uint256 n, string memory walk, uint256 prev)
        internal returns (uint256 out)
    {
        for (uint256 i = 1; i <= n; ++i) p.setTick(-V3_TS * int24(int256(i)), BOOK_NET);
        bytes memory r = _view(g, walk, abi.encodeCall(probe.v3BookWalkOut, (address(p), BOOK_IN, true)));
        out = abi.decode(r, (uint256));
        assertLt(out, prev, "every tick the walk crosses takes liquidity away");
    }

    /// One swapExactIn, recorded as `name` in group `g` from the call's own frame. The
    /// calldata is encoded before the prank, so nothing but the door call consumes it.
    function _door(string memory g, string memory name, Route memory r, uint256 amt)
        internal returns (uint256 used)
    {
        address tOut = r.hops[r.hops.length - 1].tokenOut;
        bytes memory data = abi.encodeCall(router.swapExactIn, (r, amt, 1, USER, block.timestamp + 1));
        uint256 before = MockERC20(tOut).balanceOf(USER);
        vm.prank(USER);
        (bool ok, bytes memory ret) = address(router).call(data);
        used = vm.snapshotGasLastFrame(g, name);
        _bubble(ok, ret);
        uint256 got = MockERC20(tOut).balanceOf(USER) - before;
        assertGt(got, 0, "the route pays");
        assertEq(got, abi.decode(ret, (uint256)), "the door returns what the recipient received");
    }

    /// One view into the probe, recorded from the STATICCALL's own frame.
    function _view(string memory g, string memory name, bytes memory data) internal returns (bytes memory ret) {
        (bool ok, bytes memory r) = address(probe).staticcall(data);
        vm.snapshotGasLastFrame(g, name);
        _bubble(ok, r);
        ret = r;
    }

    /// universalQuote of `v` for AMT, tA -> tB.
    function _quote(string memory g, string memory name, Venue memory v) internal {
        bytes memory r = _view(g, name, abi.encodeCall(probe.universalQuote, (_ctx(v, tA, tB, true), AMT)));
        (uint256 out,) = abi.decode(r, (uint256, uint256));
        assertGt(out, 0, "the kind is priced");
    }

    /// The priming swap, then the next block.
    function _prime(Route memory r, uint256 amt) internal {
        vm.prank(USER);
        router.swapExactIn(r, amt, 1, USER, block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _bubble(bool ok, bytes memory ret) internal pure {
        if (!ok) {
            assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
        }
    }

    // ─── Routes ─────────────────────────────────────────────────────────────

    /// One leg of `v` for `amt`, attested with the Core's own quote. Each call builds a new
    /// struct, so no two routes share a leg in memory.
    function _leg(Venue memory v, address tIn, address tOut, uint256 amt) internal view returns (Leg memory l) {
        bool v4 = v.kind == BPC.KIND_V4 || v.kind == BPC.KIND_V4_NATIVE;
        // A native pool's currency0 is the chain's coin, the WETH side of the route.
        bool zfo = v.kind == BPC.KIND_V4_NATIVE ? tIn == address(weth) : tIn < tOut;
        l = Leg({
            pool: v.pool, hooks: address(0), kind: v.kind, fee: v.fee, tickSpacing: v.tickSpacing,
            zeroForOne: zfo, stable: v.stable, amountIn: amt, expectedOut: 0,
            auxId: v4 ? bytes32(uint256(uint160(tOut))) : bytes32(0)
        });
        (l.expectedOut, , , ) = BPC.universalQuoteRank(_ctx(v, tIn, tOut, zfo), amt, type(uint256).max, false);
    }

    /// The quote context of `v`, decimals filled in as the Solver hoists them per pair.
    function _ctx(Venue memory v, address tIn, address tOut, bool zfo) internal view returns (QuoteCtx memory c) {
        // The native pool's id is keyed on address(0), the currency WETH stands for.
        address qIn = v.kind == BPC.KIND_V4_NATIVE && tIn == address(weth) ? address(0) : tIn;
        c = QuoteCtx({
            kind: v.kind, pool: v.pool, zeroForOne: zfo, fee: v.fee, tickSpacing: v.tickSpacing,
            stable: v.stable, tokenIn: qIn, tokenOther: tOut, hooks: address(0), v4Manager: address(mgr),
            hub: address(hub), decIn1: MockERC20(tIn).decimals() + 1, decOther1: MockERC20(tOut).decimals() + 1
        });
    }

    function _single(Venue memory v, address tIn, address tOut, uint256 amt) internal view returns (Hop memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(v, tIn, tOut, amt);
        return _hop(tIn, tOut, legs);
    }

    /// AMT split across `a` and `b`, tA -> tB.
    function _split(Venue memory a, Venue memory b) internal view returns (Hop memory) {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(a, tA, tB, AMT / 2);
        legs[1] = _leg(b, tA, tB, AMT - AMT / 2);
        return _hop(tA, tB, legs);
    }

    function _hop(address tIn, address tOut, Leg[] memory legs) internal pure returns (Hop memory h) {
        uint256 amt;
        uint256 out;
        for (uint256 i; i < legs.length; ++i) {
            amt += legs[i].amountIn;
            out += legs[i].expectedOut;
        }
        h = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: out, legs: legs});
    }

    /// tA -> tB on `first`, then tB -> tC on `second`, the second hop declared at what the
    /// first is attested to pay.
    function _twoHops(Venue memory first, Venue memory second) internal view returns (Route memory) {
        Hop[] memory hops = new Hop[](2);
        hops[0] = _single(first, tA, tB, AMT);
        hops[1] = _single(second, tB, tC, hops[0].expectedOut);
        return _routeOf(hops);
    }

    function _route(Hop memory h) internal pure returns (Route memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = h;
        return _routeOf(hops);
    }

    function _routeOf(Hop[] memory hops) internal pure returns (Route memory) {
        return Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    // ─── Venues ─────────────────────────────────────────────────────────────

    function _fund(address pool, address a, address b) internal {
        MockERC20(a).mint(pool, DEPTH);
        MockERC20(b).mint(pool, DEPTH);
    }

    function _v2(address a, address b) internal returns (address p) {
        MockV2Pair pair = new MockV2Pair(a, b);
        pair.setReserves(uint112(DEPTH), uint112(DEPTH));
        p = address(pair);
        _fund(p, a, b);
        hub.seedPool(p, BPC.KIND_V2, V2_FEE, address(0), a, b);
    }

    function _v3(address a, address b) internal returns (address p) {
        MockV3Pool pool = new MockV3Pool(a, b, V3_FEE);
        pool.setState(uint160(BPC.Q96), LIQ);
        p = address(pool);
        _fund(p, a, b);
        hub.seedPool(p, BPC.KIND_V3, V3_FEE, address(0), a, b);
    }

    function _algebra(address a, address b) internal returns (address p) {
        MockAlgebraPool pool = new MockAlgebraPool(a, b, uint16(V3_FEE));
        pool.setState(uint160(BPC.Q96), LIQ);
        p = address(pool);
        _fund(p, a, b);
        hub.seedPool(p, BPC.KIND_ALGEBRA, 0, address(0), a, b);
    }

    function _solidly(address a, address b, bool stable) internal returns (address p) {
        MockSolidlyPair pair = new MockSolidlyPair(a, b, stable);
        pair.setReserves(uint112(DEPTH), uint112(DEPTH));
        p = address(pair);
        _fund(p, a, b);
        hub.seedPool(p, BPC.KIND_SOLIDLY, V2_FEE, address(0), a, b);
    }

    /// A pool of the manager (c0 < c1) at price 1, with one position no leg here leaves.
    function _v4(address c0, address c1, uint24 fee, int24 ts) internal returns (bytes32 pid) {
        pid = BPC.computeV4PoolId(c0, c1, fee, ts, address(0));
        mgr.initialize(pid, uint160(BPC.Q96), 0, fee);
        mgr.addPosition(pid, -V4_RANGE, V4_RANGE, ts, LIQ);
        hub.addV4(c0, c1, fee, ts, address(0));
    }

    /// A V3 pool at price 1 whose book starts empty; _bookStep initializes its ticks.
    function _heavy() internal returns (HeavyBookPool p) {
        p = new HeavyBookPool(tA, tB, V3_FEE, V3_TS);
        p.setState(uint160(BPC.Q96), LIQ);
        _fund(address(p), tA, tB);
        hub.seedPool(address(p), BPC.KIND_V3, V3_FEE, address(0), tA, tB);
    }
}
