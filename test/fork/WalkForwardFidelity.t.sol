// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// WALK-FORWARD: THE QUOTE NEVER PROMISES MORE THAN THE BALANCE DELTA, ON BLOCKS CHOSEN BEFORE THEY EXISTED.
//
// Pre-registered in docs/prereg/wf-1113.tsv (tools/fuzz-coverage/prereg.py binds the constants,
// PREREG_TAG, PREREG_LOCK and the rule line verbatim). Block k is the first Base block with
// timestamp >= WF_T0 + k * WF_DT, for k < WF_N; CI resolves them with
// `prereg.py wf-blocks` and passes them in WF_BLOCKS (comma list). The test proves each block
// is the first one at its target (the block before is still short of it), so a list that was
// picked rather than derived fails here.
//
// THE RULE IS EXACT: netOut <= balance delta at the user (I2), no margin (Quoter R-C,
// src/BlazePhoenixQuoter.sol:436-440). The fidelity gap against netOut + safetyBuffer is
// logged, not asserted: the owner decides it.
//
// Wiring: copied from test/fork/QuoteFidelity.t.sol (_wire, _exec with the balance delta).
// Skips (never passes) without DRPC_KEY or WF_BLOCKS.
//
// Red first: red under the meta-mutant wf-1 (tools/fuzz-coverage/meta_mutants.py --apply wf-1:
// the Quoter publishes afterFee + 0.5% as netOut), run by the wf job of fuzz-mc.yml. Green at
// HEAD is for CI to confirm: no forge was run where this file was written.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {Route} from "../../src/BlazePhoenixCore.sol";

interface IERC20WF {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract WalkForwardFidelityTest is Test {
    string internal constant PREREG_TAG = "wf-1113";
    bytes32 internal constant PREREG_LOCK = 0xcf1be83b009bb87a135a70ed33f871dc7f5a52f48106d9aecea91ddfce626cd5;
    uint256 internal constant WF_T0 = 1794529506;
    uint256 internal constant WF_DT = 19208;
    uint256 internal constant WF_N = 59;

    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant V4MGR  = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);
    bytes32 constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    uint256 constant AMOUNT = 1_000e6;

    BlazePhoenixHub hub; BlazePhoenixSolver solver;
    BlazePhoenixRouter router; BlazePhoenixQuoter quoter;
    bool live;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }   // a bare return reports PASSED on a test that ran nothing
        live = true;
    }

    /// Deploy and wire on the selected fork (each fork starts without the local contracts).
    function _wire() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4MGR);
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        router.setWeth(WETH);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(WSTETH);
        uint24[] memory f4 = new uint24[](4);
        f4[0]=100; f4[1]=500; f4[2]=3000; f4[3]=10000;
        int24[] memory s4 = new int24[](4);
        s4[0]=1; s4[1]=10; s4[2]=60; s4[3]=200;
        uint24[] memory n0 = new uint24[](0);
        int24[]  memory z0 = new int24[](0);
        hub.addFactory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD, 1, 5, UNIV3_INIT, f4, s4);
        hub.addFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da, 5, 2, bytes32(0), n0, z0);
        hub.addFactory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6, 0, 0, bytes32(0), n0, z0);
        hub.addFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4, 1, 1, bytes32(0), f4, s4);
        hub.addV4(address(0), USDC, 500, 10, address(0));
        hub.addFactory(V4MGR, 4, 9, bytes32(0), n0, z0);
    }

    /// Execute the previewed route as a user; the balance delta, never the Router's return.
    /// A revert after an executable preview fails the test (no try).
    function _exec(Route memory rt) internal returns (uint256 got) {
        address user = address(0xBEEF);
        deal(USDC, user, AMOUNT);
        vm.prank(user);
        IERC20WF(USDC).approve(address(router), AMOUNT);
        uint256 before = IERC20WF(WETH).balanceOf(user);
        vm.prank(user);
        router.swapExactIn(rt, AMOUNT, 1, user, block.timestamp + 600);
        got = IERC20WF(WETH).balanceOf(user) - before;
    }

    function test_WF_QuoteNeverAboveDelivered() public {
        if (!live) { vm.skip(true); return; }   // skip, not pass: the key is absent, nothing was exercised
        if (bytes(vm.envOr("WF_BLOCKS", string(""))).length == 0) { vm.skip(true); return; }
        emit log_named_bytes32("PREREG_LOCK", PREREG_LOCK);
        uint256[] memory blocks = vm.envUint("WF_BLOCKS", ",");
        require(blocks.length > 0 && blocks.length <= WF_N, "WF: need 0 < blocks <= WF_N");
        uint256 measured;
        uint256 maxGap;
        for (uint256 k; k < blocks.length; k++) {
            uint256 target = WF_T0 + k * WF_DT;
            vm.createSelectFork("base", blocks[k] - 1);
            assertLt(block.timestamp, target, "WF: the block before is already at the target");
            vm.createSelectFork("base", blocks[k]);
            assertGe(block.timestamp, target, "WF: the block is short of its target");
            _wire();
            (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(USDC, WETH, AMOUNT);
            if (!pv.canExecute || pv.netOut == 0) {
                emit log_named_uint("WF declined at block", blocks[k]);
                continue;
            }
            uint256 got = _exec(pv.route);
            assertLe(pv.netOut, got, "WF: the quote promised more than the balance delta");
            uint256 fair = pv.netOut + pv.safetyBuffer;
            uint256 gap = got > fair ? got - fair : fair - got;
            if (gap > maxGap) maxGap = gap;
            measured++;
        }
        emit log_named_uint("WF blocks", blocks.length);
        emit log_named_uint("WF measured", measured);
        emit log_named_uint("WF max fee-model gap, wei (logged, not asserted: owner decides)", maxGap);
        assertGt(measured, 0, "WF: no block was measured (absent is not zero)");
    }
}
