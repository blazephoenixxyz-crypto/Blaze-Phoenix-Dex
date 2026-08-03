// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  FORK METRICS — L2s (Arbitrum / Base / Optimism).
//
//  Each suite wires the exact venue set of its deploy script
//  (script/Deploy{Arbitrum,Base,Optimism}.s.sol) on a fork of that chain, then
//  runs ~20 cases/chain: direct + stable + WBTC + many exotics and
//  exotic->exotic pairs, across small / medium / whale sizes and multi-size
//  sweeps. These chains are where the off-mainnet adapters live, so the cases
//  exercise them end-to-end:
//    * Arbitrum — Camelot V3 (Algebra, dynamic-fee sentinel)
//    * Base     — Aerodrome (Solidly) + Uniswap V4 (USDC/WETH 500/10)
//    * Optimism — Velodrome (Solidly) + Velodrome CL (V3-CL mode)
//
//  Run one chain at a time (each suite skips when its RPC var is unset):
//    export ARB_RPC_URL="https://arb-mainnet.g.alchemy.com/v2/<KEY>"
//    forge test --match-contract ForkArbitrumMetrics -vv
//    export BASE_RPC_URL=...   && forge test --match-contract ForkBaseMetrics -vv
//    export OP_RPC_URL=...      && forge test --match-contract ForkOptimismMetrics -vv
//
//  Optional per-chain pin: ARB_FORK_BLOCK / BASE_FORK_BLOCK / OP_FORK_BLOCK.
// =============================================================================

