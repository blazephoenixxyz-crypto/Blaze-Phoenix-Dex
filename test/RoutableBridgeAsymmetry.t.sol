// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// A BRIDGE FANTASMA — a que tinha todos os poderes menos o de ser usada.
//
// O Hub aceitava MAX_BRIDGES = 3. O Solver expande as bridges DESENROLADO A MAO (`b0`, `b1`,
// Solver:203-215) e o `_rank` tem tres lugares: directo + duas. A terceira bridge NUNCA podia
// ser um hop.
//
// E mesmo assim tinha poderes, porque o `isBridge[t]` e lido em sitios que nao tem nada a ver
// com rotear:
//   - `claimV4` (Hub): porta PERMISSIONLESS que exige "um dos lados tem de ser uma bridge de
//     confianca". Uma terceira bridge abria essa porta a todos os pares que lhe tocassem.
//   - a flag `bridged` no Monoslot (bit 7), que vale +25% de fitness no `psi` do Core.
//
// O DANO, e vai na direcao errada: o registo por par e CAPADO e o despejo decide-se por
// fitness. Uma terceira bridge enchia-o de pools bem classificadas e INALCANCAVEIS, que
// despejavam as pools que o router consegue mesmo usar. O bonus era pago sobre liquidez que o
// router nao toca.
//
// A CURA NAO FOI COLAPSAR NEM CORTAR: sao DUAS PERGUNTAS e agora tem duas respostas.
//   "este token e uma ancora de confianca?"  -> isBridge, ate MAX_BRIDGES
//   "pode um hop passar por aqui?"           -> _isRoutableBridge, ate MAX_BRIDGE_ROUTES
// E a prova de que a intencao de desenho sempre foi esta: o cabecalho da seccao das bridges no
// Hub ja dizia "max 2" enquanto a constante dizia 3. A constante e que derivou.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract RoutableBridgeAsymmetryTest is Test {
    BlazePhoenixHub hub;

    address constant B0    = address(0xB000); // roteavel (o Solver le bridge(0))
    address constant B1    = address(0xB001); // roteavel (o Solver le bridge(1))
    address constant B2    = address(0xB002); // configurada, NAO roteavel
    address constant OTHER = address(0x7777);

    /// Posicao da flag `bridged` no Monoslot — ver `_markBridged` no Hub.
    uint256 constant BRIDGED_BIT = 7;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        hub.addBridge(B0);
        hub.addBridge(B1);
        hub.addBridge(B2);
    }

    function _bridged(bytes32 key) internal view returns (bool) {
        return ((hub.getSlot(key) >> BRIDGED_BIT) & 1) == 1;
    }

    /// O NUCLEO. Duas pools identicas em tudo menos na bridge a que tocam. A que toca numa
    /// bridge ROTEAVEL leva a flag (e com ela os +25% de fitness); a que toca na terceira NAO.
    ///
    /// Este e o teste que fica vermelho se alguem trocar o `_isRoutableBridge` de volta pelo
    /// `isBridge` — que era exatamente o estado anterior.
    function test_SoUmaBridgeRoteavelGanhaOBonusDeFitness() public {
        bytes32 kRoteavel = hub.seedPool(address(0xA001), BPC.KIND_V2, 30, address(0), B0, OTHER);
        bytes32 kFantasma = hub.seedPool(address(0xA002), BPC.KIND_V2, 30, address(0), B2, OTHER);

        assertTrue(_bridged(kRoteavel),
            "uma bridge por onde o Solver roteia tem de marcar a flag bridged");
        assertFalse(_bridged(kFantasma),
            "a 3a bridge nao e roteavel: nao pode ganhar +25% de fitness num registo capado");
    }

    /// A SEGUNDA bridge tambem e roteavel — o controlo que impede este ficheiro de passar por
    /// um motivo errado. Sem ele, um `_isRoutableBridge` que so aceitasse o indice 0 tambem
    /// ficaria verde, e isso seria um segundo defeito com a mesma forma.
    function test_ControloAsDuasPrimeirasSaoRoteaveis() public {
        bytes32 k0 = hub.seedPool(address(0xA003), BPC.KIND_V2, 30, address(0), B0, OTHER);
        bytes32 k1 = hub.seedPool(address(0xA004), BPC.KIND_V2, 30, address(0), B1, OTHER);
        assertTrue(_bridged(k0), "bridge(0) e roteavel");
        assertTrue(_bridged(k1), "bridge(1) e roteavel - o Solver le b0 E b1");
    }

    /// A porta PERMISSIONLESS. O `claimV4` exige uma ancora ROTEAVEL, e com a terceira bridge
    /// tem de morrer no portao antes sequer de tentar a prova de liquidez on-chain.
    ///
    /// PORQUE ESTE TESTE MEDE GAS E NAO O CODIGO DE ERRO. O `claimV4` tem TRES `revert HubE(9)`
    /// distintos: o portao de ancora, a prova de existencia/liquidez, e a guarda de fee dinamica.
    /// Um teste que so assertasse "reverteu com HubE(9)" ficaria verde mesmo que o portao
    /// desaparecesse, porque a chamada morreria dois passos a frente com o MESMO codigo. E
    /// exatamente o defeito que o cabecalho do .github/scripts/mutants.py documenta ("o revert
    /// que o teste apanhava vinha de OUTRA verificacao com o MESMO codigo de erro") — e a
    /// primeira versao deste teste caiu nele.
    ///
    /// O gas discrimina onde o codigo de erro nao consegue: o portao reverte ANTES da chamada
    /// externa ao singleton V4; a prova de liquidez reverte DEPOIS dela. A diferenca e uma
    /// chamada externa inteira, nao um punhado de opcodes.
    ///
    /// (NOTA PARA O BACKLOG: tres verificacoes semanticamente diferentes a partilhar o codigo 9
    /// e uma perda de diagnostico real. Codigos distintos custariam bytes num Hub que tem pouca
    /// folga, por isso fica registado e nao corrigido aqui.)
    function test_ClaimV4_BridgeFantasmaMorreNoPortaoAntesDaProva() public {
        uint256 g = gasleft();
        try hub.claimV4(B2, OTHER, 3000, 60) { } catch { }
        uint256 gastoFantasma = g - gasleft();

        g = gasleft();
        try hub.claimV4(B0, OTHER, 3000, 60) { } catch { }
        uint256 gastoRoteavel = g - gasleft();

        assertLt(gastoFantasma, gastoRoteavel,
            "a bridge fantasma tem de morrer NO PORTAO, antes de tentar a prova on-chain");
    }

    /// O PINO ENTRE AS DUAS CONSTANTES. O `MAX_BRIDGE_ROUTES` existe porque o Solver expande
    /// desenrolado ate `b1`. Se alguem acrescentar um `b2` ao Solver sem subir esta constante,
    /// o terceiro fica configurado mas continua sem flag; se subir esta sem mexer no Solver,
    /// volta a pagar-se o bonus sobre liquidez inalcancavel. Nenhum teste em Solidity le o
    /// codigo do Solver — por isso o pino e este: as tres configuradas, exatamente duas
    /// roteaveis, afirmado por comportamento observavel.
    function test_ExatamenteDuasRoteaveisDeTresConfiguradas() public {
        assertEq(hub.bridgeCount(), 3, "tres bridges configuradas");
        assertTrue(hub.isBridgeToken(B2), "a terceira E uma ancora de confianca...");

        bytes32 k = hub.seedPool(address(0xA005), BPC.KIND_V2, 30, address(0), B2, OTHER);
        assertFalse(_bridged(k), "...mas NAO e roteavel, e essa e a distincao inteira");
    }
}
