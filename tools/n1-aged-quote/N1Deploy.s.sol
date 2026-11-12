// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// N1 aged-quote measurement: deploy helper.
//
// V2 is not deployed on any chain (README "Status"; test/fork/DeployedParity.t.sol), so the
// measurement runs V2 by eth_call state override. This script deploys V2 on a local anvil fork
// with the SAME test-only wiring as the chain fixtures of test/fork/TokenSweep.t.sol (Base,
// Arbitrum, Optimism: bridges, factories, V4 wiring; placeholder treasuries). The runner then
// reads the resulting code and storage with anvil_dumpState and replays them as overrides at
// real historical blocks. Nothing here touches a live chain.
//
//   anvil --fork-url <rpc> ...
//   N1_CHAIN=base N1_PK=<throwaway key> forge script tools/n1-aged-quote/N1Deploy.s.sol \
//       --rpc-url http://127.0.0.1:8545 --broadcast
import {Script, console2} from "forge-std/Script.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

interface IWETHP { function deposit() external payable; }
interface IERC20P {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice The payer/recipient of a measured execution. Placed by code override at an address
///         that holds the input (ETH wrapped here, or an ERC-20 balance override). Delivery is
///         measured as this account's balanceOf delta of tokenOut: the oracle is the token, not
///         the Router's return value (AGENTS.md rule 4).
contract N1Probe {
    function run(address router, address tIn, address tOut, uint256 amountIn, bool wrap, bytes calldata data)
        external
        returns (bool ok, bytes memory ret, uint256 delivered, uint256 gasUsed, uint256 routerReturn)
    {
        if (wrap) IWETHP(tIn).deposit{value: amountIn}();
        // Low-level approve: some dollar tokens return nothing.
        (bool a,) = tIn.call(abi.encodeWithSelector(IERC20P.approve.selector, router, amountIn));
        require(a, "N1Probe: approve");
        uint256 b0 = IERC20P(tOut).balanceOf(address(this));
        uint256 g = gasleft();
        (ok, ret) = router.call(data);
        gasUsed = g - gasleft();
        uint256 b1 = IERC20P(tOut).balanceOf(address(this));
        delivered = b1 > b0 ? b1 - b0 : 0;
        if (ok && ret.length >= 32) routerReturn = abi.decode(ret, (uint256));
    }
}

contract N1Deploy is Script {
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

    function run() external {
        string memory chain = vm.envString("N1_CHAIN");
        uint256 pk = vm.envUint("N1_PK");
        address me = vm.addr(pk);
        bytes32 c = keccak256(bytes(chain));
        vm.startBroadcast(pk);
        if (c == keccak256("base")) _base(me);
        else if (c == keccak256("arbitrum")) _arbitrum(me);
        else if (c == keccak256("optimism")) _optimism(me);
        else revert("N1Deploy: unknown chain");
        N1Probe probe = new N1Probe();
        vm.stopBroadcast();
        console2.log("N1ADDR hub", address(hub));
        console2.log("N1ADDR solver", address(solver));
        console2.log("N1ADDR router", address(router));
        console2.log("N1ADDR quoter", address(quoter));
        console2.log("N1ADDR probe", address(probe));
    }

    // Same order and arguments as TokenSweepBase._core / _v4Wire (test/fork/TokenSweep.t.sol).
    function _core(address me, address v4mgr) internal {
        hub = new BlazePhoenixHub(me);
        hub.initialize(me, v4mgr);
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), me, T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
    }

    function _v4Wire(address mgr, address weth_, address dollar_) internal {
        router.setWeth(weth_);
        hub.addV4(address(0), dollar_, 500, 10, address(0));
        hub.addFactory(mgr, KIND_V4, MODE_V4_DERIVE, bytes32(0), new uint24[](0), new int24[](0));
    }

    // TokenSweep.t.sol BaseChainFixture.setUp
    function _base(address me) internal {
        address USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address WETH = 0x4200000000000000000000000000000000000006;
        _core(me, 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452);
        hub.addFactory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A, KIND_V3, MODE_CALL_V3CL, bytes32(0), _n24(), _clSp());
        hub.addFactory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, KIND_V3, MODE_CALL_V3, bytes32(0), _pckFees(), _pckSp());
        hub.addFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0x71524B4f93c58fcbF659783284E38825f0622859, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        _v4Wire(0x498581fF718922c3f8e6A244956aF099B2652b2b, WETH, USDC);
    }

    // TokenSweep.t.sol ArbitrumFixture.setUp
    function _arbitrum(address me) internal {
        address USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        address WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        _core(me, 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(0x5979D7b546E38E414F7E9822514be443A4800529);
        uint24[] memory af = new uint24[](1); af[0] = 0;
        int24[] memory asp = new int24[](1); asp[0] = 1;
        hub.addFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0x1a3c9B1d2F0529D97f2afC5136Cc23e58f1FD35B, KIND_ALGEBRA, MODE_CALL_V3, bytes32(0), af, asp);
        hub.addFactory(0x6EcCab422D763aC031210895C81787E87B43A652, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x1af415a1EbA07a4986a52B6f2e7dE7003D82231e, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, KIND_V3, MODE_CALL_V3, bytes32(0), _pckFees(), _pckSp());
        _v4Wire(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32, WETH, USDC);
    }

    // TokenSweep.t.sol OptimismFixture.setUp
    function _optimism(address me) internal {
        address USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
        address WETH = 0x4200000000000000000000000000000000000006;
        _core(me, 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb);
        hub.addFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
        hub.addFactory(0xCc0bDDB707055e04e497aB22a59c2aF4391cd12F, KIND_V3, MODE_CALL_V3CL, bytes32(0), _n24(), _clSp());
        hub.addFactory(0x25CbdDb98b35ab1FF77413456B31EC81A6B6B746, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x0c3c1c532F1e39EdF36BE9Fe0bE1410313E074Bf, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x9c6522117e2ed1fE5bdb72bb0eD5E3f2bdE7DBe0, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0xFbc12984689e5f15626Bad03Ad60160Fe98B303C, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        _v4Wire(0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3, WETH, USDC);
    }

    function _v3Fees() internal pure returns (uint24[] memory f) { f = new uint24[](4); f[0]=100; f[1]=500; f[2]=3000; f[3]=10000; }
    function _pckFees() internal pure returns (uint24[] memory f) { f = new uint24[](4); f[0]=100; f[1]=500; f[2]=2500; f[3]=10000; }
    function _v3Sp() internal pure returns (int24[] memory s) { s = new int24[](4); s[0]=1; s[1]=10; s[2]=60; s[3]=200; }
    function _pckSp() internal pure returns (int24[] memory s) { s = new int24[](4); s[0]=1; s[1]=10; s[2]=50; s[3]=200; }
    function _clSp() internal pure returns (int24[] memory s) { s = new int24[](5); s[0]=1; s[1]=50; s[2]=100; s[3]=200; s[4]=2000; }
    function _n24() internal pure returns (uint24[] memory f) { f = new uint24[](0); }
    function _nSp() internal pure returns (int24[] memory s) { s = new int24[](0); }
}
