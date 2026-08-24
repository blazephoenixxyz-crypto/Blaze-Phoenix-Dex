// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PROVA 2: mesmo compactando `rates` na banda, o `_cutByWeight` PERMUTA
// cands/psis/bals e NAO permuta `rates` -> argmax(rates) volta a indexar a
// pool errada.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract RatesAlignmentFunnelTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair X; MockV2Pair Y; MockV2Pair Z; MockV2Pair W; MockV2Pair V;

    uint256 constant ORDER = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub));
        hub.setRoles(address(this), address(solver), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");

        // ordem de psi (= ordem em cands) != ordem de profundidade (= ordem apos o funil)
        X = _pool(800_000e18,  800_000e18, 20);  // psi 1o, profundidade ultima
        Y = _pool(1_000_000e18, 1_000_000e18, 16);
        Z = _pool(950_000e18,  950_000e18, 12);
        W = _pool(900_000e18,  936_000e18,  8);  // MELHOR TAXA (1.04), 3a mais funda
        V = _pool(850_000e18,  850_000e18,  4);
    }

    function _pool(uint256 resIn, uint256 resOut, uint256 swaps) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(p), resIn);
        tB.mint(address(p), resOut);
        if (address(tA) < address(tB)) p.setReserves(uint112(resIn), uint112(resOut));
        else p.setReserves(uint112(resOut), uint112(resIn));
        for (uint256 i; i < swaps; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, 1_000_000e18);
        }
    }

    function _v2out(uint256 x, uint256 rIn, uint256 rOut) private pure returns (uint256) {
        return (997 * x * rOut) / (1000 * rIn + 997 * x);
    }

    function test_FunilPermutaCandsMasNaoRates() public {
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), ORDER);
        Leg[] memory legs = p.best.hops[0].legs;
        for (uint256 i; i < legs.length; i++) emit log_named_address("perna", legs[i].pool);
        emit log_named_address("W (melhor taxa)", address(W));
        uint256 soW = _v2out(ORDER, 900_000e18, 936_000e18);
        emit log_named_uint("totalOut", p.best.totalOut);
        emit log_named_uint("perna unica em W", soW);
        assertGe(p.best.totalOut, soW, "o gate devia ter avaliado a perna unica em W");
    }
}
