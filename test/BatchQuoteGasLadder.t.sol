// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  batchQuote on a gas ladder: a healthy item beside one that exhausts its gas.
//
//  The heavy item is the measured permissionless shape of V4FragmentationGas:
//  V4 books split by one-wei positions on the ticks the order walks. Two shapes:
//  four books on the direct pair, and the same four books on the direct pair
//  and on both hops through a bridge (the second one costs more than the
//  per-transaction cap of EIP-7825, 2^24, when asked alone).
//  The healthy item comes in two costs: one honest V2 pair, and four honest V4
//  books with no dust (about ten times the V2 item).
//
//  The ladder has no gas literal: every rung is a fraction of the heavy item's
//  own measured cost, taken cold inside the test, and a rung is only counted
//  when the healthy item alone fits in it several times over. One rung is
//  named: 2^24.
//
//  Green in this file:
//    - with gas for both, both items are answered as alone, in either order
//      (main gives every item all the gas the batch has: a per-item budget
//      smaller than an item the batch could pay for turns this one red);
//    - a healthy item AHEAD of the starved one is answered as alone on every
//      rung, and the starved item's slot is empty (its failure is its own).
//  The mirror sentence (the healthy item BEHIND the starved one) lives in
//  RedBatchQuoteGasLadder.t.sol.
//
//  Matrix: heavy shape direct / bridged; healthy item V2 / four V4 books;
//  rungs 1/8 .. 7/8 of the heavy cost + 2^24 + ample; order healthy first /
//  heavy first; cold accounts on every call; dimensions gas + mutant.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

abstract contract BatchQuoteGasLadderBase is Test {
    MockV4TickManager  mgr;
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address attacker = address(0xBAD);
    address[] touched;

    int24   constant TS    = 1;
    uint128 constant L     = 1e24;
    uint256 constant DUST  = 600;
    uint256 constant ORDER = 1e22;
    uint256 constant TX_CAP = 1 << 24;          // EIP-7825
    uint256 constant ROOM = 4;                  // a rung counts only if the healthy item fits ROOM times
    uint256 constant SHAPES = 2;                // 0: four books on the direct pair; 1: the same through a bridge too
    uint256 constant KINDS  = 2;                // healthy item 0: one V2 pair; 1: four honest V4 books

    BlazePhoenixQuoter.BatchEntry[SHAPES] heavy;
    BlazePhoenixQuoter.BatchEntry[KINDS] healthy;
    uint256[SHAPES] gHeavy;   // gas of the heavy item asked alone, cold
    bytes32[SHAPES] hHeavy;   // its answer alone, with ample gas
    uint256[KINDS] gHealthy;  // gas of the healthy item asked alone, cold
    bytes32[KINDS] hHealthy;

    /// Builds the world and nothing else. The solo measurements are taken inside each test
    /// (`_calibrate`): `vm.cool` un-touches an account, and an account cooled in `setUp` that is not
    /// called again before `setUp` returns is not committed - the books would be gone in the test.
    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        touched.push(address(mgr)); touched.push(address(hub)); touched.push(address(solver));
        touched.push(address(router)); touched.push(address(quoter));

        uint24[4] memory fees = [uint24(100), 500, 3000, 10_000];
        // shape 0: four fragmented V4 books on one pair
        address a = _token(); address b = _token();
        for (uint256 i; i < 4; ++i) _book(a, b, fees[i], DUST);
        heavy[0] = BlazePhoenixQuoter.BatchEntry(a, b, ORDER, 0);
        // shape 1: the same four books on the direct pair and on both hops through a bridge
        address e = _token(); address f = _token(); address bridge = _token();
        hub.addBridge(bridge);
        for (uint256 i; i < 4; ++i) {
            _book(e, f, fees[i], DUST); _book(e, bridge, fees[i], DUST); _book(bridge, f, fees[i], DUST);
        }
        heavy[1] = BlazePhoenixQuoter.BatchEntry(e, f, ORDER, 0);

        // healthy, cheap: one honest V2 pair
        address c = _token(); address d = _token();
        MockV2Pair p = new MockV2Pair(c, d);
        MockERC20(c).mint(address(p), 1e24); MockERC20(d).mint(address(p), 1e24);
        p.setReserves(1e24, 1e24);
        (address t0, address t1) = c < d ? (c, d) : (d, c);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), t0, t1);
        touched.push(address(p));
        healthy[0] = BlazePhoenixQuoter.BatchEntry(c, d, 1_000e18, 0);
        // healthy, costlier: four honest V4 books, no dust
        address x = _token(); address y = _token();
        for (uint256 i; i < 4; ++i) _book(x, y, fees[i], 0);
        healthy[1] = BlazePhoenixQuoter.BatchEntry(x, y, 1_000e18, 0);
    }

    /// The solo answers and costs every sentence is measured against, taken in the test's own
    /// transaction. Reverts when the fixture is not in the regime, so no sentence passes on a world
    /// where the heavy item does not quote or is not heavy.
    function _calibrate() internal {
        bool ok; BlazePhoenixQuoter.Preview[] memory pv; uint256 used;
        for (uint256 k; k < KINDS; ++k) {
            (ok, pv, used) = _ask(_one(healthy[k]), gasleft());
            require(ok && pv[0].grossOut > 0, "fixture: the healthy item does not quote");
            gHealthy[k] = used; hHealthy[k] = keccak256(abi.encode(pv[0]));
            emit log_named_uint(k == 0 ? "healthy item (V2 pair) alone, gas" : "healthy item (four V4 books) alone, gas", used);
        }
        for (uint256 s; s < SHAPES; ++s) {
            (ok, pv, used) = _ask(_one(heavy[s]), gasleft());
            require(ok && pv[0].grossOut > 0, "fixture: the heavy item does not quote with ample gas");
            gHeavy[s] = used; hHeavy[s] = keccak256(abi.encode(pv[0]));
            emit log_named_uint(s == 0 ? "heavy item (direct) alone, gas" : "heavy item (bridged) alone, gas", used);
        }
        require(gHeavy[1] > TX_CAP, "fixture: the bridged shape fits in one transaction");
    }

    function _token() internal returns (address t) {
        t = address(new MockERC20("T", "T"));
        MockERC20(t).mint(address(mgr), 1e30);
        touched.push(t);
    }

    /// One honest V4 book for `a -> b`, with `dust` one-wei positions on the ticks the order walks.
    function _book(address a, address b, uint24 fee, uint256 dust) internal {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, fee, TS, address(0));
        mgr.initialize(pid, BPC.sqrtPriceAtTick(0), 0, fee);
        mgr.addPosition(pid, -20_000, 20_000, TS, L);
        int24 d = int24(uint24(dust));
        vm.startPrank(attacker);
        if (a == c0) { for (int24 t = -d; t < 0; ++t) mgr.addPosition(pid, t, t + 1, TS, 1); }
        else         { for (int24 t = 0;  t < d; ++t) mgr.addPosition(pid, t, t + 1, TS, 1); }
        vm.stopPrank();
        hub.addV4(c0, c1, fee, TS, address(0));
    }

    function _one(BlazePhoenixQuoter.BatchEntry memory e) internal pure returns (BlazePhoenixQuoter.BatchEntry[] memory b) {
        b = new BlazePhoenixQuoter.BatchEntry[](1); b[0] = e;
    }

    function _two(BlazePhoenixQuoter.BatchEntry memory x, BlazePhoenixQuoter.BatchEntry memory y)
        internal pure returns (BlazePhoenixQuoter.BatchEntry[] memory b)
    {
        b = new BlazePhoenixQuoter.BatchEntry[](2); b[0] = x; b[1] = y;
    }

    /// The batch asked on exactly `gasLimit`, every account cold.
    function _ask(BlazePhoenixQuoter.BatchEntry[] memory entries, uint256 gasLimit)
        internal returns (bool ok, BlazePhoenixQuoter.Preview[] memory pv, uint256 used)
    {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
        bytes memory ret;
        uint256 g0 = gasleft();
        (ok, ret) = address(quoter).staticcall{gas: gasLimit}(abi.encodeCall(quoter.batchQuote, (entries)));
        used = g0 - gasleft();
        if (ok) pv = abi.decode(ret, (BlazePhoenixQuoter.Preview[]));
    }

    /// Rung r of shape s: r eighths of that heavy item's own cost; 0 stands for the EIP-7825 cap.
    function _rung(uint256 s, uint256 r) internal view returns (uint256) {
        return r == 0 ? TX_CAP : gHeavy[s] * r / 8;
    }

    /// A rung is in the regime when the heavy item cannot finish on it and the healthy one fits
    /// ROOM times over.
    function _inRegime(uint256 s, uint256 k, uint256 g) internal view returns (bool) {
        return g < gHeavy[s] && g >= ROOM * gHealthy[k];
    }

    /// The rungs of (shape, healthy kind) that are in the regime: at least three, or the ladder
    /// says nothing about that pair.
    uint256 constant MIN_RUNGS = 3;

    function _empty() internal pure returns (bytes32) {
        BlazePhoenixQuoter.Preview memory z;
        return keccak256(abi.encode(z));
    }
}

