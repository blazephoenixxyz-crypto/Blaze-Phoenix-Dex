// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  RED-FIRST — o gemeo AO NIVEL DA PERNA do R3/BP-15.
//
//  O R3/BP-15 fechou o ataque ao nivel do HOP: continuidade
//  (hop.tokenIn == hops[h-1].tokenOut, senao RouterE(3)) mais exclusao de saldo
//  estrangeiro (foreignBase subtraido antes de reescalar). Ver
//  test/HardeningR3_HopForeignBalance.t.sol.
//
//  A HIPOTESE QUE ESTE FICHEIRO TESTA: o canal irmao — o clamp da ULTIMA PERNA
//  em BlazePhoenixRouter._execute — nao recebeu nenhuma das duas metades.
//
//    Router:1032-1035   remaining = BPC.balanceOf(legIn, address(this));
//                       if (remaining < scaledAmt) scaledAmt = remaining;
//    Router:1420-1428   _legTokens deriva legIn de token0Of/token1Of da POOL
//                       indicada no calldata — e o docstring declara a
//                       divergencia deliberada ("bridge collapsing").
//    Router:1017        so trata o caso V4 (legIn == address(0)).
//
//  Nenhuma linha exige legIn == hop.tokenIn, e o clamp nao subtrai baseline
//  nenhuma. Um hop UNICO (h == 0, onde a continuidade nem se aplica) cuja
//  unica perna nomeia uma pool de um par DIFERENTE poe legIn = token parado.
//
//  Se a hipotese estiver certa, este teste fica VERMELHO: o saldo parado de T
//  — dinheiro do caminho de resgate de 48h — sai do Router para a pool da rota
//  e volta ao chamador convertido em B.
//
//  forge test --match-contract LegDivergentStrandedDrain -vv
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract LegDivergentStrandedDrainTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 A; // tokenIn declarado da rota
    MockERC20 B; // tokenOut da rota
    MockERC20 T; // token PARADO no Router, a espera do resgate de 48h

    MockV2Pair pAB; // par honesto A/B — o que um hop A->B deveria usar
    MockV2Pair pTB; // par T/B — o que a perna divergente nomeia

    address user      = makeAddr("user");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    uint112 constant RESERVE  = 1e30;
    uint256 constant LIQ      = 1e30;
    uint256 constant AMT      = 1_000e18; // ordem do atacante
    uint256 constant STRANDED =   100e18; // < legAmt, para o clamp levar TUDO

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        T = new MockERC20("T", "T");

        pAB = new MockV2Pair(address(A), address(B));
        pTB = new MockV2Pair(address(T), address(B));
        pAB.setReserves(RESERVE, RESERVE);
        pTB.setReserves(RESERVE, RESERVE);

        A.mint(user, 10 * AMT);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function _leg(address pool, address tin, uint256 amt, uint256 quoted)
        internal view returns (Leg memory l)
    {
        l = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: tin == MockV2Pair(pool).token0(), stable: false,
            amountIn: amt, expectedOut: quoted, auxId: bytes32(0)
        });
    }

    function _route1(Hop memory h, uint256 quoted) internal pure returns (Route memory r) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = h;
        r = Route({
            hops: hops, totalOut: quoted, singleOut: quoted, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// CONTROLO: a mesma forma, mas com a perna a nomear o par HONESTO A/B.
    /// Serve para provar que o arreio do teste executa um swap normal — se este
    /// falhar, o teste de ataque nao prova nada.
    function test_Control_HonestSingleHopFills() public {
        B.mint(address(pAB), LIQ);
        Hop memory h = Hop({
            tokenIn: address(A), tokenOut: address(B),
            amountIn: AMT, expectedOut: 0,
            legs: _oneLeg(_leg(address(pAB), address(A), AMT, 0))
        });
        Route memory r = _route1(h, 0);

        uint256 before_ = B.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(B.balanceOf(user) - before_, 0, "controlo: o swap honesto tem de encher");
    }

    /// O ATAQUE. Hop unico A -> B (h == 0: a guarda de continuidade do R3 nem
    /// se aplica). A unica perna nomeia pTB, logo _legTokens devolve
    /// legIn = T != hop.tokenIn = A. O clamp da ultima perna le
    /// balanceOf(T, router) SEM baseline e entrega o saldo parado inteiro.
    function test_DivergentLegIn_DrainsStrandedBalance() public {
        T.mint(address(router), STRANDED); // dinheiro do caminho de resgate
        B.mint(address(pTB), LIQ);         // a pool do atacante pode pagar
        assertEq(T.balanceOf(address(router)), STRANDED, "setup: T parado no Router");

        // leg.amountIn ENORME: garante legAmt > STRANDED para o clamp morder.
        Hop memory h = Hop({
            tokenIn: address(A), tokenOut: address(B),
            amountIn: AMT, expectedOut: 0,
            legs: _oneLeg(_leg(address(pTB), address(T), AMT, 0))
        });
        Route memory r = _route1(h, 0);

        // FIX (2026-08-23): a perna tem de negociar o par do hop. `legIn = T`
        // diverge de `hop.tokenIn = A`, logo o Router recusa a rota inteira
        // ANTES de mover um wei — nao a executa e depois compensa.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        vm.prank(user);
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        // ── A INVARIANTE QUE TEM DE VALER ──
        // O saldo parado de T nao pertence a este swap. Nem um wei dele pode
        // sair do Router, seja para a pool seja para o chamador.
        assertEq(
            T.balanceOf(address(router)), STRANDED,
            "o saldo parado de T foi gasto por um swap que nao o possui"
        );
        assertEq(
            T.balanceOf(address(pTB)), 0,
            "o T parado acabou na pool nomeada pela rota"
        );
    }

    /// O ATAQUE AFINADO. A variante acima reverte RouterE(5) porque sobredimensionar
    /// a perna cria uma divergencia entre a quote (calculada sobre legAmt) e a
    /// entrega (feita sobre o valor POS-clamp) — e a Camada 1 apanha essa
    /// divergencia. Um atacante nao faz isso: dimensiona leg.amountIn para o
    /// saldo parado que ja observou (queueRescue emite RescueQueued, e o saldo
    /// le-se on-chain), de modo que o clamp nunca morde e quote == entrega.
    /// Se ISTO drenar, o achado esta confirmado; se reverter, esta refutado.
    function test_DivergentLegIn_SizedToStranded_DrainsWithoutTrippingCamada1() public {
        T.mint(address(router), STRANDED);
        B.mint(address(pTB), LIQ);

        // leg.amountIn == STRANDED: com scaleNum/scaleDen <= 1, legAmt <= STRANDED,
        // logo o clamp nao dispara e a perna executa exatamente o que foi cotado.
        Hop memory h = Hop({
            tokenIn: address(A), tokenOut: address(B),
            amountIn: AMT, expectedOut: 0,
            legs: _oneLeg(_leg(address(pTB), address(T), STRANDED, 0))
        });
        Route memory r = _route1(h, 0);

        // FIX: o dimensionamento exacto era o que evadia a Camada 1 — deixou de
        // importar. A guarda e de ADMISSAO da rota, nao de deteccao de perda:
        // nenhuma escolha de `leg.amountIn` a contorna.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        vm.prank(user);
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);

        console2.log("T no Router (intacto):", T.balanceOf(address(router)));
        console2.log("T na pool do atacante:", T.balanceOf(address(pTB)));

        assertEq(
            T.balanceOf(address(router)), STRANDED,
            "saldo parado de T gasto por um swap que nao o possui"
        );
        assertEq(
            T.balanceOf(address(pTB)), 0,
            "o T parado acabou na pool nomeada pela rota"
        );
    }

    function _oneLeg(Leg memory l) internal pure returns (Leg[] memory ls) {
        ls = new Leg[](1);
        ls[0] = l;
    }
}
