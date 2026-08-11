// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Multichain fork probes — Optimism (10), Arbitrum One (42161) and Robinhood
//  Chain (4663). Address book verified 2026-08-11 against official deployment
//  docs + chain explorers (two independent sources each unless noted in-line).
//  Each chain probe:
//    (1) pins the chain's verified anchor pool via factory.getPool — a live
//        cross-check of the factory address AND the anchor's existence;
//    (2) previews a real dollar→WETH route through Hub discovery + Solver;
//    (3) executes it through the Router against live liquidity —
//  the same shape as BaseFork.t.sol.
//
//  Venue-mode doctrine (measure, don't model): CREATE2 derivation is used ONLY
//  where the deployment is the canonical Uniswap one (OP and Arbitrum share
//  mainnet's factory address and init-code hash). Every other factory —
//  including Robinhood's fresh, non-canonical V3 deploy, whose init hash we
//  have NOT verified — is wired MODE_CALL_*: ask the factory.
//  Ramses (Arbitrum + Robinhood) is deliberately absent: its pair-level
//  getAmountOut signature is unverified from source; probe before wiring.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

interface IERC20Probe {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IUniV3FactoryProbe {
    function getPool(address, address, uint24) external view returns (address);
}

abstract contract ChainProbeBase is Test {
    uint8 internal constant KIND_V2 = 0;
    uint8 internal constant KIND_V3 = 1;
    uint8 internal constant KIND_SOLIDLY = 5;
    uint8 internal constant MODE_CALL_GENERIC = 0;
    uint8 internal constant MODE_CALL_V3 = 1;
    uint8 internal constant MODE_CALL_SOLIDLY = 2;
    uint8 internal constant MODE_CREATE2_V3 = 5;
    bytes32 internal constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    /// @dev Placeholder test-only fee recipients — never the real treasuries.
    address internal constant TEST_TREASURY_1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant TEST_TREASURY_2 = address(0x7e52222222222222222222222222222222222222);

    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    BlazePhoenixQuoter internal quoter;

    function _core(address v4Manager) internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), v4Manager);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), TEST_TREASURY_1, TEST_TREASURY_2
        );
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
    }

    /// @dev The anchor assert: the verified factory must resolve the verified
    ///      anchor pool for the chain's deepest pair — one live measurement
    ///      that cross-checks both addresses at once.
    function _assertAnchor(address factory, address a, address b, uint24 fee, address expected)
        internal view
    {
        address got = IUniV3FactoryProbe(factory).getPool(a, b, fee);
        assertEq(got, expected, "anchor pool mismatch: factory or address book is wrong");
        assertGt(expected.code.length, 0, "anchor pool has no code");
    }

    function _preview(address tokenIn, address tokenOut, uint256 amountIn)
        internal returns (BlazePhoenixQuoter.Preview memory pv)
    {
        (pv, , ) = quoter.previewPlan(tokenIn, tokenOut, amountIn);
        console2.log("grossOut:", pv.grossOut);
        console2.log("legs/hops:", pv.legs, pv.hops);
        assertGt(pv.grossOut, 0, "must find a live route");
        // Loose unit-sanity band for 1,000 dollars -> WETH (same discipline as
        // BaseFork): guards decimal/unit mixing, is not a price oracle.
        assertGt(pv.grossOut, 0.0001 ether);
        assertLt(pv.grossOut, 10 ether);
        assertTrue(pv.canExecute);
    }

    function _execute(address dollar, address weth, uint256 amountIn) internal {
        address user = address(0xBEEF);
        deal(dollar, user, amountIn);
        // Measure deltas, never absolute balances (0xBEEF may carry fork dust).
        uint256 wethBefore = IERC20Probe(weth).balanceOf(user);

        vm.prank(user);
        IERC20Probe(dollar).approve(address(router), amountIn);

        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(dollar, weth, amountIn);
        assertGt(pv.grossOut, 0, "precondition: a route must exist to execute");

        vm.prank(user);
        uint256 delivered = router.swapExactIn(pv.route, amountIn, 1, user, block.timestamp + 60);

        console2.log("delivered (wei WETH):", delivered);
        assertEq(IERC20Probe(weth).balanceOf(user) - wethBefore, delivered);
        assertGt(delivered, 0);
        // Router-holds-nothing invariant, verified against live venues.
        assertEq(IERC20Probe(dollar).balanceOf(address(router)), 0);
        assertEq(IERC20Probe(weth).balanceOf(address(router)), 0);
    }

    /// @dev Direct library-level V4 quote against the LIVE PoolManager —
    ///      measures whether a V4 pool actually prices through our path
    ///      (guarded extsload → effV4Fee → outV3), independent of whether a
    ///      route happened to pick a V4 leg.
    function _v4LiveQuote(
        address v4Manager, address tokenIn, address tokenOther,
        uint24 fee, int24 tickSpacing, uint256 amountIn
    ) internal view returns (uint256 out, uint256 depth) {
        QuoteCtx memory c;
        c.kind        = BPC.KIND_V4;
        c.zeroForOne  = tokenIn < tokenOther;
        c.fee         = fee;
        c.tickSpacing = tickSpacing;
        c.tokenIn     = tokenIn;
        c.tokenOther  = tokenOther;
        c.hooks       = address(0);
        c.v4Manager   = v4Manager;
        (out, depth) = BPC.universalQuote(c, amountIn);
    }

    /// @dev The V4 live invariant that can never be flaky: an initialized pool
    ///      (depth > 0) MUST quote; an absent one MUST return exactly 0.
    function _assertV4Measured(uint256 out, uint256 depth) internal pure {
        if (depth > 0) {
            require(out > 0, "live V4 pool must quote non-zero");
        } else {
            require(out == 0, "absent V4 pool must fail closed");
        }
    }

    /// @dev Chain-agnostic discovery sweep: quote `dollarIn` -> each token,
    ///      tally routes found / venue-kind legs / avg gas, exactly like the
    ///      Base top-100 sweep but parameterized so V4 (KIND 4) coverage is
    ///      measured on EVERY chain, not just Base. Seeded with the verified
    ///      token set per chain; the array is the only thing that grows.
    function _sweep(string memory chain, address dollarIn, address[] memory tokens, uint256 amountIn)
        internal
    {
        uint256 routeFound;
        uint256 noRoute;
        uint256 totalGas;
        uint256 minGas = type(uint256).max;
        uint256 maxGas;
        uint256 maxImpactBps;
        uint256 totalImpactBps;
        uint256[8] memory venueLegs; // 0=V2 1=V3 2=STABLE 3=BAL 4=V4 5=SOLIDLY 6=ALGEBRA 7=CRVCRYPTO
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == dollarIn || tokens[i] == address(0)) continue;
            uint256 g0 = gasleft();
            try quoter.previewPlan(dollarIn, tokens[i], amountIn)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory route, bool)
            {
                uint256 gasUsed = g0 - gasleft();
                totalGas += gasUsed;
                if (pv.grossOut > 0) {
                    routeFound++;
                    if (gasUsed < minGas) minGas = gasUsed;
                    if (gasUsed > maxGas) maxGas = gasUsed;
                    uint256 nLegs;
                    for (uint256 h; h < route.hops.length; ++h) {
                        Leg[] memory legs = route.hops[h].legs;
                        nLegs += legs.length;
                        for (uint256 l; l < legs.length; ++l) {
                            uint8 k = legs[l].kind;
                            if (k < 8) venueLegs[k]++;
                        }
                    }
                    uint256 imp = route.expectedImpactBps;
                    totalImpactBps += imp;
                    if (imp > maxImpactBps) maxImpactBps = imp;
                    // per-token detail: token · grossOut · gas · hops · legs · impact bps
                    console2.log("[FOUND]", tokens[i], pv.grossOut, gasUsed);
                    console2.log("   hops/legs/impactBps:", route.hops.length, nLegs, imp);
                } else {
                    noRoute++;
                    console2.log("[ZERO ]", tokens[i]);
                }
            } catch {
                noRoute++;
                console2.log("[REVERT]", tokens[i]);
            }
        }
        console2.log("==== SWEEP", chain, "====");
        console2.log("routeFound / noRoute:", routeFound, noRoute);
        if (routeFound > 0) {
            console2.log("gas min/avg/max:", minGas, totalGas / routeFound, maxGas);
            console2.log("impactBps avg/max:", totalImpactBps / routeFound, maxImpactBps);
        }
        console2.log("legs V2/V3/STABLE:", venueLegs[0], venueLegs[1], venueLegs[2]);
        console2.log("legs V4/SOLIDLY/ALGEBRA:", venueLegs[4], venueLegs[5], venueLegs[6]);
        // Coverage floor: a meaningful fraction of the verified deep tokens on
        // each chain must route (loose — liquidity fluctuates on the fork tip).
        assertGt(routeFound, tokens.length / 3, "sweep: too few routes discovered");
    }

    function _v3Fees() internal pure returns (uint24[] memory f) {
        f = new uint24[](4); f[0]=100; f[1]=500; f[2]=3000; f[3]=10000;
    }
    function _v3Sp() internal pure returns (int24[] memory s) {
        s = new int24[](4); s[0]=1; s[1]=10; s[2]=60; s[3]=200;
    }
    function _none24() internal pure returns (uint24[] memory f) { f = new uint24[](0); }
    function _noneSp() internal pure returns (int24[] memory s) { s = new int24[](0); }
}

