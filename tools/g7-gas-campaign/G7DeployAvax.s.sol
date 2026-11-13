// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// G7 gas campaign: Avalanche deploy helper. Compiled ONLY in a tree of branch avax-adapters-1106
// (the adapters do not exist on main); deploy_state.sh copies it there.
//
// Wiring: test/fork/avax/AvaxForkBase.sol _deployStack (Hub, Gate, Solver, Router, Quoter,
// setRoles, setWeth WAVAX, bridges WAVAX/USDC/BTC.b) + test/fork/avax/AvaxS9Battery.t.sol
// _afterDeploy (UniV3 row, Pharaoh V3 mode 3, Blackhole Algebra row, Gate with the LFJ v2.1,
// LFJ v2.2, Pharaoh DLMM and Algebra Integral adapters, its wrappers and its Hub row).
// The Gate's ADAPTER_DELAY (48 h) cannot be warped in a broadcast, so the deploy has two
// phases; deploy_state.sh advances the anvil clock between them (evm_increaseTime).
//   G7_PHASE=A G7_PK=<key>                         -> stack, rows, proposeAdapter x4
//   G7_PHASE=B G7_PK=<key> G7_HUB=<hub> G7_GATE=<gate> -> acceptAdapter x4, wrappers, Gate row
import {Script, console2} from "forge-std/Script.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixGate} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixAdapterLB} from "../../src/adapters/BlazePhoenixAdapterLB.sol";
import {BlazePhoenixAdapterAlgebraIntegral} from "../../src/adapters/BlazePhoenixAdapterAlgebraIntegral.sol";
import {G7Probe} from "./G7Probe.sol";

