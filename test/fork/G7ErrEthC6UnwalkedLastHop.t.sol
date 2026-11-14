// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  G7 draw ethereum major-5 idx 2 (block 26,339,826): WBTC -> USDC, 18.04784006 WBTC.
//  G7 lines: 8 (D, M0, M1h, M6h, M24h, M72h, MF24h, MF72h), all `noquote canExecute=0`.
//
//  The stack is the G7 ethereum deploy (tools/g7-gas-campaign/G7Deploy.s.sol `_core` +
//  `_ethereum`, then prereg/wiring.tsv rows 1-11): WETH, USDC and USDT are bridges.
//  With USDT a bridge the Solver leads with WBTC -> USDT -> USDC: hop 1 on two V3 legs,
//  hop 2 on the USDC/USDT 0.01 % pool. `Solver._paysWhatItWalks` shares V3_PAY_READS
//  reads in route order; hop 1 spends them and the last hop keeps its single-range
//  figure. That figure sets totalOut and the floor; the pool pays ~15 % less, and the
//  encode door (`Quoter._encode`, the `_fundedOut < effectiveMinOut` line) refuses:
//  no bytes, where the direct route (one hop, no USDT bridge) settles ~1,368,146 USDC.
//
//  Pinned here:
//    oracle : without bridges (the G7 state before 6c368ad) the same stack quotes one
//             hop, encodes and SETTLES the swap; the Router moves the tokens and the user
//             receives >= the floor and >= the G7 direct figure. Green. (Measured run 1:
//             with WETH and USDC only, the Solver already picks 2 hops, netOut
//             1,374,296,403,321, canExecute true: the USDT hop is the one that fails.)
//    door   : with the USDT bridge, the encode door returns executable bytes and the Router
//             SETTLES them at or above the direct route's delivery, 1,367,143,390,227. The
//             Solver's leader (2 hops via USDT) promises above what its last hop pays and
//             `_encode` refuses it; `Quoter._encodePlan` (#126) then asks the runner-up the
//             Solver already returned, which settles. Red at juncao-125 588364f: canExecute
//             false, no bytes (leader exactOut 1,180,387,084,643; last-hop promise
//             1,391,117,287,780). Mutant [QF-1].
//  Not pinned here: the Solver's leader itself paying at least the direct route (the last hop
//  left unwalked by V3_PAY_READS); that is a Solver fix of its own.
//  Run: forge test --match-path test/fork/G7ErrEthC6UnwalkedLastHop.t.sol -vv (DRPC_KEY set).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixGate} from "../../src/BlazePhoenixGate.sol";

