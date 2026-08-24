// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// NENHUMA BRIDGE CONFIGURADA PODE SER FANTASMA.
//
// HISTORIA, porque a conclusao so se percebe com ela. O Hub aceitava MAX_BRIDGES = 3, mas o
// Solver expandia as bridges DESENROLADO A MAO (`b0`, `b1`) e o `_rank` tinha tres lugares:
// directo + duas. A TERCEIRA BRIDGE NUNCA PODIA SER UM HOP.
//
// E mesmo assim tinha poderes, porque o `isBridge[t]` e lido onde nao se roteia:
//   - `claimV4`: porta PERMISSIONLESS cujo portao de ancora exige uma bridge de confianca;
//   - a flag `bridged` no Monoslot (bit 7), que vale +25% de fitness no `psi` do Core.
// Num registo CAPADO com despejo por fitness, isso enchia-o de pools bem classificadas e
// INALCANCAVEIS, que despejavam as que o router consegue usar. O bonus era pago sobre liquidez
// que o router nao toca.
//
// A PRIMEIRA CURA foi gerir a assimetria: MAX_BRIDGE_ROUTES = 2, e os poderes so para as
// roteaveis. Funcionava, e estava errada — partia do principio de que expandir a terceira era
// caro de mais, e ninguem tinha medido ONDE esse custo cai.
//
// A CURA CERTA foi apagar a assimetria na origem: o Solver expande TODAS as bridges
// configuradas e entrega-as ao `_rank`, que ja e o produtor unico do juizo "qual rota e melhor"
// e decide pelo `totalOut` — a saida CONSTRUIDA e medida, nao um proxy.
//
// PORQUE NAO SE PRE-FILTRAM "AS MELHORES 2" (o erro que este ficheiro tambem regista): um
// pre-filtro por profundidade do registo seria um SEGUNDO produtor do mesmo juizo, ao lado do
// `_rank` — e o pior dos dois, porque profundidade e um proxy e `totalOut` e o numero real. Um
// proxy so pode descartar exatamente a rota que o produtor verdadeiro escolheria. A
// profundidade ja faz o seu trabalho um nivel abaixo, a ordenar candidatos DENTRO de cada hop.
//
// E o custo? O solve dentro da tx custa 55,7k-220,9k gas (MEDIDO, EquationBench). A terceira
// bridge acrescenta ~40%. Mas so paga no `swapBestExactIn` — e essa porta so vence em chains
// dominadas por dados (Scroll, 99,91% do custo em L1), onde a execucao e 0,09% da tx. Nas
// chains onde a execucao domina usa-se `swapExactIn` com a rota resolvida fora da cadeia, e o
// solver off-chain nao tem limite de bridges nenhum. O custo cai onde menos importa.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract RoutableBridgeAsymmetryTest is Test {
    BlazePhoenixHub hub;

    address constant B0    = address(0xB000);
    address constant B1    = address(0xB001);
    address constant B2    = address(0xB002); // a que era fantasma
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

    /// O LIMITE E O QUE O SOLVER CONSEGUE EXPANDIR, e nada mais. O Solver le `hub.bridge(0)`
    /// e `hub.bridge(1)` DESENROLADO A MAO; uma terceira posicao no array sem um terceiro
    /// braco la seria a bridge fantasma outra vez, e uma terceira leitura sem a posicao no
    /// array reverte com Panic 0x32. As duas constantes tem de descer e subir JUNTAS.
    function test_LimiteDeBridgesEExactamenteMaxBridges() public {
        assertEq(hub.bridgeCount(), 3, "o setUp ja configurou o maximo");
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 7));
        hub.addBridge(address(0xB003));
    }

    function _bridged(bytes32 key) internal view returns (bool) {
        return ((hub.getSlot(key) >> BRIDGED_BIT) & 1) == 1;
    }

    /// O NUCLEO. TODAS as bridges configuradas tem de ganhar a flag — porque todas sao
    /// expandidas pelo Solver. Uma bridge que ganhe fitness sem poder ser um hop e um fantasma,
    /// e um fantasma num registo capado despeja liquidez util.
    ///
    /// Fica vermelho se alguem subir o MAX_BRIDGES sem acrescentar o bracco correspondente ao
    /// Solver e ao `_rank` — que e exatamente como o defeito nasceu.
    function test_NenhumaBridgeConfiguradaEFantasma() public {
        bytes32 k0 = hub.seedPool(address(0xA001), BPC.KIND_V2, 30, address(0), B0, OTHER);
        bytes32 k1 = hub.seedPool(address(0xA002), BPC.KIND_V2, 30, address(0), B1, OTHER);
        bytes32 k2 = hub.seedPool(address(0xA003), BPC.KIND_V2, 30, address(0), B2, OTHER);

        assertTrue(_bridged(k0), "bridge(0) tem de ser roteavel");
        assertTrue(_bridged(k1), "bridge(1) tem de ser roteavel");
        assertTrue(_bridged(k2),
            "bridge(2) tem de ser roteavel: o Solver expande-a e o _rank julga-a pelo totalOut");
    }

    /// O CONTROLO NEGATIVO, e sem ele este ficheiro nao valia nada: um token que NAO e bridge
    /// nenhuma nao pode ganhar a flag. Sem isto, um `_isRoutableBridge` que devolvesse `true` a
    /// toda a gente ficava verde no teste acima.
    function test_ControloUmTokenQueNaoEBridgeNaoGanhaFlag() public {
        bytes32 k = hub.seedPool(address(0xA004), BPC.KIND_V2, 30, address(0), OTHER, address(0x8888));
        assertFalse(_bridged(k), "um par sem nenhuma bridge nao pode levar o bonus de fitness");
    }

    /// A porta PERMISSIONLESS aceita QUALQUER bridge configurada como ancora.
    ///
    /// PORQUE MEDE GAS E NAO O CODIGO DE ERRO: o `claimV4` tem TRES `revert HubE(9)` distintos —
    /// o portao de ancora, a prova de existencia/liquidez, e a guarda de fee dinamica. Um teste
    /// que so assertasse "reverteu com HubE(9)" ficaria verde mesmo que o portao mudasse, porque
    /// a chamada morre dois passos a frente com o MESMO codigo. E o defeito exato que o
    /// cabecalho do .github/scripts/mutants.py documenta, e a primeira versao deste teste caiu
    /// nele. O gas discrimina onde o codigo de erro nao consegue: o portao reverte ANTES da
    /// chamada externa ao singleton V4, a prova reverte DEPOIS dela.
    function test_ClaimV4_QualquerBridgeConfiguradaPassaOPortao() public {
        uint256 g = gasleft();
        try hub.claimV4(address(0x9999), OTHER, 3000, 60) { } catch { }
        uint256 gastoSemAncora = g - gasleft();

        g = gasleft();
        try hub.claimV4(B2, OTHER, 3000, 60) { } catch { }
        uint256 gastoComB1 = g - gasleft();

        assertLt(gastoSemAncora, gastoComB1,
            "um par sem ancora morre NO PORTAO; com a bridge(1) tem de passar e chegar a prova");
    }

    /// O PINO ENTRE AS DUAS CONSTANTES. Hoje `MAX_BRIDGE_ROUTES == MAX_BRIDGES` e por isso
    /// `_isRoutableBridge` e `isBridge` respondem o mesmo. ISSO E UM FACTO, NAO UMA DEFINICAO:
    /// as duas perguntas continuam a ser diferentes ("e uma ancora de confianca?" vs "pode um
    /// hop passar por aqui?") e continuam a ter dois nomes, precisamente para que o dia em que
    /// divergirem seja um dia em que alguem tem de explicar a divergencia.
    function test_TodasAsConfiguraveisSaoRoteaveis() public {
        assertEq(hub.bridgeCount(), 3, "o setUp configurou o maximo");
        bytes32 k = hub.seedPool(address(0xA005), BPC.KIND_V2, 30, address(0), B2, OTHER);
        assertTrue(hub.isBridgeToken(B2), "e uma ancora de confianca");
        assertTrue(_bridged(k), "e TAMBEM roteavel - hoje as duas respostas coincidem");
    }
}
