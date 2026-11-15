// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  G7 draw ethereum fee_low-1 idx 3 (block 26,394,437): wstETH -> WETH,
//  1,161.445461420340464844 wstETH. G7 lines: 8 (D, M0, M1h, M6h, M24h, M72h ok;
//  MF24h, MF72h mf_unforced). G7 (bb4cdbb, no V4 derive row): netOut
//  1,400,015,128,543,091,356,531, floor 1,348,176,052,505,555,454,075, delivered
//  1,444,192,108,941,566,033,105 on 3 legs.
//
//  Candidate C1 (G7-COBERTURA 1b): adding the Uniswap V4 derive row
//  `hub.addFactory(V4_MGR, KIND_V4, MODE_V4_DERIVE, 0, [], [])` to the hub state made
//  the same route quote ~69 % lower (netOut 435,023,519,713,684,300,375) while the
//  delivered figure stayed the same. Measured there on a synthetic state; here on a
//  real deploy, with the same figures.
//
//  Cause (run 2): the route, its 3 legs and their inputs are identical in both states;
//  only the deep leg 0x109830a1 (V3 0.01 %, 1,160.05 wstETH in) changes its promise. Its
//  quote exceeds Solver.MAX_CONC_DRAIN_BPS (30 %) of the pool's 1,453.43 WETH, so
//  `_capacity` holds it at the cap (436,028,684,373,817,525,719) until the leader's WALK
//  rebuild prices it. That rebuild is a self-staticcall bounded by WALK_GAS = 2,500,000
//  (`_walkOnItsOwnBudget`). Without the V4 row it uses 1,703,038 gas and prices
//  1,404,789,051,271,809,371,756; with the V4 row it needs 3,786,116 (warm), runs out of
//  gas, fails silently, and the capped promise stays: grossOut 436.5 WETH, floor 418.9
//  WETH, while the pools pay 1,444.19 WETH.
//
//  Fix (C1, c1-126): F1 - a rebuild that does not complete stops the solve instead of
//  leaving the cap; F2 - the rebuild's budget is what SOLVE_GAS leaves after the search
//  (WALK_GAS removed). Red at 588364f (netOut 435,023,519,713,684,300,375 with the row).
//  Pinned here: without the row the quote is G7's and at most what settles; with it the
//  quote of the same route is no lower than without it and at most what settles.
//  Mutants that turn the row test red: [c1-m1] (a failed rebuild leaves the cap again,
//  with W fixed at 2.5M) and [c1-m2] (W fixed at 2.5M).
//  Local only: a red test for an unfixed path ships with its fix.
//
//  Stack: G7Deploy `_core` + `_ethereum` + prereg/wiring.tsv rows 1-11 (bridges WETH,
//  USDC, USDT), as in G7ErrEthC6UnwalkedLastHop. `v4Row` adds the derive row.
//  Run: forge test --match-path test/fork/G7ErrEthV4LineLowersQuote.t.sol -vv (DRPC_KEY set).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixGate} from "../../src/BlazePhoenixGate.sol";
import {Route, RoutePlan} from "../../src/BlazePhoenixCore.sol";

