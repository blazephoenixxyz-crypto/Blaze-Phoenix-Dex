// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../../src/BlazePhoenixCore.sol";
import {Top100BaseTokens} from "./Top100BaseTokens.sol";

interface IERC20F {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice DUAS PERGUNTAS QUE O VARRIMENTO NAO RESPONDE.
///
///  1. FIDELIDADE — a cotacao e honesta? Quantos bps separam o que o Quoter
///     PROMETE do que o Router ENTREGA, no MESMO bloco? Um varrimento so
///     confirma que existe rota; nunca compara a promessa com o facto.
///
///  2. LATENCIA — entre cotar e a transacao entrar passam segundos. Na Base o
///     bloco e ~2s, logo 4-6s sao 2-3 blocos. A rota foi calculada contra um
///     estado que ja nao existe. Quantas execucoes revertem por causa disso?
///
///  METODO. A rota e DADOS, nao estado: o `swapExactIn` recebe-a como
///  argumento. Isso permite cotar no bloco N, rolar o fork para N+K, reconstruir
///  a stack la, e executar a rota VELHA contra o estado NOVO — que e exactamente
///  o que acontece a quem assina uma transacao que demora a entrar.
///
///  O `minOut` usado na segunda fase e o `effectiveMinOut` que o Quoter deu no
///  bloco N, nao um `1` complacente. E esse o numero que o utilizador teria
///  assinado, e e ele que decide se a transacao reverte ou passa.
contract QuoteFidelityTest is Test {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant V4MGR  = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);
    bytes32 constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    uint256 constant BLOCO   = 49_800_000;
    uint256 constant AMOUNT  = 1_000e6;   // 1.000 USDC
    uint256 constant N_PARES = 14;        // topo da lista = os mais liquidos