contract BatchQuoteGasLadderTest is BatchQuoteGasLadderBase {
    function test_Ladder_WithGasForBoth_BothItemsAreAnsweredAsAlone_InEitherOrder() public {
        _calibrate();
        for (uint256 s; s < SHAPES; ++s) {
            for (uint256 k; k < KINDS; ++k) {
                uint256 ample = 2 * (gHeavy[s] + gHealthy[k]);
                (bool ok, BlazePhoenixQuoter.Preview[] memory pv,) = _ask(_two(heavy[s], healthy[k]), ample);
                assertTrue(ok, "the batch reverted with gas for both items");
                assertEq(keccak256(abi.encode(pv[0])), hHeavy[s], "heavy first: the heavy item differs from alone");
                assertEq(keccak256(abi.encode(pv[1])), hHealthy[k], "heavy first: the healthy item differs from alone");
                (ok, pv,) = _ask(_two(healthy[k], heavy[s]), ample);
                assertTrue(ok, "the batch reverted with gas for both items");
                assertEq(keccak256(abi.encode(pv[0])), hHealthy[k], "healthy first: the healthy item differs from alone");
                assertEq(keccak256(abi.encode(pv[1])), hHeavy[s], "healthy first: the heavy item differs from alone");
            }
        }
    }

    function test_Ladder_AHealthyItemAheadOfAStarvedOneIsAnsweredAsAlone_AndTheStarvedSlotIsEmpty() public {
        _calibrate();
        for (uint256 s; s < SHAPES; ++s) {
            for (uint256 k; k < KINDS; ++k) {
                uint256 counted;
                for (uint256 r; r <= 7; ++r) {
                    uint256 g = _rung(s, r);
                    if (!_inRegime(s, k, g)) continue;
                    ++counted;
                    (bool ok, BlazePhoenixQuoter.Preview[] memory pv,) = _ask(_two(healthy[k], heavy[s]), g);
                    assertTrue(ok, "a starved item took the whole batch down");
                    assertEq(keccak256(abi.encode(pv[0])), hHealthy[k], "the healthy item ahead of a starved one differs from alone");
                    assertEq(keccak256(abi.encode(pv[1])), _empty(), "the starved item's slot is not empty");
                }
                assertGe(counted, MIN_RUNGS, "the ladder has too few rungs in the regime");
            }
        }
    }
}
