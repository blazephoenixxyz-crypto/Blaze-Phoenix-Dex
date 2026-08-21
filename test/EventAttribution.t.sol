// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// E5 — OS EVENTOS TEM DE SER ATRIBUIDOS AO PAGADOR, NAO AO `msg.sender`.
//
// O `swapBestExactIn` chega ao `_execute` por uma SELF-CALL externa — e o proprio docstring do
// `_execute` explica isso, para justificar o parametro `payer` que existe ao lado. Nesse caminho
// `msg.sender` E O PROPRIO ROUTER.
//
// Ate 2026-08-21 os dois eventos usavam `msg.sender`. Consequencia: na porta que os docstrings
// chamam "the philosophy entry point" — a unica em que a rota e decidida 100% on-chain — o `Swap`
// e o `ExecutionProof` ficavam indexados ao ENDERECO DO CONTRATO.
//
// PORQUE ISSO IMPORTA MAIS DO QUE PARECE. A serie `ExecutionProof` e o unico ativo genuinamente
// novo deste protocolo: a quote de referencia produzida por consenso no MESMO frame da execucao,
// reproduzivel por qualquer pessoa com um eth_call. Estava a ser emitida SEM DONO exatamente na
// porta que a torna unica — um dataset de auditoria nao atribuivel e metade de um dataset.
//
// E o `amountIn` do `Swap`: desde que a fee passou a sair de dentro do laco, o `amountIn` que
// viaja no frame ja vem liquido do hop 0. Emiti-lo sub-reportava o que o utilizador entregou.

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract EventAttributionTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair pair;

    address user = address(0x5E4);
    uint256 constant AMOUNT_IN = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );
        // Semeia-se com `this` no papel de router (o `recordSwap` e onlyRouter) e SO DEPOIS se
        // entrega o papel ao Router real — que e quem tem de o ter para o swapBestExactIn correr.
        hub.setRoles(address(this), address(solver), address(this));

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        pair = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(pair), 1_000_000e18);
        tB.mint(address(pair), 1_000_000e18);
        pair.setReserves(1_000_000e18, 1_000_000e18);
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(pair), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, 1_000_000e18);
        }

        hub.setRoles(address(router), address(solver), address(this));

        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    /// A PORTA BANDEIRA. O `swapBestExactIn` calcula a rota on-chain e auto-executa — e e por ai
    /// que o `msg.sender` deixa de ser o utilizador.
    function test_SwapBest_EventosAtribuidosAoUtilizador() public {
        vm.recordLogs();
        vm.prank(user);
        router.swapBestExactIn(address(tA), address(tB), AMOUNT_IN, 1, user, block.timestamp + 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sigSwap  = keccak256("Swap(address,address,address,uint256,uint256,uint256)");
        bytes32 sigProof = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        bool viuSwap;
        bool viuProof;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == sigSwap) {
                viuSwap = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), user,
                    "Swap indexado ao Router em vez do utilizador");
                (uint256 amtIn, , ) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(amtIn, AMOUNT_IN,
                    "o Swap reporta a entrada JA liquida de fee, e nao o que o utilizador entregou");
            }
            if (logs[i].topics[0] == sigProof) {
                viuProof = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), user,
                    "ExecutionProof indexado ao Router: a serie fica sem dono");
            }
        }
        // Sem estas duas, o teste passaria se os eventos simplesmente nao fossem emitidos.
        assertTrue(viuSwap,  "pre-condicao: o Swap tem de ser emitido");
        assertTrue(viuProof, "pre-condicao: o ExecutionProof tem de ser emitido");
    }

    /// ANTI-REGRESSAO: na porta classica `msg.sender` E o pagador, logo trocar para `payer` nao
    /// pode ter mudado nada aqui.
    function test_SwapExactIn_ContinuaAtribuidoAoUtilizador() public {
        uint256 q = (AMOUNT_IN * 9970 * 1_000_000e18) / (1_000_000e18 * 10_000 + AMOUNT_IN * 9970);
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tA) < address(tB), stable: false,
            amountIn: AMOUNT_IN, expectedOut: q, auxId: bytes32(0)});
        Hop[] memory hp = new Hop[](1);
        hp[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: AMOUNT_IN, expectedOut: q, legs: l});
        Route memory r = Route({hops: hp, totalOut: q, singleOut: q, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, AMOUNT_IN, 1, user, block.timestamp + 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sigSwap = keccak256("Swap(address,address,address,uint256,uint256,uint256)");
        bool viu;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == sigSwap) {
                viu = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), user, "porta classica");
            }
        }
        assertTrue(viu, "pre-condicao: o Swap tem de ser emitido");
    }
}
