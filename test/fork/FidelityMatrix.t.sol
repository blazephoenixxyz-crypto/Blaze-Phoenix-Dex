// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/console2.sol";
import {TokenSweepBase, BaseChainFixture, ArbitrumFixture, OptimismFixture} from "./TokenSweep.t.sol";
import {BlazePhoenixCore as BPC, PoolInfo, QuoteCtx, Route} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

interface IERC20M {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IMintPair { function mint(address) external returns (uint256); }

/// @notice A MATRIZ DE FIDELIDADE — as tres perguntas do dono, medidas:
///
///  1. O QUOTER E FIEL? Por par: o que o preview PROMETE (netOut,
///     effectiveMinOut) contra o que o Router ENTREGA no mesmo bloco, em bps.
///     O `QuoteFidelity` ja media isto — SO na Base. Aqui e nas 4 chains, e
///     com as familias que acordaram HOJE (CL, Solidly V1) — que nunca foram
///     EXECUTADAS: o censo prova que ganham pares, nao que o executor fala o
///     dialecto delas. Se nao falar, o fix de hoje criou a classe exacta do
///     `QuoteExecDivergence` (cota executavel, reverte) — dai os testes de
///     execucao ISOLADA por familia, primeiro que tudo.
///
///  2. A EQUACAO DO OPTIMO ENTREGA? O grossOut do Solver contra (a) a melhor
///     perna UNICA de todos os candidatos descobertos — tem de ganhar ou
///     empatar, senao o solver deixa dinheiro na mesa — e (b) uma grelha de
///     splits 2-vias em passos de 10% sobre os dois pools mais fundos, com
///     10 bps de tolerancia (o gate de split sacrifica micro-ganhos por gas,
///     por desenho — SplitThreshold).
///
///  3. TUDO DISCRIMINADO POR PAR: legs, hops, topologia, gas estimado vs gas
///     REAL de execucao, gas de discovery FRIO vs QUENTE, gas de cotacao,
///     impacto (bps), fee do protocolo, distancia ao piso, fidelidade e
///     escorregamento gross->entregue.
///
/// Cablagem HERDADA das fixtures do TokenSweep (Base/ARB/OP) — zero copias
/// novas; a deriva de cablagem foi o defeito central da nota 135. Blocos
/// FIXADOS pelas fixtures: comparacoes codigo-vs-codigo.
///
/// forge test --match-contract "FidelityMatrix|IsoladaExecucao" --threads 1 -vv
abstract contract MatrixOps is TokenSweepBase {
    address internal constant USER = address(0xF1DE);

    /// Tolerancia do optimo em bps. 10 por defeito; um override so e legitimo
    /// com um ACHADO documentado no proprio override.
    function _tolBps() internal pure virtual returns (uint256) { return 10; }

    function _uqDir(PoolInfo memory h, address tIn, uint256 amt)
        internal view returns (uint256 out, uint256 depth)
    {
        bool z = h.token0 == tIn;
        (out, depth) = BPC.universalQuote(_gateCtx(h, z), amt);
    }

    /// A linha da matriz para UM par. `exec=true` executa de verdade e mede
    /// fidelidade; false fica-se pela metrica de preview (cauda longa).
    function _linha(string memory rotulo, address tIn, address tOut, uint256 amt, bool exec) internal {
        uint256 g0 = gasleft();
        hub.discoverFor(tIn, tOut);
        uint256 dFrio = g0 - gasleft();

        g0 = gasleft();
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(tIn, tOut, amt);
        uint256 qGas = g0 - gasleft();

        if (pv.grossOut == 0) {
            console2.log(string.concat("[SEM ROTA] ", rotulo));
            return;
        }

        // ── o optimo, parte (a): nunca abaixo da melhor perna unica ──
        PoolInfo[] memory hits = hub.discoverFor(tIn, tOut);
        uint256 maxSingle; uint256 win = type(uint256).max; uint256 miragens;
        for (uint256 i; i < hits.length; ++i) {
            if (!hits[i].active || hits[i].pool == address(0)) continue;
            (uint256 o, ) = _uqDir(hits[i], tIn, amt);
            // QUARENTENA DE MIRAGENS — higiene PERMANENTE do aparelho, nao
            // detector de fix pendente. A primeira versao deste comentario
            // chamava "lacuna" ao clamp V3 em falta; o corpus REFUTOU-a: a
            // nota medida do Core (branch V4 do universalQuote) explica que o
            // clamp foi tirado da camada de RANKING de proposito — clampar so
            // as familias concentradas poe o ranking a comparar convencoes
            // diferentes (V2 rasa a bater V4 funda; a classe do depthBucket),
            // e no ENA/USDC o modelo clampado subestimava 14,5%. O clamp vive
            // na camada de PROMESSA (expectedOut dimensionado, netOut, iron
            // floor) — e a fidelidade de 1 bps aqui medida prova-a a segurar.
            // Um quote de ranking num pool concentrado fino extrapola alem da
            // fronteira POR DESENHO (medido: 1,35e17 por 0,5 WETH no OP);
            // este aparelho, que o usa como referencia de "melhor perna",
            // tem de o pontear em quarentena — para sempre, nao ate um fix.
            if (o > pv.grossOut * 4) {
                miragens++;
                console2.log("  MIRAGEM (clamp V3 em falta) pool/out:", hits[i].pool, o);
                continue;
            }
            if (o > maxSingle) { maxSingle = o; win = i; }
        }
        if (miragens > 0) console2.log("  miragens em quarentena:", miragens);
        if (win != type(uint256).max) {
            console2.log("  melhor-perna-unica pool/kind/spacing:",
                hits[win].pool, hits[win].kind, uint256(int256(hits[win].tickSpacing)));
            console2.log("  solver leg0 pool/kind:",
                pv.route.hops[0].legs[0].pool, pv.route.hops[0].legs[0].kind);
            console2.log("  solver grossOut vs maxSingle:", pv.grossOut, maxSingle);
        }
        // 10 bps de folga: capacity clamps e o gate de split podem legitimamente
        // aparar um fio; mais do que isso e o solver a deixar dinheiro na mesa.
        if (maxSingle > 0) {
            assertGe(pv.grossOut * 10_000, maxSingle * (10_000 - _tolBps()),
                string.concat(rotulo, ": solver abaixo da melhor perna unica alem da tolerancia"));
        }

        uint256 entregue; uint256 gReal;
        if (exec) {
            deal(tIn, USER, amt);
            vm.prank(USER);
            IERC20M(tIn).approve(address(router), amt);
            uint256 balAntes = IERC20M(tOut).balanceOf(USER);
            vm.prank(USER);
            g0 = gasleft();
            entregue = router.swapExactIn(pv.route, amt, 1, USER, block.timestamp + 60);
            gReal = g0 - gasleft();
            assertEq(IERC20M(tOut).balanceOf(USER) - balAntes, entregue, "delta != retorno");
            // A PROMESSA PUBLICA: o entregue nunca abaixo do effectiveMinOut.
            assertGe(entregue, pv.effectiveMinOut,
                string.concat(rotulo, ": entregou abaixo do minimo prometido"));
            // FIDELIDADE: netOut ~= entregue no mesmo bloco. 50 bps e o alarme;
            // o valor exacto fica no log para o livro-razao.
            uint256 fidBps = entregue > pv.netOut
                ? ((entregue - pv.netOut) * 10_000) / pv.netOut
                : ((pv.netOut - entregue) * 10_000) / pv.netOut;
            assertLe(fidBps, 50,
                string.concat(rotulo, ": preview e entrega divergem mais de 50 bps no MESMO bloco"));
            console2.log(string.concat("  fidelidade bps / slip gross->entregue bps: "),
                fidBps, ((pv.grossOut - entregue) * 10_000) / pv.grossOut);
        }

        // discovery QUENTE: depois da execucao o registo ja viu o par.
        g0 = gasleft();
        hub.discoverFor(tIn, tOut);
        uint256 dQuente = g0 - gasleft();

        console2.log(string.concat("[PAR] ", rotulo));
        console2.log("  legs/hops/topo:", pv.legs, pv.hops, pv.topology);
        console2.log("  gas: est/exec real:", pv.estGas, gReal);
        console2.log("  gas: disc frio/quente/quote:", dFrio, dQuente, qGas);
        console2.log("  impacto bps / fee (tokenOut) / piso->net bps:",
            pv.route.expectedImpactBps, pv.protocolFee,
            pv.netOut > pv.effectiveMinOut && pv.netOut > 0
                ? ((pv.netOut - pv.effectiveMinOut) * 10_000) / pv.netOut : 0);
    }

    /// O optimo, parte (b): grelha de splits 2-vias, passos de 10%, sobre os
    /// dois candidatos mais fundos. O solver tem de chegar a 10 bps do maximo
    /// da grelha — a tolerancia e o preco documentado do gate de split.
    function _otimoGrelha(string memory rotulo, address tIn, address tOut, uint256 amt) internal {
        PoolInfo[] memory hits = hub.discoverFor(tIn, tOut);
        uint256 d1; uint256 d2; uint256 i1 = type(uint256).max; uint256 i2 = type(uint256).max;
        (BlazePhoenixQuoter.Preview memory pvRef, , ) = quoter.previewPlan(tIn, tOut, amt);
        for (uint256 i; i < hits.length; ++i) {
            if (!hits[i].active || hits[i].pool == address(0)) continue;
            (uint256 oM, uint256 d) = _uqDir(hits[i], tIn, amt);
            if (oM > pvRef.grossOut * 4) continue; // miragem: ver quarentena em _linha
            if (d > d1) { d2 = d1; i2 = i1; d1 = d; i1 = i; }
            else if (d > d2) { d2 = d; i2 = i; }
        }
        if (i2 == type(uint256).max) { console2.log("[GRELHA] so um candidato, nada a comparar"); return; }
        uint256 gridMax;
        uint256 melhorX;
        for (uint256 x; x <= 10; ++x) {
            uint256 a = (amt * x) / 10;
            uint256 o1; uint256 o2;
            if (a > 0)       (o1, ) = _uqDir(hits[i1], tIn, a);
            if (amt - a > 0) (o2, ) = _uqDir(hits[i2], tIn, amt - a);
            if (o1 + o2 > gridMax) { gridMax = o1 + o2; melhorX = x; }
        }
        BlazePhoenixQuoter.Preview memory pv = pvRef;
        console2.log(string.concat("[GRELHA] ", rotulo, " solver/gridMax/x*10:"),
            pv.grossOut, gridMax, melhorX);
        assertGe(pv.grossOut * 10_000, gridMax * (10_000 - _tolBps()),
            string.concat(rotulo, ": solver alem da tolerancia do optimo da grelha 2-vias"));
    }
}

// ═══ EXECUCAO ISOLADA DAS FAMILIAS QUE ACORDARAM HOJE ═══════════════════════
// So a factory da familia: a rota NAO TEM alternativa — ou o executor fala o
// dialecto, ou reverte. E o teste que o censo nao faz.

contract IsoladaExecucaoCL is TokenSweepBase {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant AEROCL = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    function _dollar() internal pure override returns (address) { return USDC; }
    function _weth() internal pure override returns (address) { return WETH; }
    function _n() internal pure override returns (uint256) { return 0; }
    function _at(uint256) internal pure override returns (string memory, address) { return ("", address(0)); }
    function _label() internal pure override returns (string memory) { return "CL isolada"; }

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base", 49_800_000);
        _core(address(0));
        hub.addFactory(AEROCL, KIND_V3, MODE_CALL_V3CL, bytes32(0), _n24(), _clSp());
    }

