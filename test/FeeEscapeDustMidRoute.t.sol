// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice PO NO MEIO DA ROTA NAO PODE EVADIR A FEE.
///
/// ─────────────────────────────────────────────────────────────────────────
///  A FUGA QUE ESTE FICHEIRO FECHA, E PORQUE O DETECTOR ANTIGO ERA CEGO A ELA
/// ─────────────────────────────────────────────────────────────────────────
///  A regra de fee introduzida a 2026-08-22 ancorava no INDICE literal `h == 1`
///  e ASSUMIA — nunca verificava — que `hops[1].tokenIn` era ponte.
///
///  Um atacante cunha `tX`, monta a pool (tU,tX) onde e o UNICO LP, e pede a
///  rota tU -> tX -> tU -> tW. A fee sai inteira em `tX` (po que ele imprimiu)
///  e o `tU` fica preso na pool DELE, que ele recupera queimando LP.
///  MEDIDO: +280 tU liquidos, 100% da fee, por ~130k de gas. Reproduzido
///  tambem com uma pool CPMM canonica de 30 bps, logo nao depende de fee
///  exotica.
///
///  O `FeeEscapeViaJunkPrefix` ja existia e PASSA — mas so testa o po como
///  PREFIXO (X->U->W), que e exactamente a unica topologia que a ancora `h==1`
///  ainda cobria. Detector vivo, cego a variante que o diff abriu.
///
///  A cura ancora por VALOR: o primeiro hop cuja ENTRADA seja mesmo uma ponte.
///  E a rota que nao toca ponte nenhuma paga em TODOS os hops — o unico regime
///  imune por EXAUSTAO (nao ha indice onde inserir po que escape a todos).
contract FeeEscapeDustMidRouteTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;

    MockERC20 tU;   // valioso (pensa USDC) — o que o utilizador move
    MockERC20 tW;   // destino
    MockERC20 tX;   // po cunhado pelo atacante

    MockV2Pair pairUW;   // pool real, funda
    MockV2Pair pairUX;   // pool do atacante, funda, fee 1 bps

    address atacante  = address(0xA77ACE);
    address honesto   = address(0x40E5);
    address treasury1 = address(0x7451);
    address treasury2 = address(0x7452);

    uint256 constant AMT = 100_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tU = new MockERC20("U", "U");
        // `tU` E PONTE, e o Hub tem de o saber. Sem esta linha o `feeHop` nao
        // encontra ponte nenhuma e cai no regime de EXAUSTAO (cobra em todos os
        // hops), que fecha a fuga na mesma mas por outra via — e entao o teste
        // estaria a validar o fallback em vez da ancora por valor, que e o que
        // interessa aqui. Foi precisamente por NENHUM teste de fee do repo
        // chamar `addBridge` que esta classe de fuga viveu ate 2026-08-23.
        hub.addBridge(address(tU));
        tW = new MockERC20("W", "W");
        tX = new MockERC20("X", "X");

        pairUW = new MockV2Pair(address(tU), address(tW));
        tU.mint(address(pairUW), 5_000_000e18);
        tW.mint(address(pairUW), 5_000_000e18);
        pairUW.setReserves(uint112(5_000_000e18), uint112(5_000_000e18));

        pairUX = new MockV2Pair(address(tU), address(tX));
        tU.mint(address(pairUX), 10_000_000_000e18);
        tX.mint(address(pairUX), 10_000_000_000e18);
        pairUX.setReserves(uint112(10_000_000_000e18), uint112(10_000_000_000e18));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );

        tU.mint(atacante, AMT);
        vm.prank(atacante);
        tU.approve(address(router), type(uint256).max);

        tU.mint(honesto, AMT);
        vm.prank(honesto);
        tU.approve(address(router), type(uint256).max);
    }

    function _outV2(uint256 amtIn, uint256 rIn, uint256 rOut, uint256 fee)
        private pure returns (uint256)
    {
        uint256 inWithFee = amtIn * (10_000 - fee);
        return (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
    }

    function _leg(address pool, address inTok, address outTok, uint24 fee, uint256 amtIn, uint256 expOut)
        private pure returns (Leg memory)
    {
        return Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: fee, tickSpacing: 0,
            zeroForOne: inTok < outTok, stable: false,
            amountIn: amtIn, expectedOut: expOut, auxId: bytes32(0)
        });
    }

    function _one(Leg memory l) private pure returns (Leg[] memory a) {
        a = new Leg[](1); a[0] = l;
    }

    // BASE HONESTA: um hop, U -> W. A fee sai na ENTRADA, em tU.
    function test_A_honesto() public {
        uint256 q = _outV2(AMT - (AMT * 28) / 10_000, 5_000_000e18, 5_000_000e18, 30);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tU), tokenOut: address(tW), amountIn: AMT, expectedOut: q,
            legs: _one(_leg(address(pairUW), address(tU), address(tW), 30, AMT, q))
        });
        Route memory r = Route({hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});

        vm.prank(honesto);
        uint256 got = router.swapExactIn(r, AMT, 1, honesto, block.timestamp + 1);
        uint256 feeU = tU.balanceOf(treasury1) + tU.balanceOf(treasury2);
        emit log_named_decimal_uint("HONESTO tW recebido", got, 18);
        emit log_named_decimal_uint("HONESTO fee em tU", feeU, 18);
        assertApproxEqRel(feeU, (AMT * 28) / 10_000, 0.01e18, "honesto paga 28 bps em tU");
    }

    // A FUGA: tres hops, U -> X -> U -> W. A fee e cobrada no INPUT DO HOP 1 = tX (po).
    function test_PoNoMeioDaRotaNaoEvadeAFee() public {
        uint256 qUX = _outV2(AMT, 10_000_000_000e18, 10_000_000_000e18, 1);
        uint256 qXU = _outV2(qUX, 10_000_000_000e18 - qUX, 10_000_000_000e18 + qUX, 1);
        uint256 poolUBefore = tU.balanceOf(address(pairUX));
        uint256 qUW = _outV2(qXU, 5_000_000e18, 5_000_000e18, 30);

        Hop[] memory hops = new Hop[](3);
        hops[0] = Hop({tokenIn: address(tU), tokenOut: address(tX), amountIn: AMT, expectedOut: qUX,
            legs: _one(_leg(address(pairUX), address(tU), address(tX), 1, AMT, qUX))});
        hops[1] = Hop({tokenIn: address(tX), tokenOut: address(tU), amountIn: qUX, expectedOut: qXU,
            legs: _one(_leg(address(pairUX), address(tX), address(tU), 1, qUX, qXU))});
        hops[2] = Hop({tokenIn: address(tU), tokenOut: address(tW), amountIn: qXU, expectedOut: qUW,
            legs: _one(_leg(address(pairUW), address(tU), address(tW), 30, qXU, qUW))});

        Route memory r = Route({hops: hops, totalOut: qUW, singleOut: qUW, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});

        vm.prank(atacante);
        uint256 got = router.swapExactIn(r, AMT, 1, atacante, block.timestamp + 1);

        uint256 feeU = tU.balanceOf(treasury1) + tU.balanceOf(treasury2);
        uint256 feeW = tW.balanceOf(treasury1) + tW.balanceOf(treasury2);
        uint256 feeX = tX.balanceOf(treasury1) + tX.balanceOf(treasury2);

        emit log_named_decimal_uint("ATACANTE tW recebido", got, 18);
        emit log_named_decimal_uint("fee em tU (valioso)", feeU, 18);
        emit log_named_decimal_uint("fee em tW (valioso)", feeW, 18);
        emit log_named_decimal_uint("fee em tX (po)", feeX, 18);

        assertGt(feeU, 0, "a tesouraria TEM de receber tU: a ancora e por VALOR, nao por indice");
        assertApproxEqRel(feeU, (AMT * 28) / 10_000, 0.02e18,
            "e tem de ser a fee INTEIRA, nao um residuo");
        
        assertEq(feeX, 0, "nem um wei de po para a tesouraria");
        uint256 recuperavel = tU.balanceOf(address(pairUX)) - poolUBefore;
        emit log_named_decimal_uint("tU preso na pool DO ATACANTE (recuperavel: e o unico LP)", recuperavel, 18);
        emit log_named_decimal_uint("tU do atacante devolvido (residuo)", tU.balanceOf(atacante), 18);
    }
}