contract G7DeployAvax is Script {
    address constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address constant USDC  = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant BTCB  = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
    address constant COQ = 0x420FcA0121DC28039145009570975747295f2329;
    address constant SAVAX = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address constant JOE = 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd;
    address constant ARENA = 0xB8d7710f7d8349A506b75dD184F05777c82dAd0C;
    address constant QI = 0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5;
    address constant BLACK = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;
    address constant UNIV3_FACTORY = 0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD;
    bytes32 constant UNIV3_INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address constant PHARAOH_V3_FACTORY = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d;
    address constant BH_FACTORY = 0x512eb749541B7cf294be882D636218c84a5e9E5F;
    bytes32 constant BH_INIT = 0xeaa3eea3233916c82fe1281a51bd9cde844b7c4673c0714ca0028a57f5634752;
    address constant BH_DEPLOYER = 0x9B2441037E286d5Bf9456a3BE7b5273fe28DbA1e;
    address constant BH_CUSTOM_5D43 = 0x5D433A94A4a2aA8f9AA34D8D15692Dc2E9960584;
    address constant BH_CUSTOM_DCFC = 0xDcFccf2e8c4EfBba9127B80eAc76c5A122125d29;
    address constant LB21_FACTORY = 0x8e42f2F4101563bF679975178e880FD87d3eFd4e;
    address constant LB22_FACTORY = 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c;
    address constant DLMM_FACTORY = 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D;
    uint8 constant KIND_V3 = 1;
    uint8 constant MODE_CALL_V3CL = 3;
    uint8 constant MODE_CREATE2_V3 = 5;
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);

    function run() external {
        uint256 pk = vm.envUint("G7_PK");
        address me = vm.addr(pk);
        bytes32 ph = keccak256(bytes(vm.envString("G7_PHASE")));
        vm.startBroadcast(pk);
        if (ph == keccak256("A")) _phaseA(me);
        else if (ph == keccak256("B")) _phaseB(BlazePhoenixHub(vm.envAddress("G7_HUB")), BlazePhoenixGate(vm.envAddress("G7_GATE")));
        else revert("G7DeployAvax: phase");
        vm.stopBroadcast();
    }

    function _phaseA(address me) internal {
        BlazePhoenixHub hub = new BlazePhoenixHub(me);
        hub.initialize(me, address(0));
        BlazePhoenixGate gate = new BlazePhoenixGate(me);
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(gate));
        BlazePhoenixRouter router = new BlazePhoenixRouter(address(hub), address(solver), me, T1, T2);
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        router.setWeth(WAVAX);
        hub.addBridge(WAVAX); hub.addBridge(USDC); hub.addBridge(BTCB);
        // AvaxForkBase._addUniV3Row
        uint24[] memory f = new uint24[](4);
        (f[0], f[1], f[2], f[3]) = (100, 500, 3000, 10000);
        int24[] memory s = new int24[](4);
        (s[0], s[1], s[2], s[3]) = (1, 10, 60, 200);
        hub.addFactory(UNIV3_FACTORY, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, f, s);
        // AvaxForkBase._addPharaohV3Row(MODE_CALL_V3CL)
        int24[] memory ps = new int24[](6);
        (ps[0], ps[1], ps[2], ps[3], ps[4], ps[5]) = (1, 5, 10, 50, 100, 200);
        hub.addFactory(PHARAOH_V3_FACTORY, KIND_V3, MODE_CALL_V3CL, bytes32(0), new uint24[](0), ps);
        // AvaxS9Battery: Blackhole base Algebra row
        hub.addFactory(BH_FACTORY, BPC.KIND_ALGEBRA, MODE_CREATE2_V3, BH_INIT, new uint24[](1), new int24[](0));
        // AvaxS9Battery._mountGate, first half
        address[3] memory fac = [LB21_FACTORY, LB22_FACTORY, DLMM_FACTORY];
        for (uint8 i = 1; i <= 3; ++i) gate.proposeAdapter(i, address(new BlazePhoenixAdapterLB(address(gate), fac[i - 1])));
        gate.proposeAdapter(4, address(new BlazePhoenixAdapterAlgebraIntegral(address(gate), BH_FACTORY, BH_DEPLOYER, BH_INIT)));
        G7Probe probe = new G7Probe();
        console2.log("G7ADDR hub", address(hub));
        console2.log("G7ADDR solver", address(solver));
        console2.log("G7ADDR router", address(router));
        console2.log("G7ADDR quoter", address(quoter));
        console2.log("G7ADDR gate", address(gate));
        console2.log("G7ADDR probe", address(probe));
        console2.log("G7ADDR admin", me);
    }

    // AvaxS9Battery._mountGate, second half. A venue in G7_SKIP (comma list of indices) is left
    // out, as the battery's try/catch leaves out a venue the adapter refuses (a reverted call
    // cannot be broadcast).
    function _phaseB(BlazePhoenixHub hub, BlazePhoenixGate gate) internal {
        for (uint8 i = 1; i <= 4; ++i) gate.acceptAdapter(i);
        string memory skip = vm.envOr("G7_SKIP", string(""));
        _lb(gate, skip, 0, 1, 1, BTCB, USDC, 10);
        _lb(gate, skip, 1, 3, 1, BTCB, USDC, 5);
        _lb(gate, skip, 2, 3, 2, BTCB, USDC, 25);
        _lb(gate, skip, 3, 1, 1, BTCB, WAVAX, 10);
        _lb(gate, skip, 4, 2, 1, BTCB, WAVAX, 5);
        _lb(gate, skip, 5, 1, 1, COQ, USDC, 100);
        _lb(gate, skip, 6, 2, 1, COQ, WAVAX, 50);
        _lb(gate, skip, 7, 1, 1, COQ, WAVAX, 100);
        _lb(gate, skip, 8, 1, 1, JOE, WAVAX, 15);
        _lb(gate, skip, 9, 2, 1, JOE, WAVAX, 25);
        _lb(gate, skip, 10, 2, 1, QI, WAVAX, 25);
        _lb(gate, skip, 11, 1, 1, QI, WAVAX, 25);
        _lb(gate, skip, 12, 2, 1, WAVAX, ARENA, 100);
        _lb(gate, skip, 13, 2, 1, WAVAX, BLACK, 10);
        _lb(gate, skip, 14, 3, 1, WAVAX, USDC, 5);
        _lb(gate, skip, 15, 2, 1, WAVAX, USDC, 10);
        _lb(gate, skip, 16, 1, 1, WAVAX, USDC, 20);
        _lb(gate, skip, 17, 2, 1, SAVAX, WAVAX, 5);
        _lb(gate, skip, 18, 1, 1, SAVAX, WAVAX, 5);
        _bh(gate, skip, 19, WAVAX, USDC, BH_CUSTOM_5D43);
        _bh(gate, skip, 20, BTCB, WAVAX, BH_CUSTOM_5D43);
        _bh(gate, skip, 21, BTCB, USDC, BH_CUSTOM_5D43);
        _bh(gate, skip, 22, SAVAX, WAVAX, BH_CUSTOM_DCFC);
        _bh(gate, skip, 23, WAVAX, BLACK, BH_CUSTOM_5D43);
        _bh(gate, skip, 24, USDC, BLACK, BH_CUSTOM_5D43);
        uint24[] memory keys = new uint24[](5);
        (keys[0], keys[1], keys[2], keys[3], keys[4]) = (_key(1, 1), _key(2, 1), _key(3, 1), _key(3, 2), _key(4, 1));
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, MODE_CREATE2_V3, gate.WRAPPER_INIT_HASH(), keys, new int24[](0));
    }

    function _key(uint8 family, uint8 slot) internal pure returns (uint24) { return (uint24(family) << 16) | slot; }

    function _skipped(string memory skip, uint256 i) internal pure returns (bool) {
        bytes memory b = bytes(skip);
        uint256 v; bool any;
        for (uint256 k; k <= b.length; ++k) {
            if (k == b.length || b[k] == ",") { if (any && v == i) return true; v = 0; any = false; }
            else { v = v * 10 + (uint8(b[k]) - 48); any = true; }
        }
        return false;
    }

    function _lb(BlazePhoenixGate g, string memory skip, uint256 i, uint8 family, uint8 slot, address a, address b, uint256 binStep) internal {
        if (_skipped(skip, i)) return;
        address w = g.create(a, b, _key(family, slot), abi.encode(binStep));
        console2.log("G7WRAP", i, w);
    }

    function _bh(BlazePhoenixGate g, string memory skip, uint256 i, address a, address b, address deployer) internal {
        if (_skipped(skip, i)) return;
        address w = g.create(a, b, _key(4, 1), abi.encode(deployer));
        console2.log("G7WRAP", i, w);
    }
}
