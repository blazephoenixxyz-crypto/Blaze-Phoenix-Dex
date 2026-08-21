// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// JUIZ — A FUGA ESPELHO. A fee ancorada na ENTRADA tem o MESMO buraco que a fee ancorada na
// SAIDA, no outro extremo da rota.
//
// O fix de 2026-08-21 moveu a fee do tokenOut para o tokenIn. Fechou "acrescenta um hop de po
// no FIM". Abriu "acrescenta um hop de po no INICIO".
//
//   fee = 28 bps x (soma dos leg.amountIn do hop 0), em route.hops[0].tokenIn
//
// Ambos os fatores sao ESCOLHIDOS PELO CHAMADOR: o token (hops[0].tokenIn) e a quantidade.
// Quem quiser mover 100k de um token valioso prefixa a rota com um hop a partir de um token
// que ele proprio cunhou, alojado numa pool CPMM normal que ele proprio semeou.
//
// AO CONTRARIO da fuga anterior, esta NAO precisa de desligar piso nenhum: todas as pernas tem
// expectedOut correto, todas as quotes in-frame batem certo, todos os pisos passam. E uma rota
// perfeitamente conforme.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract JudgeFeeEscapeInputSideTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;

    MockERC20 tX;   // token SEM VALOR, cunhado pelo atacante — sera o hops[0].tokenIn
    MockERC20 tU;   // o token VALIOSO que se quer mesmo mover (pensa USDC)
    MockERC20 tW;   // destino (pensa WETH)

    MockV2Pair pairXU;   // pool do atacante: 1.000 tX  <-> 10.000.000 tU
    MockV2Pair pairUW;   // pool real e funda:  5.000.000 tU <-> 5.000.000 tW

    address atacante  = address(0xA77ACE);
    address honesto   = address(0x40E5);
    address treasury1 = address(0x7451);
    address treasury2 = address(0x7452);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tX = new MockERC20("X", "X");
        tU = new MockERC20("U", "U");
        tW = new MockERC20("W", "W");

        pairXU = new MockV2Pair(address(tX), address(tU));
        tX.mint(address(pairXU), 1_000e18);
        tU.mint(address(pairXU), 10_000_000e18);
        pairXU.setReserves(
            address(tX) < address(tU) ? uint112(1_000e18) : uint112(10_000_000e18),
            address(tX) < address(tU) ? uint112(10_000_000e18) : uint112(1_000e18)
        );

        pairUW = new MockV2Pair(address(tU), address(tW));
        tU.mint(address(pairUW), 5_000_000e18);
        tW.mint(address(pairUW), 5_000_000e18);
        pairUW.setReserves(uint112(5_000_000e18), uint112(5_000_000e18));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );

        tX.mint(atacante, 1_000e18);
        vm.prank(atacante);
        tX.approve(address(router), type(uint256).max);

        tU.mint(honesto, 1_000_000e18);
        vm.prank(honesto);
        tU.approve(address(router), type(uint256).max);
    }

    function _outV2(uint256 amtIn, uint256 rIn, uint256 rOut) private pure returns (uint256) {
        uint256 inWithFee = amtIn * 9970;
        return (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
    }

    function _leg(address pool, address inTok, address outTok, uint256 amtIn, uint256 expOut)
        private pure returns (Leg memory)
    {
        return Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: inTok < outTok, stable: false,
            amountIn: amtIn, expectedOut: expOut, auxId: bytes32(0)
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    //  A FUGA: prefixar a rota com um hop a partir de um token sem valor.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_JUIZ_PrefixoSemValorEscapaAFee() public {
        uint256 AMT_X = 10e18;                                   // 10 tX (cunhados, valem 0)
        uint256 qXU = _outV2(AMT_X, 1_000e18, 10_000_000e18);     // ~98.700 tU
        uint256 qUW = _outV2(qXU, 5_000_000e18, 5_000_000e18);

        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(address(pairXU), address(tX), address(tU), AMT_X, qXU);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(address(pairUW), address(tU), address(tW), qXU, qUW);

        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tX), tokenOut: address(tU), amountIn: AMT_X, expectedOut: qXU, legs: l0});
        hops[1] = Hop({tokenIn: address(tU), tokenOut: address(tW), amountIn: qXU, expectedOut: qUW, legs: l1});

        Route memory r = Route({hops: hops, totalOut: qUW, singleOut: qUW, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});

        vm.prank(atacante);
        uint256 got = router.swapExactIn(r, AMT_X, 1, atacante, block.timestamp + 1);

        uint256 feeX = tX.balanceOf(treasury1) + tX.balanceOf(treasury2);
        uint256 feeU = tU.balanceOf(treasury1) + tU.balanceOf(treasury2);
        uint256 feeW = tW.balanceOf(treasury1) + tW.balanceOf(treasury2);

        emit log_named_decimal_uint("tU realmente roteado", qXU, 18);
        emit log_named_decimal_uint("tW entregue ao atacante", got, 18);
        emit log_named_decimal_uint("fee cobrada, em tX (SEM VALOR)", feeX, 18);
        emit log_named_decimal_uint("fee cobrada, em tU", feeU, 18);
        emit log_named_decimal_uint("fee cobrada, em tW", feeW, 18);

        // O que a casa quer provar e FALSO: as tesourarias nao viram um wei de nada com valor.
        // DEPOIS DO FIX (fee no INTERIOR da rota): o prefixo de po deixou de servir de nada.
        // O hop real cobra a taxa cheia no token real, e o hop de po passa a CUSTAR ao atacante
        // em vez de o poupar — 0,028 de lixo para a tesouraria, mais o gas do hop extra.
        assertGt(qXU, 90_000e18, "pre-condicao: moveu-se de facto liquidez a serio");
        assertApproxEqRel(feeU, (qXU * 28) / 10_000, 0.02e18,
            "o hop real tem de pagar a taxa cheia no token que realmente se moveu");
        assertEq(feeW, 0, "e nada e cobrado do lado da saida");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    //  A COMPARACAO: o utilizador honesto que move O MESMO tU paga a serio.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_JUIZ_HonestoPagaAtacanteNao() public {
        uint256 AMT_X = 10e18;
        uint256 qXU = _outV2(AMT_X, 1_000e18, 10_000_000e18);

        // --- honesto: entra com qXU de tU, uma perna, direto ---
        uint256 qUWh = _outV2(qXU, 5_000_000e18, 5_000_000e18);
        Leg[] memory lh = new Leg[](1);
        lh[0] = _leg(address(pairUW), address(tU), address(tW), qXU, qUWh);
        Hop[] memory hh = new Hop[](1);
        hh[0] = Hop({tokenIn: address(tU), tokenOut: address(tW), amountIn: qXU, expectedOut: qUWh, legs: lh});
        Route memory rh = Route({hops: hh, totalOut: qUWh, singleOut: qUWh, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});

        vm.prank(honesto);
        uint256 gotHonesto = router.swapExactIn(rh, qXU, 1, honesto, block.timestamp + 1);
        uint256 feeUHonesto = tU.balanceOf(treasury1) + tU.balanceOf(treasury2);

        emit log_named_decimal_uint("HONESTO: fee paga em tU", feeUHonesto, 18);
        emit log_named_decimal_uint("HONESTO: tW recebido", gotHonesto, 18);

        assertGt(feeUHonesto, 250e18, "o honesto paga ~276 tU de fee");
    }
}
