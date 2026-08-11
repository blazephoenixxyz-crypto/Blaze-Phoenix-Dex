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
}
