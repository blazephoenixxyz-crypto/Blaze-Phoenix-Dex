// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// G7 gas campaign: BSC deploy helper. Compiled ONLY in a tree of branch bsc-infinity-1106;
// deploy_state.sh copies it there.
// Wiring: test/fork/bsc/BscForkBase.sol _deployStack (Hub initialised with the Uniswap V4
// PoolManager, Gate, Solver, Router, Quoter, setRoles, setWeth WBNB, bridges WBNB/USDT/USDC) +
// the rows test/fork/bsc/BscCoveredVenues.t.sol admits (PancakeV3 mode 1, UniV3 mode 1,
// PancakeV2 mode 0, addV4(native, USDT, 500, 10)). The Infinity adapters of
// BscInfinityCLFork/BscInfinityBinFork are mounted only per test there and are not mounted here.
//   G7_PK=<key> forge script tools/g7-gas-campaign/G7DeployBsc.s.sol --tc G7DeployBsc ...
import {Script, console2} from "forge-std/Script.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixGate} from "../../src/BlazePhoenixGate.sol";
import {G7Probe} from "./G7Probe.sol";

contract G7DeployBsc is Script {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant UNI_V3_FACTORY     = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
    address constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant UNI_V4_PM          = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);

    function run() external {
        uint256 pk = vm.envUint("G7_PK");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        BlazePhoenixHub hub = new BlazePhoenixHub(me);
        hub.initialize(me, UNI_V4_PM);
        BlazePhoenixGate gate = new BlazePhoenixGate(me);
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(gate));
        BlazePhoenixRouter router = new BlazePhoenixRouter(address(hub), address(solver), me, T1, T2);
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        router.setWeth(WBNB);
        hub.addBridge(WBNB); hub.addBridge(USDT); hub.addBridge(USDC);
        hub.addFactory(PANCAKE_V3_FACTORY, 1, 1, bytes32(0), _f(100, 500, 2500, 10000), _s(1, 10, 50, 200));
        hub.addFactory(UNI_V3_FACTORY, 1, 1, bytes32(0), _f(100, 500, 3000, 10000), _s(1, 10, 60, 200));
        hub.addFactory(PANCAKE_V2_FACTORY, 0, 0, bytes32(0), new uint24[](0), new int24[](0));
        hub.addV4(address(0), USDT, 500, 10, address(0));
        G7Probe probe = new G7Probe();
        vm.stopBroadcast();
        console2.log("G7ADDR hub", address(hub));
        console2.log("G7ADDR solver", address(solver));
        console2.log("G7ADDR router", address(router));
        console2.log("G7ADDR quoter", address(quoter));
        console2.log("G7ADDR gate", address(gate));
        console2.log("G7ADDR probe", address(probe));
        console2.log("G7ADDR admin", me);
    }

    function _f(uint24 a, uint24 b, uint24 c, uint24 d) internal pure returns (uint24[] memory f) {
        f = new uint24[](4); (f[0], f[1], f[2], f[3]) = (a, b, c, d);
    }
    function _s(int24 a, int24 b, int24 c, int24 d) internal pure returns (int24[] memory s) {
        s = new int24[](4); (s[0], s[1], s[2], s[3]) = (a, b, c, d);
    }
}
