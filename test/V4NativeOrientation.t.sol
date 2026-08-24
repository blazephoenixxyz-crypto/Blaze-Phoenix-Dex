// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract RouterWethStub2 { address public weth; constructor(address w) { weth = w; } }

/// @notice AS DUAS DERIVACOES DA CHAVE V4-NATIVA TEM DE CONCORDAR.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O CONTRATO QUE A PROSA AFIRMA E O CODIGO NAO ENTREGA
/// ─────────────────────────────────────────────────────────────────────────
///  Uma pool V4 de ETH nativo tem `currency0 == address(0)` (o zero ordena
///  sempre primeiro). O registo guarda-a em forma WETH-canonica para o Solver
///  a encontrar ao rotear WETH->X, e a traducao acontece na execucao.
///
///  Mas ha DUAS derivacoes independentes de qual lado e o nativo:
///
///    ROUTER  (`_execV4Amt`, BlazePhoenixRouter.sol):
///        `BPC.nativeMapVerified(tokenIn, tokenOther, weth)`
///        -> mapeia o lado que E o WETH canonico. Verificado contra `weth`.
///
///    QUOTER  (`_simV4`) e SOLVER (`_quoteWithDepth`):
///        `if (zeroForOne) tokenIn = address(0); else tokenOther = address(0);`
///        -> mapeia por ORIENTACAO, sem olhar para o WETH.
///
///  A segunda so esta certa se valer o "contrato de orientacao" que os
///  comentarios do Solver e do Quoter invocam: **token0 do PoolInfo e o lado
///  wrapped-native**. Fui verificar o `Hub._readPoolInfo`: ele copia `t0`/`t1`
///  do INDICE, que `_register` ordena por ENDERECO (`sortTokens`). Nao existe
///  contrato de orientacao nenhum — a prosa afirma-o, o codigo nao o entrega.
///
///  Consequencia: sempre que o outro token tiver endereco MENOR que o do WETH,
///  `token0 == other`, logo `zeroForOne == false` numa rota WETH->other, e o
///  Quoter/Solver mapeiam `other` para nativo em vez do WETH. PoolId errado.
///
///  O dano e FAIL-CLOSED (cotacao zero, nunca perda) mas a pool V4 nativa fica
///  INVISIVEL para metade do espaco de tokens — e essa metade nao e pequena:
///  na Base o WETH e 0x4200..., e ha tokens vivos abaixo disso.
contract V4NativeOrientationTest is Test {
    // WETH da Base. Tudo abaixo de 0x4200... inverte a ordenacao.
    address constant WETH  = 0x4200000000000000000000000000000000000006;
    address constant ACIMA = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC Base > WETH
    address constant ABAIXO= 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // < WETH

    uint24 constant FEE = 500;
    int24  constant TS  = 10;

    /// Como o ROUTER deriva: mapeia o lado que E o WETH.
    function _chaveRouter(address tokenIn, address tokenOther)
        internal pure returns (bytes32)
    {
        (address a, address b) = BPC.nativeMapVerified(tokenIn, tokenOther, WETH);
        (address c0, address c1) = BPC.sortTokens(a, b);
        return BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
    }

    /// Como o QUOTER/SOLVER derivam: mapeiam por orientacao.
    function _chaveQuoter(address tokenIn, address tokenOther, bool zeroForOne)
        internal pure returns (bytes32)
    {
        if (zeroForOne) tokenIn = address(0);
        else            tokenOther = address(0);
        (address c0, address c1) = BPC.sortTokens(tokenIn, tokenOther);
        return BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
    }

    /// `zeroForOne` como o Solver o calcula: token0 do registo == tokenIn.
    /// O registo ordena por endereco (`_register` -> `sortTokens`).
    function _zfoDoRegisto(address tokenIn, address tokenOther)
        internal pure returns (bool)
    {
        (address t0, ) = BPC.sortTokens(tokenIn, tokenOther);
        return t0 == tokenIn;
    }

    /// @notice CASO QUE FUNCIONA: o outro token ordena ACIMA do WETH.
    ///         token0 == WETH, `zeroForOne` verdadeiro numa rota WETH->USDC,
    ///         e as duas derivacoes coincidem. E este o caso que alguem testou
    ///         e que fez a prosa parecer verdadeira.
    function test_TokenAcimaDoWeth_AsDuasDerivacoesConcordam() public pure {
        bool zfo = _zfoDoRegisto(WETH, ACIMA);
        assertTrue(zfo, "com USDC (> WETH) o token0 e o WETH");
        assertEq(
            _chaveRouter(WETH, ACIMA),
            _chaveQuoter(WETH, ACIMA, zfo),
            "deviam concordar quando a ordenacao calha bem"
        );
    }

    /// @notice O NUCLEO, E TEM DE PASSAR PELO SISTEMA.
    ///
    /// @dev PORQUE ESTE TESTE MUDOU DE ALVO. A primeira versao comparava as
    ///      duas FORMULAS em funcoes puras e ficava vermelha para sempre: as
    ///      formulas nao mudam, o que mudou foi a ORIENTACAO que o registo
    ///      reporta. Um teste que aponta para a costura errada fica vermelho
    ///      mesmo com o defeito corrigido — ja aconteceu hoje no depthBucket.
    ///
    ///      O contrato de orientacao vive no `Hub._readPoolInfo`, que desfaz a
    ///      inversao lendo o bit 6 do Monoslot. E ISSO que se testa: registar
    ///      uma pool nativa cujo outro token ordena ABAIXO do WETH, e exigir
    ///      que o PoolInfo reporte `token0 == WETH` na mesma.
    function test_RegistoReportaWethComoToken0MesmoOrdenandoAbaixo() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0x4444));
        hub.setRoles(address(new RouterWethStub2(WETH)), address(this), address(this));

        // ABAIXO (0x0Bd7...) ordena antes do WETH (0x4200...): o indice fica
        // com token0 = ABAIXO. O PoolInfo tem de reportar o contrario.
        (address idx0, ) = BPC.sortTokens(WETH, ABAIXO);
        assertEq(idx0, ABAIXO, "premissa: o indice ordena o outro token primeiro");

        hub.addV4(address(0), ABAIXO, FEE, TS, address(0));
        PoolInfo[] memory ps = hub.getActivePools(WETH, ABAIXO);
        assertEq(ps.length, 1, "a pool nativa tem de estar registada");
        assertEq(ps[0].kind, BPC.KIND_V4_NATIVE, "e nativa");
        assertEq(
            ps[0].token0, WETH,
            "CONTRATO DE ORIENTACAO: token0 tem de ser o lado wrapped-native"
        );
        assertEq(ps[0].token1, ABAIXO, "e token1 o outro");

        // Com a orientacao restaurada, as duas derivacoes concordam: o Solver
        // calcula zeroForOne = (token0 == tIn), que agora e verdadeiro numa
        // rota WETH->ABAIXO, e o Quoter mapeia o lado certo.
        bool zfo = ps[0].token0 == WETH;
        assertEq(
            _chaveRouter(WETH, ABAIXO),
            _chaveQuoter(WETH, ABAIXO, zfo),
            "com a orientacao correcta as duas derivacoes tem de coincidir"
        );
    }

    /// @notice O caso que ja funcionava tem de continuar a funcionar — sem
    ///         isto, o fix podia ter invertido a orientacao dos pares normais.
    function test_TokenAcimaDoWethContinuaCerto() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0x4444));
        hub.setRoles(address(new RouterWethStub2(WETH)), address(this), address(this));
        hub.addV4(address(0), ACIMA, FEE, TS, address(0));
        PoolInfo[] memory ps = hub.getActivePools(WETH, ACIMA);
        assertEq(ps.length, 1, "registada");
        assertEq(ps[0].token0, WETH, "token0 continua a ser o WETH");
    }

    /// @notice O CONTROLO. Sem isto, "concordam" ficaria verde com duas
    ///         funcoes que devolvessem sempre a mesma constante.
    function test_ChavesDePoolsDiferentesSaoDiferentes() public pure {
        assertTrue(
            _chaveRouter(WETH, ACIMA) != _chaveRouter(WETH, ABAIXO),
            "pools de pares diferentes tem de ter chaves diferentes"
        );
    }
}
