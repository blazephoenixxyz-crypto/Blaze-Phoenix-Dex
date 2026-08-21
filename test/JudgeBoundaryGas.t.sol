// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  JUDGE BOUNDARY GAS — the "one question, two traversals" pattern (P1),
//  measured against the REAL Hub with a DIFFERENTIAL method.
//
//  Method: every quantity is the difference between a loop of 2K iterations and
//  a loop of K iterations, divided by K.  All operands are cached in LOCALS
//  before the window and every account/slot is pre-warmed by a dry run, so the
//  result is the true MARGINAL cost of one more traversal — free of cold-access
//  and of the test contract's own storage reads (which contaminated the naive
//  version of this harness by ~10k gas).
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract Trivial {
    function nothing() external pure returns (uint256) { return 1; }
}

contract JudgeBoundaryGasTest is Test {
    BlazePhoenixHub hub;
    MockERC20 tA;
    MockERC20 tB;
    Trivial triv;
    address[] poolsS;

    uint256 constant K = 8;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        hub.setRoles(address(this), address(this), address(this));
        triv = new Trivial();
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        for (uint256 i; i < 16; ++i) {
            MockV2Pair p = new MockV2Pair(address(tA), address(tB));
            tA.mint(address(p), 1_000_000e18 + i * 1e18);
            tB.mint(address(p), 1_000_000e18);
            p.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tA), address(tB));
            poolsS.push(address(p));
        }
        hub.addBridge(address(tA));
        hub.addBridge(address(tB));
    }

    function _localKeyOf(address pool, address x, address y) internal pure returns (bytes32) {
        (address s0, address s1) = x < y ? (x, y) : (y, x);
        return keccak256(abi.encodePacked(pool, s0, s1));
    }

    function _mem() internal view returns (address[] memory m) {
        uint256 n = poolsS.length;
        m = new address[](n);
        for (uint256 i; i < n; ++i) m[i] = poolsS[i];
    }

    /// @dev marginal cost of ONE external warm staticcall, as a control floor.
    function test_A_Control_MarginalExternalCall() public view {
        Trivial t = triv;
        uint256 acc = t.nothing(); // warm the account
        uint256 g0 = gasleft();
        for (uint256 i; i < K; ++i) acc += t.nothing();
        uint256 gK = g0 - gasleft();
        uint256 g1 = gasleft();
        for (uint256 i; i < 2 * K; ++i) acc += t.nothing();
        uint256 g2K = g1 - gasleft();
        require(acc != 0, "acc");
        console2.log("JB|control|marginal_trivial_staticcall", (g2K - gK) / K);
        console2.log("JB|control|loopK", gK);
        console2.log("JB|control|loop2K", g2K);
    }

    /// @dev (1) hub.getSlot(hub.keyOf(...))  vs  hub.getSlot(localKeyOf(...))
    function test_B_SlotOf_TwoTraversals_vs_LocalKeccak() public view {
        address[] memory p = _mem();
        address a = address(tA);
        address b = address(tB);
        uint256 acc;
        // dry run: warm hub account + every pair's slot in both variants
        for (uint256 i; i < 2 * K; ++i) acc += hub.getSlot(hub.keyOf(p[i], a, b));

        uint256 g0 = gasleft();
        for (uint256 i; i < K; ++i) acc += hub.getSlot(hub.keyOf(p[i], a, b));
        uint256 twoK = g0 - gasleft();
        uint256 g1 = gasleft();
        for (uint256 i; i < 2 * K; ++i) acc += hub.getSlot(hub.keyOf(p[i], a, b));
        uint256 two2K = g1 - gasleft();

        uint256 g2 = gasleft();
        for (uint256 i; i < K; ++i) acc += hub.getSlot(_localKeyOf(p[i], a, b));
        uint256 oneK = g2 - gasleft();
        uint256 g3 = gasleft();
        for (uint256 i; i < 2 * K; ++i) acc += hub.getSlot(_localKeyOf(p[i], a, b));
        uint256 one2K = g3 - gasleft();

        require(acc != 0, "acc");
        uint256 mTwo = (two2K - twoK) / K;
        uint256 mOne = (one2K - oneK) / K;
        console2.log("JB|slot|marginal_two_traversals_per_pool", mTwo);
        console2.log("JB|slot|marginal_local_keccak_per_pool", mOne);
        console2.log("JB|slot|SAVED_per_pool", mTwo - mOne);
    }

    /// @dev (3) v4PoolManager() re-read per V4 quote vs read once
    function test_C_V4PoolManager_MarginalReread() public view {
        BlazePhoenixHub h = hub;
        address x = h.v4PoolManager();
        uint256 acc = uint256(uint160(x)) + 1;
        uint256 g0 = gasleft();
        for (uint256 i; i < K; ++i) acc += uint256(uint160(h.v4PoolManager()));
        uint256 gK = g0 - gasleft();
        uint256 g1 = gasleft();
        for (uint256 i; i < 2 * K; ++i) acc += uint256(uint160(h.v4PoolManager()));
        uint256 g2K = g1 - gasleft();
        require(acc != 0, "acc");
        console2.log("JB|v4pm|marginal_reread", (g2K - gK) / K);
    }

    /// @dev (2) bridges: marginal cost of each of the 3 traversals
    function test_D_Bridges_MarginalTraversal() public view {
        BlazePhoenixHub h = hub;
        uint8 c = h.bridgeCount();
        address b0 = h.bridge(0);
        require(c == 2 && b0 != address(0), "bridges");
        uint256 acc;
        uint256 g0 = gasleft();
        for (uint256 i; i < K; ++i) { acc += h.bridgeCount(); acc += uint256(uint160(h.bridge(0))); acc += uint256(uint160(h.bridge(1))); }
        uint256 gK = g0 - gasleft();
        uint256 g1 = gasleft();
        for (uint256 i; i < 2 * K; ++i) { acc += h.bridgeCount(); acc += uint256(uint160(h.bridge(0))); acc += uint256(uint160(h.bridge(1))); }
        uint256 g2K = g1 - gasleft();
        require(acc != 0, "acc");
        console2.log("JB|bridges|marginal_three_traversals", (g2K - gK) / K);
        console2.log("JB|bridges|marginal_one_traversal_est", (g2K - gK) / K / 3);
    }
}

