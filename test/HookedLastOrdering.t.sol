// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// CAMADA 2 — ordenacao canonica: pernas HOOKLESS antes de HOOKED, por hop.
//
// Porque: um hook ganha controlo de EVM durante o swap e pode tocar em qualquer
// contrato, incluindo o pool de uma perna AINDA NAO EXECUTADA da mesma rota. Se
// as pernas hookless correrem primeiro, liquidam e sao verificadas por
// balance-delta ANTES de qualquer codigo de terceiros correr — o passado nao se
// manipula. Fecha o vetor intra-hop por ORDEM DE EXECUCAO, nao por tolerancia.
//
// Tem de ser imposta NO ROUTER: swapExactIn recebe a Route de calldata e itera
// na ordem recebida (Router:~755); ordenar no Solver e contornavel por quem
// monta a rota a mao.
//
// Nao rejeita nenhuma pool nem nenhuma rota: toda a rota e reexprimivel na ordem
// canonica. E regra de encoding, como a ordenacao de tokens — nao e uma lista.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract HookedLastOrderingTest is Test {
    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router;
    MockERC20 tokenA; MockERC20 tokenB;
    MockV2Pair poolA; MockV2Pair poolB;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    // endereco de "hook" — so os bits baixos importam para a classificacao;
    // 0x...0000 evita os bits RETURNS_DELTA que o Router ja rejeita.
    address constant HOOK = address(0x4444444444444444444444444444444444444000);
    uint256 constant AMT = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        tokenA = new MockERC20("A", "A"); tokenB = new MockERC20("B", "B");
        poolA = new MockV2Pair(address(tokenA), address(tokenB));
        poolB = new MockV2Pair(address(tokenA), address(tokenB));
        _seed(poolA); _seed(poolB);
        hub.seedPool(address(poolA), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(poolB), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        tokenA.mint(user, 1_000_000e18);
        vm.prank(user); tokenA.approve(address(router), type(uint256).max);
    }

    function _seed(MockV2Pair p) internal {
        if (p.token0() == address(tokenA)) p.setReserves(uint112(100_000e18), uint112(100_000e18));
        else p.setReserves(uint112(100_000e18), uint112(100_000e18));
        tokenA.mint(address(p), 100_000e18); tokenB.mint(address(p), 100_000e18);
    }

    function _out(MockV2Pair p) internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = p.getReserves();
        bool zfo = p.token0() == address(tokenA);
        return BPC.outV2(AMT, zfo ? r0 : r1, zfo ? r1 : r0, 30);
    }

    function _leg(MockV2Pair p, address hooks) internal view returns (Leg memory) {
        return Leg({pool: address(p), hooks: hooks, kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: p.token0() == address(tokenA), stable: false,
            amountIn: AMT, expectedOut: _out(p), auxId: bytes32(0)});
    }

    function _route(Leg[] memory legs) internal view returns (Route memory r) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
                       amountIn: AMT * legs.length, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// ORDEM CANONICA: hookless primeiro, hooked depois -> PASSA.
    function test_CanonicalOrder_HooklessThenHooked_Passes() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(poolA, address(0));   // hookless
        legs[1] = _leg(poolB, HOOK);         // hooked
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(legs), AMT * 2, 1, user, block.timestamp + 1);
        assertGt(got, 0, "ordem canonica tem de passar");
    }

    /// ORDEM INVALIDA: hooked antes de hookless -> REVERTE.
    /// Sem isto, o hook da perna 0 corre ANTES de a perna 1 ser medida.
    function test_HookedBeforeHookless_Reverts() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(poolA, HOOK);         // hooked PRIMEIRO — invalido
        legs[1] = _leg(poolB, address(0));   // hookless depois
        vm.prank(user);
        vm.expectRevert();
        router.swapExactIn(_route(legs), AMT * 2, 1, user, block.timestamp + 1);
    }

    /// SEM RIGIDEZ: uma rota so com pernas hookless nunca e afetada.
    function test_AllHookless_Unaffected() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(poolA, address(0));
        legs[1] = _leg(poolB, address(0));
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(legs), AMT * 2, 1, user, block.timestamp + 1);
        assertGt(got, 0, "rota sem hooks nao pode ser afetada");
    }
}
