// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// E3 — UMA DOACAO NAO PODE COMPRAR FATIA DO SPLIT.
//
// O fix T2 (Thomas) enuncia a doutrina, e esta escrita no Solver: "ancora na profundidade MEDIDA,
// NUNCA no balanceOf cru — uma doacao (uma simples transferencia para a pool) infla-o SEM mover a
// reserva nem o preco, e a doacao e recuperavel (skim do V2 / claim de LP no V3), logo NAO e
// capital em risco".
//
// Foi aplicado a ancora da BANDA. Nao foi aplicado ao PESO que decide a FATIA de cada perna no
// split: quando o conjunto cruzava familias e todos tinham saldo, o peso passava a ser
// `balanceOf(tokenOut, pool)` — uma ancora de saldo cru, exatamente o que a doutrina proibe.
// Assinatura de defeito da casa: um fix aplicado a UM de dois canais que fazem a MESMA pergunta
// relativa ("qual destas pools merece mais?").
//
// O QUE ESTE TESTE FIXA: doar tokenOut a uma pool NAO pode mudar a fatia que ela recebe. Uma
// doacao nao move `getReserves` nem `getLiquidity`; se o peso vier da profundidade medida, o
// split e identico antes e depois.
//
// NOTA sobre o canal irmao que NAO mudou: o teto de capacidade tambem le `balanceOf` e continua a
// le-lo, de proposito. La a pergunta e FISICA ("consegue pagar isto?") e uma doacao sobe
// genuinamente o que a pool paga — os tokens doados sao consumidos no pagamento ao utilizador.
// Ler a mesma grandeza nao implica fazer a mesma pergunta, e foi um red-first que o provou:
// trocar tambem esse por profundidade tornou o teto MAIS FROUXO, porque para uma pool V3 a
// reserva virtual derivada de L e muito maior que as existencias fisicas.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract DonationCannotSteerSplitTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair funda;    // a pool honesta e funda
    MockV2Pair fina;     // a pool fina do atacante

    uint256 constant ORDER = 10_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        hub.setRoles(address(this), address(solver), address(this));

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");

        funda = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(funda), 1_000_000e18);
        tB.mint(address(funda), 1_000_000e18);
        funda.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));

        fina = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(fina), 50_000e18);
        tB.mint(address(fina), 50_000e18);
        fina.setReserves(uint112(50_000e18), uint112(50_000e18));

        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(funda), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, 1_000_000e18);
            hub.recordSwap(address(fina), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, 50_000e18);
        }
    }

    function _fatiaDaFina() private view returns (uint256 fatia, uint256 total) {
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        if (p.best.hops.length == 0) return (0, 0);
        Leg[] memory legs = p.best.hops[0].legs;
        for (uint256 i; i < legs.length; i++) {
            total += legs[i].amountIn;
            if (legs[i].pool == address(fina)) fatia = legs[i].amountIn;
        }
    }

    /// A PROVA. A doacao e enorme — 20x o que a pool fina tem — e nao pode comprar nada.
    function test_DoacaoNaoCompraFatiaDoSplit() public {
        (uint256 antes, uint256 totalAntes) = _fatiaDaFina();
        assertGt(totalAntes, 0, "pre-condicao: tem de haver rota");

        // O atacante doa tokenOut a sua pool fina. `getReserves` NAO se mexe — e por isso que a
        // doacao e gratuita para ele: pode fazer skim depois.
        tB.mint(address(fina), 1_000_000e18);

        (uint256 depois, uint256 totalDepois) = _fatiaDaFina();
        assertEq(totalDepois, totalAntes, "o total comprometido nao pode mudar");
        assertEq(depois, antes, "a doacao comprou fatia do split");
    }

    /// CONTROLO, para que o teste acima nao passe por a pool fina nunca entrar no plano: mexer nas
    /// RESERVAS a serio (capital em risco de verdade) TEM de mudar a fatia.
    function test_CapitalARiscoMudaAFatia() public {
        (uint256 antes, ) = _fatiaDaFina();
        // Desta vez sobe as reservas SINCRONIZADAS: isto e capital que move o preco e nao se
        // recupera com um skim.
        tA.mint(address(fina), 950_000e18);
        tB.mint(address(fina), 950_000e18);
        fina.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
        for (uint256 i; i < 3; i++) {
            hub.recordSwap(address(fina), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, 1_000_000e18);
        }
        (uint256 depois, ) = _fatiaDaFina();
        assertGt(depois, antes, "capital REAL tem de mudar a fatia, senao o peso nao mede nada");
    }
}
