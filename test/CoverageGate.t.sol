// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PORTAO DE COBERTURA — o piso por perna deixa de ser desligavel por calldata.
//
// O DEFEITO. A guarda por perna exigia `leg.expectedOut != 0` para sequer correr:
//
//     bool guard = legOut != address(0) && leg.expectedOut != 0 && leg.amountIn != 0 && amt != 0;
//
// Quem submete a rota desligava o SEU PROPRIO piso escrevendo zero. E nao desligava so um: o
// `attested` que a guarda produz e o mesmo que alimenta o `hopAttested` da Camada 1, logo
// `expectedOut == 0` apagava as DUAS protecoes de uma vez, a local e a agregada. Uma atestacao
// meramente DEFLACIONADA (1 wei) fazia o mesmo por outra via: a guarda corria, mas contra um piso
// de ~zero.
//
// PORQUE NAO E AUTO-DANO. No `swapExactIn` a `Route` vem do integrador, nao do utilizador: o
// utilizador assina `amountIn` e `userMinOut`, o integrador escreve os hops. E nos hops
// INTERMEDIOS de uma bridge nao ha output visivel ao utilizador — o `userMinOut` nao tem analogo
// por hop, e o piso do protocolo so existe no ULTIMO hop.
//
// A FORMA — cobertura, nao substituicao. A medicao in-frame nao substitui a atestacao:
// acrescenta-se-lhe como segundo elemento de um max. Rota honesta cota ~= entregue (cobertura
// ~100%) e nada muda. Rota deflacionada cai para a medicao.
//
// MAX, NAO MIN. Num piso, `min(alegado, medido)` com o alegado deflacionado devolve o deflacionado
// — RELAXA, que e exatamente o ataque. Um desenho anterior enunciou "a medicao ganha" e escolheu
// o operador que garante o contrario; morreu por isso.
//
// COMO ESTE TESTE DISCRIMINA. Um mock que COTA honesto (reservas reais, logo a quote in-frame do
// Router e alta) e PAGA CURTO (transfere uma fraccao do que lhe pedem) — o efeito de um sandwich,
// sem precisar de um. Com a atestacao deflacionada e o piso a assentar na medicao, a entrega curta
// tem de reverter RouterE(5). Sem o portao, o piso vinha da atestacao de 1 wei e passava tudo.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Pool V2 que cota pelas reservas reais mas paga apenas `payBps` do que lhe pedem.
///         E o efeito observavel de um sandwich, sem precisar de montar um: a quote in-frame do
///         Router (calculada das reservas) fica alta, e a entrega medida (delta de balanceOf)
///         fica curta. `payBps = 10_000` reproduz uma pool honesta.
contract ShortPayingV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public payBps = 10_000;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function setPayBps(uint256 b) external { payBps = b; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20Min(token0).transfer(to, (amount0Out * payBps) / 10_000);
        if (amount1Out > 0) IERC20Min(token1).transfer(to, (amount1Out * payBps) / 10_000);
        reserve0 = uint112(IERC20Min(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Min(token1).balanceOf(address(this)));
    }
}

