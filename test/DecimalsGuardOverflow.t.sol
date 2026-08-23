// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, stdError} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract TokenDecimais {
    uint256 private immutable D;
    constructor(uint256 d) { D = d; }
    function decimals() external view returns (uint256) { return D; }
}

/// @notice UM TOKEN NAO PODE ESCOLHER O EXPOENTE QUE NOS REBENTA.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O DEFEITO
/// ─────────────────────────────────────────────────────────────────────────
///  `_decimalsOf` aceitava qualquer `decimals()` abaixo de 256, mas o `to18`
///  calcula `10 ** (dec - 18)` em aritmetica CHECKED. Com `dec >= 96` isso
///  transborda uint256 e da **Panic 0x11**.
///
///  O contrato escrito do Core diz que estas primitivas SATURAM em vez de
///  reverter. Um token com `decimals() = 200` quebrava isso — e o dano nao e
///  academico: o Router chama `_recordHits` DEPOIS de executar as pernas todas
///  e FORA do try/catch, portanto a swap corria por inteiro e revertia no fim.
///  O utilizador pagava o gas todo e nao recebia nada. Custo de montagem do
///  ataque: publicar um ERC-20 que devolve 200 em `decimals()`.
///
///  A cura e uma constante: 10^77 e o maior valor que cabe em uint256, logo
///  qualquer expoente acima de 77 e inutilizavel. Acima disso cai-se no
///  default de 18, que e o mesmo fail-open que a funcao ja usava para um
///  token sem `decimals()`.
contract DecimalsGuardOverflowTest is Test {
    /// @notice A PROVA DE QUE O PERIGO E REAL — sem isto, o teste principal
    ///         podia ficar verde por a aritmetica ser inofensiva.
    function test_To18ComExpoenteGrandeReverteMesmo() public {
        vm.expectRevert(stdError.arithmeticError);
        this.chamaTo18(1e18, 200);
    }
    function chamaTo18(uint256 v, uint8 d) external pure returns (uint256) {
        return BPC.to18(v, d);
    }

    /// @notice O NUCLEO: um token hostil nao consegue entregar esse expoente.
    function test_DecimaisAbsurdosCaemNoDefault() public {
        address t = address(new TokenDecimais(200));
        assertEq(BPC.decimalsOf(t), 18, "decimals() = 200 tem de cair no default 18");
        // E com o valor saneado, o to18 deixa de poder reverter.
        assertEq(BPC.to18(1e18, BPC.decimalsOf(t)), 1e18, "18 casas: identidade");
    }

    /// @notice A FRONTEIRA, dos dois lados. Sem isto, um guarda demasiado
    ///         apertado (por exemplo `lt(v, 19)`) passaria o teste acima e
    ///         partiria em silencio todos os tokens de 24 casas.
    function test_Fronteira77_78() public {
        assertEq(BPC.decimalsOf(address(new TokenDecimais(77))), 77, "77 e utilizavel");
        assertEq(BPC.decimalsOf(address(new TokenDecimais(78))), 18, "78 ja transborda: default");
    }

    /// @notice O CONTROLO dos casos reais — 6, 8 e 18 tem de passar intactos.
    function test_DecimaisNormaisIntactos() public {
        assertEq(BPC.decimalsOf(address(new TokenDecimais(6))),  6,  "USDC");
        assertEq(BPC.decimalsOf(address(new TokenDecimais(8))),  8,  "WBTC");
        assertEq(BPC.decimalsOf(address(new TokenDecimais(18))), 18, "WETH");
        assertEq(BPC.decimalsOf(address(new TokenDecimais(0))),  0,  "0 casas e legitimo");
    }

    /// @notice `decimals() == 255` transbordava o `uint8` do Solver
    ///         (`decimalsOf(tIn) + 1`). Com o guarda, o +1 e sempre seguro.
    function test_SolverPlusUmNaoTransborda() public {
        uint8 d = BPC.decimalsOf(address(new TokenDecimais(255)));
        assertEq(d, 18, "255 cai no default");
        assertEq(uint8(d + 1), 19, "o +1 do Solver nao transborda");
    }
}
