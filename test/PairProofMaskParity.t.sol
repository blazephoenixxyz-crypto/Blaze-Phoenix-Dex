// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// O PINO POR CONSTRUCAO DA MASCARA DE PROVA DE PAR.
//
// PORQUE ESTE FICHEIRO EXISTE. Uma proposta desta ronda queria colapsar a mascara do Hub no
// atributo A_PAIR_VER da theta, marcada "bytes: ~0, principio: neutro". Nao era neutra: na altura
// a mascara tinha um bit a mais (uma venue ja retirada) e a substituicao RETIRAVA esse kind do
// gate — e o teste de paridade que a propria proposta citava como rede vinha VERDE com o buraco
// aberto, porque so iterava kinds vivos.
//
// A REGRA QUE ISSO ENSINOU: o `A_PAIR_VER` responde "que FORMA tem o estado?"; a mascara do Hub
// responde "que kinds tem de PROVAR que negoceiam este par antes de entrar no registo?". E um
// predicado de ACEITACAO. Colapsar os dois porque os bits batem certo troca uma VERIFICACAO por
// uma COINCIDENCIA.
//
// O QUE ENTRA, ENTAO, E SO A METADE INOFENSIVA: nao colapsar, mas PINAR a coincidencia por
// construcao. Se um dia divergirem, e a divergencia que tem de ser explicada — em vez de ninguem
// dar por ela. E o pino e derivado da theta em vez de escrito a mao, porque um literal repetido
// num teste e apenas mais um irmao a espera de divergir: a versao anterior deste pino era o
// numero `0x6b` escrito a mao, e teria ficado verde mesmo que a constante do Hub desaparecesse.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @notice Expoe a constante `internal` do Hub. Herdar e a unica forma de a ler sem a tornar
///         publica no contrato de producao — o pino nao deve custar superficie ao Hub.
contract HubProbe is BlazePhoenixHub {
    constructor() BlazePhoenixHub(msg.sender) {}
    function pairProofMask() external pure returns (uint256) { return KINDS_PAIR_PROOF; }
    function routableMask()  external pure returns (uint256) { return KINDS_ROUTABLE; }
}

contract PairProofMaskParityTest is Test {
    HubProbe probe;
    function setUp() public { probe = new HubProbe(); }

    /// A coincidencia, pinada — e derivada da theta, nunca escrita a mao.
    function test_PairProofMaskMatchesTheta() public view {
        uint256 daTheta;
        for (uint8 k; k <= 8; k++) {
            if (BPC.kindHas(k, BPC.A_PAIR_VER)) daTheta |= (uint256(1) << k);
        }
        assertEq(probe.pairProofMask(), daTheta,
            "a mascara de prova de par e o A_PAIR_VER divergiram sem que a divergencia fosse explicada");
    }

    /// E o que a mascara TEM de conter, dito por extenso: os kinds vivos cujo campo `pool` e um
    /// par com token0()/token1(). Se um deles cair fora, um contrato escrito pelo atacante entra
    /// no registo sob um par escolhido por ele.
    function test_EveryLivePairShapedKindIsCovered() public view {
        uint8[4] memory pares = [BPC.KIND_V2, BPC.KIND_V3, BPC.KIND_SOLIDLY, BPC.KIND_ALGEBRA];
        for (uint256 i; i < pares.length; i++) {
            assertTrue(((probe.pairProofMask() >> pares[i]) & 1) != 0,
                "um kind pair-shaped vivo saiu da prova de autenticidade");
        }
        // Os singleton-shaped provam-se de outra forma (recomputacao do poolId) e nao entram.
        assertEq((probe.pairProofMask() >> BPC.KIND_V4) & 1, 0, "V4 nao e um par");
        assertEq((probe.pairProofMask() >> BPC.KIND_V4_NATIVE) & 1, 0, "V4_NATIVE nao e um par");
    }

    /// AS LAPIDES: 2, 3 e 7 nao podem estar em NENHUMA das duas mascaras. E o pino que impede que
    /// um numero queimado seja reatribuido — o Monoslot le o kind desses bits, logo reutilizar o
    /// 2 faria toda a pool ja gravada sob o 2 ser lida como a venue nova.
    function test_TombstonesAreInNoMask() public view {
        uint8[3] memory mortos = [uint8(2), 3, 7];
        for (uint256 i; i < mortos.length; i++) {
            assertEq((probe.pairProofMask() >> mortos[i]) & 1, 0, "lapide na mascara de prova");
            assertEq((probe.routableMask()  >> mortos[i]) & 1, 0, "lapide na mascara de roteaveis");
            assertEq(BPC.thetaOf(mortos[i]), 0, "lapide com atributos na theta");
        }
    }
}
