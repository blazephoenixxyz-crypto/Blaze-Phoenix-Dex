// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// E4 — A BASE DA BANDA TINHA PONTO DE RUTURA ZERO.
//
// A banda de +-4% e o filtro que decide QUE POOLS entram no split. O seu centro era o rate da
// UNICA pool mais funda. Em estatistica robusta isso e um estimador com ponto de rutura ZERO:
// basta UM sensor forjado — a pool mais funda — para capturar o centro inteiro e expulsar as
// honestas para fora da banda.
//
// O proprio codigo confessava a fraqueza a poucas linhas: "active-tick L is cheap to inflate with
// a one-spacing position... does NOT make it impossible... deferred". E havia um facto errado
// escrito: o comentario do MEDIAN_FILTER_BPS justificava a seguranca com "para mover a mediana, um
// atacante tem de mover mais de metade das pools" quando a base ja NAO era a mediana.
//
// AGORA e a mediana PONDERADA PELA MASSA DE PROFUNDIDADE. Para capturar a base, o atacante deixa
// de precisar de out-depth UMA pool e passa a precisar de mais de METADE da massa do conjunto.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract BandBaseBreakdownPointTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair h1;
    MockV2Pair h2;
    MockV2Pair h3;
    MockV2Pair atacante;

    // ORDEM GRANDE de proposito. Com impacto minusculo o Solver escolhe UMA perna, e o caminho
    // single-leg NAO passa pela banda — o teste nunca exercitava o que diz testar. Foi o guarda de
    // mutacao que o revelou: passava com o estimador mutado.
    uint256 constant ORDER = 300_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        hub.setRoles(address(this), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");

        // TRES pools honestas ao preco justo 1:1, cada uma com 400k de massa.
        h1 = _pool(400_000e18, 400_000e18);
        h2 = _pool(400_000e18, 400_000e18);
        h3 = _pool(400_000e18, 400_000e18);
    }

    function _pool(uint112 rA, uint112 rB) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), rA);
        tB.mint(address(p), rB);
        // reserves in the pair's own token order, so each side reports what it holds
        (uint112 r0, uint112 r1) = p.token0() == address(tA) ? (rA, rB) : (rB, rA);
        p.setReserves(r0, r1);
        for (uint256 i; i < 4; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, rA < rB ? rA : rB);
        }
    }

    function _pools() private returns (uint256 nHonestas, uint256 nAtacante) {
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertGt(p.best.hops.length, 0, "pre-condicao: tem de haver rota");
        Leg[] memory legs = p.best.hops[0].legs;
        // PRE-CONDICAO QUE IMPEDE O VACUO: sem split nao ha banda a testar.
        assertGe(legs.length, 2, "pre-condicao: a rota TEM de dividir, senao a banda nao decide nada");
        for (uint256 i; i < legs.length; i++) {
            if (legs[i].pool == address(atacante)) nAtacante++;
            else nHonestas++;
        }
    }

    /// The band's own claim checked FIRST, the split precondition after it. A captured base
    /// leaves one leg, on the attacker; with the precondition first the test would die on
    /// "the route must split" and never say which guard failed (masking, axis M).
    function _assertBandHolds(string memory onAttackerMsg, string memory honestMsg) private {
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertGt(p.best.hops.length, 0, "pre-condition: there must be a route");
        Leg[] memory legs = p.best.hops[0].legs;
        uint256 onAttacker;
        for (uint256 i; i < legs.length; i++) if (legs[i].pool == address(atacante)) onAttacker++;
        assertEq(onAttacker, 0, onAttackerMsg);
        assertGt(legs.length - onAttacker, 0, honestMsg);
        assertGe(legs.length, 2, "pre-condition: the route must split, or the band decides nothing");
    }

    /// A PROVA. Uma pool com preco MAU (1:0,5 — metade do justo) e mais funda que QUALQUER honesta
    /// isolada, mas com menos de metade da massa total. Com o estimador antigo capturava a base e
    /// expulsava as tres honestas; com a mediana ponderada nao chega perto.
    function test_UmaPoolFundaNaoCapturaABanda() public {
        // 600k de massa contra 1.2M das tres honestas juntas: e a mais funda de todas
        // individualmente, e mesmo assim minoria.
        atacante = _pool(600_000e18, 300_000e18);   // preco 1:0,5, muito fora do justo

        (uint256 honestas, uint256 daAtacante) = _pools();
        assertGt(honestas, 0, "as pools honestas nao podem ser expulsas por UMA pool funda");
        assertEq(daAtacante, 0, "a pool de preco mau nao pode entrar no split");
    }

    /// The same deep minority pool on the other side of fair: it holds what it reports and
    /// quotes 1 tA for 2 tB, the highest rate on the pair. The base follows the weighted
    /// median of the mass, not the highest rate, so the honest pools keep the band.
    function test_ADeepPoolAboveTheFairRate_CannotCaptureTheBand() public {
        atacante = _pool(300_000e18, 600_000e18);

        _assertBandHolds("a pool far above the fair rate is outside the band",
            "one deep pool cannot push the honest pools out of the band");
    }

    /// The breakdown point from below: a pool above the fair rate holding just short of half the
    /// mass. V2 depth is the short side, so it weighs 1.15M against the honest 1.2M (48.9%); the
    /// walk up the sorted rates reaches half the mass (1.175M) on the third honest pool, and the
    /// base stays honest. Together with `test_MaioriaDaMassaMandaMesmo` this brackets the 50%.
    function test_JustShortOfHalfTheMass_AboveTheFairRate_CannotCaptureTheBand() public {
        atacante = _pool(1_150_000e18, 2_300_000e18);

        _assertBandHolds("a minority of the mass does not set the base, however close to half",
            "a pool short of half the mass cannot push the honest pools out");
    }

    /// CONTROLO: sem ela, o teste acima passaria mesmo que o Solver nunca escolhesse ninguem.
    function test_SemAtacanteAsHonestasEntram() public view {
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertGt(p.best.hops.length, 0, "pre-condicao: tem de haver rota");
        assertGt(p.best.hops[0].legs.length, 0, "pre-condicao: tem de haver pernas");
    }

    /// E O LIMITE HONESTO: quem detem MAIS de metade da massa E o mercado, e a base segue-o. Nao e
    /// um bug — e a definicao de mediana ponderada, e tem de estar escrita como teste.
    function test_MaioriaDaMassaMandaMesmo() public {
        atacante = _pool(uint112(5_000_000e18), uint112(2_500_000e18));   // >50% da massa

        // Nao usa o helper: aqui a rota NAO tem de dividir. Quem detem a maioria da massa e o
        // mercado, a banda centra-se nele, e o Solver comprometer tudo numa perna e o resultado
        // CERTO — nao um vacuo.
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertGt(p.best.hops.length, 0, "pre-condicao: tem de haver rota");
        Leg[] memory legs = p.best.hops[0].legs;
        assertGt(legs.length, 0, "pre-condicao: tem de haver pernas");
        bool viuAtacante;
        for (uint256 i; i < legs.length; i++) if (legs[i].pool == address(atacante)) viuAtacante = true;
        assertTrue(viuAtacante, "quem detem a maioria da massa define o mercado, por definicao");
    }
}
