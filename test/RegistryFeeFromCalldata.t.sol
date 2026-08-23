// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  REG-01 (regressao) — a fee canonica do registo NAO pode entrar crua do
//  calldata. Vermelho ate 2026-08-23, corrigido no Hub na mesma sessao.
//
//  O ARTEFACTO PARTILHADO e o campo `fee` do Monoslot (`decodeFee`). Dois
//  consumidores, duas perguntas:
//    - Router-exec  : "que fee vai esta pool cobrar?"  -> MEDE (Router:736,
//                     `effV3Fee(getV3Fee(leg.pool), 0, false)`) e deita fora.
//    - Solver/Quoter: "que fee devo assumir?"          -> LE o registo
//                     (Hub:1173, `p.fee = decodeFee(s)`).
//
//  O produtor do valor gravado e `Router._recordHits` (Router:1789-1792), que
//  passa `leg.fee` DIRECTO do calldata a `recordSwap`, e o Hub grava-o em
//  `encodeSlot(true, fee, ...)` sem prova nenhuma. Na mesma funcao a
//  PROFUNDIDADE e medida; a fee e o unico datum de H1 que entra sem medicao.
//
//  Doutrina violada (I-measure / H1): os dados do proponente sao COORDENADAS
//  que o contrato MEDE, nao factos que o contrato GRAVA.
//
//  PERMANENCIA: `Core.tickSlot` limpa swapCount/lastBlk/bucket e preserva os
//  bits da fee; `recordSwap` auto-guarda em `slot != 0`. Uma fee envenenada no
//  primeiro swap fica ate despejo ou `seedPool` do operador.
//
//  Este ficheiro prova o defeito na porta onde ele se escreve — o Hub. A
//  alcancabilidade pelo Router (porta A, `swapExactIn`, rota em calldata, sem
//  Solver) esta verificada por leitura: o exec V3 nao consulta `leg.fee` em
//  ramo nenhum desde o fix T1, logo o swap executa limpo com a fee que o
//  atacante quiser.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RegistryFeeFromCalldataTest is Test {
    BlazePhoenixHub hub;
    MockERC20 tA;
    MockERC20 tB;
    MockV3Pool pool;

    uint24 constant FEE_REAL   = 3000;  // o que a pool cobra mesmo
    uint24 constant FEE_FORJADA = 100;  // o que o atacante escreve no calldata

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        // este contrato de teste E o Router: e exactamente o privilegio que o
        // Router tem, e o Router expoe-no a qualquer chamador pela porta A.
        hub.setRoles(address(this), address(this), address(this));

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        pool = new MockV3Pool(address(tA), address(tB), FEE_REAL);
        pool.setState(uint160(1 << 96), 1e21);
    }

    function _slotFee() internal view returns (uint24) {
        (address t0, address t1) = address(tA) < address(tB)
            ? (address(tA), address(tB))
            : (address(tB), address(tA));
        return BPC.decodeFee(hub.getSlot(hub.keyOf(address(pool), t0, t1)));
    }

    /// CONTROLO: com uma fee honesta o registo fica certo. Valida o arreio —
    /// se este falhar, o vermelho do outro nao prova nada.
    function test_Controlo_FeeHonestaRegistaCerto() public {
        hub.recordSwap(
            address(pool), BPC.KIND_V3, FEE_REAL, address(0),
            address(tA), address(tB), 1e18, 1e18, 1e18
        );
        assertEq(_slotFee(), FEE_REAL, "controlo: fee honesta nao chegou ao registo");
    }

    /// VERMELHO: a fee do calldata ganha a fee medivel.
    function test_FeeForjadaNoCalldataNaoEntraNoRegisto() public {
        hub.recordSwap(
            address(pool), BPC.KIND_V3, FEE_FORJADA, address(0),
            address(tA), address(tB), 1e18, 1e18, 1e18
        );

        uint24 gravada = _slotFee();
        uint24 medivel = pool.fee();   // o mesmo que BPC.getV3Fee(pool) le

        emit log_named_uint("fee gravada no registo", gravada);
        emit log_named_uint("fee que a pool cobra  ", medivel);

        // A pool foi registada (o ataque nao falhou por outra guarda).
        assertTrue(gravada != 0 || medivel == 0, "pool nem sequer registou");

        // O que o sistema DEVIA gravar e o que MEDIU, nao o que lhe disseram.
        assertEq(
            gravada, medivel,
            "o registo guardou a fee do calldata em vez da fee da pool"
        );
    }

    /// A PERMANENCIA, que era o que tornava isto caro: `recordSwap` auto-guarda
    /// em `slot != 0` e o `tickSlot` preserva os bits da fee, logo o valor do
    /// PRIMEIRO registo fica ate ao despejo. Com o fix isso deixa de ser um
    /// problema e passa a ser a garantia: nasce medido, e medido fica.
    function test_RegistoNasceMedidoEAssimFica() public {
        hub.recordSwap(
            address(pool), BPC.KIND_V3, FEE_FORJADA, address(0),
            address(tA), address(tB), 1e18, 1e18, 1e18
        );
        uint24 depoisDaTentativa = _slotFee();

        hub.recordSwap(
            address(pool), BPC.KIND_V3, FEE_REAL, address(0),
            address(tA), address(tB), 5e18, 5e18, 5e18
        );
        uint24 depoisDoHonesto = _slotFee();

        emit log_named_uint("apos tentativa de forja", depoisDaTentativa);
        emit log_named_uint("apos swap honesto      ", depoisDoHonesto);

        assertEq(
            depoisDoHonesto, FEE_REAL,
            "a fee do registo deixou de ser a medida"
        );
    }
}