// =============================================================================
//  OPTIMISM (id 10)
// =============================================================================
contract OptimismProbeTest is ChainProbeBase {
    // Canonical Uniswap deployments (same addresses as mainnet) — VERIFIED.
    address constant OP_UNIV3  = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant OP_UNIV2  = 0x0c3c1c532F1e39EdF36BE9Fe0bE1410313E074Bf;
    address constant OP_V4_MGR = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
    // Velodrome V2 PoolFactory (Solidly family; Aerodrome's parent) — VERIFIED.
    address constant OP_VELO   = 0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;
    address constant OP_SUSHI3 = 0x9c6522117e2ed1fE5bdb72bb0eD5E3f2bdE7DBe0;

    address constant OP_WETH   = 0x4200000000000000000000000000000000000006; // predeploy
    address constant OP_USDC   = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // native Circle
    address constant OP_WSTETH = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    // Uni V3 USDC/WETH 0.30% — ~$4.4M reserve; the legacy USDC.e 5bps pool has
    // decayed and is no longer a valid deep-liquidity anchor.
    address constant OP_REF_POOL = 0xc1738D90E2E26C35784A0d3E3d8A9f795074bcA4;

    function setUp() public {
        vm.createSelectFork("optimism");
        _core(OP_V4_MGR);
        hub.addBridge(OP_WETH);
        hub.addBridge(OP_USDC);
        hub.addBridge(OP_WSTETH);
        hub.addFactory(OP_UNIV3,  KIND_V3,      MODE_CREATE2_V3,   UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(OP_VELO,   KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _none24(), _noneSp());
        hub.addFactory(OP_UNIV2,  KIND_V2,      MODE_CALL_GENERIC, bytes32(0), _none24(), _noneSp());
        hub.addFactory(OP_SUSHI3, KIND_V3,      MODE_CALL_V3,      bytes32(0), _v3Fees(), _v3Sp());
        // Canonical-guess V4 key: if the pool is absent it quotes 0 and simply
        // never routes (fail-closed) — registration costs nothing.
        hub.addV4(OP_USDC, OP_WETH, 500, 10, address(0));
    }

    function test_Anchor_USDCWETH() public view {
        _assertAnchor(OP_UNIV3, OP_WETH, OP_USDC, 3000, OP_REF_POOL);
    }

    function test_Preview_USDCtoWETH() public {
        _preview(OP_USDC, OP_WETH, 1_000e6);
    }

    function test_Execute_USDCtoWETH() public {
        _execute(OP_USDC, OP_WETH, 1_000e6);
    }

    /// @notice Measured, not guessed: does the canonical-key V4 USDC/WETH pool
    ///         exist and quote on Optimism? Logs the answer either way; the
    ///         assert is the exists→quotes / absent→zero invariant only.
    function test_V4CanonicalKey_Measured() public view {
        (uint256 out, uint256 depth) = _v4LiveQuote(OP_V4_MGR, OP_USDC, OP_WETH, 500, 10, 1_000e6);
        console2.log("OP V4 USDC/WETH 5bps: out/depth", out, depth);
        _assertV4Measured(out, depth);
    }

    /// @notice General routing sweep — USDC -> each verified deep OP token.
    function test_Sweep_USDCtoVerifiedTokens() public {
        address[] memory t = new address[](10);
        t[0]=OP_WETH; t[1]=OP_WSTETH;
        t[2]=0x94b008aA00579c1307B0EF2c499aD98a8ce58e58; // USDT (bridged)
        t[3]=0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1; // DAI
        t[4]=0x68f180fcCe6836688e9084f035309E29Bf0A2095; // WBTC
        t[5]=0x4200000000000000000000000000000000000042; // OP
        t[6]=0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db; // VELO
        t[7]=0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4; // SNX
        t[8]=0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6; // LINK
        t[9]=0x7F5c764cBc14f9669B88837ca1490cCa17c31607; // USDC.e
        _sweep("OPTIMISM", OP_USDC, t, 1_000e6);
    }
}

// =============================================================================
//  ARBITRUM ONE (id 42161)
// =============================================================================
contract ArbitrumProbeTest is ChainProbeBase {
    // Canonical Uniswap V3 (same as mainnet) — VERIFIED. V2 factory on
    // Arbitrum is chain-specific (NOT mainnet's 0x5C69...) — VERIFIED.
    address constant ARB_UNIV3    = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant ARB_UNIV2    = 0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9;
    address constant ARB_V4_MGR   = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant ARB_SUSHI3   = 0x1af415a1EbA07a4986a52B6f2e7dE7003D82231e;
    // PancakeSwap V3 (same multichain address as Base's BASE_PCK3): pools
    // derive from a separate POOL_DEPLOYER with a non-Uniswap init hash, so
    // MODE_CALL_V3 only — never CREATE2 here.
    address constant ARB_PCK3     = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    // Camelot V2 is UniV2-style (their V3 is Algebra — different interface,
    // deliberately not wired this round).
    address constant ARB_CAMELOT2 = 0x6EcCab422D763aC031210895C81787E87B43A652;

    address constant ARB_WETH   = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ARB_USDC   = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native Circle
    address constant ARB_WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    // Uni V3 WETH/USDC(native) 0.05% — deepest V3 pool on Arbitrum (~$35M+).
    address constant ARB_REF_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    function setUp() public {
        vm.createSelectFork("arbitrum");
        _core(ARB_V4_MGR);
        hub.addBridge(ARB_WETH);
        hub.addBridge(ARB_USDC);
        hub.addBridge(ARB_WSTETH);
        hub.addFactory(ARB_UNIV3,    KIND_V3, MODE_CREATE2_V3,   UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(ARB_UNIV2,    KIND_V2, MODE_CALL_GENERIC, bytes32(0), _none24(), _noneSp());
        hub.addFactory(ARB_SUSHI3,   KIND_V3, MODE_CALL_V3,      bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(ARB_PCK3,     KIND_V3, MODE_CALL_V3,      bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(ARB_CAMELOT2, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _none24(), _noneSp());
        hub.addV4(ARB_USDC, ARB_WETH, 500, 10, address(0));
    }

    function test_Anchor_WETHUSDC() public view {
        _assertAnchor(ARB_UNIV3, ARB_WETH, ARB_USDC, 500, ARB_REF_POOL);
    }

    function test_Preview_USDCtoWETH() public {
        _preview(ARB_USDC, ARB_WETH, 1_000e6);
    }

    function test_Execute_USDCtoWETH() public {
        _execute(ARB_USDC, ARB_WETH, 1_000e6);
    }

    function test_V4CanonicalKey_Measured() public view {
        (uint256 out, uint256 depth) = _v4LiveQuote(ARB_V4_MGR, ARB_USDC, ARB_WETH, 500, 10, 1_000e6);
        console2.log("ARB V4 USDC/WETH 5bps: out/depth", out, depth);
        _assertV4Measured(out, depth);
    }

    /// @notice General routing sweep — USDC -> each verified deep Arbitrum token.
    function test_Sweep_USDCtoVerifiedTokens() public {
        address[] memory t = new address[](10);
        t[0]=ARB_WETH; t[1]=ARB_WSTETH;
        t[2]=0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // USDT0
        t[3]=0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1; // DAI
        t[4]=0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f; // WBTC
        t[5]=0x912CE59144191C1204E64559FE8253a0e49E6548; // ARB
        t[6]=0xf97f4df75117a78c1A5a0DBb814Af92458539FB4; // LINK
        t[7]=0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a; // GMX
        t[8]=0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8; // PENDLE
        t[9]=0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978; // CRV
        _sweep("ARBITRUM", ARB_USDC, t, 1_000e6);
    }
}

// =============================================================================
//  ROBINHOOD CHAIN (id 4663) — mainnet live 2026-07-01, Arbitrum stack.
//  No USDC on this chain: the dollar is Paxos USDG (6 decimals). WETH is a
//  plain ERC20 at a chain-specific address (no OP-style predeploys).
// =============================================================================
contract RobinhoodProbeTest is ChainProbeBase {
    // Fresh (non-canonical) official Uniswap deploys — VERIFIED on docs +
    // Blockscout. V3 init hash UNVERIFIED for this deploy → MODE_CALL_V3 only.
    address constant RH_UNIV3  = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant RH_UNIV2  = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant RH_V4_MGR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    address constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    // Uni V3 USDG/WETH 0.01% — the chain's anchor pool (~$8.6M reserve,
    // ~$106M/day volume at verification time).
    address constant RH_REF_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;

    function setUp() public {
        vm.createSelectFork("robinhood");
        _core(RH_V4_MGR);
        hub.addBridge(RH_WETH);
        hub.addBridge(RH_USDG);
        hub.addFactory(RH_UNIV3, KIND_V3, MODE_CALL_V3,      bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(RH_UNIV2, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _none24(), _noneSp());
        // V4 PoolManager registered for discovery; the live WETH/USDG v4 pool's
        // key params (fee/tickSpacing/hooks) are not yet verified, so no addV4
        // entry this round — V3/V2 carry the probe.
    }

    function test_Anchor_USDGWETH() public view {
        _assertAnchor(RH_UNIV3, RH_WETH, RH_USDG, 100, RH_REF_POOL);
    }

    function test_Preview_USDGtoWETH() public {
        _preview(RH_USDG, RH_WETH, 1_000e6);
    }

    function test_Execute_USDGtoWETH() public {
        _execute(RH_USDG, RH_WETH, 1_000e6);
    }

    /// @notice The live WETH/USDG v4 pool's key params are unpublished; its
    ///         poolId (GeckoTerminal, single-source) is. Try the standard
    ///         hookless fee/tickSpacing pairs + the dynamic-fee sentinel: if
    ///         one reproduces the poolId, the key is FOUND — quote it and
    ///         assert. If none match, the pool is hooked/nonstandard: log and
    ///         pass (no guess asserted).
    function test_V4_FindWETHUSDGKey_AndQuote() public view {
        bytes32 target = 0x30dac7167c36242d1bacfd30561d444cf014529ee55978991d03e4ee178e725a;
        (address s0, address s1) = BPC.sortTokens(RH_WETH, RH_USDG);
        uint24[5] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000), uint24(0x800000)];
        int24[5] memory tss = [int24(1), int24(10), int24(60), int24(200), int24(60)];
        for (uint256 i = 0; i < 5; i++) {
            if (BPC.computeV4PoolId(s0, s1, fees[i], tss[i], address(0)) != target) continue;
            console2.log("RH V4 key found: fee/tickSpacing", uint256(fees[i]), uint256(uint24(tss[i])));
            (uint256 out, uint256 depth) =
                _v4LiveQuote(RH_V4_MGR, RH_USDG, RH_WETH, fees[i], tss[i], 1_000e6);
            console2.log("RH V4 USDG->WETH: out/depth", out, depth);
            _assertV4Measured(out, depth);
            assertGt(depth, 0, "matched key must be initialized on-chain");
            return;
        }
        console2.log("RH V4 WETH/USDG key not matched (hooked or nonstandard) - nothing asserted");
    }

    /// @notice General routing sweep — USDG (the chain dollar) -> verified
    ///         Robinhood tokens. Thinner set: young chain, fewer deep pairs;
    ///         floor scales with tokens.length/3 so it stays honest.
    function test_Sweep_USDGtoVerifiedTokens() public {
        address[] memory t = new address[](4);
        t[0]=RH_WETH;
        t[1]=0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34; // USDe
        t[2]=0x020bfC650A365f8BB26819deAAbF3E21291018b4; // CASHCAT
        t[3]=0xe934e36A439C94017B64a3FecE66AF12099aBF50; // STONKBROKER
        _sweep("ROBINHOOD", RH_USDG, t, 1_000e6);
    }
}

// =============================================================================
//  BASE — direct live-V4 measurement (the canonical USDC/WETH 5bps v4 pool).
//  The Base fork suite registers this key but never asserted a V4 quote; this
//  pins it: the pool is live and MUST price through our exact path.
// =============================================================================
contract BaseV4ProbeTest is ChainProbeBase {
    address constant BASE_V4_MGR = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant BASE_WETH   = 0x4200000000000000000000000000000000000006;
    address constant BASE_USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function setUp() public {
        vm.createSelectFork("base");
    }

    function test_V4CanonicalPool_QuotesLive() public view {
        (uint256 out, uint256 depth) = _v4LiveQuote(BASE_V4_MGR, BASE_USDC, BASE_WETH, 500, 10, 1_000e6);
        console2.log("BASE V4 USDC/WETH 5bps: out/depth", out, depth);
        assertGt(depth, 0, "canonical Base V4 USDC/WETH must be initialized");
        assertGt(out, 0, "canonical Base V4 USDC/WETH must quote");
        assertGt(out, 0.0001 ether);
        assertLt(out, 10 ether);
    }
}