    BlazePhoenixHub hub; BlazePhoenixSolver solver;
    BlazePhoenixRouter router; BlazePhoenixQuoter quoter;
    bool ligado;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) return;
        vm.createSelectFork("base", BLOCO);
        ligado = true;
        _wire();
    }

    /// Deploy + cablagem. Chamada outra vez depois do `rollFork`, porque o roll
    /// repoe o estado do fork e leva os contratos locais com ele. A rota, essa,
    /// vive na memoria do teste e sobrevive.
    function _wire() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4MGR);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        router.setWeth(WETH);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(WSTETH);
        uint24[] memory f4 = new uint24[](4);
        f4[0]=100; f4[1]=500; f4[2]=3000; f4[3]=10000;
        int24[] memory s4 = new int24[](4);
        s4[0]=1; s4[1]=10; s4[2]=60; s4[3]=200;
        uint24[] memory n0 = new uint24[](0);
        int24[]  memory z0 = new int24[](0);
        hub.addFactory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD, 1, 5, UNIV3_INIT, f4, s4);
        hub.addFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da, 5, 2, bytes32(0), n0, z0);
        hub.addFactory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6, 0, 0, bytes32(0), n0, z0);
        hub.addFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4, 1, 1, bytes32(0), f4, s4);
        hub.addV4(address(0), USDC, 500, 10, address(0));
        hub.addFactory(V4MGR, 4, 9, bytes32(0), n0, z0);
    }

    function _tok(uint256 i) internal pure returns (string memory, address) {
        Top100BaseTokens.Entry[100] memory e = Top100BaseTokens.all();
        return (e[i].symbol, e[i].token);
    }

    function _exec(address tok, Route memory rt, uint256 minOut)
        internal returns (bool ok, uint256 got)
    {
        address user = address(0xBEEF);
        deal(USDC, user, AMOUNT);
        vm.prank(user);
        IERC20F(USDC).approve(address(router), AMOUNT);
        uint256 antes = IERC20F(tok).balanceOf(user);
        vm.prank(user);
        try router.swapExactIn(rt, AMOUNT, minOut, user, block.timestamp + 600)
            returns (uint256)
        {
            // A variacao de SALDO, nao o retorno do Router. Se algum dia os dois
            // divergirem e o saldo que conta — e a divergencia seria, ela
            // propria, o achado.
            got = IERC20F(tok).balanceOf(user) - antes;
            return (true, got);
        } catch { return (false, 0); }
    }

    /// @notice FIDELIDADE no mesmo bloco: promessa contra facto.
    function test_Fidelidade_MesmoBloco() public {
        if (!ligado) return;
        uint256 n; int256 somaBps; int256 pior;
        for (uint256 i; i < N_PARES; ++i) {
            (string memory sym, address tok) = _tok(i);
            if (tok == USDC || tok == address(0)) continue;
            try quoter.previewPlan(USDC, tok, AMOUNT)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
            {
                if (pv.grossOut == 0) continue;
                uint256 prometido = pv.netOut;
                (bool ok, uint256 entregue) = _exec(tok, pv.route, 1);
                if (!ok) { console2.log(string.concat("[X] ", sym)); continue; }
                int256 bps = int256((entregue * 10_000) / prometido) - 10_000;
                somaBps += bps; n++;
                if (bps < pior) pior = bps;
                console2.log(string.concat("[=] ", sym), prometido, entregue);
                console2.logInt(bps);
            } catch { }
        }
        console2.log("--- FIDELIDADE (bps de netOut) ---");
        console2.log("pares:", n);
        console2.log("media x1:"); console2.logInt(n == 0 ? int256(0) : somaBps / int256(n));
        console2.log("pior:");     console2.logInt(pior);
        assertGt(n, 0, "sem pares medidos: cablagem suspeita");
    }

    /// @notice LATENCIA a tres pisos diferentes.
    ///
    ///  `tolBps == 0` usa o `effectiveMinOut` do Quoter — o PISO DE FERRO que o
    ///  Solver impoe. Os outros usam a tolerancia que um utilizador escolheria
    ///  na carteira (50 bps = 0,5%, 100 bps = 1%), aplicada ao `netOut`.
    ///
    ///  Medir os tres e o que torna o numero acionavel: se o piso de ferro for
    ///  MAIS APERTADO que 0,5%, e ele que reverte primeiro e a tolerancia do
    ///  utilizador nunca chega a ser consultada. Nesse caso o parametro a mexer
    ///  e nosso, nao da UI — e um teste que so medisse 0,5% concluiria o oposto.
    function test_Latencia_N3_PisoDeFerro() public { _latencia(0); }
    function test_Latencia_N3_Slippage_050() public { _latencia(50); }
    function test_Latencia_N3_Slippage_100() public { _latencia(100); }

    function _latencia(uint256 tolBps) internal {
        if (!ligado) return;
        address[N_PARES] memory toks;
        uint256[N_PARES] memory minOuts;
        uint256[N_PARES] memory previstos;
        // O indice ORIGINAL na lista de tokens. Sem ele, o segundo ciclo
        // percorre o array compactado e imprime o simbolo errado — um log que
        // mente e pior que um log que falta.
        uint256[N_PARES] memory idx;
        Route[] memory rotas = new Route[](N_PARES);
        uint256 n;
        for (uint256 i; i < N_PARES; ++i) {
            (, address tok) = _tok(i);
            if (tok == USDC || tok == address(0)) continue;
            try quoter.previewPlan(USDC, tok, AMOUNT)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
            {
                if (pv.grossOut == 0) continue;
                toks[n] = tok; rotas[n] = pv.route; idx[n] = i;
                minOuts[n] = tolBps == 0
                    ? pv.effectiveMinOut
                    : (pv.netOut * (10_000 - tolBps)) / 10_000;
                previstos[n] = pv.netOut;
                n++;
            } catch { }
        }
        console2.log("cotados no bloco N:", n, "| tolBps:", tolBps);
        // CALIBRACAO DO APARELHO. Se o `rollFork` nao mexer o bloco, este teste
        // nao mede latencia nenhuma e os "0 reverts" seriam um artefacto.
        console2.log("block.number ANTES do roll:", block.number);

        vm.rollFork(BLOCO + 3);
        console2.log("block.number DEPOIS do roll:", block.number);
        _wire();

        uint256 passou; uint256 reverteu; int256 somaBps;
        for (uint256 i; i < n; ++i) {
            (string memory sym, ) = _tok(idx[i]);
            (bool ok, uint256 got) = _exec(toks[i], rotas[i], minOuts[i]);
            if (!ok) { reverteu++; console2.log(string.concat("[REVERT] ", sym)); continue; }
            passou++;
            int256 bps = int256((got * 10_000) / previstos[i]) - 10_000;
            somaBps += bps;
            console2.log(string.concat("[ok] ", sym), got);
            console2.logInt(bps);
        }
        console2.log("--- LATENCIA N+3 (~6s na Base), tolBps:", tolBps);
        console2.log("passou / reverteu:", passou, reverteu);
        if (passou > 0) { console2.log("desvio medio (bps):"); console2.logInt(somaBps / int256(passou)); }
    }

    /// @notice PORQUE E QUE O ENA entrega 14,5% mais do que o Quoter promete.
    ///         O `safetyBuffer` esta limitado a 10 bps, logo NAO e ele. Isto
    ///         dumpa a rota e os numeros todos para o desvio ter uma causa com
    ///         nome em vez de uma suspeita.
    function test_Diag_ENA() public {
        if (!ligado) return;
        address ENA = 0x58538e6A46E07434d7E7375Bc268D3cb839C0133;
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(USDC, ENA, AMOUNT);
        console2.log("grossOut     :", pv.grossOut);
        console2.log("protocolFee  :", pv.protocolFee);
        console2.log("safetyBuffer :", pv.safetyBuffer);
        console2.log("netOut       :", pv.netOut);
        console2.log("hops / legs  :", pv.hops, pv.legs);
        console2.log("topology     :", pv.topology);
        for (uint256 h; h < pv.route.hops.length; ++h) {
            console2.log(" hop", h, "tokenOut:", pv.route.hops[h].tokenOut);
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                console2.log("   leg kind / fee / pool:",
                    pv.route.hops[h].legs[l].kind,
                    pv.route.hops[h].legs[l].fee);
                console2.log("   pool:", pv.route.hops[h].legs[l].pool);
                console2.log("   amountIn deste leg:", pv.route.hops[h].legs[l].amountIn);
            }
        }
        (bool ok, uint256 got) = _exec(ENA, pv.route, 1);
        console2.log("executado ok / entregue:", ok, got);
        console2.log("entregue - netOut:", got > pv.netOut ? got - pv.netOut : 0);
    }

    /// @notice A ASSINATURA DO MODELO DE TICK UNICO.
    ///
    ///  O `outV3` (Core:972) assume L constante durante toda a swap: nunca
    ///  atravessa ticks. Se for essa a causa do desvio do ENA, o erro tem de
    ///  CRESCER com o tamanho da ordem — uma ordem maior empurra o preco para
    ///  mais longe do intervalo corrente, onde o modelo deixa de valer.
    ///
    ///  Se o erro for CONSTANTE em percentagem, a causa e outra (uma fee mal
    ///  aplicada, por exemplo) e este teste refuta a minha explicacao.
    function test_Diag_ENA_PorTamanho() public {
        if (!ligado) return;
        address ENA = 0x58538e6A46E07434d7E7375Bc268D3cb839C0133;
        uint256[5] memory montantes = [uint256(100e6), 1_000e6, 10_000e6, 100_000e6, 1_000_000e6];
        for (uint256 i; i < 5; ++i) {
            uint256 amt = montantes[i];
            // REPOR O ESTADO entre tamanhos. Sem isto as swaps sao cumulativas
            // — a de 100 USDC move a pool antes de a de 1.000 ser cotada — e a
            // serie mede o efeito das swaps anteriores em vez do tamanho.
            // Foi exactamente o que a primeira versao deste teste fez, e os
            // numeros pareciam dramaticos por essa razao.
            uint256 snap = vm.snapshotState();
            try quoter.previewPlan(USDC, ENA, amt)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
            {
                if (pv.grossOut == 0) { console2.log("sem rota para", amt); continue; }
                address user = address(0xBEE0);
                deal(USDC, user, amt);
                vm.prank(user);
                IERC20F(USDC).approve(address(router), amt);
                uint256 antes = IERC20F(ENA).balanceOf(user);
                vm.prank(user);
                try router.swapExactIn(pv.route, amt, 1, user, block.timestamp + 600) returns (uint256) {
                    uint256 got = IERC20F(ENA).balanceOf(user) - antes;
                    // CONTRA `netOut`, NAO `grossOut`. O `got` ja vem liquido
                    // dos 28 bps de PROTOCOL_FEE_BPS; medir contra o bruto
                    // faz a fee aparecer como erro do modelo, e foi assim que
                    // eu li uma sobrestimacao de 28 bps que nao existia.
                    // Escala 1e6 para dar resolucao de 0,01 bps.
                    int256 bps100 = int256((got * 1_000_000) / pv.netOut) - 1_000_000;
                    console2.log("amountIn USDC:", amt / 1e6);
                    console2.log("  netOut :", pv.netOut);
                    console2.log("  real   :", got);
                    console2.log("  erro (centesimos de bps):");
                    console2.logInt(bps100);
                } catch { console2.log("execucao reverteu em", amt / 1e6); }
            } catch { console2.log("cotacao reverteu em", amt / 1e6); }
            vm.revertToState(snap);
        }
    }

    /// @notice O CUSTO DE UMA COTACAO, decomposto em frio e morno.
    ///
    ///  "Tempo de execucao" de um `eth_call` tem duas partes e so uma e nossa:
    ///    · REDE — medida a parte: 0,34-0,37 s de ida e volta nesta ligacao,
    ///      dos quais 0,11 s sao so estabelecer a ligacao. Nao depende do gas.
    ///    · EXECUCAO DO NO — proporcional ao gas. Um no faz ~50-100M gas/s.
    ///
    ///  Por isso o numero que interessa aqui e o GAS: e o unico termo que o
    ///  nosso codigo controla, e converte-se em tempo dividindo pela taxa do no.
    ///
    ///  FRIO vs MORNO importa mais que o valor absoluto: a primeira chamada paga
    ///  acessos frios (2.600 por conta, 2.100 por slot) que a segunda nao paga.
    ///  Um utilizador real quase sempre cai no caso frio, porque cada `eth_call`
    ///  comeca com o cache do no vazio para a sua transacao.
    function test_GasDeCotacao_WETH_USDC() public {
        if (!ligado) return;
        uint256 amt = 1e18; // 1 WETH

        uint256 a = gasleft();
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(WETH, USDC, amt);
        uint256 gFrio = a - gasleft();

        // WARM-VERSUS-COLD IS NOT MEASURABLE IN ONE FRAME, and the attempt to measure it here
        // was red for an unknown length of time. Two effects pull opposite ways across a margin
        // of 0.005%: the second call pays less for warm accounts and slots, and MORE for memory
        // expansion, because its returned Preview is allocated at a higher offset and expansion
        // is quadratic. Equalising the call shapes was tried first and made the gap larger
        // (84 gas -> 109), which is what refuted the harness explanation.
        //
        // The property is kept as an observation and no longer asserted. What replaces it is
        // the property that actually decides whether a caller can use this: the docstring above
        // already says a real user almost always pays the COLD path, because each eth_call
        // starts with an empty node cache. So the ceiling on the cold quote is the claim worth
        // making, and it is asserted below.
        a = gasleft();
        (BlazePhoenixQuoter.Preview memory pvWarm, , ) = quoter.previewPlan(WETH, USDC, amt);
        uint256 gMorno = a - gasleft();

        console2.log("WETH->USDC, 1 WETH");
        console2.log("  saida       :", pv.grossOut);
        console2.log("  hops / legs :", pv.hops, pv.legs);
        console2.log("  estGas      :", pv.estGas);
        console2.log("  GAS da cotacao FRIA :", gFrio);
        console2.log("  GAS da cotacao MORNA:", gMorno);
        console2.log("  ms de no a 50M gas/s (frio x1000):", (gFrio * 1000) / 50_000);
        console2.log("  ms de no a 100M gas/s (frio x1000):", (gFrio * 1000) / 100_000);

        // O sentido inverso, que e o do varrimento — para se ver se sao simetricos.
        a = gasleft();
        (BlazePhoenixQuoter.Preview memory pv2, , ) = quoter.previewPlan(USDC, WETH, 1_000e6);
        uint256 gInv = a - gasleft();
        console2.log("USDC->WETH, 1.000 USDC");
        console2.log("  saida  :", pv2.grossOut);
        console2.log("  GAS    :", gInv);

        assertGt(pv.grossOut, 0, "tem de haver rota WETH->USDC na Base");
        // Determinism, which the old shape could not check because it threw the answer away:
        // the same question asked twice in one frame must give the same answer.
        assertEq(pvWarm.grossOut, pv.grossOut, "the same quote twice in one frame disagreed");
        // A public node serves eth_call under a gas cap - 50M is the common default, and some
        // are lower. A quote that needs a quarter of that leaves no room for the caller's own
        // simulation on top, so the budget asserted here is 5M: an order of magnitude of
        // headroom against the usual cap, and roughly 50 ms of node time at 100M gas/s.
        assertLt(gFrio, 5_000_000,
            "a cold quote must stay inside the budget a public node will serve");
        // The warm/cold difference is logged, not asserted: see the note above.
        console2.log("  diferenca morno-frio (nao afirmada, ver nota):",
            gMorno > gFrio ? gMorno - gFrio : gFrio - gMorno);
    }
}