interface IERC20G7V4Line {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

contract G7ErrEthV4LineLowersQuoteTest is Test {
    uint256 internal constant BLK = 26_394_437;
    uint256 internal constant AMT = 1_161_445_461_420_340_464_844; // the draw's amount_in
    /// netOut of this draw without the V4 row (G7 bb4cdbb; re-measured here with the row at 30M).
    uint256 internal constant NET_NO_ROW = 1_400_015_128_543_091_356_531;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant V4_MGR = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant UNIV3_INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    uint8 internal constant KIND_V4 = 4;
    uint8 internal constant MODE_V4_DERIVE = 9;

    struct Stack { BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router; BlazePhoenixQuoter quoter; }

    address internal user = address(0xD1A6);

    function setUp() public {
        vm.createSelectFork(vm.envOr("C1_FORK_URL", string("mainnet")), BLK);
    }

    function _deploy(bool v4Row) internal returns (Stack memory s) {
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
        s.hub.addBridge(WETH); s.hub.addBridge(USDC); s.hub.addBridge(USDT);
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
        if (v4Row) s.hub.addFactory(V4_MGR, KIND_V4, MODE_V4_DERIVE, bytes32(0), f0, s0);
    }

    function _log(BlazePhoenixQuoter.Preview memory pv) internal {
        emit log_named_uint("canExecute", pv.canExecute ? 1 : 0);
        emit log_named_uint("hops", pv.hops);
        emit log_named_uint("legs", pv.legs);
        emit log_named_uint("grossOut", pv.grossOut);
        emit log_named_uint("protocolFee", pv.protocolFee);
        emit log_named_uint("safetyBuffer", pv.safetyBuffer);
        emit log_named_uint("netOut", pv.netOut);
        emit log_named_uint("ironFloor", pv.ironFloor);
        emit log_named_uint("effectiveMinOut", pv.effectiveMinOut);
        emit log_named_uint("route.totalOut", pv.route.totalOut);
        emit log_named_uint("route.singleOut", pv.route.singleOut);
        emit log_named_uint("route.singleOutFloor", pv.route.singleOutFloor);
        emit log_named_uint("route.confidenceWad", pv.route.confidenceWad);
        emit log_named_uint("route.expectedImpactBps", pv.route.expectedImpactBps);
        emit log_named_uint("route.isV4Bundle", pv.route.isV4Bundle ? 1 : 0);
        for (uint256 h; h < pv.route.hops.length; ++h) {
            emit log_named_uint("hop", h);
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                emit log_named_address("  pool", pv.route.hops[h].legs[l].pool);
                emit log_named_uint("    kind", pv.route.hops[h].legs[l].kind);
                emit log_named_uint("    fee", pv.route.hops[h].legs[l].fee);
                emit log_named_uint("    amountIn", pv.route.hops[h].legs[l].amountIn);
                emit log_named_uint("    expectedOut", pv.route.hops[h].legs[l].expectedOut);
            }
        }
    }

    function _settle(Stack memory s, bytes memory call) internal returns (bool ok, uint256 got) {
        deal(WSTETH, user, AMT);
        uint256 b0 = IERC20G7V4Line(WETH).balanceOf(user) + user.balance;
        vm.startPrank(user);
        IERC20G7V4Line(WSTETH).approve(address(s.router), AMT);
        (ok,) = address(s.router).call(call);
        vm.stopPrank();
        got = IERC20G7V4Line(WETH).balanceOf(user) + user.balance - b0;
    }

    function _run(bool v4Row) internal returns (BlazePhoenixQuoter.Preview memory pv, bool ok, uint256 got) {
        Stack memory s = _deploy(v4Row);
        bytes memory call;
        (pv, call) = s.quoter.previewAndEncode(WSTETH, WETH, AMT, user, block.timestamp + 600);
        _log(pv);
        try s.quoter.previewPlanExact(WSTETH, WETH, AMT) returns (Route memory, uint256 eo) {
            emit log_named_uint("exactOut (venues pay)", eo);
        } catch (bytes memory err) {
            emit log_named_bytes("previewPlanExact reverted", err);
        }
        if (pv.canExecute) {
            (ok, got) = _settle(s, call);
            emit log_named_uint("settled", ok ? 1 : 0);
            emit log_named_uint("delivered", got);
        }
    }

    /// @dev Oracle: the G7 state (no V4 derive row) quotes, encodes and settles at or above its floor.
    function test_oracle_withoutV4Row_quotesEncodesAndSettlesAboveTheFloor() public {
        (BlazePhoenixQuoter.Preview memory pv, bool ok, uint256 got) = _run(false);
        assertTrue(pv.canExecute, "precondition: the G7 state encodes this draw");
        assertTrue(ok, "the Router settles the bytes the Quoter encoded");
        assertGe(got, pv.effectiveMinOut, "delivered at or above the floor");
        assertEq(pv.netOut, NET_NO_ROW, "the G7 state's quote (G7 bb4cdbb)");
        assertLe(pv.netOut, got, "the quote promises no more than the route delivers");
    }

    /// @dev With the V4 derive row the route, its legs and what it delivers are the same; the
    ///      row only adds candidates, so the quote of that route may not fall below the quote
    ///      without the row (monotone in venues), nor promise more than the route delivers.
    function test_withV4Row_quoteTracksWhatTheEncodedRouteDelivers() public {
        (BlazePhoenixQuoter.Preview memory pv, bool ok, uint256 got) = _run(true);
        assertTrue(pv.canExecute, "with the V4 row the draw still encodes");
        assertTrue(ok, "the Router settles the bytes the Quoter encoded");
        assertGe(got, pv.effectiveMinOut, "delivered at or above the floor");
        assertGe(pv.netOut, NET_NO_ROW, "a factory row lowered the quote of the same route");
        assertLe(pv.netOut, got, "the quote promises more than the route delivers");
    }
}