import { ForkMetricsBase } from "./ForkMetricsBase.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  ARBITRUM ONE (chainid 42161) — no V4; Camelot is Algebra.
// ─────────────────────────────────────────────────────────────────────────────
contract ForkArbitrumMetrics is ForkMetricsBase {
    address constant UNIV2_FACTORY = 0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9;
    address constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant CAMELOT_V3    = 0x1a3c9B1d2F0529D97f2afC5136Cc23e58f1FD35B; // Algebra
    address constant SUSHI_V2      = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
    address constant SUSHI_V3      = 0x1af415a1EbA07a4986a52B6f2e7dE7003D82231e;
    address constant PANCAKE_V3    = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant CAMELOT_V2    = 0x6EcCab422D763aC031210895C81787E87B43A652;

    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native USDC
    address constant ARB  = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address constant GMX  = 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant DAI  = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant LINK = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    address constant UNI  = 0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0;
    address constant PENDLE = 0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8;

    function setUp() public {
        live = _startFork("ARB_RPC_URL", "ARB_FORK_BLOCK");
        if (!live) return;
        _deployCore(address(0)); // no V4 on Arbitrum

        hub.addBridge(WETH);
        hub.addBridge(USDC);

        uint24[] memory v3Fees = new uint24[](4);
        v3Fees[0]=100; v3Fees[1]=500; v3Fees[2]=3000; v3Fees[3]=10000;
        int24[] memory v3Sp = new int24[](4);
        v3Sp[0]=1; v3Sp[1]=10; v3Sp[2]=60; v3Sp[3]=200;
        uint24[] memory noFees = new uint24[](0);
        int24[] memory noSp = new int24[](0);

        hub.addFactory(UNIV3_FACTORY, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, v3Fees, v3Sp);
        // Camelot (Algebra): V3-style with the fee=0 dynamic-fee sentinel.
        uint24[] memory algFees = new uint24[](1); algFees[0]=0;
        int24[] memory algSp = new int24[](1); algSp[0]=1;
        hub.addFactory(CAMELOT_V3, KIND_ALGEBRA, MODE_CALL_V3, bytes32(0), algFees, algSp);
        hub.addFactory(UNIV2_FACTORY, KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V2,      KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V3,      KIND_V3, MODE_CALL_V3,      bytes32(0), v3Fees, v3Sp);
        uint24[] memory pFees = new uint24[](4);
        pFees[0]=100; pFees[1]=500; pFees[2]=2500; pFees[3]=10000;
        hub.addFactory(PANCAKE_V3,    KIND_V3, MODE_CALL_V3,      bytes32(0), pFees, v3Sp);
        hub.addFactory(CAMELOT_V2,    KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
    }

    function test_fork_arb_direct_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB DIRECT  WETH -> USDC", WETH, USDC, 10 ether);
    }

    function test_fork_arb_discoverySkip_gas() public {
        if (!live) { vm.skip(true); return; }
        _reportDiscoverySkip("ARB DISCOVERY-SKIP  WETH->USDC quote gas", WETH, USDC, 10 ether);
    }

    function test_fork_arb_direct_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB DIRECT  USDC -> WETH", USDC, WETH, 25_000e6);
    }

    function test_fork_arb_sweep_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("ARB SWEEP WETH->USDC (size / legs / quoteGas / execGas / out)",
            WETH, USDC, [uint256(1 ether), 5 ether, 25 ether, 100 ether, 400 ether]);
    }

    function test_fork_arb_exotic_ARB_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB EXOTIC  ARB -> USDC", ARB, USDC, 100_000e18);
    }

    function test_fork_arb_exotic2_GMX_ARB() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB EXO->EXO  GMX -> ARB", GMX, ARB, 10_000e18);
    }

    // ── size variety ──
    function test_fork_arb_small_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB SMALL  WETH -> USDC (0.5)", WETH, USDC, 0.5 ether);
    }
    function test_fork_arb_whale_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB WHALE  WETH -> USDC (500)", WETH, USDC, 500 ether);
    }
    function test_fork_arb_sweep_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _sweep("ARB SWEEP USDC->WETH (size / legs / quoteGas / execGas / out)",
            USDC, WETH, [uint256(1_000e6), 25_000e6, 250_000e6, 1_000_000e6, 5_000_000e6]);
    }

    // ── WBTC ──
    function test_fork_arb_direct_WETH_WBTC() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB DIRECT  WETH -> WBTC", WETH, WBTC, 25 ether);
    }
    function test_fork_arb_exotic_WBTC_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB EXOTIC  WBTC -> USDC", WBTC, USDC, 5e8);
    }

    // ── stables ──
    function test_fork_arb_stable_USDC_USDT() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB STABLE  USDC -> USDT", USDC, USDT, 1_000_000e6);
    }
    function test_fork_arb_stable_USDC_DAI() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB STABLE  USDC -> DAI", USDC, DAI, 500_000e6);
    }
    function test_fork_arb_stable_DAI_USDT() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB STABLE  DAI -> USDT (bridge)", DAI, USDT, 500_000e18);
    }

    // ── more exotics ──
    function test_fork_arb_exotic_LINK_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB EXOTIC  LINK -> USDC", LINK, USDC, 50_000e18);
    }
    function test_fork_arb_exotic_UNI_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB EXOTIC  UNI -> WETH", UNI, WETH, 50_000e18);
    }
    function test_fork_arb_exotic_PENDLE_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB EXOTIC  PENDLE -> USDC", PENDLE, USDC, 100_000e18);
    }

    // ── more exotic -> exotic ──
    function test_fork_arb_exotic2_ARB_GMX() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB EXO->EXO  ARB -> GMX", ARB, GMX, 100_000e18);
    }
    function test_fork_arb_exotic2_LINK_ARB() public {
        if (!live) { vm.skip(true); return; }
        _report("ARB EXO->EXO  LINK -> ARB", LINK, ARB, 50_000e18);
    }

    function test_fork_arb_sweep_ARB_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("ARB SWEEP ARB->USDC (size / legs / quoteGas / execGas / out)",
            ARB, USDC, [uint256(10_000e18), 100_000e18, 500_000e18, 1_000_000e18, 5_000_000e18]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  BASE (chainid 8453) — Aerodrome (Solidly) + Uniswap V4.
// ─────────────────────────────────────────────────────────────────────────────
contract ForkBaseMetrics is ForkMetricsBase {
    address constant UNIV2_FACTORY   = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address constant UNIV3_FACTORY   = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant AERODROME       = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da; // Solidly
    address constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant PANCAKE_V3      = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant SUSHI_V3        = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
    address constant BASESWAP        = 0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB;
    address constant SUSHI_V2        = 0x71524B4f93c58fcbF659783284E38825f0622859;
    // Aerodrome Slipstream CLFactory — concentrated-liquidity Solidly. This is
    // where Base's DEEP stable liquidity (USDC/DAI, USDC/USDbC) lives; the
    // classic sAMM pools are shallower. Registered via V3-CL mode; a wrong
    // address is harmless (Hub hasCode guard discards code-less derivations).
    address constant AERODROME_CL    = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    address constant WETH  = 0x4200000000000000000000000000000000000006;
    address constant USDC  = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO  = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant DEGEN = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed;
    address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant DAI   = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address constant USDbC = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant BRETT = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
    address constant WELL  = 0xA88594D404727625A9437C3f886C7643872296AE;
    address constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;

    function setUp() public {
        live = _startFork("BASE_RPC_URL", "BASE_FORK_BLOCK");
        if (!live) return;
        _deployCore(V4_POOL_MANAGER);

        hub.addBridge(WETH);
        hub.addBridge(USDC);

        uint24[] memory v3Fees = new uint24[](4);
        v3Fees[0]=100; v3Fees[1]=500; v3Fees[2]=3000; v3Fees[3]=10000;
        int24[] memory v3Sp = new int24[](4);
        v3Sp[0]=1; v3Sp[1]=10; v3Sp[2]=60; v3Sp[3]=200;
        uint24[] memory noFees = new uint24[](0);
        int24[] memory noSp = new int24[](0);

        hub.addFactory(UNIV3_FACTORY, KIND_V3,      MODE_CREATE2_V3,  UNIV3_INIT, v3Fees, v3Sp);
        hub.addFactory(AERODROME,     KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), noFees, noSp);
        hub.addFactory(UNIV2_FACTORY, KIND_V2,      MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(PANCAKE_V3,    KIND_V3,      MODE_CALL_V3,      bytes32(0), v3Fees, v3Sp);
        hub.addFactory(SUSHI_V3,      KIND_V3,      MODE_CALL_V3,      bytes32(0), v3Fees, v3Sp);
        hub.addFactory(BASESWAP,      KIND_V2,      MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V2,      KIND_V2,      MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        // Aerodrome Slipstream (CL): the deep concentrated stable venue on Base.
        int24[] memory clSp = new int24[](5);
        clSp[0]=1; clSp[1]=50; clSp[2]=100; clSp[3]=200; clSp[4]=2000;
        hub.addFactory(AERODROME_CL,  KIND_V3,      MODE_CALL_V3CL,    bytes32(0), noFees, clSp);
        // V4 USDC/WETH 500/10 (probe-verified on fork).
        hub.addV4(USDC, WETH, 500, 10, address(0));
    }

    function test_fork_base_direct_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE DIRECT  WETH -> USDC", WETH, USDC, 10 ether);
    }

    function test_fork_base_discoverySkip_gas() public {
        if (!live) { vm.skip(true); return; }
        _reportDiscoverySkip("BASE DISCOVERY-SKIP  WETH->USDC quote gas", WETH, USDC, 10 ether);
    }

    function test_fork_base_direct_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE DIRECT  USDC -> WETH", USDC, WETH, 25_000e6);
    }

    function test_fork_base_sweep_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("BASE SWEEP WETH->USDC (size / legs / quoteGas / execGas / out)",
            WETH, USDC, [uint256(1 ether), 5 ether, 25 ether, 100 ether, 400 ether]);
    }

    function test_fork_base_exotic_AERO_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXOTIC  AERO -> USDC", AERO, USDC, 100_000e18);
    }

    function test_fork_base_exotic2_DEGEN_CBETH() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXO->EXO  DEGEN -> cbETH", DEGEN, CBETH, 1_000_000e18);
    }

    // ── size variety ──
    function test_fork_base_small_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE SMALL  WETH -> USDC (0.5)", WETH, USDC, 0.5 ether);
    }
    function test_fork_base_whale_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE WHALE  WETH -> USDC (500)", WETH, USDC, 500 ether);
    }
    function test_fork_base_sweep_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _sweep("BASE SWEEP USDC->WETH (size / legs / quoteGas / execGas / out)",
            USDC, WETH, [uint256(1_000e6), 25_000e6, 250_000e6, 1_000_000e6, 5_000_000e6]);
    }

    // ── cbETH / cbBTC ──
    function test_fork_base_direct_WETH_CBETH() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE DIRECT  WETH -> cbETH", WETH, CBETH, 50 ether);
    }
    function test_fork_base_exotic_CBBTC_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXOTIC  cbBTC -> USDC", CBBTC, USDC, 5e8);
    }

    // ── stables ──
    function test_fork_base_stable_USDC_DAI() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE STABLE  USDC -> DAI", USDC, DAI, 500_000e6);
    }
    function test_fork_base_stable_USDC_USDbC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE STABLE  USDC -> USDbC", USDC, USDbC, 250_000e6);
    }

    // ── more exotics ──
    function test_fork_base_exotic_BRETT_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXOTIC  BRETT -> USDC", BRETT, USDC, 1_000_000e18);
    }
    function test_fork_base_exotic_VIRTUAL_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXOTIC  VIRTUAL -> USDC", VIRTUAL, USDC, 500_000e18);
    }
    function test_fork_base_exotic_WELL_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXOTIC  WELL -> USDC", WELL, USDC, 1_000_000e18);
    }

    // ── more exotic -> exotic ──
    function test_fork_base_exotic2_AERO_DEGEN() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXO->EXO  AERO -> DEGEN", AERO, DEGEN, 100_000e18);
    }
    function test_fork_base_exotic2_BRETT_AERO() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXO->EXO  BRETT -> AERO", BRETT, AERO, 1_000_000e18);
    }

    function test_fork_base_sweep_AERO_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("BASE SWEEP AERO->USDC (size / legs / quoteGas / execGas / out)",
            AERO, USDC, [uint256(10_000e18), 100_000e18, 500_000e18, 1_000_000e18, 5_000_000e18]);
    }
    function test_fork_base_exotic2_VIRTUAL_AERO() public {
        if (!live) { vm.skip(true); return; }
        _report("BASE EXO->EXO  VIRTUAL -> AERO", VIRTUAL, AERO, 500_000e18);
    }
    function test_fork_base_sweep_DEGEN_WETH() public {
        if (!live) { vm.skip(true); return; }
        _sweep("BASE SWEEP DEGEN->WETH (size / legs / quoteGas / execGas / out)",
            DEGEN, WETH, [uint256(100_000e18), 1_000_000e18, 10_000_000e18,
                          50_000_000e18, 200_000_000e18]);
    }

    // ── RETAIL @ 0.5% minOut, bound to the EXACT quote (previewPlanExact) ──
    // The pairs that floor-rejected with minOut=0 (optimistic-quote V3/V4
    // routes) are re-run here with the honest exact-quote binding a real
    // front-end must use. Solidly pairs are included to show the pool-exact
    // pricing holding at a tight tolerance.
    function test_fork_base_retail_WETH_USDC_050() public {
        if (!live) { vm.skip(true); return; }
        _reportExactRetail("BASE RETAIL  WETH -> USDC 0.5%", WETH, USDC, 10 ether, 50);
    }
    function test_fork_base_retail_USDC_WETH_050() public {
        if (!live) { vm.skip(true); return; }
        _reportExactRetail("BASE RETAIL  USDC -> WETH 0.5%", USDC, WETH, 25_000e6, 50);
    }
    function test_fork_base_retail_USDC_USDbC_050() public {
        if (!live) { vm.skip(true); return; }
        _reportExactRetail("BASE RETAIL  USDC -> USDbC 0.5%", USDC, USDbC, 250_000e6, 50);
    }
    function test_fork_base_retail_USDC_DAI_050() public {
        if (!live) { vm.skip(true); return; }
        _reportExactRetail("BASE RETAIL  USDC -> DAI 0.5%", USDC, DAI, 500_000e6, 50);
    }
    function test_fork_base_retail_WETH_CBETH_050() public {
        if (!live) { vm.skip(true); return; }
        _reportExactRetail("BASE RETAIL  WETH -> cbETH 0.5% (Solidly)", WETH, CBETH, 50 ether, 50);
    }
    function test_fork_base_retail_AERO_USDC_050() public {
        if (!live) { vm.skip(true); return; }
        _reportExactRetail("BASE RETAIL  AERO -> USDC 0.5% (Solidly)", AERO, USDC, 100_000e18, 50);
    }
    function test_fork_base_retail_CBBTC_USDC_050() public {
        if (!live) { vm.skip(true); return; }
        _reportExactRetail("BASE RETAIL  cbBTC -> USDC 0.5%", CBBTC, USDC, 5e8, 50);
    }
    function test_fork_base_retail_small_WETH_USDC_050() public {
        if (!live) { vm.skip(true); return; }
        _reportExactRetail("BASE RETAIL  WETH -> USDC 0.5% (small 0.5 ETH)", WETH, USDC, 0.5 ether, 50);
    }

    // ── SANDWICH / price-manipulation: the floor must protect the victim ──
    // A whale front-runs the victim to move the book, then the victim submits
    // their stale route. The Router must revert or deliver >= minOut — never a
    // silent bad fill. slip = 0.5%, bound to the exact quote.
    function test_fork_base_sandwich_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sandwich("BASE SANDWICH  WETH -> USDC (victim 1, attacker 300)",
            WETH, USDC, 1 ether, 300 ether, 50);
    }
    function test_fork_base_sandwich_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _sandwich("BASE SANDWICH  USDC -> WETH (victim 2k, attacker 800k)",
            USDC, WETH, 2_000e6, 800_000e6, 50);
    }
    function test_fork_base_sandwich_AERO_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sandwich("BASE SANDWICH  AERO -> USDC (victim 10k, attacker 2M) [Solidly]",
            AERO, USDC, 10_000e18, 2_000_000e18, 50);
    }
    function test_fork_base_sandwich_cbBTC_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sandwich("BASE SANDWICH  cbBTC -> USDC (victim 0.5, attacker 50)",
            CBBTC, USDC, 5e7, 5e9, 50);
    }

    // ── RATE SWEEP diagnostic: is the bad stable rate depth (honest) or a bug? ──
    // 10000 == 1:1 parity. If small sizes quote ~10000 and only large sizes
    // degrade, DAI/USDbC are genuinely thin on Base (honest). If even 100 units
    // quote broken, there's a pricing/decimals bug to hunt.
    function test_fork_base_ratesweep_USDC_DAI() public {
        if (!live) { vm.skip(true); return; }
        _rateSweep("BASE RATE-SWEEP  USDC -> DAI (10000 = 1:1)",
            USDC, DAI, [uint256(100), 1_000, 10_000, 100_000, 500_000]);
    }
    function test_fork_base_ratesweep_USDC_USDbC() public {
        if (!live) { vm.skip(true); return; }
        _rateSweep("BASE RATE-SWEEP  USDC -> USDbC (10000 = 1:1)",
            USDC, USDbC, [uint256(100), 1_000, 10_000, 100_000, 250_000]);
    }
    // Control: a pair we KNOW is deep, to confirm the metric reads 1:1 clean.
    function test_fork_base_ratesweep_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _rateSweep("BASE RATE-SWEEP  WETH -> USDC (control, deep)",
            WETH, USDC, [uint256(1), 5, 25, 100, 400]);
    }

    // ── FULL MEASUREMENT: hops / legs / gas / impact(bps+USD) / slippage ──
    function test_fork_base_measure_WETH_USDC_mid() public {
        if (!live) { vm.skip(true); return; }
        _measureUsd("MEASURE  WETH -> USDC (10 ETH)", WETH, USDC, 10 ether, USDC);
    }
    function test_fork_base_measure_WETH_USDC_whale() public {
        if (!live) { vm.skip(true); return; }
        _measureUsd("MEASURE  WETH -> USDC (500 ETH)", WETH, USDC, 500 ether, USDC);
    }
    function test_fork_base_measure_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _measureUsd("MEASURE  USDC -> WETH (250k)", USDC, WETH, 250_000e6, USDC);
    }
    function test_fork_base_measure_AERO_USDC() public {
        if (!live) { vm.skip(true); return; }
        _measureUsd("MEASURE  AERO -> USDC (100k)", AERO, USDC, 100_000e18, USDC);
    }
    function test_fork_base_measure_cbBTC_USDC() public {
        if (!live) { vm.skip(true); return; }
        _measureUsd("MEASURE  cbBTC -> USDC (5)", CBBTC, USDC, 5e8, USDC);
    }
    function test_fork_base_measure_AERO_DEGEN() public {
        if (!live) { vm.skip(true); return; }
        _measureUsd("MEASURE  AERO -> DEGEN (100k)", AERO, DEGEN, 100_000e18, USDC);
    }
    function test_fork_base_measure_DEGEN_CBETH() public {
        if (!live) { vm.skip(true); return; }
        _measureUsd("MEASURE  DEGEN -> cbETH (1M)", DEGEN, CBETH, 1_000_000e18, USDC);
    }
    function test_fork_base_measure_USDC_DAI_whale() public {
        if (!live) { vm.skip(true); return; }
        _measureUsd("MEASURE  USDC -> DAI (500k)", USDC, DAI, 500_000e6, USDC);
    }

    // ── BATCH / PORTFOLIO STRESS: buy N tokens with USDC back-to-back ──
    // One fork, one loop, N real swaps. After every swap the Router must hold
    // nothing (hard require in _basket) — the offline holds-nothing invariant,
    // now under a long run of real heterogeneous Base liquidity. The output is a
    // per-token profile (symbol / hops / legs / impact bps / gas / USD) plus a
    // portfolio aggregate. Each token's on-chain symbol() is printed and NO-ROUTE
    // / code-less entries are flagged, so the basket self-audits on the fork.
    //
    // The list is ordered by confidence: the first ~20 are the high-liquidity
    // Base majors; the tail are lower-confidence exotics kept for breadth. Any
    // wrong/stale address simply shows NO ROUTE (harmless) — read the symbol
    // column to confirm each entry resolved to the token it claims to be.
    address constant USDT_B   = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address constant WSTETH   = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant RETH     = 0xB6fe221Fe9EeF5aBa221c348bA20A1Bf5e73624c;
    address constant WEETH    = 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A;
    address constant EURC     = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
    address constant TOSHI    = 0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4;
    address constant TBTC     = 0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b;
    address constant MOG      = 0x2Da56AcB9Ea78330f947bD57C54119Debda7AF71;
    address constant HIGHER   = 0x0578d8A44db98B23BF096A382e016e29a5Ce0ffe;
    address constant PRIME    = 0xfA980cEd6895AC314E7dE34Ef1bFAE90a5AdD21b;
    address constant USDS_B   = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address constant MORPHO_B = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
    address constant SPX      = 0x50dA645f148798F68EF2d7dB7C1CB22A6819bb2C;
    address constant TYBG     = 0x0d97F261b1e88845184f678e2d1e7a98D9FD38dE;
    address constant KEYCAT   = 0x9a26F5433671751C3276a065f57e5a02D2817973;
    address constant SEAM     = 0x1C7a460413dD4e964f96D8dFC56E7223cE88CD85;
    address constant DOGINME  = 0x6921B130D297cc43754afba22e5EAc0FBf8Db75b;
    address constant ZORA     = 0x1111111111166b7FE7bd91427724B487980aFc69;
    address constant AIXBT    = 0x4F9Fd6Be4a90f2620860d680c0d4d5Fb53d1A825;
    address constant CLANKER  = 0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb;
    address constant BENJI    = 0xBC45647eA894030a4E9801Ec03479739FA2485F0;

    /// @dev Full 40-entry ordered basket; the 20/30/40 tests slice the head.
    function _baseBasket() internal pure returns (address[] memory a) {
        a = new address[](40);
        // 0..19 — high-confidence Base majors.
        a[0]=WETH;   a[1]=USDbC;  a[2]=DAI;     a[3]=USDT_B;  a[4]=AERO;
        a[5]=DEGEN;  a[6]=CBETH;  a[7]=CBBTC;   a[8]=BRETT;   a[9]=WELL;
        a[10]=VIRTUAL; a[11]=WSTETH; a[12]=RETH; a[13]=WEETH; a[14]=EURC;
        a[15]=TOSHI; a[16]=TBTC;  a[17]=MOG;    a[18]=HIGHER; a[19]=PRIME;
        // 20..29 — mid-confidence.
        a[20]=USDS_B; a[21]=MORPHO_B; a[22]=SPX; a[23]=TYBG;  a[24]=KEYCAT;
        a[25]=SEAM;  a[26]=DOGINME; a[27]=ZORA;  a[28]=AIXBT; a[29]=CLANKER;
        // 30..39 — breadth tail (repeat proven exotics + one lower-confidence).
        a[30]=BENJI; a[31]=WELL;  a[32]=VIRTUAL; a[33]=AERO;  a[34]=DEGEN;
        a[35]=BRETT; a[36]=TOSHI; a[37]=HIGHER; a[38]=MOG;    a[39]=CBBTC;
    }

    function _basketSlice(uint256 n) internal pure returns (address[] memory s) {
        address[] memory a = _baseBasket();
        s = new address[](n);
        for (uint256 i; i < n; ++i) s[i] = a[i];
    }

    // ── GAS DISSECTION: which leg burns the anomalous 7.5M gas on USDS? ──
    // basket30 showed USDC->USDS (1 hop, 3 legs) at 7.5M execGas — 8x the
    // ~900k basket average — while impact was 1 bps. Hypothesis: a stable V3
    // pool whose liquidity is spread across a dense tick ladder (spacing 1),
    // so $10k crosses hundreds of initialized ticks: each tick is cheap, the
    // ladder is not. Three probes:
    //   1k vs 10k  — tick-crossing gas scales with size; flat gas would point
    //                at the token/pool itself instead.
    //   WETH 10k   — control pair at normal gas, same harness.
    function test_fork_base_dissect_USDS_10k() public {
        if (!live) { vm.skip(true); return; }
        _dissect("DISSECT  USDC -> USDS (10k)", USDC, USDS_B, 10_000e6);
    }
    function test_fork_base_dissect_USDS_1k() public {
        if (!live) { vm.skip(true); return; }
        _dissect("DISSECT  USDC -> USDS (1k)", USDC, USDS_B, 1_000e6);
    }
    function test_fork_base_dissect_WETH_control() public {
        if (!live) { vm.skip(true); return; }
        _dissect("DISSECT  USDC -> WETH (10k, control)", USDC, WETH, 10_000e6);
    }

    function test_fork_base_basket20() public {
        if (!live) { vm.skip(true); return; }
        _basket("BASE BASKET 20 tokens (USDC -> token, $10k each)",
            _basketSlice(20), USDC, 10_000e6);
    }
    function test_fork_base_basket30() public {
        if (!live) { vm.skip(true); return; }
        _basket("BASE BASKET 30 tokens (USDC -> token, $10k each)",
            _basketSlice(30), USDC, 10_000e6);
    }
    function test_fork_base_basket40() public {
        if (!live) { vm.skip(true); return; }
        _basket("BASE BASKET 40 tokens (USDC -> token, $10k each)",
            _basketSlice(40), USDC, 10_000e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  OPTIMISM (chainid 10) — Velodrome (Solidly) + Velodrome CL; no V4, no UniV2.
// ─────────────────────────────────────────────────────────────────────────────
contract ForkOptimismMetrics is ForkMetricsBase {
    address constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant VELODROME     = 0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a; // Solidly
    address constant SUSHI_V2      = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
    address constant SUSHI_V3      = 0x9c6522117e2ed1fE5bdb72bb0eD5E3f2bdE7DBe0;
    address constant PANCAKE_V3    = 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9;
    address constant VELODROME_CL  = 0xCc0bDDB707055e04e497aB22a59c2aF4391cd12F; // CL/Slipstream

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // native USDC
    address constant OP   = 0x4200000000000000000000000000000000000042;
    address constant VELO = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
    address constant WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;
    address constant USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant DAI  = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant WLD  = 0xdC6fF44d5d932Cbd77B52E5612Ba0529DC6226F1;
    address constant SNX  = 0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4;
    address constant LINK = 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;

    function setUp() public {
        live = _startFork("OP_RPC_URL", "OP_FORK_BLOCK");
        if (!live) return;
        _deployCore(address(0)); // no V4 on Optimism

        hub.addBridge(WETH);
        hub.addBridge(USDC);

        uint24[] memory v3Fees = new uint24[](4);
        v3Fees[0]=100; v3Fees[1]=500; v3Fees[2]=3000; v3Fees[3]=10000;
        int24[] memory v3Sp = new int24[](4);
        v3Sp[0]=1; v3Sp[1]=10; v3Sp[2]=60; v3Sp[3]=200;
        uint24[] memory noFees = new uint24[](0);
        int24[] memory noSp = new int24[](0);

        hub.addFactory(UNIV3_FACTORY, KIND_V3,      MODE_CREATE2_V3,  UNIV3_INIT, v3Fees, v3Sp);
        hub.addFactory(VELODROME,     KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V2,      KIND_V2,      MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V3,      KIND_V3,      MODE_CALL_V3,      bytes32(0), v3Fees, v3Sp);
        uint24[] memory pFees = new uint24[](4);
        pFees[0]=100; pFees[1]=500; pFees[2]=2500; pFees[3]=10000;
        hub.addFactory(PANCAKE_V3,    KIND_V3,      MODE_CALL_V3,      bytes32(0), pFees, v3Sp);
        // Velodrome CL/Slipstream: V3-CL mode with its own tick-spacing set.
        int24[] memory clSp = new int24[](5);
        clSp[0]=1; clSp[1]=50; clSp[2]=100; clSp[3]=200; clSp[4]=2000;
        hub.addFactory(VELODROME_CL,  KIND_V3,      MODE_CALL_V3CL,    bytes32(0), noFees, clSp);
    }

    function test_fork_op_direct_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("OP DIRECT  WETH -> USDC", WETH, USDC, 10 ether);
    }

    function test_fork_op_discoverySkip_gas() public {
        if (!live) { vm.skip(true); return; }
        _reportDiscoverySkip("OP DISCOVERY-SKIP  WETH->USDC quote gas", WETH, USDC, 10 ether);
    }

    function test_fork_op_direct_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("OP DIRECT  USDC -> WETH", USDC, WETH, 25_000e6);
    }

    function test_fork_op_sweep_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("OP SWEEP WETH->USDC (size / legs / quoteGas / execGas / out)",
            WETH, USDC, [uint256(1 ether), 5 ether, 25 ether, 100 ether, 400 ether]);
    }

    function test_fork_op_exotic_OP_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("OP EXOTIC  OP -> USDC", OP, USDC, 100_000e18);
    }

    function test_fork_op_exotic2_VELO_OP() public {
        if (!live) { vm.skip(true); return; }
        _report("OP EXO->EXO  VELO -> OP", VELO, OP, 100_000e18);
    }

    // ── size variety ──
    function test_fork_op_small_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("OP SMALL  WETH -> USDC (0.5)", WETH, USDC, 0.5 ether);
    }
    function test_fork_op_whale_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("OP WHALE  WETH -> USDC (500)", WETH, USDC, 500 ether);
    }
    function test_fork_op_sweep_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _sweep("OP SWEEP USDC->WETH (size / legs / quoteGas / execGas / out)",
            USDC, WETH, [uint256(1_000e6), 25_000e6, 250_000e6, 1_000_000e6, 5_000_000e6]);
    }

    // ── WBTC ──
    function test_fork_op_direct_WETH_WBTC() public {
        if (!live) { vm.skip(true); return; }
        _report("OP DIRECT  WETH -> WBTC", WETH, WBTC, 25 ether);
    }
    function test_fork_op_exotic_WBTC_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("OP EXOTIC  WBTC -> USDC", WBTC, USDC, 5e8);
    }

    // ── stables ──
    function test_fork_op_stable_USDC_USDT() public {
        if (!live) { vm.skip(true); return; }
        _report("OP STABLE  USDC -> USDT", USDC, USDT, 1_000_000e6);
    }
    function test_fork_op_stable_USDC_DAI() public {
        if (!live) { vm.skip(true); return; }
        _report("OP STABLE  USDC -> DAI", USDC, DAI, 500_000e6);
    }
    function test_fork_op_stable_DAI_USDT() public {
        if (!live) { vm.skip(true); return; }
        _report("OP STABLE  DAI -> USDT (bridge)", DAI, USDT, 500_000e18);
    }

    // ── more exotics ──
    function test_fork_op_exotic_SNX_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("OP EXOTIC  SNX -> USDC", SNX, USDC, 100_000e18);
    }
    function test_fork_op_exotic_WLD_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("OP EXOTIC  WLD -> USDC", WLD, USDC, 100_000e18);
    }
    function test_fork_op_exotic_LINK_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("OP EXOTIC  LINK -> WETH", LINK, WETH, 50_000e18);
    }

    // ── more exotic -> exotic ──
    function test_fork_op_exotic2_OP_VELO() public {
        if (!live) { vm.skip(true); return; }
        _report("OP EXO->EXO  OP -> VELO", OP, VELO, 100_000e18);
    }
    function test_fork_op_exotic2_SNX_OP() public {
        if (!live) { vm.skip(true); return; }
        _report("OP EXO->EXO  SNX -> OP", SNX, OP, 50_000e18);
    }

    function test_fork_op_sweep_OP_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("OP SWEEP OP->USDC (size / legs / quoteGas / execGas / out)",
            OP, USDC, [uint256(10_000e18), 100_000e18, 500_000e18, 1_000_000e18, 5_000_000e18]);
    }
}