    /// A familia inteira quotava 0 ate hoje; agora quota — mas EXECUTA?
    function test_ClPerna_ExecutaEEntregaAcimaDoPiso() public {
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(USDC, WETH, 1_000e6);
        assertGt(pv.grossOut, 0, "pos-fix a CL tem de cotar");
        deal(USDC, address(0xF1DE), 1_000e6);
        vm.prank(address(0xF1DE));
        IERC20M(USDC).approve(address(router), 1_000e6);
        vm.prank(address(0xF1DE));
        uint256 entregue = router.swapExactIn(pv.route, 1_000e6, 1, address(0xF1DE), block.timestamp + 60);
        assertGe(entregue, pv.effectiveMinOut, "CL: entregou abaixo do minimo prometido");
        assertGt(entregue, 0.0001 ether); assertLt(entregue, 10 ether);
    }
}

contract IsoladaExecucaoV4Nativa is TokenSweepBase {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant V4_MGR = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    function _dollar() internal pure override returns (address) { return USDC; }
    function _weth() internal pure override returns (address) { return WETH; }
    function _n() internal pure override returns (uint256) { return 0; }
    function _at(uint256) internal pure override returns (string memory, address) { return ("", address(0)); }
    function _label() internal pure override returns (string memory) { return "V4 nativa isolada"; }

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        // Bloco RECENTE de proposito, nao o 49,8M da matriz: a medicao "nativa
        // 3,76x mais funda" e de 2026-08-22; a 49,8M (~14 dias antes) a pool
        // nativa ainda podia ser rasa e o assert testaria a vindima do bloco,
        // nao a cablagem. Fixado a 50.390.000 (~cabeca de 2026-08-24).
        vm.createSelectFork("base", 50_390_000);
        _core(V4_MGR);
        // SO a V4 (as tres pecas) — nenhuma outra venue para onde fugir.
        _v4Wire(V4_MGR, WETH, USDC);
    }

    /// O gemeo que faltava: CL e V1 executaram; a NATIVA — a familia que a
    /// sessao de hoje recuperou no deploy — nunca tinha sido executada pela
    /// stack completa. E o teste pina a razao de ser da recuperacao: a pool
    /// nativa e 3,76x mais funda que a wrapped nesta chain (nota 115), logo o
    /// funil, escolhendo por profundidade, TEM de rotear a perna KIND_V4_NATIVE
    /// (8) — se rotear so a wrapped (4), a cablagem nativa esta morta outra vez.
    function test_V4Nativa_RoteiaEExecutaAcimaDoPiso() public {
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(USDC, WETH, 1_000e6);
        assertGt(pv.grossOut, 0, "so-V4 tem de cotar o par ancora");
        uint256 nativas;
        for (uint256 h; h < pv.route.hops.length; ++h)
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l)
                if (pv.route.hops[h].legs[l].kind == BPC.KIND_V4_NATIVE) nativas++;
        assertGt(nativas, 0, "a pool nativa (3,76x mais funda) tem de ganhar a perna; wrapped-only = cablagem nativa morta");
        deal(USDC, address(0xF1DE), 1_000e6);
        vm.prank(address(0xF1DE));
        IERC20M(USDC).approve(address(router), 1_000e6);
        vm.prank(address(0xF1DE));
        uint256 entregue = router.swapExactIn(pv.route, 1_000e6, 1, address(0xF1DE), block.timestamp + 60);
        assertGe(entregue, pv.effectiveMinOut, "V4 nativa: entregou abaixo do minimo prometido");
        assertGt(entregue, 0.0001 ether); assertLt(entregue, 10 ether);
    }
}