// =============================================================================
//  EXEC-PATH PROBE — marginal cost of the staticcalls the Router makes on the
//  HOT path (the one both entry points share). Same differential method.
// =============================================================================
interface IPairProbe {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract JudgeExecProbeTest is Test {
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair pair;
    uint256 constant K = 8;

    function setUp() public {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        pair = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(pair), 1_000_000e18);
        tB.mint(address(pair), 1_000_000e18);
        pair.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
    }

    function test_MarginalPoolReads() public view {
        IPairProbe p = IPairProbe(address(pair));
        MockERC20 t = tA;
        address who = address(pair);
        uint256 acc = uint256(uint160(p.token0())) + uint256(uint160(p.token1())) + t.balanceOf(who);
        (uint112 r0,,) = p.getReserves();
        acc += r0;

        // token0 + token1 (what _legTokenOut/_legTokenIn pay per non-V4 leg)
        uint256 g0 = gasleft();
        for (uint256 i; i < K; ++i) { acc += uint256(uint160(p.token0())); acc += uint256(uint160(p.token1())); }
        uint256 aK = g0 - gasleft();
        uint256 g1 = gasleft();
        for (uint256 i; i < 2 * K; ++i) { acc += uint256(uint160(p.token0())); acc += uint256(uint160(p.token1())); }
        uint256 a2K = g1 - gasleft();

        uint256 g2 = gasleft();
        for (uint256 i; i < K; ++i) { (uint112 x,,) = p.getReserves(); acc += x; }
        uint256 bK = g2 - gasleft();
        uint256 g3 = gasleft();
        for (uint256 i; i < 2 * K; ++i) { (uint112 x,,) = p.getReserves(); acc += x; }
        uint256 b2K = g3 - gasleft();

        uint256 g4 = gasleft();
        for (uint256 i; i < K; ++i) acc += t.balanceOf(who);
        uint256 cK = g4 - gasleft();
        uint256 g5 = gasleft();
        for (uint256 i; i < 2 * K; ++i) acc += t.balanceOf(who);
        uint256 c2K = g5 - gasleft();

        require(acc != 0, "acc");
        console2.log("JB|exec|marginal_token0_plus_token1_per_leg", (a2K - aK) / K);
        console2.log("JB|exec|marginal_getReserves", (b2K - bK) / K);
        console2.log("JB|exec|marginal_balanceOf_warm", (c2K - cK) / K);
    }

    function test_ColdVsWarmPoolRead() public {
        IPairProbe p = IPairProbe(address(pair));
        vm.cool(address(pair));
        uint256 g0 = gasleft();
        address x = p.token0();
        uint256 cold = g0 - gasleft();
        uint256 g1 = gasleft();
        address y = p.token1();
        uint256 warmAcctColdSlot = g1 - gasleft();
        uint256 g2 = gasleft();
        address z = p.token0();
        uint256 warmBoth = g2 - gasleft();
        require(x != address(0) && y != address(0) && z != address(0), "t");
        console2.log("JB|exec|token0_cold_account", cold);
        console2.log("JB|exec|token1_warm_acct_cold_slot", warmAcctColdSlot);
        console2.log("JB|exec|token0_warm_both", warmBoth);
    }
}
