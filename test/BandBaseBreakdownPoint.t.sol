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
//
// Since the measured rival (`BlazePhoenixMath._measuredAbove`), a row the contract measures itself
// (a vouched pair, a bare concentrated pool) is never dropped from above: it is quoted at the whole
// order, so it can only add output. The upper edge still judges every row it only models. The
// attacks above the fair rate therefore sit on a hooked V4 book (listed hook: it votes, it is not
// measured), and a measured twin pins what the rule says for the same pair.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract BandBaseBreakdownPointTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair h1;
    MockV2Pair h2;
    MockV2Pair h3;
    MockV2Pair atacante;
    /// The modelled attacker: a hooked V4 book's row (its pool id as an address).
    address livro;
    MockV4TickManager mgr;
    address constant HOOK = address(uint160(0x1000));

    // ORDEM GRANDE de proposito. Com impacto minusculo o Solver escolhe UMA perna, e o caminho
    // single-leg NAO passa pela banda — o teste nunca exercitava o que diz testar. Foi o guarda de
    // mutacao que o revelou: passava com o estimador mutado.
    uint256 constant ORDER = 300_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        mgr = new MockV4TickManager();
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");

        // TRES pools honestas ao preco justo 1:1, cada uma com 400k de massa.
        h1 = _pool(400_000e18, 400_000e18);
        h2 = _pool(400_000e18, 400_000e18);
        h3 = _pool(400_000e18, 400_000e18);
    }

    function _pool(uint112 rA, uint112 rB) private returns (MockV2Pair p) {
        p = _poolOn(tA, tB, rA, rB);
    }

    function _poolOn(MockERC20 x, MockERC20 y, uint112 rA, uint112 rB) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), rA);
        y.mint(address(p), rB);
        // reserves in the pair's own token order, so each side reports what it holds
        (uint112 r0, uint112 r1) = p.token0() == address(x) ? (rA, rB) : (rB, rA);
        p.setReserves(r0, r1);
        // rizki-3107: the swap door seats only a pool a wired factory derives; each pool is
        // born in its own V2 factory, honest or not. Every row is then listed, so every row
        // votes, as before the fix (when none was listed and the vote was not muted at all).
        Origin.wire(hub, address(p), address(x), address(y), BPC.KIND_V2, 30);
        for (uint256 i; i < 4; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(x), address(y), 1e18, 1e18, rA < rB ? rA : rB);
        }
    }

    /// A full-range V4 book behind the listed hook HOOK, 0.3% like the pairs, priced at `tickC0`
    /// (token1 per token0 = 1.0001^tick). The hub lists the hook, so the book votes its held
    /// tokenOut; the contract does not measure a hooked book, so the upper edge judges it.
    /// Returns its row and the vote it carries for `tIn` -> the other token.
    function _book(address tIn, address tOut, int24 tickC0, int24 ts, uint128 liq)
        private returns (address row, uint256 vote)
    {
        (address c0, address c1) = tIn < tOut ? (tIn, tOut) : (tOut, tIn);
        MockERC20(c0).mint(address(mgr), 1e30);
        MockERC20(c1).mint(address(mgr), 1e30);
        hub.allowHook(HOOK, true);
        bytes32 pid = BPC.computeV4PoolId(c0, c1, 3000, ts, HOOK);
        uint160 sp = mgr.sqrtAt(tickC0);
        mgr.initialize(pid, sp, tickC0, 3000);
        mgr.addPosition(pid, -887220, 887220, ts, liq);
        hub.addV4(c0, c1, 3000, ts, HOOK);
        row = address(uint160(uint256(pid)));
        bool zfo = tIn == c0;
        vote = BPC.v4HeldShare(address(mgr), pid, ts, zfo, BPC.outSide18(liq, sp, zfo, 18), 0);
    }

    /// The attacker's book at 2 tB per tA holding `mass` of tB: full range, L = mass / sqrt(2).
    function _bookAtTwo(uint256 mass) private returns (uint256 vote) {
        int24 tick = address(tA) < address(tB) ? int24(6931) : int24(-6932);
        (livro, vote) = _book(address(tA), address(tB), tick, 60, uint128(mass * 1e9 / 1_414_213_562));
        assertApproxEqRel(vote, mass, 1e15, "pre-condition: the book votes the tB it holds");
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
        for (uint256 i; i < legs.length; i++) {
            if (legs[i].pool == address(atacante) || (livro != address(0) && legs[i].pool == livro)) onAttacker++;
        }
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
    /// History (2026-11-24): the pool was a V2 pair (300k A, 600k B). Since the measured rival
    /// (`_measuredAbove`) a pair the contract measures above the base is kept, so the claim stands
    /// on a row it only models: a hooked V4 book at the same rate holding the same 600k B. The pair
    /// is pinned by `test_ADeepMeasuredPairAboveTheFairRate_IsKeptBesideTheHonestPools`.
    function test_ADeepPoolAboveTheFairRate_CannotCaptureTheBand() public {
        _bookAtTwo(600_000e18);

        _assertBandHolds("a pool far above the fair rate is outside the band",
            "one deep pool cannot push the honest pools out of the band");
    }

    /// The breakdown point from below: a pool above the fair rate holding just short of half the
    /// mass. A book's mass is the tokenOut it holds (`Core.hopMass18`, MAT-02), so it weighs 1.15M
    /// against the honest 1.2M (48.9%); the walk up the sorted rates reaches half the mass
    /// (1.175M) on the third honest pool, and the base stays honest. Together with
    /// `test_MaioriaDaMassaMandaMesmo` this brackets the 50%.
    /// History: until 2026-11-10 the pool was (1.15M A, 2.3M B) and weighed its short side, a
    /// count of A. Counted in B, the token the others are counted in, it held 65.7% of the mass:
    /// a majority, the other side of the bracket. Same rate, same 48.9%, in the one unit.
    /// History (2026-11-24): the pool was the V2 pair (575k A, 1.15M B); it is now a hooked V4
    /// book at the same rate holding the same 1.15M B, for the reason in the test above. The pair
    /// is pinned by `test_JustShortOfHalf_AMeasuredPairAboveTheFairRate_IsKeptBesideTheHonestPools`.
    function test_JustShortOfHalfTheMass_AboveTheFairRate_CannotCaptureTheBand() public {
        _bookAtTwo(1_150_000e18);

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
    /// History (2026-11-24): the honest market was the three V2 pairs of setUp (400k each at 1:1).
    /// Since the measured rival (`_measuredAbove`) a pair the contract measures above the base is
    /// kept, so they stayed beside the majority base and carried the order (pinned by
    /// `test_TheMassMajority_MeasuredPairsAboveItStillCarryTheOrder`). The honest market is now three
    /// hooked V4 books at 1:1 holding the same 400k each, on a pair of its own (the setUp pairs are
    /// measured and would stay). The books were listed over an hour before the quote: three fresh
    /// curated rows switch the discovery sweep off (`Solver._registryFresh`), then no sweep vouches
    /// the majority pair and its vote is muted (`Math._mutedVotes`, bounty #85). A test of who holds
    /// the mass first lets the mass vote: the pre-conditions below say so.
    function test_MaioriaDaMassaMandaMesmo() public {
        MockERC20 c = new MockERC20("C", "C");
        MockERC20 d = new MockERC20("D", "D");
        atacante = _poolOn(c, d, uint112(5_000_000e18), uint112(2_500_000e18));   // >50% da massa
        (address t0, address t1) = address(c) < address(d) ? (address(c), address(d)) : (address(d), address(c));
        address[3] memory books;
        uint256 honestVotes;
        for (uint256 k; k < 3; k++) {
            uint256 vote;
            // three distinct books (the spacing is in the pool id), each full range at 1:1
            (books[k], vote) = _book(address(c), address(d), 0, [int24(60), int24(30), int24(20)][k], 400_000e18);
            assertApproxEqRel(vote, 400_000e18, 1e15, "pre-condition: each honest book votes the 400k D it holds");
            honestVotes += vote;
        }
        (uint112 r0, uint112 r1,) = atacante.getReserves();
        assertGt(t0 == address(d) ? r0 : r1, honestVotes, "pre-condition: the pair holds more than half the mass");
        // The books' rows age past the discovery TTL (`Solver.DISCOVERY_TTL_SECONDS`, 3600 s): the
        // sweep runs, finds the factory-born pair and vouches for it, so its mass votes.
        vm.warp(block.timestamp + 3601);
        for (uint256 k; k < 3; k++) {
            uint256 seen = BPC.decodeLastUpdateTs(hub.getSlot(BPC.pairKey(books[k], t0, t1)));
            assertGt(seen, 0, "pre-condition: the book's row is listed");
            assertGt(block.timestamp - seen, 3600, "pre-condition: no fresh curated row switches the sweep off");
        }

        // Nao usa o helper: aqui a rota NAO tem de dividir. Quem detem a maioria da massa e o
        // mercado, a banda centra-se nele, e o Solver comprometer tudo numa perna e o resultado
        // CERTO — nao um vacuo.
        RoutePlan memory p = solver.findBestRoutePlan(address(c), address(d), ORDER);
        assertGt(p.best.hops.length, 0, "pre-condicao: tem de haver rota");
        Leg[] memory legs = p.best.hops[0].legs;
        assertGt(legs.length, 0, "pre-condicao: tem de haver pernas");
        bool viuAtacante;
        for (uint256 i; i < legs.length; i++) if (legs[i].pool == address(atacante)) viuAtacante = true;
        assertTrue(viuAtacante, "quem detem a maioria da massa define o mercado, por definicao");
    }

    /// The measured twin of the deep pool above the fair rate: the same pair (300k A, 600k B) as a
    /// vouched V2 pair. The contract measures it, so it is not dropped from above: it is quoted at
    /// the whole order and takes a leg. The honest pools keep theirs (a captured base would drop
    /// them from below), and the order's output does not fall below the honest pools' alone.
    function test_ADeepMeasuredPairAboveTheFairRate_IsKeptBesideTheHonestPools() public {
        _assertMeasuredRivalKept(300_000e18, 600_000e18, true);
    }

    /// The measured twin of the pool just short of half the mass (575k A, 1.15M B). Measured and
    /// kept, it pays twice the honest rate over the whole order, so the order may rightly sit on it
    /// alone: the twin pins that it is kept and that the output does not fall, not a split.
    function test_JustShortOfHalf_AMeasuredPairAboveTheFairRate_IsKeptBesideTheHonestPools() public {
        _assertMeasuredRivalKept(575_000e18, 1_150_000e18, false);
    }

    /// The measured twin of the majority: the same pool (5M A, 2.5M B) holds the base, and the three
    /// honest V2 pairs at 1:1 sit above it. They are measured, so they stay: they carry the order,
    /// and the output does not fall below what they gave alone.
    function test_TheMassMajority_MeasuredPairsAboveItStillCarryTheOrder() public {
        uint256 honestOnly = solver.findBestRoutePlan(address(tA), address(tB), ORDER).best.totalOut;
        atacante = _pool(uint112(5_000_000e18), uint112(2_500_000e18));
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertGt(p.best.hops.length, 0, "pre-condition: there must be a route");
        Leg[] memory legs = p.best.hops[0].legs;
        uint256 honest;
        for (uint256 i; i < legs.length; i++) if (legs[i].pool != address(atacante)) honest++;
        assertGt(honest, 0, "measured pairs above a majority base were dropped from above");
        assertGe(p.best.totalOut, honestOnly, "a majority base cost the order the honest pairs");
    }

    /// `split`: the pair is shallow enough that the honest pools must keep legs beside it.
    function _assertMeasuredRivalKept(uint112 rA, uint112 rB, bool split) private {
        uint256 honestOnly = solver.findBestRoutePlan(address(tA), address(tB), ORDER).best.totalOut;
        atacante = _pool(rA, rB);
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertGt(p.best.hops.length, 0, "pre-condition: there must be a route");
        Leg[] memory legs = p.best.hops[0].legs;
        uint256 onPair;
        for (uint256 i; i < legs.length; i++) if (legs[i].pool == address(atacante)) onPair++;
        assertGt(onPair, 0, "a measured pair above the base was dropped from above");
        if (split) assertGt(legs.length - onPair, 0, "the honest pools lost the band: the base was captured");
        assertGe(p.best.totalOut, honestOnly,
            "a measured pair above the base lowered the order's output");
    }
}