contract IsoladaExecucaoSolidlyV1 is TokenSweepBase {
    address constant WETH  = 0x4200000000000000000000000000000000000006;
    address constant USDC  = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant VELO1 = 0x25CbdDb98b35ab1FF77413456B31EC81A6B6B746;

    function _dollar() internal pure override returns (address) { return USDC; }
    function _weth() internal pure override returns (address) { return WETH; }
    function _n() internal pure override returns (uint256) { return 0; }
    function _at(uint256) internal pure override returns (string memory, address) { return ("", address(0)); }
    function _label() internal pure override returns (string memory) { return "Solidly V1 isolada"; }

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("optimism", 156_000_000);
        _core(address(0));
        hub.addFactory(VELO1, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
    }

    address constant V1_PAIR = 0x055f06391C4bb260e43Fb5D5315Ab67271E6A790;

    /// MEDIDO 2026-08-24: o par ancora da V1 esta VAZIO (getReserves = 0,0 —
    /// a V1 foi drenada para a V2 ha anos). A primeira versao deste teste
    /// exigia rota e ficou vermelha com SolverE(5): o SOLVER estava CERTO —
    /// um par vazio nao pode produzir rota, e bestU==0 recusa fail-closed.
    /// Este teste pina exactamente isso: descoberta VE o par (o fallback de
    /// dialecto funciona) e o funil recusa-o sem rota-fantasma.
    function test_V1ParVazio_DescobertoMasRecusadoFailClosed() public {
        PoolInfo[] memory hits = hub.discoverFor(WETH, USDC);
        uint256 v1Hits;
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == V1_PAIR) v1Hits++;
        assertGt(v1Hits, 0, "o dialecto getPair tem de continuar a ver o par");
        vm.expectRevert();   // SolverE(5): nenhum candidato produz output
        quoter.previewPlan(WETH, USDC, 0.1 ether);
    }

    /// A pergunta que o par vazio deixava sem resposta: a EXECUCAO fala o
    /// dialecto V1? Resposta por semeadura: deal + MINT poe liquidez REAL no
    /// bytecode REAL do par no fork — e a troca corre contra ele. MINT e nao
    /// sync(): com totalSupply 0 o proprio pair PANICA no swap (o indice de
    /// fees divide por totalSupply — medido no trace, div-by-zero dentro do
    /// bytecode da V1), o que de passagem prova que o funil recusar pares
    /// vazios e fail-closed contra um pair que nem reverter limpo consegue.
    function test_V1Perna_ComLiquidezSemeada_ExecutaAcimaDoPiso() public {
        deal(USDC, V1_PAIR, 50_000e6);
        deal(WETH, V1_PAIR, 20 ether);
        IMintPair(V1_PAIR).mint(address(this));
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(WETH, USDC, 0.1 ether);
        assertGt(pv.grossOut, 0, "com reservas, o par V1 tem de cotar");
        deal(WETH, address(0xF1DE), 0.1 ether);
        vm.prank(address(0xF1DE));
        IERC20M(WETH).approve(address(router), 0.1 ether);
        vm.prank(address(0xF1DE));
        uint256 entregue = router.swapExactIn(pv.route, 0.1 ether, 1, address(0xF1DE), block.timestamp + 60);
        assertGe(entregue, pv.effectiveMinOut, "V1: entregou abaixo do minimo prometido");
        assertGt(entregue, 100e6); assertLt(entregue, 10_000e6); // 0,1 ETH ~ 250 USDC no seed 2500/ETH
    }
}

