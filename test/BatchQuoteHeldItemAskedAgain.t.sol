// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// batchQuote: an item ahead of the last whose solve walks a held leader reads empty on its share
// (5662).
//
// RED at 6e5067b. Item i is given gasleft() / (n - i). A solve that walks a held leader needs
// SOLVE_GAS whole and stops with empty revert data on less (Solver, SOLVE_B), so on a 50M call of
// n >= 4 items a pair with a route read zero unless it was last, while the automatic door
// (`swapBestExactIn`, SOLVE_GAS) fills it. The fix asks such an item once more, in order, with
// SOLVE_GAS, while the gas left covers SOLVE_GAS * 64 / 63 (EIP-150) and PACK_RESERVE; a refusal
// with data is an answer and is not asked again.
//
// The oracle is the Solver alone at ample gas. The instrument (GasEchoSolver) answers with the
// gas it was handed, so the floor is read off the preview: at the least batch gas that asks the
// item again, it receives SOLVE_GAS whole, and the batch answers on both sides of that edge.

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Leg, Hop, Route, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {HeavyBookPool} from "./CapacityWalkBudget.t.sol";

/// A Solver stand-in. For `held` it acts as a solve that walks a held leader: on less than
/// SOLVE_B it spends what it was given and stops with empty data; on SOLVE_B or more it spends
/// all but KEEP and answers. Every answer is the largest route `_pack` reads (MAX_HOPS hops of
/// MAX_LEGS_PER_HOP V4 legs behind a swap-only hook), its totalOut the gas the call was handed.
contract GasEchoSolver {
    uint256 internal constant SOLVE_B = BPC.SOLVE_GAS - 1_200;
    uint256 public constant KEEP = 120_000;
    address public immutable bridge;
    address public immutable hook;
    address public held;

    constructor(address bridge_, address hook_) { bridge = bridge_; hook = hook_; }

    function setHeld(address h) external { held = h; }

    function findBestRoutePlan(address tIn, address tOut, uint256 amountIn)
        external view returns (RoutePlan memory p)
    {
        uint256 g = gasleft();
        if (tIn == held) {
            if (g < SOLVE_B) {
                while (gasleft() > 400) {}
                assembly { revert(0, 0) }
            }
            while (gasleft() > KEEP) {}
        }
        p.best = _route(tIn, tOut, tIn == held ? g : amountIn);
    }

    function _route(address tIn, address tOut, uint256 out) internal view returns (Route memory r) {
        r.hops = new Hop[](2);
        r.hops[0] = _hop(tIn, bridge, out);
        r.hops[1] = _hop(bridge, tOut, out);
        r.totalOut = out;
        r.singleOut = out;
        r.singleOutFloor = out / 2;
        r.estGas = 1;
    }

    function _hop(address a, address b, uint256 out) internal view returns (Hop memory h) {
        uint24[5] memory fees = [uint24(100), 500, 3_000, 10_000, 2_500];
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        h.tokenIn = a;
        h.tokenOut = b;
        h.amountIn = out;
        h.expectedOut = out;
        h.legs = new Leg[](5);
        for (uint256 l; l < 5; ++l) {
            h.legs[l] = Leg({
                pool: address(uint160(uint256(BPC.computeV4PoolId(c0, c1, fees[l], 1, hook)))),
                hooks: hook, kind: BPC.KIND_V4, fee: fees[l], tickSpacing: 1, zeroForOne: a == c0,
                stable: false, amountIn: out / 5, expectedOut: out / 5,
                auxId: bytes32(uint256(uint160(b)))
            });
        }
    }
}

contract BatchQuoteHeldItemAskedAgainTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    MockV2Factory fac;
    address t0;    // the held pair: four V3 books the walk's cap binds, holding 100e18 each
    address t1;
    address hIn;   // the healthy pair: one deep V2 venue
    address hOut;
    address[] touched;

    uint8   constant MODE_ASK = 0;
    uint160 constant SP   = uint160(1 << 96);
    uint128 constant L    = 1_000e18;
    int24   constant TS   = 60;
    uint256 constant IN   = 200e18;
    uint256 constant ETH_CALL_GAS = 50_000_000;
    /// EIP-7825's per-transaction cap.
    uint256 constant TX_CAP = 1 << 24;
    uint256 constant SOLVE_B = BPC.SOLVE_GAS - 1_200;
    /// The Quoter's PACK_RESERVE, written down here so the floor test reads the source's.
    uint256 constant PACK_RESERVE = 560_000;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(0xD0D0), address(solver), address(0xC0FFEE));
        vm.mockCall(address(0xD0D0), abi.encodeWithSignature("paused()"), abi.encode(false));
        fac = new MockV2Factory();
        hub.addFactory(address(fac), BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));
        touched.push(address(mgr));
        touched.push(address(hub));
        touched.push(address(solver));
        touched.push(address(quoter));
        touched.push(address(fac));

        t0 = _token();
        t1 = _token();
        uint24[4] memory fees = [uint24(3_000), 500, 10_000, 100];
        for (uint256 k; k < 4; ++k) _heavy(t0, t1, fees[k]);

        hIn = _token();
        hOut = _token();
        MockV2Pair p = new MockV2Pair(hIn, hOut);
        fac.setPair(hIn, hOut, address(p));
        MockERC20(hIn).mint(address(p), 1e24);
        MockERC20(hOut).mint(address(p), 1e24);
        p.setReserves(uint112(1e24), uint112(1e24));
        touched.push(address(p));
    }

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        MockERC20(t).mint(address(mgr), 1e30);
        touched.push(t);
    }

    /// CapacityWalkBudget's heavy book: twenty initialized ticks each side, 100e18 of each token.
    function _heavy(address a, address b, uint24 fee) internal {
        HeavyBookPool p = new HeavyBookPool(a, b, fee, TS);
        p.setState(SP, L);
        for (int24 i = 1; i <= 20; ++i) {
            p.setTick(-i * TS, int128(L / 1000));
            p.setTick(i * TS, -int128(L / 1000));
        }
        MockERC20(a).mint(address(p), 100e18);
        MockERC20(b).mint(address(p), 100e18);
        hub.seedPool(address(p), BPC.KIND_V3, fee, address(0), a, b);
        touched.push(address(p));
    }

    /// BatchQuoteItemGasShare's exhausting shape: four V4 books fragmented by 600 one-wei
    /// positions on the direct hop and on both bridge hops.
    function _exhausting() internal returns (address a, address b) {
        a = _token();
        b = _token();
        address br = _token();
        hub.addBridge(br);
        _books(a, b);
        _books(a, br);
        _books(br, b);
    }

    function _books(address a, address b) internal {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10_000];
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        for (uint256 i; i < 4; ++i) {
            bytes32 pid = BPC.computeV4PoolId(c0, c1, fees[i], 1, address(0));
            mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, fees[i]);
            mgr.addPosition(pid, -20_000, 20_000, 1, 1e24);
            vm.startPrank(address(0xBAD));
            if (a == c0) { for (int24 t = -600; t < 0; ++t) mgr.addPosition(pid, t, t + 1, 1, 1); }
            else         { for (int24 t = 0;  t < 600; ++t) mgr.addPosition(pid, t, t + 1, 1, 1); }
            vm.stopPrank();
            hub.addV4(c0, c1, fees[i], 1, address(0));
        }
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    function _held() internal view returns (BlazePhoenixQuoter.BatchEntry memory) {
        return BlazePhoenixQuoter.BatchEntry({tIn: t0, tOut: t1, amountIn: IN, userMinOut: 0});
    }

    function _healthy(uint256 i) internal view returns (BlazePhoenixQuoter.BatchEntry memory) {
        return BlazePhoenixQuoter.BatchEntry({tIn: hIn, tOut: hOut, amountIn: 1_000e18 + i * 1e18, userMinOut: 0});
    }

    /// `n` healthy entries with the held pair at `pos`.
    function _batch(uint256 n, uint256 pos) internal view returns (BlazePhoenixQuoter.BatchEntry[] memory es) {
        es = new BlazePhoenixQuoter.BatchEntry[](n);
        for (uint256 i; i < n; ++i) es[i] = i == pos ? _held() : _healthy(i);
    }

    function _quote(BlazePhoenixQuoter.BatchEntry[] memory es, uint256 gas_)
        internal returns (bool ok, BlazePhoenixQuoter.Preview[] memory pv)
    {
        _cool();
        bytes memory ret;
        (ok, ret) = address(quoter).staticcall{gas: gas_}(abi.encodeCall(quoter.batchQuote, (es)));
        if (ok) pv = abi.decode(ret, (BlazePhoenixQuoter.Preview[]));
    }

    function _oracle(BlazePhoenixQuoter.BatchEntry memory e) internal view returns (uint256) {
        return solver.findBestRoutePlan(e.tIn, e.tOut, e.amountIn).best.totalOut;
    }

    /// Every item reads what the Solver answers for it alone.
    function _row(uint256 n, uint256 pos, uint256 gas_) internal {
        string memory tag = string.concat("n=", vm.toString(n), " pos=", vm.toString(pos), " gas=", vm.toString(gas_));
        BlazePhoenixQuoter.BatchEntry[] memory es = _batch(n, pos);
        (bool ok, BlazePhoenixQuoter.Preview[] memory pv) = _quote(es, gas_);
        assertTrue(ok, string.concat(tag, ": the batch itself reverted"));
        for (uint256 i; i < n; ++i) {
            uint256 want = _oracle(es[i]);
            assertGt(want, 0);
            assertEq(pv[i].grossOut, want, string.concat(tag, ": item ", vm.toString(i), " read other than its solve"));
        }
    }

    /// The premise: the held pair's solve stops with empty data on less than SOLVE_GAS and
    /// answers on SOLVE_GAS, and a share of a 50M call of four items is less.
    function test_Fixture_TheHeldSolveNeedsSolveGasWhole() public {
        assertGt(_oracle(_held()), 4 * 30e18, "premise: the walk changes the plan");
        (bool ok, bytes memory r) = address(solver).staticcall{gas: ETH_CALL_GAS / 4}(
            abi.encodeCall(solver.findBestRoutePlan, (t0, t1, IN)));
        assertFalse(ok, "the held solve answered on a quarter of 50M");
        assertEq(r.length, 0, "it stopped with data, not empty");
        assertLt(ETH_CALL_GAS / 4, SOLVE_B);
        (ok, ) = address(solver).staticcall{gas: BPC.SOLVE_GAS}(abi.encodeCall(solver.findBestRoutePlan, (t0, t1, IN)));
        assertTrue(ok, "the held solve does not answer on SOLVE_GAS");
    }

    /// RED at 6e5067b on every n >= 4 at 50M: the held item ahead of the last read zero.
    function test_HeldItemAheadOfTheLast_ReadsItsSolve() public {
        uint256[5] memory ns = [uint256(2), 3, 4, 8, 32];
        for (uint256 k; k < ns.length; ++k) {
            uint256 n = ns[k];
            uint256[3] memory ps = [uint256(0), n / 2 - (n == 2 ? 1 : 0), n - 2];
            for (uint256 j; j < 3; ++j) {
                _row(n, ps[j], ETH_CALL_GAS);
                _row(n, ps[j], n * BPC.SOLVE_GAS * 64 / 63 + 2_000_000);
            }
        }
    }

    /// Control: the last item was always given everything that is left.
    function test_Control_HeldItemLast_ReadsItsSolve() public {
        _row(4, 3, ETH_CALL_GAS);
        _row(32, 31, ETH_CALL_GAS);
    }

    /// A refusal with data (no route, SolverE(5)) is an answer: it is asked once, not again.
    function test_NoRouteItem_IsAskedOnce() public {
        address a = _token();
        address b = _token();
        BlazePhoenixQuoter.BatchEntry[] memory es = _batch(4, 3);
        es[0] = BlazePhoenixQuoter.BatchEntry({tIn: a, tOut: b, amountIn: 1e18, userMinOut: 0});
        vm.expectCall(address(solver), abi.encodeCall(solver.findBestRoutePlan, (a, b, 1e18)), 1);
        BlazePhoenixQuoter.Preview[] memory pv = quoter.batchQuote{gas: ETH_CALL_GAS}(es);
        assertEq(pv[0].grossOut, 0);
        assertEq(pv[3].grossOut, _oracle(es[3]), "the held item last");
    }

    /// An exhausting item first and the held item second, then 30 healthy: the exhausting item is
    /// asked again on SOLVE_GAS only, so the held item still gets its SOLVE_GAS after it.
    function test_ExhaustingItemFirst_TheHeldItemStillAnswers() public {
        (address a, address b) = _exhausting();
        BlazePhoenixQuoter.BatchEntry[] memory es = _batch(32, 1);
        es[0] = BlazePhoenixQuoter.BatchEntry({tIn: a, tOut: b, amountIn: 1e22, userMinOut: 0});
        (bool ok, BlazePhoenixQuoter.Preview[] memory pv) = _quote(es, ETH_CALL_GAS);
        assertTrue(ok, "the batch reverted");
        assertEq(pv[0].grossOut, 0, "premise: the exhausting item fit");
        assertEq(pv[1].grossOut, _oracle(es[1]), "the held item read other than its solve");
        for (uint256 i = 2; i < 32; ++i) assertEq(pv[i].grossOut, _oracle(es[i]), "a healthy item was starved");
        // At the transaction cap the held item may stay empty, never wrong, and the rest answers.
        (ok, pv) = _quote(es, TX_CAP);
        assertTrue(ok, "the batch reverted at the transaction cap");
        assertTrue(pv[1].grossOut == 0 || pv[1].grossOut == _oracle(es[1]), "the held item read wrong at the cap");
        for (uint256 i = 2; i < 32; ++i) assertEq(pv[i].grossOut, _oracle(es[i]), "a healthy item was starved at the cap");
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_HeldItem_EmptyOrItsSolve(uint256 n, uint256 pos, uint256 gas_) public {
        n = bound(n, 1, 8);
        pos = bound(pos, 0, n - 1);
        gas_ = bound(gas_, 1_000_000, 150_000_000);
        BlazePhoenixQuoter.BatchEntry[] memory es = _batch(n, pos);
        (bool ok, BlazePhoenixQuoter.Preview[] memory pv) = _quote(es, gas_);
        if (gas_ >= n * BPC.SOLVE_GAS * 64 / 63 + 2_000_000) assertTrue(ok, "the batch reverted on ample gas");
        if (!ok) return;
        for (uint256 i; i < n; ++i) {
            uint256 want = _oracle(es[i]);
            assertTrue(pv[i].grossOut == 0 || pv[i].grossOut == want, "an item read other than its solve");
            if (gas_ >= n * BPC.SOLVE_GAS * 64 / 63 + 2_000_000) assertEq(pv[i].grossOut, want, "starved on ample gas");
        }
    }

    // ---- the floor, read off the instrument ----

    function _echo() internal returns (BlazePhoenixQuoter q, GasEchoSolver m, BlazePhoenixQuoter.BatchEntry[] memory es) {
        address br = _token();
        // A swap-only hook: bit 7 (in 0xCC), neither delta flag (bits 2 and 3).
        address hk = address(uint160(0xA000000000000000000000000000000000000080));
        m = new GasEchoSolver(br, hk);
        q = new BlazePhoenixQuoter(address(hub), address(m));
        touched.push(address(m));
        touched.push(address(q));
        es = new BlazePhoenixQuoter.BatchEntry[](32);
        for (uint256 i; i < 32; ++i) es[i] = BlazePhoenixQuoter.BatchEntry({tIn: _token(), tOut: _token(), amountIn: 1e18 + i, userMinOut: 0});
        m.setHeld(es[0].tIn);
    }

    function _echoQuote(BlazePhoenixQuoter q, BlazePhoenixQuoter.BatchEntry[] memory es, uint256 g)
        internal returns (uint256 out0, uint256 left)
    {
        _cool();
        (bool ok, bytes memory ret) = address(q).staticcall{gas: g}(abi.encodeCall(q.batchQuote, (es)));
        left = vm.lastCallGas().gasRemaining;
        assertTrue(ok, string.concat("the batch reverted at gas ", vm.toString(g)));
        BlazePhoenixQuoter.Preview[] memory pv = abi.decode(ret, (BlazePhoenixQuoter.Preview[]));
        for (uint256 i = 1; i < 32; ++i) assertEq(pv[i].grossOut, es[i].amountIn, "a healthy item was starved");
        out0 = pv[0].grossOut;
    }

    /// The least batch gas that asks the held item again (the Quoter's SOLVE_AGAIN_FLOOR at the
    /// check): there the item is handed SOLVE_GAS whole (its answer is SOLVE_GAS less the
    /// dispatch), one gas less it stays empty, and the batch answers on both sides with every
    /// preview at its largest. What is left at the edge, with the item spending all but KEEP of
    /// its SOLVE_GAS, is PACK_RESERVE's margin.
    function test_Floor_TheItemAskedAgainGetsSolveGasWhole_AndTheBatchAnswers() public {
        (BlazePhoenixQuoter q, GasEchoSolver m, BlazePhoenixQuoter.BatchEntry[] memory es) = _echo();
        uint256 lo = BPC.SOLVE_GAS;
        uint256 hi = 2 * BPC.SOLVE_GAS * 64 / 63 + 4_000_000;
        (uint256 o, ) = _echoQuote(q, es, lo);
        assertEq(o, 0, "premise: asked again at SOLVE_GAS");
        (o, ) = _echoQuote(q, es, hi);
        assertGt(o, 0, "premise: not asked again at hi");
        while (hi - lo > 1) {
            uint256 g = (lo + hi) / 2;
            (o, ) = _echoQuote(q, es, g);
            if (o == 0) lo = g; else hi = g;
        }
        (uint256 got, uint256 left) = _echoQuote(q, es, hi);
        emit log_named_uint("least batch gas that asks again", hi);
        emit log_named_uint("gas handed to the item", got);
        emit log_named_uint("left to the batch at the edge", left);
        assertGe(got, SOLVE_B, "the item asked again was handed less than SOLVE_B");
        assertLe(got, BPC.SOLVE_GAS, "the item was handed more than SOLVE_GAS");
        // What the item leaves unspent of SOLVE_GAS on the same budget, alone and warm, as the
        // batch calls it the second time.
        m.findBestRoutePlan{gas: BPC.SOLVE_GAS}(es[0].tIn, es[0].tOut, 1);
        uint256 unspent = vm.lastCallGas().gasRemaining;
        // At the edge the gas at the floor check is SOLVE_GAS * 64 / 63 + PACK_RESERVE; the item
        // spent SOLVE_GAS - unspent of it, so everything else past the check (the call's own
        // cost, _pack of the largest route, the 32 largest previews encoded and returned) is
        // that, less the item's spend, less what was left.
        uint256 post = BPC.SOLVE_GAS / 63 + PACK_RESERVE + unspent - left;
        emit log_named_uint("left unspent by the item, warm", unspent);
        emit log_named_uint("past the check, less the solve", post);
        assertLe(post, PACK_RESERVE, "PACK_RESERVE does not cover what follows the solve by itself");
        (o, ) = _echoQuote(q, es, hi - 1);
        assertEq(o, 0, "asked again one gas under the edge");
    }
}
