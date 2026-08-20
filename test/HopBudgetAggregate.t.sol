// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// CAMADA 1 — orçamento partilhado por hop.
//
// O piso por perna (LEG_FLOOR_BPS = 80%) é LOCAL, mas a composição é GLOBAL:
// num hop de L pernas, quem controla 1 perna extrai ~20%*(L-1)/L sem que perna
// nenhuma falhe o seu piso. Este teste prende o agregado: a soma entregue de um
// hop tem de cobrir a soma das quotes ATESTADAS menos um orçamento B.
//
// Red-first: hoje passa (não existe verificação por hop); com a Camada 1 reverte.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract HopBudgetAggregateTest is Test {
    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router;
    MockERC20 tokenA; MockERC20 tokenB;
    MockV2Pair poolHonest; MockV2Pair poolAttacked;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    uint256 constant AMT_PER_LEG = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A"); tokenB = new MockERC20("B", "B");
        poolHonest   = new MockV2Pair(address(tokenA), address(tokenB));
        poolAttacked = new MockV2Pair(address(tokenA), address(tokenB));
        _seed(poolHonest,   100_000e18, 100_000e18);
        _seed(poolAttacked, 100_000e18, 100_000e18);

        hub.seedPool(address(poolHonest),   BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(poolAttacked), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user); tokenA.approve(address(router), type(uint256).max);
    }

    function _seed(MockV2Pair p, uint256 a, uint256 b) internal {
        if (p.token0() == address(tokenA)) p.setReserves(uint112(a), uint112(b));
        else p.setReserves(uint112(b), uint112(a));
        tokenA.mint(address(p), a); tokenB.mint(address(p), b);
    }

    function _trueOut(MockV2Pair p) internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = p.getReserves();
        bool zfo = p.token0() == address(tokenA);
        return BPC.outV2(AMT_PER_LEG, zfo ? r0 : r1, zfo ? r1 : r0, 30);
    }

    function _leg(MockV2Pair p, uint256 expectedOut) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2,
            fee: 30, tickSpacing: 0, zeroForOne: p.token0() == address(tokenA),
            stable: false, amountIn: AMT_PER_LEG, expectedOut: expectedOut, auxId: bytes32(0)
        });
    }

    function _route(Leg[] memory legs, uint256 totalIn) internal view returns (Route memory r) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
                       amountIn: totalIn, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// ANTI-RIGIDEZ (a garantia que importa): um hop de UMA perna que entrega
    /// 85% do atestado passa o piso por perna (80%) e TEM de continuar a passar.
    /// O orçamento por hop é derivado de max(atestado), logo para L=1 colapsa
    /// exatamente no piso por perna — zero rigidez nova, por construção.
    function test_SingleLegHop_At85pct_StillPasses() public {
        uint256 out1 = _trueOut(poolHonest);
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(poolHonest, BPC.mulDiv(out1, 10_000, 8_500));  // entrega 85% do atestado
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(legs, AMT_PER_LEG), AMT_PER_LEG, 1, user, block.timestamp + 1);
        assertGt(got, 0, "hop de 1 perna a 85% NAO pode reverter");
    }

    /// UMA perna má num hop de duas é PERMITIDA de propósito: é indistinguível
    /// de uma pool legitimamente má, e recusa-la seria a rigidez que o dono
    /// proibiu. O orçamento cobre exatamente uma perna.
    function test_OneBadLegOfTwo_IsTolerated() public {
        uint256 o1 = _trueOut(poolHonest);
        uint256 o2 = _trueOut(poolAttacked);
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(poolHonest,   o1);                              // 100%
        legs[1] = _leg(poolAttacked, BPC.mulDiv(o2, 10_000, 8_200));   // 82%
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(legs, AMT_PER_LEG * 2), AMT_PER_LEG * 2, 1, user, block.timestamp + 1);
        assertGt(got, 0, "uma pool ma sozinha tem de passar");
    }

    /// O ATAQUE: duas pernas a sangrar ao mesmo tempo. Cada uma passa o seu piso
    /// de 80%, mas o agregado excede o que UMA perna poderia legitimamente
    /// perder -> reverte. É esta a forma do 20%*(L-1)/L.
    function test_TwoBleedingLegs_RevertOnHopBudget() public {
        uint256 o1 = _trueOut(poolHonest);
        uint256 o2 = _trueOut(poolAttacked);
        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(poolHonest,   BPC.mulDiv(o1, 10_000, 8_200));   // 82%
        legs[1] = _leg(poolAttacked, BPC.mulDiv(o2, 10_000, 8_200));   // 82%
        vm.prank(user);
        vm.expectRevert();
        router.swapExactIn(_route(legs, AMT_PER_LEG * 2), AMT_PER_LEG * 2, 1, user, block.timestamp + 1);
    }

    /// SPLIT-GAMING — o vetor que uma analise adversarial alegou (extracao de
    /// 16,67% inflando a propria perna). NAO se confirma: essa analise ignorou
    /// que o piso de 80% POR PERNA continua a aplicar-se as pernas drenadas.
    /// Com ele, a extracao maxima e 0.20*(1-m)*Q, que DESCE quando a perna do
    /// atacante (m) cresce — o incentivo nao se inverte. Aqui m=0.8: a extracao
    /// teorica e ~4% e a rota PASSA, e isso e o comportamento correto (drenar
    /// uma perna a 82% esta dentro da tolerancia que o piso concede de
    /// proposito; recusa-la seria a rigidez proibida).
    /// O que a regra do hop apanha e 2+ pernas a sangrar — ver o teste acima.
    function test_SplitGaming_IsBoundedByPerLegFloor_NotByHopBudget() public {
        uint256 big   = AMT_PER_LEG * 4;
        (uint256 r0, uint256 r1,) = poolAttacked.getReserves();
        bool zfo = poolAttacked.token0() == address(tokenA);
        uint256 outBig = BPC.outV2(big, zfo ? r0 : r1, zfo ? r1 : r0, 30);
        uint256 outSmall = _trueOut(poolHonest);

        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({pool: address(poolAttacked), hooks: address(0), kind: BPC.KIND_V2,
            fee: 30, tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: big, expectedOut: outBig, auxId: bytes32(0)});
        legs[1] = _leg(poolHonest, BPC.mulDiv(outSmall, 10_000, 8_200));

        vm.prank(user);
        uint256 got = router.swapExactIn(_route(legs, big + AMT_PER_LEG), big + AMT_PER_LEG, 1, user, block.timestamp + 1);
        assertGt(got, 0, "m alto => extracao pequena; nao ha nada a apanhar aqui");
    }
}
