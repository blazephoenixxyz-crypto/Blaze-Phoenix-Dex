// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// HD-01, liveness face (audit 2026-11-06, area x-hops2-delta-final, round 3).
//
// WHAT WAS WRONG. The same one-cut-per-bridge poisoning as Hd01OneCutPerBridge.t.sol, but each
// book sits at the BOTTOM of its one-tick range, so it holds only the token the victim SELLS and
// pays nothing in the victim's direction. `_dropDust` still dropped the honest row (the
// registry's depth is the virtual side, with no direction), the stage built on the book was
// empty, and with no direct pair every two-hop topology was empty: `findBestRoutePlan` reverted
// SolverE(5), preview and automatic door alike.
//
// FIXTURE. X < B1 < B2 < Y, 18 decimals, priced 1:1; honest V2 pairs X/B1 500k, B1/B2 5M,
// B2/Y 500k (deep chain), X/B2 5k and B1/Y 2.5k (cheap sides); no X/Y pair.
// THE BOOK (no privilege: Hub.claimV4 with a bridge side, hookless): a one-tick V4 position
// (spacing 1, L = 1e28) on [69077, 69078), price exactly at its lower tick (~1e3 token1 per
// token0), on (X,B2) and on (B1,Y). Its virtual depth is over 4e4 times the honest rows. Each
// book holds ~1.58e22 of token0 (the token the victim sells) and no token1.
//
// WHAT IS MEASURED NOW. A book holding none of the bought token adds nothing to the other rows'
// sum in `_dropDust` (`Solver._heldBooks`): the honest rows are quoted and 100 X is routed at
// >= 99 % of the clean plan.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract HD01LivenessOneQuietCutPerBridgeTest is Test {
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
    int24 constant TLO = 69077;            // 1.0001^69077 ~ 1e3 token1 per token0
    uint128 constant L = 1e28;
    uint256 constant HELD = 16_000e18;     // >= the ~1.58e22 of token0 the position holds
    uint256 constant AMOUNT = 100e18;      // the victim's input, 100 X

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

        _pair(X, B1, 500_000e18);
        _pair(B1, B2, 5_000_000e18);
        _pair(B2, Y, 500_000e18);
        _pair(X, B2, 5_000e18);
        _pair(B1, Y, 2_500e18);
    }

    function _pair(address a, address b, uint256 side) internal {
        MockV2Pair p = new MockV2Pair(a, b);
        PathologicalERC20(a).mint(address(p), side);
        PathologicalERC20(b).mint(address(p), side);
        p.setReserves(uint112(side), uint112(side));
        (address s0, address s1) = a < b ? (a, b) : (b, a);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), s0, s1);
    }

    /// The attacker's book on (t0, t1), t0 < t1: one tick, price at its lower tick, holding
    /// token0 only (the token a victim selling t0 brings); claimed through the permissionless door.
    function _poisonQuiet(address t0, address t1) internal returns (bytes32 pid) {
        require(t0 < t1, "fixture: sorted pair");
        pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(TLO), TLO, FEE);
        mgr.addPosition(pid, TLO, TLO + 1, TS, L);
        PathologicalERC20(t0).mint(address(mgr), HELD);
        vm.prank(ATK);
        hub.claimV4(t0, t1, FEE, TS);
    }

    function _plan() internal view returns (uint256 out, uint256 hops, bytes memory err) {
        try solver.findBestRoutePlan(X, Y, AMOUNT) returns (RoutePlan memory p) {
            return (p.best.totalOut, p.best.hops.length, "");
        } catch (bytes memory e) {
            return (0, 0, e);
        }
    }

    function test_HD01_Liveness_OneQuietCutPerBridgeLeavesThePairRoutable() public {
        (uint256 clean, uint256 cleanHops, ) = _plan();
        emit log_named_uint("clean totalOut (Y wei)", clean);
        emit log_named_uint("clean hops", cleanHops);
        assertGt(clean, 95e18, "control: the clean plan routes 100 X at > 95 Y");

        bytes32 p1 = _poisonQuiet(X, B2);
        bytes32 p2 = _poisonQuiet(B1, Y);

        // Fixture facts, read from the venue's own math (the mock), not from the code under test:
        // each book pays nothing to a seller of token0, and its registry depth crosses the gate.
        (, uint256 o1, , , ) = mgr.specSwap(p1, AMOUNT, FEE, TS, true);
        (, uint256 o2, , , ) = mgr.specSwap(p2, AMOUNT, FEE, TS, true);
        emit log_named_uint("book (X,B2) pays a seller of X", o1);
        emit log_named_uint("book (B1,Y) pays a seller of B1", o2);
        assertEq(o1 + o2, 0, "fixture: the books pay nothing in the victim's direction");
        uint256 d1 = BPC.registryDepth18(address(uint160(uint256(p1))), BPC.KIND_V4, X, B2, address(mgr), p1);
        uint256 d2 = BPC.registryDepth18(address(uint160(uint256(p2))), BPC.KIND_V4, B1, Y, address(mgr), p2);
        emit log_named_uint("book (X,B2) registry depth", d1);
        emit log_named_uint("book (B1,Y) registry depth", d2);
        assertLt(uint256(5_000e18) * 1e6, 25 * d1, "fixture: X/B2 honest row under the dust gate");
        assertLt(uint256(2_500e18) * 1e6, 25 * d2, "fixture: B1/Y honest row under the dust gate");

        (uint256 got, uint256 gotHops, bytes memory err) = _plan();
        emit log_named_uint("attacked totalOut (Y wei)", got);
        emit log_named_uint("attacked hops", gotHops);
        emit log_named_bytes("attacked revert data", err);
        emit log_named_bytes("SolverE(5) encoding", abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        assertGe(got, clean * 99 / 100,
            "one quiet cut per bridge left the pair without any plan (no three-hop rescue)");
    }
}
