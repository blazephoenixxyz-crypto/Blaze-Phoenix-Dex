// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// G7 gas campaign: deploy helper for the chains the main branch wires (base, optimism,
// arbitrum, robinhood). Avalanche and BSC are wired only on their branches and have their own
// scripts (G7DeployAvax.s.sol, G7DeployBsc.s.sol), compiled in those trees.
//
// V2 is not deployed on any chain. This script deploys V2 on a local anvil fork with the repo's
// TEST wiring; deploy_state.sh dumps the code and storage and the runner replays them by
// stateOverride at real blocks. The broadcaster is the admin (and so an operator: Hub:445), so
// the runner can call Hub.seedPool with `from` = admin. Nothing here touches a live chain.
//
// Wiring sources (test-only, placeholder treasuries):
//   base      test/fork/TokenSweep.t.sol BaseChainFixture.setUp (3 bridges, 8 factories, _v4Wire)
//             + the Gate of test/fork/BaseTestDeploy.sol:82 + BASE_PCK2 of BaseTestDeploy.sol
//   optimism  test/fork/MultichainProbe.t.sol _core + OptimismProbeTest.setUp + _v4Wire
//   arbitrum  test/fork/MultichainProbe.t.sol _core + ArbitrumProbeTest.setUp + _v4Wire
//   robinhood test/fork/MultichainProbe.t.sol _core + RobinhoodProbeTest.setUp + _v4Wire
//
// _v4Wire on every chain with a PoolManager: without its MODE_V4_DERIVE row the Hub never runs the
// V4 derive scan, so cold discovery (mode D) sees no V4 pool at all, while the seeded modes still
// reach it through the memory. Pinned by test/fork/G7RobinhoodV4Wire.t.sol (G7 robinhood
// midtail-1: USDG->USDe lives on a V4 pool only). Each PoolManager below was checked on chain
// (2026-11-14): 24009-byte runtime, and slot0 of the native-ETH/USDC|USDG 500/10 pool non-zero.
//
//   G7_CHAIN=<chain> G7_PK=<throwaway key> forge script tools/g7-gas-campaign/G7Deploy.s.sol \
//       --tc G7Deploy --rpc-url http://127.0.0.1:<port> --broadcast
import {Script, console2} from "forge-std/Script.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixGate} from "../../src/BlazePhoenixGate.sol";
import {G7Probe} from "./G7Probe.sol";

