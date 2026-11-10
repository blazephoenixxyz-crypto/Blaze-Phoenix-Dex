// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// batchQuote: one item's solve may spend its share of the gas that is left, not all of it.
//
// RED at e01b503. `batchQuote` isolates a failing item with a `try`, but the Solver call inside
// it forwarded everything the batch had. Under EIP-150 a child that runs out of gas hands back
// 1/64 of what it was given, so an item whose solve exhausts its gas left the items after it
// 1/64 of the batch: they ran out too and read zero. The exhausting shape is permissionless
// (a V4 book fragmented by one-wei positions, the fixture of V4FragmentationGas); the healthy
// items it zeroed had nothing to do with it.
//
// The rule: item i is given gasleft() / (n - i). No constant: the share is what is left over
// the items still to run. Two consequences, both pinned below:
//   - shares never shrink down the batch (an item that spends less leaves more), so an item
//     that solves inside G/n is quoted whatever the other items do;
//   - the last item is given all that is left, so a lone heavy item loses nothing.
//
// Oracle: the Solver asked directly for the same item, never the Quoter itself.
//
// Matrix: batch size {2, 3, 8, 32} x exhausting item {first, middle, last, two of them}
//       x budget {tight: derived from the measured cost of a healthy item, EIP-7825 cap}.
// The tight budget is what makes a row discriminate: 1/64 of it does not cover a healthy item.
// Known limit, not pinned here: an item that exhausts its gas LAST leaves 1/64 of it for the
// answer, as before; those rows run at the transaction cap, where that is enough.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract BatchQuoteItemGasShareTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    MockV2Factory fac;
    address fIn;   // the fragmented pair: its solve exhausts any share it is given below
    address fOut;
    address hIn;   // the healthy pair: one deep V2 pool
    address hOut;
    address attacker = address(0xBAD);
    address[] touched;

    uint8   constant MODE_ASK = 0;
    int24   constant TS    = 1;
    uint128 constant L     = 1e24;
    uint256 constant DUST  = 600;
    uint256 constant ORDER = 1e22;
    /// EIP-7825's per-transaction cap.
    uint256 constant TX_CAP = 1 << 24;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(0xD0D0), address(solver), address(0xC0FFEE));
        fac = new MockV2Factory();
        hub.addFactory(address(fac), BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));
        touched.push(address(mgr));
        touched.push(address(hub));
        touched.push(address(solver));
        touched.push(address(quoter));
        touched.push(address(fac));

        // The measured permissionless shape: four fragmented books on the direct hop and on
        // both bridge hops.
        fIn = _token();
        fOut = _token();
        address bridge = _token();
        hub.addBridge(bridge);
        _books(fIn, fOut);
        _books(fIn, bridge);
        _books(bridge, fOut);

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

    /// Four honest V4 books for `a -> b`, each with DUST one-wei positions on the order's path.
    function _books(address a, address b) internal {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10_000];
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        int24 d = int24(uint24(DUST));
        for (uint256 i; i < 4; ++i) {
            bytes32 pid = BPC.computeV4PoolId(c0, c1, fees[i], TS, address(0));
            mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, fees[i]);
            mgr.addPosition(pid, -20_000, 20_000, TS, L);
            vm.startPrank(attacker);
            if (a == c0) { for (int24 t = -d; t < 0; ++t) mgr.addPosition(pid, t, t + 1, TS, 1); }
            else         { for (int24 t = 0;  t < d; ++t) mgr.addPosition(pid, t, t + 1, TS, 1); }
            vm.stopPrank();
            hub.addV4(c0, c1, fees[i], TS, address(0));
        }
    }

    function _cool() internal {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
    }

    function _healthy(uint256 i) internal view returns (BlazePhoenixQuoter.BatchEntry memory) {
        // A different amount per position, so an item cannot pass on another item's answer.
        return BlazePhoenixQuoter.BatchEntry({tIn: hIn, tOut: hOut, amountIn: 1_000e18 + i * 1e18, userMinOut: 0});
    }

    function _fragmented() internal view returns (BlazePhoenixQuoter.BatchEntry memory) {
        return BlazePhoenixQuoter.BatchEntry({tIn: fIn, tOut: fOut, amountIn: ORDER, userMinOut: 0});
    }

    /// `n` entries, fragmented where bit i of `fragMask` is set, healthy elsewhere.
    function _batch(uint256 n, uint256 fragMask) internal view returns (BlazePhoenixQuoter.BatchEntry[] memory es) {
        es = new BlazePhoenixQuoter.BatchEntry[](n);
        for (uint256 i; i < n; ++i) es[i] = (fragMask >> i) & 1 == 1 ? _fragmented() : _healthy(i);
    }

    function _quote(BlazePhoenixQuoter.BatchEntry[] memory es, uint256 gas_)
        internal returns (bool ok, BlazePhoenixQuoter.Preview[] memory pv)
    {
        _cool();
        bytes memory ret;
        (ok, ret) = address(quoter).staticcall{gas: gas_}(abi.encodeCall(quoter.batchQuote, (es)));
        if (ok) pv = abi.decode(ret, (BlazePhoenixQuoter.Preview[]));
    }

    /// Cold cost of one solve, asked of the Solver itself.
    function _solveGas(address tIn, address tOut, uint256 amt) internal returns (uint256 used, uint256 out) {
        _cool();
        uint256 g0 = gasleft();
        out = solver.findBestRoutePlan(tIn, tOut, amt).best.totalOut;
        used = g0 - gasleft();
    }

    /// Cold cost of one healthy item through the batch door itself: solve, pack and answer.
    function _itemGas() internal returns (uint256 used) {
        BlazePhoenixQuoter.BatchEntry[] memory one = _batch(1, 0);
        _cool();
        uint256 g0 = gasleft();
        quoter.batchQuote(one);
        used = g0 - gasleft();
    }

    /// A budget that discriminates, midway between its two bounds: every healthy item fits its
    /// 1/n share with half as much again to spare (3n/2 items), and what an exhausted call hands
    /// back (1/64, EIP-150) does not cover one healthy item (64 items).
    function _tight(uint256 n) internal returns (uint256 g) {
        uint256 c = _itemGas();
        g = c * (3 * n + 128) / 4;
        assertLt(g / 64, c, "fixture: the budget would feed an item from an exhausted call's refund");
        assertLe(g, TX_CAP, "fixture: the tight budget is above the transaction cap");
    }

    /// One row: every healthy item reads what the Solver answers for it alone, and every
    /// fragmented item reads zero (it did exhaust its share: the row is not vacuous).
    function _row(uint256 n, uint256 fragMask, uint256 gas_) internal {
        string memory tag = string.concat("n=", vm.toString(n), " mask=", vm.toString(fragMask), " gas=", vm.toString(gas_));
        // The premise of the guarantee: a healthy item fits the smallest share, with room.
        (uint256 hGas, ) = _solveGas(hIn, hOut, 1_000e18);
        assertLt(hGas * 3 / 2, gas_ / n, string.concat(tag, ": fixture - the healthy item does not fit its share"));
        (bool ok, BlazePhoenixQuoter.Preview[] memory pv) = _quote(_batch(n, fragMask), gas_);
        assertTrue(ok, string.concat(tag, ": the batch itself reverted"));
        assertEq(pv.length, n);
        for (uint256 i; i < n; ++i) {
            if ((fragMask >> i) & 1 == 1) {
                assertEq(pv[i].grossOut, 0, string.concat(tag, ": the fragmented item fit - the row proves nothing"));
                assertFalse(pv[i].canExecute);
                continue;
            }
            uint256 want = solver.findBestRoutePlan(hIn, hOut, _healthy(i).amountIn).best.totalOut;
            assertGt(want, 0);
            assertEq(pv[i].grossOut, want, string.concat(tag, ": healthy item ", vm.toString(i), " was starved"));
            assertTrue(pv[i].canExecute, string.concat(tag, ": healthy item ", vm.toString(i), " not executable"));
        }
    }

    /// The fragmented item is out of reach of the transaction cap, alone, and no row below gives
    /// it a larger share than that: whatever it is given, it spends.
    function test_Fixture_TheFragmentedSolveExceedsTheTransactionCap() public {
        _cool();
        (bool ok, ) = address(solver).staticcall{gas: TX_CAP}(
            abi.encodeCall(solver.findBestRoutePlan, (fIn, fOut, ORDER)));
        assertFalse(ok, "the fragmented solve fits the transaction cap");
    }

    function test_ExhaustedFirstItem_LeavesTheNextQuoted() public {
        _row(2, 1, _tight(2)); // the reported shape
    }

    function test_ExhaustedItem_AnyPosition_LeavesEveryOtherItemQuoted() public {
        _row(3, 1 << 1, _tight(3));
        _row(8, 1 << 0, _tight(8));
        _row(8, 1 << 3, _tight(8));
        _row(8, 1 << 6, _tight(8));
        // Last: nothing runs after it, so the row holds before and after the rule.
        _row(2, 1 << 1, TX_CAP);
        _row(8, 1 << 7, TX_CAP);
    }

    function test_TwoExhaustedItems_LeaveEveryOtherItemQuoted() public {
        _row(8, 1 << 0 | 1 << 4, _tight(8));
        _row(8, 1 << 5 | 1 << 6, _tight(8));
    }

    function test_FullBatch_ExhaustedFirstItem_LeavesThirtyOneQuoted() public {
        _row(32, 1, _tight(32));
    }

    /// Control: with nothing exhausting, the share changes no answer.
    function test_Control_AllHealthy_EveryItemQuoted() public {
        _row(8, 0, _tight(8));
        _row(32, 0, _tight(32));
        _row(32, 0, TX_CAP);
    }

    /// The last item is given ALL that is left. A solve that needs most of the budget is quoted
    /// when it runs alone, and when it runs last behind a light item: what the light item did
    /// not spend flowed on to it. A share of 1/(n - i + 1) would refuse both.
    function test_LastItem_ReceivesAllThatIsLeft() public {
        // A heavy but solvable item: one fragmented direct hop, no bridge.
        address a = _token();
        address b = _token();
        _books(a, b);
        (uint256 heavy, uint256 want) = _solveGas(a, b, ORDER);
        assertGt(want, 0, "fixture: the heavy item must be solvable");
        (uint256 light, ) = _solveGas(hIn, hOut, 1_000e18);
        assertGt(heavy, 8 * light, "fixture: the heavy item must dominate the batch");

        BlazePhoenixQuoter.BatchEntry[] memory one = new BlazePhoenixQuoter.BatchEntry[](1);
        one[0] = BlazePhoenixQuoter.BatchEntry({tIn: a, tOut: b, amountIn: ORDER, userMinOut: 0});
        (bool ok, BlazePhoenixQuoter.Preview[] memory pv) = _quote(one, heavy + heavy / 4);
        assertTrue(ok);
        assertEq(pv[0].grossOut, want, "a lone item was denied part of the budget");

        BlazePhoenixQuoter.BatchEntry[] memory two = new BlazePhoenixQuoter.BatchEntry[](2);
        two[0] = _healthy(0);
        two[1] = one[0];
        // Less than twice the heavy solve: an even split of the budget would not cover it.
        (ok, pv) = _quote(two, heavy + heavy / 4 + 2 * light);
        assertTrue(ok);
        assertGt(pv[0].grossOut, 0);
        assertEq(pv[1].grossOut, want, "the last item did not receive what the first left unspent");
    }
}