// ═══ A MATRIZ POR CHAIN ═════════════════════════════════════════════════════
contract FidelityMatrixBaseTest is BaseChainFixture, MatrixOps {
    /// A fidelidade so tinha sido medida a 1 hop e a um tamanho. A escada de
    /// tamanhos (1k/10k/100k) e o multi-hop (USDC->wstETH via WETH) sao onde o
    /// impacto cresce e o piso e testado a serio — e onde uma infidelidade
    /// composta por hops apareceria (a fee e por-hop desde 2026-08-21).
    function test_Matriz_EscadaDeTamanhos() public {
        if (address(hub) == address(0)) return;
        _linha("USDC->WETH 10k", _dollar(), _weth(), 10_000e6, true);
        _linha("USDC->WETH 100k", _dollar(), _weth(), 100_000e6, true);
    }
    function test_Matriz_MultiHop() public {
        if (address(hub) == address(0)) return;
        // wstETH da Base: par sem rota directa funda -> forca ponte via WETH.
        _linha("USDC->wstETH", _dollar(), 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452, 1_000e6, true);
    }
    function test_Matriz() public {
        if (address(hub) == address(0)) return;
        _linha("USDC->WETH", _dollar(), _weth(), 1_000e6, true);
        _linha("WETH->USDC", _weth(), _dollar(), 0.5 ether, true);
        (string memory s0, address t0) = _at(0);
        (string memory s1, address t1) = _at(1);
        if (t0 != _dollar()) _linha(string.concat("USDC->", s0), _dollar(), t0, 1_000e6, false);
        if (t1 != _dollar()) _linha(string.concat("USDC->", s1), _dollar(), t1, 1_000e6, false);
    }
    function test_Otimo() public {
        if (address(hub) == address(0)) return;
        _otimoGrelha("USDC->WETH", _dollar(), _weth(), 1_000e6);
    }
}

