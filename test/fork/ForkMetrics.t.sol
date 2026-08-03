// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  FORK METRICS — ETHEREUM MAINNET (chainid 1).
//
//  Run:
//    export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<KEY>"
//    forge test --match-path test/fork/ForkMetrics.t.sol -vv
//
//  (optional) pin a block for determinism:
//    export ETH_FORK_BLOCK=20000000
//
//  Wires the exact venue set of script/DeployEthereum.s.sol (UniV2/V3, Sushi
//  V2/V3, Pancake V2/V3; Curve stays disabled in v1.0), deals real tokens and
//  runs direct / exotic / stable swaps plus size sweeps, printing hops, legs,
//  quote gas, exec gas, realised output and realised/quote ratio. If ETH_RPC_URL
//  is unset the tests skip (so the offline suite stays green).
// =============================================================================

import { ForkMetricsBase } from "./ForkMetricsBase.sol";

contract ForkMetricsTest is ForkMetricsBase {
    // ── mainnet venues (same set as script/DeployEthereum.s.sol) ──
    address constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant V4_MANAGER    = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant SUSHI_V2      = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
    address constant PANCAKE_V2    = 0x1097053Fd2ea711dad45caCcc45EfF7548fCB362;
    address constant PANCAKE_V3    = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant SUSHI_V3      = 0xbACEB8eC6b9355Dfc0269C18bac9d6E2Bdc29C4F;

    // ── tokens ──
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PEPE = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant SHIB = 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE;
    address constant UNI  = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant MKR  = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
    address constant LDO  = 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
    address constant CRV  = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    function setUp() public {
        live = _startFork("ETH_RPC_URL", "ETH_FORK_BLOCK");
        if (!live) return;                              // offline → tests skip

        _deployCore(V4_MANAGER);

        hub.addBridge(WETH);
        hub.addBridge(USDC);

        uint24[] memory v3Fees = new uint24[](4);
        v3Fees[0]=100; v3Fees[1]=500; v3Fees[2]=3000; v3Fees[3]=10000;
        int24[] memory v3Sp = new int24[](4);
        v3Sp[0]=1; v3Sp[1]=10; v3Sp[2]=60; v3Sp[3]=200;
        uint24[] memory noFees = new uint24[](0);
        int24[] memory noSp = new int24[](0);

        hub.addFactory(UNIV3_FACTORY, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, v3Fees, v3Sp);
        hub.addFactory(UNIV2_FACTORY, KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V2,      KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(PANCAKE_V2,    KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V3,      KIND_V3, MODE_CALL_V3,      bytes32(0), v3Fees, v3Sp);
        uint24[] memory pFees = new uint24[](4);
        pFees[0]=100; pFees[1]=500; pFees[2]=2500; pFees[3]=10000;
        hub.addFactory(PANCAKE_V3,    KIND_V3, MODE_CALL_V3,      bytes32(0), pFees, v3Sp);
    }

    function test_fork_direct_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("DIRECT  WETH -> USDC", WETH, USDC, 10 ether);
    }

    function test_fork_direct_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("DIRECT  USDC -> WETH", USDC, WETH, 25_000e6);
    }

    function test_fork_exotic_PEPE_LINK() public {
        if (!live) { vm.skip(true); return; }
        _report("EXOTIC  PEPE -> LINK  (via bridge)", PEPE, LINK, 1_000_000_000e18);
    }

    function test_fork_exotic_PEPE_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("EXOTIC  PEPE -> USDC  (via WETH bridge)", PEPE, USDC, 500_000_000e18);
    }

    // ── exotic -> exotic section ── both ends non-bridge; forces a 2-hop route
    // through a WETH/USDC bridge and exercises the multi-hop leg accounting.
    function test_fork_exotic2_PEPE_SHIB() public {
        if (!live) { vm.skip(true); return; }
        _report("EXO->EXO  PEPE -> SHIB", PEPE, SHIB, 1_000_000_000e18);
    }

    function test_fork_exotic2_SHIB_LINK() public {
        if (!live) { vm.skip(true); return; }
        _report("EXO->EXO  SHIB -> LINK", SHIB, LINK, 50_000_000e18);
    }

    function test_fork_exotic2_UNI_PEPE() public {
        if (!live) { vm.skip(true); return; }
        _report("EXO->EXO  UNI -> PEPE", UNI, PEPE, 50_000e18);
    }

    function test_fork_exotic2_LINK_UNI() public {
        if (!live) { vm.skip(true); return; }
        _report("EXO->EXO  LINK -> UNI", LINK, UNI, 50_000e18);
    }

    // ── stablecoin section ──
    // Stable<->stable pairs route through the wired V2/V3 venues (Curve-style
    // KIND_STABLE/KIND_CURVE stay disabled in v1.0 — see Hub.addFactory). These
    // exercise the tight-spread, low-slippage regime the solver should pick the
    // deepest single venue for.
    function test_fork_stable_USDC_USDT() public {
        if (!live) { vm.skip(true); return; }
        _report("STABLE  USDC -> USDT", USDC, USDT, 1_000_000e6);
    }

    function test_fork_stable_DAI_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("STABLE  DAI -> USDC", DAI, USDC, 1_000_000e18);
    }

    function test_fork_stable_USDT_DAI() public {
        if (!live) { vm.skip(true); return; }
        _report("STABLE  USDT -> DAI  (via bridge)", USDT, DAI, 500_000e6);
    }

    // ── WBTC section ──
    // WBTC has 8 decimals and routes WETH<->WBTC directly plus WBTC->USDC via the
    // WETH bridge; covers a non-18-decimal, non-stable bridge path.
    function test_fork_direct_WETH_WBTC() public {
        if (!live) { vm.skip(true); return; }
        _report("DIRECT  WETH -> WBTC", WETH, WBTC, 50 ether);
    }

    function test_fork_exotic_WBTC_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("EXOTIC  WBTC -> USDC  (via WETH bridge)", WBTC, USDC, 5e8);
    }

    // ── LINK section ── direct deep pair.
    function test_fork_direct_LINK_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("DIRECT  LINK -> WETH", LINK, WETH, 50_000e18);
    }

    function test_fork_sweep_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("SWEEP WETH->USDC (size / legs / quoteGas / execGas / out)",
            WETH, USDC, [uint256(1 ether), 5 ether, 25 ether, 100 ether, 400 ether]);
    }

    function test_fork_sweep_USDC_USDT() public {
        if (!live) { vm.skip(true); return; }
        _sweep("SWEEP USDC->USDT (size / legs / quoteGas / execGas / out)",
            USDC, USDT, [uint256(10_000e6), 100_000e6, 1_000_000e6, 5_000_000e6, 25_000_000e6]);
    }

    // ── size variety on the deepest pair ──
    function test_fork_small_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("SMALL   WETH -> USDC (0.5)", WETH, USDC, 0.5 ether);
    }

    function test_fork_whale_WETH_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("WHALE   WETH -> USDC (1000)", WETH, USDC, 1000 ether);
    }

    function test_fork_whale_USDC_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("WHALE   USDC -> WETH (2M)", USDC, WETH, 2_000_000e6);
    }

    // ── more bluechip exotics ──
    function test_fork_exotic_AAVE_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("EXOTIC  AAVE -> USDC", AAVE, USDC, 2_000e18);
    }

    function test_fork_exotic_MKR_WETH() public {
        if (!live) { vm.skip(true); return; }
        _report("EXOTIC  MKR -> WETH", MKR, WETH, 200e18);
    }

    function test_fork_exotic_CRV_USDC() public {
        if (!live) { vm.skip(true); return; }
        _report("EXOTIC  CRV -> USDC", CRV, USDC, 1_000_000e18);
    }

    // ── more exotic -> exotic ──
    function test_fork_exotic2_LDO_CRV() public {
        if (!live) { vm.skip(true); return; }
        _report("EXO->EXO  LDO -> CRV", LDO, CRV, 500_000e18);
    }

    function test_fork_exotic2_AAVE_LINK() public {
        if (!live) { vm.skip(true); return; }
        _report("EXO->EXO  AAVE -> LINK", AAVE, LINK, 2_000e18);
    }

    function test_fork_exotic2_CRV_UNI() public {
        if (!live) { vm.skip(true); return; }
        _report("EXO->EXO  CRV -> UNI", CRV, UNI, 500_000e18);
    }

    // ── more sweeps (5 sizes each) ──
    function test_fork_sweep_WETH_WBTC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("SWEEP WETH->WBTC (size / legs / quoteGas / execGas / out)",
            WETH, WBTC, [uint256(1 ether), 5 ether, 25 ether, 100 ether, 400 ether]);
    }

    function test_fork_sweep_PEPE_USDC() public {
        if (!live) { vm.skip(true); return; }
        _sweep("SWEEP PEPE->USDC (size / legs / quoteGas / execGas / out)",
            PEPE, USDC, [uint256(10_000_000e18), 100_000_000e18, 1_000_000_000e18,
                         5_000_000_000e18, 20_000_000_000e18]);
    }

    // ── freshness-gated discovery skip: quote gas with an EMPTY registry (full
    //    discovery) vs after a swap registered the venues (discovery skipped).
    //    Same pair / same venues, so the delta is the discovery work saved.
    //    (qFresh also gains some EIP-2929 warmth from the swap, so the delta is an
    //    upper bound; the bulk is the skipped discovery sweep.)
    function test_fork_discoverySkip_gas() public {
        if (!live) { vm.skip(true); return; }
        _reportDiscoverySkip("DISCOVERY-SKIP  WETH->USDC quote gas", WETH, USDC, 10 ether);
    }
}
