// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PROVA: no gate de min-split, o `rates[]` NAO e compactado nem permutado junto
// com `cands[]`, logo `argmax(rates)` indexa a pool ERRADA.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RatesAlignmentBandTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair R; // rejeitada pela banda, mas com o psi mais alto -> cands[0]
    MockV2Pair D; // mais funda, preco justo 1.00
    MockV2Pair Bp; // menos funda, MELHOR preco 1.04

    uint256 constant ORDER = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        hub.setRoles(address(this), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");

        // preco 3.0 -> fora da banda (+-5%); psi maximo para ficar em cands[0]
        R  = _pool(100_000e18, 300_000e18, 20_000_000e18, 16);
        D  = _pool(1_000_000e18, 1_000_000e18, 1_000_000e18, 4);
        Bp = _pool(900_000e18, 936_000e18, 900_000e18, 4);
    }

    function _pool(uint256 resIn, uint256 resOut, uint256 depthRegistada, uint256 swaps)
        private returns (MockV2Pair p)
    {
        p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), resIn);
        tB.mint(address(p), resOut);
        if (address(tA) < address(tB)) p.setReserves(uint112(resIn), uint112(resOut));
        else p.setReserves(uint112(resOut), uint112(resIn));
        for (uint256 i; i < swaps; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, depthRegistada);
        }
    }

    function _v2out(uint256 x, uint256 rIn, uint256 rOut) private pure returns (uint256) {
        return (997 * x * rOut) / (1000 * rIn + 997 * x);
    }

    function test_ArgmaxRatesIndexaAPoolErrada() public {
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        assertEq(p.best.hops.length, 1, "pre-condicao: rota directa");
        Leg[] memory legs = p.best.hops[0].legs;

        for (uint256 i; i < legs.length; i++) {
            emit log_named_address("perna", legs[i].pool);
            emit log_named_uint("  in ", legs[i].amountIn);
            emit log_named_uint("  out", legs[i].expectedOut);
            assertTrue(legs[i].pool != address(R), "pre-condicao: R fora da banda");
        }

        uint256 soD = _v2out(ORDER, 1_000_000e18, 1_000_000e18);
        uint256 soB = _v2out(ORDER, 900_000e18, 936_000e18);
        emit log_named_uint("totalOut da rota escolhida", p.best.totalOut);
        emit log_named_uint("perna unica em D (cands[0], mais funda)", soD);
        emit log_named_uint("perna unica em Bp (melhor taxa)", soB);

        // O duplo fallback promete: a rota devolvida nunca fica abaixo da melhor
        // perna unica entre {mais funda, melhor taxa marginal}.
        assertGe(p.best.totalOut, soB, "o gate devia ter avaliado a perna unica em Bp");
    }
}
