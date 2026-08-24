// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

interface IRouterCD {
    function swapExactIn(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) external returns (uint256);
}

/// @notice QUANTOS BYTES CUSTA MANDAR A ROTA PARA A CHAIN.
///
/// A porta A tira o solver de dentro da transacao (2,3M de gas de execucao) e
/// paga em CALLDATA: a `Route` resolvida fora vai codificada nos argumentos.
/// Esta e a troca do rho*: bytes contra execucao.
///
/// Sem este numero, "a porta A e melhor" e uma crença. Com ele, e uma conta.
contract RouteCalldataSizeTest is Test {
    function _leg(address pool) internal pure returns (Leg memory) {
        return Leg({
            pool: pool, hooks: address(0), kind: 1, fee: 3000, tickSpacing: 60,
            zeroForOne: true, stable: false,
            amountIn: 1_000e6, expectedOut: 5e17, auxId: bytes32(0)
        });
    }

    function _rota(uint256 nHops, uint256 legsPorHop) internal pure returns (Route memory r) {
        r.hops = new Hop[](nHops);
        for (uint256 h; h < nHops; ++h) {
            Leg[] memory ls = new Leg[](legsPorHop);
            for (uint256 l; l < legsPorHop; ++l) ls[l] = _leg(address(uint160(0x1000 + h * 10 + l)));
            r.hops[h] = Hop({
                tokenIn: address(0xAAAA), tokenOut: address(0xBBBB),
                amountIn: 1_000e6, expectedOut: 5e17, legs: ls
            });
        }
    }

    function _bytesDaChamada(Route memory r) internal pure returns (uint256) {
        return abi.encodeCall(
            IRouterCD.swapExactIn, (r, 1_000e6, 1, address(0xBEEF), 1_800_000_000)
        ).length;
    }

    function test_TamanhoDaCalldataPorTopologia() public pure {
        console2.log("=========================================");
        console2.log(" CALLDATA DE swapExactIn, POR TOPOLOGIA");
        console2.log("=========================================");
        uint256[5] memory casos;
        casos[0] = _bytesDaChamada(_rota(1, 1));
        casos[1] = _bytesDaChamada(_rota(1, 2));
        casos[2] = _bytesDaChamada(_rota(2, 1));
        casos[3] = _bytesDaChamada(_rota(2, 2));
        casos[4] = _bytesDaChamada(_rota(2, 3));

        console2.log("1 hop , 1 leg  ->", casos[0], "bytes");
        console2.log("1 hop , 2 legs ->", casos[1], "bytes");
        console2.log("2 hops, 1 leg  ->", casos[2], "bytes");
        console2.log("2 hops, 2 legs ->", casos[3], "bytes");
        console2.log("2 hops, 3 legs ->", casos[4], "bytes");
        console2.log("-----------------------------------------");
        console2.log("custo marginal de UMA leg extra:", casos[1] - casos[0], "bytes");
        console2.log("custo marginal de UM hop extra :", casos[2] - casos[0], "bytes");

        // A rota tem de crescer com a topologia — se nao crescesse, este
        // ficheiro estaria a medir a codificacao errada.
        assertGt(casos[1], casos[0], "mais legs tem de dar mais bytes");
        assertGt(casos[2], casos[0], "mais hops tem de dar mais bytes");
    }
}