contract CoverageGateTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    ShortPayingV2Pair pair;
    ShortPayingV2Pair pairB;   // a segunda perna: pequena, e a que sangra

    address user      = address(0x5E4);
    address treasury1 = address(0x7451);
    address treasury2 = address(0x7452);

    uint256 constant AMOUNT_IN = 1_000e18;

    function setUp() public {
        hub      = new BlazePhoenixHub(address(this));
        tokenIn  = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair     = new ShortPayingV2Pair(address(tokenIn), address(tokenOut));
        pairB    = new ShortPayingV2Pair(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );

        tokenIn.mint(address(pair), 100_000e18);
        tokenOut.mint(address(pair), 100_000e18);
        pair.setReserves(100_000e18, 100_000e18);
        tokenIn.mint(address(pairB), 100_000e18);
        tokenOut.mint(address(pairB), 100_000e18);
        pairB.setReserves(100_000e18, 100_000e18);

        tokenIn.mint(user, 10_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _route(uint256 expectedOut)
        private view returns (Route memory r)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tokenIn) < address(tokenOut),
            stable: false, amountIn: AMOUNT_IN, expectedOut: expectedOut,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: AMOUNT_IN, expectedOut: expectedOut, legs: legs
        });
        r = Route({
            hops: hops,
            totalOut: expectedOut,
            singleOut: expectedOut,
            singleOutFloor: 0,
            expectedImpactBps: 0,
            confidenceWad: 0,
            estGas: 0,
            hasSurplus: false,
            isV4Bundle: false
        });
    }

    // ── ANTI-REGRESSAO: tem de passar ANTES e DEPOIS do portao ────────────────────────────

    /// Rota honesta, pool honesta: a cobertura da ~100%, o portao nao morde, e o swap liquida
    /// exatamente como sempre liquidou. E este teste que prova que o portao nao criou RIGIDEZ.
    function test_HonestRouteAndHonestPoolStillSettle() public {
        vm.prank(user);
        uint256 out = router.swapExactIn(_route(985e18), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 900e18, "uma rota honesta tem de liquidar como sempre liquidou");
    }

    /// Uma entrega ligeiramente curta continua a passar — o portao NAO aperta a margem que ja
    /// existia. NOTA sobre o numero: 85% NAO passa, e nao e por causa do portao. O piso POR PERNA
    /// e LEG_FLOOR_BPS = 8.000 (80%), mas a Iron Law da ROTA comeca em 96% para um swap limpo de
    /// uma perna e so afrouxa ate 80% com impacto, numero de pernas e volatilidade. Para um swap
    /// destes o vinculativo e o piso da ROTA, nao o da perna — foi exatamente esta confusao que
    /// fez a primeira versao deste teste falhar, e vale a pena deixa-la escrita: o piso por perna
    /// e um limite ADICIONAL, nunca o unico.
    function test_DeliveryAboveFloorStillSettles() public {
        pair.setPayBps(9_800);
        vm.prank(user);
        uint256 out = router.swapExactIn(_route(985e18), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 0, "entrega acima do piso nao pode reverter");
    }

    // ── O NUCLEO: o que o portao fecha ───────────────────────────────────────────────────

    /// ATESTACAO DEFLACIONADA + entrega curta. Com `expectedOut = 1 wei` o piso antigo era ~zero e
    /// qualquer entrega passava. Com o portao, a cobertura (1 wei contra ~988e18 medidos) fica
    /// muito abaixo dos 50% do MIN_QUOTE_COVERAGE_BPS, o piso passa a assentar na medicao, e uma
    /// entrega de 50% reverte.
    function test_DeflatedAttestationCannotDisableTheFloor() public {
        pair.setPayBps(5_000);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        vm.prank(user);
        router.swapExactIn(_route(1), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    /// ATESTACAO ZERO — o opt-out puro. Antes a guarda nem corria (`leg.expectedOut != 0` era
    /// condicao para ela existir), logo a perna sangrava sem limite nenhum e ainda apagava a sua
    /// contribuicao para a Camada 1. Agora corre, porque HA medicao.
    function test_ZeroAttestationCannotDisableTheFloor() public {
        pair.setPayBps(5_000);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        vm.prank(user);
        router.swapExactIn(_route(0), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    /// A atestacao HONESTA continua a mandar quando cobre. Aqui a pool paga curto mas a atestacao
    /// e alta: o piso vem da atestacao (nao do max, que daria o mesmo) e reverte na mesma. O que
    /// este teste fixa e que o portao nao INVERTEU a semantica — quem atesta alto continua preso
    /// ao que atestou.
    function test_HonestAttestationStillBindsOnShortDelivery() public {
        pair.setPayBps(5_000);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        vm.prank(user);
        router.swapExactIn(_route(985e18), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    // ── O TESTE QUE DISCRIMINA MESMO ─────────────────────────────────────────────────────
    //
    // PORQUE OS DE UMA PERNA NAO CHEGAM. Numa rota de uma perna o piso vinculativo e o da ROTA
    // (a Iron Law, 96% para um swap limpo), nao o da PERNA (80%). Um `RouterE(5)` ali vem do
    // agregado, e passaria com o portao removido — foi o que a mutacao mostrou. Um revert com o
    // codigo certo NAO e prova de que a verificacao certa disparou.
    //
    // O CENARIO CERTO e aquele para o qual o piso por perna existe, e o comentario do proprio
    // Router di-lo: "bounding each leg means a single sandwiched pool reverts the swap immediately
    // instead of hiding its loss inside an otherwise healthy total". Duas pernas: uma grande e
    // honesta que carrega o agregado acima do piso da rota, e uma pequena que nao entrega nada.
    // O total sobrevive; a perna nao pode sobreviver.

    function _twoLegRoute(uint256 expectedOutB)
        private view returns (Route memory r)
    {
        uint256 aIn = 980e18;   // 98% do input, honesta — segura o agregado
        uint256 bIn =  20e18;   // 2% do input, e a que sangra

        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tokenIn) < address(tokenOut),
            stable: false, amountIn: aIn, expectedOut: 966e18, auxId: bytes32(0)
        });
        legs[1] = Leg({
            pool: address(pairB), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tokenIn) < address(tokenOut),
            stable: false, amountIn: bIn, expectedOut: expectedOutB, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: AMOUNT_IN, expectedOut: 985e18, legs: legs
        });
        r = Route({
            hops: hops, totalOut: 985e18, singleOut: 985e18, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// ANTI-REGRESSAO: as duas pernas honestas liquidam. Prova que o cenario de duas pernas
    /// funciona e que o portao nao o quebrou.
    function test_TwoHonestLegsSettle() public {
        vm.prank(user);
        uint256 out = router.swapExactIn(_twoLegRoute(19e18), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 900e18, "duas pernas honestas tem de liquidar");
    }

    /// O NUCLEO, e o unico que morre se o portao for removido. A perna B nao entrega NADA e
    /// atesta 1 wei. Sem o portao: o piso da perna vem da atestacao (1 wei -> piso 0), a perna
    /// passa, e o agregado (98% do total) sobrevive a Iron Law da rota. Com o portao: o piso da
    /// perna B assenta na quote MEDIDA in-frame, e uma entrega de zero contra ela reverte.
    function test_BleedingLegHiddenInAHealthyTotalIsCaught() public {
        pairB.setPayBps(0);   // a perna pequena nao entrega nada
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        vm.prank(user);
        router.swapExactIn(_twoLegRoute(1), AMOUNT_IN, 1, user, block.timestamp + 1);
    }
}