interface IERC20G7Err {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

contract G7ErrEthC6UnwalkedLastHopTest is Test {
    uint256 internal constant BLK = 26_339_826;
    uint256 internal constant AMT = 1_804_784_006; // 18.04784006 WBTC, the draw's amount_in
    /// @dev What the direct route DELIVERS at this block: the oracle test's settled swap (1 hop,
    ///      no bridges; run 2, juncao-125 3649673). G7 run 43376232767 previewed it at netOut
    ///      1,368,146,700,421; this stack previews 1,368,140,753,067 and delivers this.
    uint256 internal constant DIRECT_OUT = 1_367_143_390_227;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant V4_MGR = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant UNIV3_INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    struct Stack { BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router; BlazePhoenixQuoter quoter; }

    address internal user = address(0xD1A6);

    function setUp() public {
        vm.createSelectFork("mainnet", BLK);
    }

    /// @dev G7Deploy `_core(me, V4_MGR, true)` + `_ethereum` + wiring.tsv. `bridges = false` is the
    ///      G7 state before 6c368ad (no bridge: the run 43376232767 that settled one hop).
    function _deploy(bool bridges) internal returns (Stack memory s) {
        address me = address(this);
        s.hub = new BlazePhoenixHub(me);
        s.hub.initialize(me, V4_MGR);
        address gate = address(new BlazePhoenixGate(me));
        s.solver = new BlazePhoenixSolver(address(s.hub), gate);
        s.router = new BlazePhoenixRouter(
            address(s.hub), address(s.solver), me,
            address(0x7E51111111111111111111111111111111111111), address(0x7e52222222222222222222222222222222222222));
        s.quoter = new BlazePhoenixQuoter(address(s.hub), address(s.solver));
        s.hub.setRoles(address(s.router), address(s.solver), address(s.quoter));
        uint24[] memory f0 = new uint24[](0);
        int24[] memory s0 = new int24[](0);
        s.hub.addFactory(0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f, 0, 0, bytes32(0), f0, s0); // _core row
        s.router.setWeth(WETH);
        if (bridges) { s.hub.addBridge(WETH); s.hub.addBridge(USDC); s.hub.addBridge(USDT); }
        uint24[] memory f = new uint24[](4); f[0] = 100; f[1] = 500; f[2] = 3000; f[3] = 10000;
        int24[] memory sp = new int24[](4); sp[0] = 1; sp[1] = 10; sp[2] = 60; sp[3] = 200;
        s.hub.addFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984, 1, 5, UNIV3_INIT, f, sp);   // wiring.tsv 1
        s.hub.addFactory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f, 0, 0, bytes32(0), f0, s0);   // 2
        s.hub.addFactory(0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac, 0, 0, bytes32(0), f0, s0);   // 3
        s.hub.addFactory(0x1097053Fd2ea711dad45caCcc45EfF7548fCB362, 0, 0, bytes32(0), f0, s0);   // 4
        s.hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, 1, 1, bytes32(0), f, sp);    // 5
        s.hub.addFactory(0xbACEB8eC6b9355Dfc0269C18bac9d6E2Bdc29C4F, 1, 1, bytes32(0), f, sp);    // 6
        s.hub.addFactory(0x115934131916C8b277DD010Ee02de363c09d037c, 0, 0, bytes32(0), f0, s0);   // 7
        s.hub.addFactory(0x43eC799eAdd63848443E2347C49f5f52e8Fe0F6f, 0, 0, bytes32(0), f0, s0);   // 8
        // rows 9-11 re-add WETH, USDC, USDT: addBridge returns early on a bridge already set.
    }

    /// @dev Oracle, not the code under test's promise: the Router moves the tokens.
    function test_oracle_withoutBridges_directRouteEncodesAndSettlesAtTheDirectFigure() public {
        Stack memory s = _deploy(false);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            s.quoter.previewAndEncode(WBTC, USDC, AMT, user, block.timestamp + 600);
        emit log_named_uint("hops", pv.hops);
        emit log_named_uint("netOut", pv.netOut);
        emit log_named_uint("effectiveMinOut", pv.effectiveMinOut);
        assertTrue(pv.canExecute, "precondition: the direct route encodes at this block");
        assertEq(pv.hops, 1, "one hop without bridges");
        deal(WBTC, user, AMT);
        uint256 b0 = IERC20G7Err(USDC).balanceOf(user);
        vm.startPrank(user);
        IERC20G7Err(WBTC).approve(address(s.router), AMT);
        (bool ok,) = address(s.router).call(call);
        vm.stopPrank();
        assertTrue(ok, "the Router settles the bytes the Quoter encoded");
        uint256 got = IERC20G7Err(USDC).balanceOf(user) - b0;
        emit log_named_uint("delivered", got);
        assertGe(got, pv.effectiveMinOut, "delivered at or above the floor");
        assertGe(got, DIRECT_OUT, "the direct route delivers the pinned direct figure");
    }

    /// @dev The encode door with the USDT bridge: executable bytes, settled by the Router at or
    ///      above the direct route's delivery. Oracle: the tokens the Router moves.
    function test_withUsdtBridge_encodeDoorFallsBackToTheRunnerUp_bytesSettleAtOrAboveTheDirect() public {
        Stack memory s = _deploy(true);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            s.quoter.previewAndEncode(WBTC, USDC, AMT, user, block.timestamp + 600);
        emit log_named_uint("hops", pv.hops);
        emit log_named_uint("legs", pv.legs);
        emit log_named_uint("netOut (promise)", pv.netOut);
        emit log_named_uint("effectiveMinOut", pv.effectiveMinOut);
        assertTrue(pv.canExecute, "an order with an executable route gets executable bytes");
        assertGt(call.length, 0, "bytes");
        deal(WBTC, user, AMT);
        uint256 b0 = IERC20G7Err(USDC).balanceOf(user);
        vm.startPrank(user);
        IERC20G7Err(WBTC).approve(address(s.router), AMT);
        (bool ok, bytes memory ret) = address(s.router).call(call);
        vm.stopPrank();
        assertTrue(ok, string.concat("the Router settles the bytes: ", vm.toString(ret)));
        uint256 got = IERC20G7Err(USDC).balanceOf(user) - b0;
        emit log_named_uint("delivered", got);
        assertGe(got, pv.effectiveMinOut, "delivered at or above the floor the bytes carry");
        assertGe(got, DIRECT_OUT, "delivered at or above the direct route");
    }
}