contract G7Deploy is Script {
    uint8 internal constant KIND_V2 = 0;
    uint8 internal constant KIND_V3 = 1;
    uint8 internal constant KIND_V4 = 4;
    uint8 internal constant KIND_SOLIDLY = 5;
    uint8 internal constant KIND_ALGEBRA = 6;
    uint8 internal constant MODE_CALL_GENERIC = 0;
    uint8 internal constant MODE_CALL_V3 = 1;
    uint8 internal constant MODE_CALL_SOLIDLY = 2;
    uint8 internal constant MODE_CALL_V3CL = 3;
    uint8 internal constant MODE_CREATE2_V3 = 5;
    uint8 internal constant MODE_V4_DERIVE = 9;
    bytes32 internal constant UNIV3_INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant T1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant T2 = address(0x7e52222222222222222222222222222222222222);

    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router; BlazePhoenixQuoter quoter;
    address gate;

    function run() external {
        string memory chain = vm.envString("G7_CHAIN");
        uint256 pk = vm.envUint("G7_PK");
        address me = vm.addr(pk);
        bytes32 c = keccak256(bytes(chain));
        vm.startBroadcast(pk);
        if (c == keccak256("base")) _base(me);
        else if (c == keccak256("optimism")) _optimism(me);
        else if (c == keccak256("arbitrum")) _arbitrum(me);
        else if (c == keccak256("robinhood")) _robinhood(me);
        else if (c == keccak256("ethereum")) _ethereum(me);
        else revert("G7Deploy: unknown chain");
        G7Probe probe = new G7Probe();
        vm.stopBroadcast();
        console2.log("G7ADDR hub", address(hub));
        console2.log("G7ADDR solver", address(solver));
        console2.log("G7ADDR router", address(router));
        console2.log("G7ADDR quoter", address(quoter));
        console2.log("G7ADDR gate", gate);
        console2.log("G7ADDR probe", address(probe));
        console2.log("G7ADDR admin", me);
    }

    // MultichainProbe.t.sol ChainProbeBase._core / TokenSweep.t.sol TokenSweepBase._core, with the
    // broadcaster as admin. `withGate` mounts BaseTestDeploy's Gate (admin = broadcaster).
    function _core(address me, address v4mgr, bool withGate) internal {
        hub = new BlazePhoenixHub(me);
        hub.initialize(me, v4mgr);
        if (withGate) gate = address(new BlazePhoenixGate(me));
        solver = new BlazePhoenixSolver(address(hub), gate);
        router = new BlazePhoenixRouter(address(hub), address(solver), me, T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
    }

    // TokenSweep.t.sol _v4Wire
    function _v4Wire(address mgr, address weth_, address dollar_) internal {
        router.setWeth(weth_);
        hub.addV4(address(0), dollar_, 500, 10, address(0));
        hub.addFactory(mgr, KIND_V4, MODE_V4_DERIVE, bytes32(0), _n24(), _nSp());
    }

    function _base(address me) internal {
        address USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address WETH = 0x4200000000000000000000000000000000000006;
        _core(me, 0x498581fF718922c3f8e6A244956aF099B2652b2b, true);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452);
        hub.addFactory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A, KIND_V3, MODE_CALL_V3CL, bytes32(0), _n24(), _clSp());
        hub.addFactory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, KIND_V3, MODE_CALL_V3, bytes32(0), _pckFees(), _pckSp());
        hub.addFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0x71524B4f93c58fcbF659783284E38825f0622859, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        // BaseTestDeploy.sol BASE_PCK2 (absent from TokenSweep's list)
        hub.addFactory(0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        _v4Wire(0x498581fF718922c3f8e6A244956aF099B2652b2b, WETH, USDC);
    }

    function _optimism(address me) internal {
        address WETH = 0x4200000000000000000000000000000000000006;
        address USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
        address PM = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
        _core(me, PM, true); // G7: Gate mounted for the gates stratum
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb);
        hub.addFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x0c3c1c532F1e39EdF36BE9Fe0bE1410313E074Bf, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x9c6522117e2ed1fE5bdb72bb0eD5E3f2bdE7DBe0, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addV4(USDC, WETH, 500, 10, address(0));
        _v4Wire(PM, WETH, USDC);
    }

    function _arbitrum(address me) internal {
        address WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        address USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        address PM = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        _core(me, PM, true); // G7: Gate mounted for the gates stratum
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(0x5979D7b546E38E414F7E9822514be443A4800529);
        hub.addFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x1af415a1EbA07a4986a52B6f2e7dE7003D82231e, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0x6EcCab422D763aC031210895C81787E87B43A652, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addV4(USDC, WETH, 500, 10, address(0));
        _v4Wire(PM, WETH, USDC);
    }

    function _robinhood(address me) internal {
        address PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
        address WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
        address USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        _core(me, PM, true); // G7: Gate mounted for the gates stratum
        hub.addBridge(WETH);
        hub.addBridge(USDG);
        hub.addBridge(0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31); // VIRTUAL (pool token, 18 decimals; owner decision 13/11)
        hub.addFactory(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        _v4Wire(PM, WETH, USDG);
    }

    // Ethereum: not wired on main (G7.md "Cobertura"). Core + Gate here; WETH from
    // test/fork/RpcProbe.t.sol:18, the V4 PoolManager read on chain from the V1 Hub
    // (v4PoolManager(), g7/S2.md). Bridges and factories are added by deploy_state.sh from
    // prereg/wiring.tsv (the V1 registry's Factory_ events, S2 inventory).
    function _ethereum(address me) internal {
        _core(me, 0x000000000004444c5dc75cB358380D2e3dE08A90, true);
        router.setWeth(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        // bridges (site_tokens.json ethereum: WETH, USDC, USDT), so G8 has bridge cases on ethereum
        hub.addBridge(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH
        hub.addBridge(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
        hub.addBridge(0xdAC17F958D2ee523a2206206994597C13D831ec7); // USDT
    }

    function _v3Fees() internal pure returns (uint24[] memory f) { f = new uint24[](4); f[0]=100; f[1]=500; f[2]=3000; f[3]=10000; }
    function _pckFees() internal pure returns (uint24[] memory f) { f = new uint24[](4); f[0]=100; f[1]=500; f[2]=2500; f[3]=10000; }
    function _v3Sp() internal pure returns (int24[] memory s) { s = new int24[](4); s[0]=1; s[1]=10; s[2]=60; s[3]=200; }
    function _pckSp() internal pure returns (int24[] memory s) { s = new int24[](4); s[0]=1; s[1]=10; s[2]=50; s[3]=200; }
    function _clSp() internal pure returns (int24[] memory s) { s = new int24[](5); s[0]=1; s[1]=50; s[2]=100; s[3]=200; s[4]=2000; }
    function _n24() internal pure returns (uint24[] memory f) { f = new uint24[](0); }
    function _nSp() internal pure returns (int24[] memory s) { s = new int24[](0); }
}