contract FidelityMatrixArbitrumTest is ArbitrumFixture, MatrixOps {
    function test_Matriz() public {
        if (address(hub) == address(0)) return;
        _linha("USDC->WETH", _dollar(), _weth(), 1_000e6, true);
        _linha("WETH->USDC", _weth(), _dollar(), 0.5 ether, true);
    }
    function test_Otimo() public {
        if (address(hub) == address(0)) return;
        _otimoGrelha("USDC->WETH", _dollar(), _weth(), 1_000e6);
    }
}

contract FidelityMatrixOptimismTest is OptimismFixture, MatrixOps {
    // O override _tolBps()=25 que aqui viveu (achado do funil frio: top-K por
    // ordem de descoberta cortava a CL barata antes de a cotar) foi APAGADO a
    // 2026-08-24 no proprio dia: o desempate por fee no _topKPools fechou-o.
    // Tolerancia de volta aos 10 bps globais — se isto voltar a ficar
    // vermelho, o funil regrediu.
    function test_Matriz() public {
        if (address(hub) == address(0)) return;
        _linha("USDC->WETH", _dollar(), _weth(), 1_000e6, true);
        _linha("WETH->USDC", _weth(), _dollar(), 0.5 ether, true);
    }
    function test_Otimo() public {
        if (address(hub) == address(0)) return;
        _otimoGrelha("USDC->WETH", _dollar(), _weth(), 1_000e6);
    }
}

