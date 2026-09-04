// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";

interface IERC20B {
    function approve(address, uint256) external returns (bool);
}

/// @notice DE ONDE VEM O CUSTO DO DISCOVERY ON-CHAIN.
///
/// O dono lembra-se de uma versao anterior a ~900k (frio) / ~500k (quente) e a
/// medicao de hoje deu 3,22M / 2,58M na porta B. Este ficheiro nao explica a
/// diferenca por narrativa — isola as variaveis uma a uma e mede cada uma.
///
/// Variaveis isoladas:
///   A. numero de FACTORIES registadas (quantas venues o discoverFor sonda)
///   B. numero de BRIDGES (2 vs 3 — o 3o braco do _rank)
///
/// Cada configuracao mede a MESMA rota, no MESMO bloco, com o MESMO tamanho.
contract DiscoveryCostBreakdownTest is Test {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant LINK   = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant UNIV3  = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant AERO   = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant V4MGR  = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    bytes32 constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    uint256 constant BLK = 49_800_000;
    uint256 constant AMT = 1_000e6;
    address user = address(0xB1A2E);

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }   // a bare return reports PASSED on a test that ran nothing
        vm.createSelectFork("base", BLK);
    }

    function _v3Fees() internal pure returns (uint24[] memory f) {
        f = new uint24[](4); f[0]=100; f[1]=500; f[2]=3000; f[3]=10000;
    }
    function _v3Sp() internal pure returns (int24[] memory s) {
        s = new int24[](4); s[0]=1; s[1]=10; s[2]=60; s[3]=200;
    }
    function _n24() internal pure returns (uint24[] memory f) { f = new uint24[](0); }
    function _nSp() internal pure returns (int24[] memory s) { s = new int24[](0); }

    /// Deploy MINIMO: 1 factory (Uniswap V3), 2 bridges. O mais perto possivel
    /// de uma configuracao antiga e enxuta.
    function _deployMinimo(bool comAero, bool com3aBridge)
        internal
        returns (BlazePhoenixHub h, BlazePhoenixRouter r, BlazePhoenixQuoter q)
    {
        h = new BlazePhoenixHub(address(this));
        h.initialize(address(this), V4MGR);
        BlazePhoenixSolver s = new BlazePhoenixSolver(address(h));
        r = new BlazePhoenixRouter(address(h), address(s), address(this),
                                   address(0x7E51), address(0x7E52));
        q = new BlazePhoenixQuoter(address(h), address(s));
        h.setRoles(address(r), address(s), address(q));
        h.addBridge(WETH);
        h.addBridge(USDC);
        if (com3aBridge) h.addBridge(WSTETH);
        h.addFactory(UNIV3, 1, 5, UNIV3_INIT, _v3Fees(), _v3Sp());
        if (comAero) h.addFactory(AERO, 5, 2, bytes32(0), _n24(), _nSp());
    }

    function _mede(BlazePhoenixHub h, BlazePhoenixRouter r, string memory label)
        internal returns (uint256 frio, uint256 quente)
    {
        uint256 t0 = block.timestamp;
        deal(USDC, user, AMT * 8);
        vm.prank(user);
        IERC20B(USDC).approve(address(r), type(uint256).max);

        vm.prank(user);
        uint256 g = gasleft();
        try r.swapBestExactIn(USDC, LINK, AMT, 1, user, t0 + 600) returns (uint256) {
            frio = g - gasleft();
        } catch { console2.log(string.concat(label, ": porta B reverteu a frio")); return (0,0); }

        vm.prank(user);
        g = gasleft();
        try r.swapBestExactIn(USDC, LINK, AMT, 1, user, t0 + 600) returns (uint256) {
            quente = g - gasleft();
        } catch { quente = 0; }

        console2.log(label);
        console2.log("   factories:", h.factoryCount(), "| bridges:", h.bridgeCount());
        console2.log("   porta B FRIO  :", frio);
        console2.log("   porta B QUENTE:", quente);
    }

    function test_DeOndeVemOCusto() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        console2.log("=========================================");
        console2.log(" DISCOVERY ON-CHAIN -- de onde vem o custo");
        console2.log(" mesma rota USDC->LINK, mesmo bloco, 1.000 USDC");
        console2.log("=========================================");

        uint256 snap = vm.snapshotState();

        (BlazePhoenixHub h1, BlazePhoenixRouter r1, ) = _deployMinimo(false, false);
        (uint256 f1, uint256 q1) = _mede(h1, r1, "A) 1 factory (UniV3), 2 bridges");
        vm.revertToState(snap);

        (BlazePhoenixHub h2, BlazePhoenixRouter r2, ) = _deployMinimo(true, false);
        (uint256 f2, uint256 q2) = _mede(h2, r2, "B) 2 factories (+Aerodrome), 2 bridges");
        vm.revertToState(snap);

        (BlazePhoenixHub h3, BlazePhoenixRouter r3, ) = _deployMinimo(true, true);
        (uint256 f3, uint256 q3) = _mede(h3, r3, "C) 2 factories, 3 bridges");
        vm.revertToState(snap);

        (BlazePhoenixHub h4, BlazePhoenixSolver s4, BlazePhoenixRouter r4, ) =
            BaseTestDeploy.deploy(address(this), false);
        s4; // silencia
        (uint256 f4, uint256 q4) = _mede(h4, r4, "D) deploy completo, 2 bridges");
        vm.revertToState(snap);

        (BlazePhoenixHub h5, BlazePhoenixSolver s5, BlazePhoenixRouter r5, ) =
            BaseTestDeploy.deploy(address(this), true);
        s5;
        (uint256 f5, uint256 q5) = _mede(h5, r5, "E) deploy completo, 3 bridges");

        console2.log("=========================================");
        console2.log(" DELTAS ISOLADOS");
        console2.log("=========================================");
        console2.log("+1 factory (A->B) frio:", f2 > f1 ? f2 - f1 : 0);
        console2.log("+1 bridge  (B->C) frio:", f3 > f2 ? f3 - f2 : 0);
        console2.log("minimo->completo (B->D) frio:", f4 > f2 ? f4 - f2 : 0);
        console2.log("completo +1 bridge (D->E) frio:", f5 > f4 ? f5 - f4 : 0);
        console2.log("-----------------------------------------");
        console2.log("mais enxuto  (A) frio/quente:", f1, q1);
        console2.log("mais gordo   (E) frio/quente:", f5, q5);
        console2.log("racio E/A frio (x100):", f1 == 0 ? 0 : (f5 * 100) / f1);
    }
}
