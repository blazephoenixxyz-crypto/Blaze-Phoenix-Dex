// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// E2 — A BIJECAO WETH <-> address(0), TESTADA NA PRIMITIVA E NAO SO NOS SEUS CONSUMIDORES.
//
// A substituicao vivia escrita a mao em DOIS sitios do Router (o braco de cotacao e o de
// execucao) e o comentario de um deles JURAVA que "cannot diverge" — sem mecanismo nenhum que o
// garantisse. Se divergissem, os dois lados derivavam poolIds DIFERENTES e a promessa de que
// "cotar e executar leem a MESMA pool" caia em silencio.
//
// PORQUE ESTE FICHEIRO EXISTE, e a licao e do guarda de mutacao: o primeiro mutante desta
// primitiva (estragar o ramo `tokenOther == weth`) passou VERDE, porque o teste que eu tinha
// escolhido para o vigiar so exercitava a orientacao contraria. Testar a primitiva atraves de um
// consumidor so cobre os caminhos que ESSE consumidor toma.
//
// AS QUATRO SAIDAS, uma a uma. E o `(0,0)` de falha nao e um detalhe: e o que torna o esquecimento
// impossivel. Em Solidity `(a, b, ) = f(...)` compila SEM AVISO, portanto um terceiro valor `ok`
// seria algo que se pode ignorar — e se o valor de falha fosse utilizavel, quem o ignorasse
// construia a chave do pool ERC20 em vez da nativa e lia um numero valido do sitio errado. Com
// `(0,0)`, a chave e IMPOSSIVEL (o V4 exige currency0 < currency1) e falha fechada sozinha.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract NativeMapPrimitiveTest is Test {
    address constant W = address(0xEEEE);
    address constant T = address(0xAAAA);
    address constant U = address(0xBBBB);

    /// tokenIn e o WETH: substitui-se o PRIMEIRO.
    function test_LadoDaEntrada() public pure {
        (address a, address b) = BPC.nativeMapVerified(W, T, W);
        assertEq(a, address(0), "o lado WETH tem de virar address(0)");
        assertEq(b, T,          "o outro lado fica intacto");
    }

    /// tokenOther e o WETH: substitui-se o SEGUNDO. E a orientacao que o primeiro mutante
    /// atravessou sem ser apanhado.
    function test_LadoDoOutro() public pure {
        (address a, address b) = BPC.nativeMapVerified(T, W, W);
        assertEq(a, T,          "o outro lado fica intacto");
        assertEq(b, address(0), "o lado WETH tem de virar address(0)");
    }

    /// NENHUM dos dois e o WETH: par degenerado, nao o par original.
    function test_NenhumEWeth_ParDegenerado() public pure {
        (address a, address b) = BPC.nativeMapVerified(T, U, W);
        assertEq(a, address(0), "falha tem de devolver (0,0), nunca o par utilizavel");
        assertEq(b, address(0), "idem");
    }

    /// WETH nao cablado: mesma falha degenerada.
    function test_WethNaoCablado_ParDegenerado() public pure {
        (address a, address b) = BPC.nativeMapVerified(T, U, address(0));
        assertEq(a, address(0), "sem weth nao ha mapeamento possivel");
        assertEq(b, address(0), "idem");
    }

    /// A PROPRIEDADE QUE TORNA O `ok` DESNECESSARIO: num sucesso, EXATAMENTE UM dos dois e zero.
    /// Numa falha, os DOIS sao. Logo `a == 0 && b == 0` distingue-os sem ambiguidade — e essa
    /// combinacao e uma chave V4 impossivel, portanto quem nem sequer testar falha fechado.
    function test_FalhaEAutoIdentificavelEImpossivelComoChave() public pure {
        (address a1, address b1) = BPC.nativeMapVerified(W, T, W);
        assertFalse(a1 == address(0) && b1 == address(0), "sucesso nunca devolve (0,0)");
        (address a2, address b2) = BPC.nativeMapVerified(T, W, W);
        assertFalse(a2 == address(0) && b2 == address(0), "sucesso nunca devolve (0,0)");
        (address a3, address b3) = BPC.nativeMapVerified(T, U, W);
        assertTrue(a3 == address(0) && b3 == address(0), "falha devolve sempre (0,0)");
    }
}