/// Robinhood: sem fixture no sweep (sem lista Top100) — cablagem minima aqui,
/// UMA copia consciente e assinalada, com o par ancora nas duas direccoes.
contract FidelityMatrixRobinhoodTest is MatrixOps {
    address constant RH_WETH  = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant RH_USDG  = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant RH_UNIV3 = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant RH_UNIV2 = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant RH_PCK3  = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant RH_PCK2  = 0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E;
    address constant RH_V4MGR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function _dollar() internal pure override returns (address) { return RH_USDG; }
    function _weth() internal pure override returns (address) { return RH_WETH; }
    function _n() internal pure override returns (uint256) { return 0; }
    function _at(uint256) internal pure override returns (string memory, address) { return ("", address(0)); }
    function _label() internal pure override returns (string memory) { return " ROBINHOOD 4663 - matriz"; }

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("robinhood", 45_140_000);
        _core(RH_V4MGR);
        hub.addBridge(RH_WETH); hub.addBridge(RH_USDG);
        hub.addFactory(RH_UNIV3, KIND_V3, MODE_CALL_V3,      bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(RH_UNIV2, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(RH_PCK3,  KIND_V3, MODE_CALL_V3,      bytes32(0), _pckFees(), _pckSp());
        hub.addFactory(RH_PCK2,  KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        _v4Wire(RH_V4MGR, RH_WETH, RH_USDG);
        hub.addV4(address(0), RH_USDG, 100, 1, address(0)); // a chave nativa medida da chain
    }

    function test_Matriz() public {
        if (address(hub) == address(0)) return;
        _linha("USDG->WETH", RH_USDG, RH_WETH, 1_000e6, true);
        _linha("WETH->USDG", RH_WETH, RH_USDG, 0.1 ether, true);
    }
    function test_Otimo() public {
        if (address(hub) == address(0)) return;
        _otimoGrelha("USDG->WETH", RH_USDG, RH_WETH, 1_000e6);
    }
}
