// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Leg, PoolInfo} from "../../src/BlazePhoenixCore.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {Top100BaseTokens} from "./Top100BaseTokens.sol";

interface IERC20M {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice COLHEITA DE MÉTRICAS — legs, hops, gás e cobertura de venues sobre
///         a stack real, em fork.
///
/// Responde às perguntas que o dono fez, e a cada uma com um número medido:
///   · quantas legs / quantos hops usa uma rota, por token e por tamanho
///   · quanto gás custa DISCOVERY (frio), WARM (registo quente) e REFRESH
///     (depois do TTL expirar) — os três estados distintos do registo
///   · qual bridge foi usada (o `Preview` já traz `bridgeUsed` e `topology`)
///   · quais factories ficaram registadas, e quais famílias aparecem nas rotas
///   · o V4 funciona? (aparece alguma leg de KIND_V4 / KIND_V4_NATIVE?)
///
/// ─────────────────────────────────────────────────────────────────────────
///  DUAS PORTAS, E PORQUE AS MEDIMOS SEPARADAMENTE
/// ─────────────────────────────────────────────────────────────────────────
///  O Router tem quatro entry points e só `swapBestExactIn` corre o Solver
///  DENTRO da transacção. `swapExactIn` recebe a `Route` por calldata e nunca
///  o invoca. Um relatório de gás que resolva a rota FORA da janela e execute
///  por `swapExactIn` mede a porta onde o Solver não corre — e dá delta zero
///  para qualquer optimização do Solver. É o defeito registado na nota 128 §2
///  e é exactamente o que o `test/GasReport.t.sol` faz hoje (linha 70 resolve,
///  linha 80 abre a janela).
///
///  Por isso aqui a janela de gás abre ANTES de tudo o que se quer medir, e as
///  duas portas são medidas separadamente e nomeadas.
///
///  forge test --match-contract MetricsSweep -vv
abstract contract MetricsSweepBase is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    address user = address(0xB1A2E);

    /// TTL do registo de descoberta — a fronteira entre WARM e REFRESH.
    uint256 constant DISCOVERY_TTL = 3_600;

    // ─── o que cada chain tem de fornecer ───
    function _tokenIn() internal view virtual returns (address);
    function _sizes() internal pure virtual returns (uint256[4] memory);
    function _tokenCount() internal view virtual returns (uint256);
    function _tokenAt(uint256 i) internal view virtual returns (string memory, address);
    function _chainLabel() internal pure virtual returns (string memory);

    // ═══════════════════════════════════════════════════════════════════════
    //  1. AUDITORIA DE REGISTO — o que ficou realmente ligado
    // ═══════════════════════════════════════════════════════════════════════
    function test_1_RegistrationAudit() public {
        if (address(hub) == address(0)) { vm.skip(true); return; }
        console2.log("=========================================");
        console2.log(" REGISTO --", _chainLabel());
        console2.log("=========================================");
        console2.log("factories registadas:", hub.factoryCount());
        uint8 nb = hub.bridgeCount();
        console2.log("bridges registadas  :", nb);
        for (uint8 i; i < nb; ++i) console2.log("  bridge:", hub.bridge(i));
        // MAX_BRIDGES = 3 no Hub. Menos do que isso e o 3o braco do _rank
        // nunca e exercitado — a medicao de rotas fica cega a uma topologia.
        assertGt(hub.factoryCount(), 0, "nenhuma factory registada");
        assertGt(nb, 1, "menos de 2 bridges: o roteamento por ponte nao existe");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2. VARRIMENTO DE COBERTURA — legs, hops, bridge e família, por token
    // ═══════════════════════════════════════════════════════════════════════
    function test_2_CoverageSweep() public {
        if (address(hub) == address(0)) { vm.skip(true); return; }
        address tIn = _tokenIn();
        uint256 n = _tokenCount();
        uint256 amountIn = _sizes()[1]; // tamanho médio para o varrimento largo

        uint256 achou; uint256 semRota; uint256 proprio;
        uint256 somaLegs; uint256 somaHops; uint256 maxLegs; uint256 maxHops;
        uint256 viaBridge;
        uint256[8] memory legsPorKind;

        console2.log("=========================================");
        console2.log(" COBERTURA --", _chainLabel());
        console2.log("=========================================");

        for (uint256 i; i < n; ++i) {
            (string memory sym, address tok) = _tokenAt(i);
            if (tok == tIn || tok == address(0)) { proprio++; continue; }

            try quoter.previewPlan(tIn, tok, amountIn)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
            {
                if (pv.grossOut == 0) { semRota++; continue; }
                achou++;
                somaLegs += pv.legs; somaHops += pv.hops;
                if (pv.legs > maxLegs) maxLegs = pv.legs;
                if (pv.hops > maxHops) maxHops = pv.hops;
                if (pv.topology == 1) viaBridge++;

                for (uint256 h; h < pv.route.hops.length; ++h) {
                    Leg[] memory legs = pv.route.hops[h].legs;
                    for (uint256 l; l < legs.length; ++l) {
                        uint8 k = legs[l].kind;
                        if (k < 8) legsPorKind[k]++;
                    }
                }
                console2.log(
                    string.concat("[OK] ", sym),
                    pv.legs, pv.hops, pv.estGas
                );
                if (pv.topology == 1) console2.log("      via bridge:", pv.bridgeUsed);
            } catch {
                semRota++;
            }
        }

        console2.log("--------- RESUMO DE COBERTURA -----------");
        console2.log("com rota / sem rota / proprio:", achou, semRota, proprio);
        if (achou > 0) {
            console2.log("legs media (x100):", (somaLegs * 100) / achou, "| max:", maxLegs);
            console2.log("hops media (x100):", (somaHops * 100) / achou, "| max:", maxHops);
            console2.log("rotas via bridge :", viaBridge, "de", achou);
        }
        console2.log("legs V2      :", legsPorKind[0]);
        console2.log("legs V3      :", legsPorKind[1]);
        console2.log("legs V4      :", legsPorKind[4]);
        console2.log("legs SOLIDLY :", legsPorKind[5]);
        console2.log("legs ALGEBRA :", legsPorKind[6]);
        // O V4 nao e assumido: e uma PERGUNTA que este varrimento responde.
        // Zero legs V4 nao e falha do teste — e o resultado, e fica no log.
        if (legsPorKind[4] == 0) console2.log(">> V4 NAO ROTEOU nenhuma leg neste varrimento");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3. CICLO DE GÁS — DISCOVERY / WARM / REFRESH, e as duas portas
    // ═══════════════════════════════════════════════════════════════════════
    function test_3_GasCycle() public {
        if (address(hub) == address(0)) { vm.skip(true); return; }
        address tIn = _tokenIn();
        (address tOut, ) = _alvoExecutavel();
        if (tOut == address(0)) { console2.log("sem alvo executavel"); return; }
        uint256[4] memory sizes = _sizes();

        console2.log("=========================================");
        console2.log(" CICLO DE GAS --", _chainLabel());
        console2.log("=========================================");
        console2.log("tokenIn :", tIn);
        console2.log("tokenOut:", tOut);

        for (uint256 s; s < sizes.length; ++s) {
            uint256 amountIn = sizes[s];
            // Estado limpo por tamanho: fork novo, registo vazio outra vez.
            _reset();
            deal(tIn, user, amountIn * 4);
            vm.prank(user);
            IERC20M(tIn).approve(address(router), type(uint256).max);

            console2.log("---------------------------------------");
            console2.log("amountIn:", amountIn);

            // SEMENTE DO RELOGIO, uma unica vez por tamanho.
            // Este build do forge (1.7.1-dev) devolve um block.timestamp OBSOLETO
            // num segundo call site dentro da mesma funcao. Reler depois do warp
            // faz o passo do TTL virar um no-op SILENCIOSO: o REFRESH mede o mesmo
            // que o WARM e parece resultado legitimo. Foi o que aconteceu na 1a
            // corrida (REFRESH 2.089.802 vs WARM 2.093.565, frio 2.168.368).
            uint256 t0 = block.timestamp;

            // DISCOVERY (frio): registo vazio, o discoverFor corre.
            uint256 g = gasleft();
            (BlazePhoenixQuoter.Preview memory pv1, , ) =
                quoter.previewPlan(tIn, tOut, amountIn);
            uint256 gasFrio = g - gasleft();
            if (pv1.grossOut == 0 || !pv1.canExecute) {
                console2.log("  sem rota executavel neste tamanho");
                continue;
            }
            console2.log("  DISCOVERY (frio) gas:", gasFrio);
            console2.log("    legs/hops:", pv1.legs, pv1.hops);

            vm.prank(user);
            g = gasleft();
            try router.swapExactIn(pv1.route, amountIn, 1, user, t0 + 600) returns (uint256 outA) {
                uint256 gasPortaA = g - gasleft();
                console2.log("  PORTA A swapExactIn      gas:", gasPortaA, "out:", outA);

                g = gasleft();
                (BlazePhoenixQuoter.Preview memory pv2, , ) =
                    quoter.previewPlan(tIn, tOut, amountIn);
                uint256 gasQuente = g - gasleft();
                console2.log("  WARM  gas:", gasQuente);
                console2.log("    delta frio-quente:", gasFrio > gasQuente ? gasFrio - gasQuente : 0);
                console2.log("    legs/hops:", pv2.legs, pv2.hops);

                // So AQUI se toca no relogio, e a partir da semente t0.
                vm.warp(t0 + DISCOVERY_TTL + 1);
                g = gasleft();
                (BlazePhoenixQuoter.Preview memory pv3, , ) =
                    quoter.previewPlan(tIn, tOut, amountIn);
                uint256 gasRefresh = g - gasleft();
                console2.log("  REFRESH (TTL expirado) gas:", gasRefresh);
                console2.log("    legs/hops:", pv3.legs, pv3.hops);
                // O refresh TEM de custar como o frio. Se custar como o quente,
                // o warp nao pegou — e a medicao mente sem dar erro.
                if (gasFrio > gasQuente && gasRefresh < gasQuente + ((gasFrio - gasQuente) / 2))
                    console2.log("  >> AVISO: REFRESH mediu como WARM - o TTL nao expirou");

                vm.prank(user);
                g = gasleft();
                try router.swapBestExactIn(tIn, tOut, amountIn, 1, user, t0 + DISCOVERY_TTL + 600)
                    returns (uint256 outB)
                {
                    uint256 gasPortaB = g - gasleft();
                    console2.log("  PORTA B swapBestExactIn  gas:", gasPortaB, "out:", outB);
                    console2.log("    B/A (x100):", gasPortaA == 0 ? 0 : (gasPortaB * 100) / gasPortaA);
                } catch {
                    console2.log("  PORTA B reverteu");
                }
            } catch {
                console2.log("  PORTA A reverteu - mas o quote dizia canExecute");
            }
        }
    }


    // ═══════════════════════════════════════════════════════════════════════
    //  4. MONOSLOT — o que fica REALMENTE gravado depois de uma execução
    // ═══════════════════════════════════════════════════════════════════════
    /// O registo do Hub guarda uma palavra empacotada por pool (o "Monoslot").
    /// Este teste executa um swap e depois LÊ o slot cru de cada pool que
    /// ficou registada, descodificando campo a campo — em vez de assumir o
    /// que lá está.
    ///
    /// Cadeia de leitura (toda pública, nada de vm.load):
    ///   getActivePools(t0,t1) -> keyOf(pool,t0,t1) -> getSlot(key) -> decode*
    function test_4_MonoslotAfterSwap() public {
        if (address(hub) == address(0)) { vm.skip(true); return; }
        address tIn = _tokenIn();
        (address tOut, ) = _alvoExecutavel();
        if (tOut == address(0)) { console2.log("sem alvo executavel"); return; }
        uint256 amountIn = _sizes()[1];

        console2.log("=========================================");
        console2.log(" MONOSLOT --", _chainLabel());
        console2.log("=========================================");

        // Antes: o registo deste par tem de estar vazio.
        PoolInfo[] memory antes = hub.getActivePools(tIn, tOut);
        console2.log("pools registadas ANTES:", antes.length);

        deal(tIn, user, amountIn * 2);
        vm.prank(user);
        IERC20M(tIn).approve(address(router), type(uint256).max);

        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(tIn, tOut, amountIn);
        if (pv.grossOut == 0) { console2.log("sem rota - nada a gravar"); return; }

        vm.prank(user);
        router.swapExactIn(pv.route, amountIn, 1, user, block.timestamp + 60);

        // ERRO QUE ESTE BLOCO CORRIGE: o registo e indexado pelo PAR DA POOL,
        // nao pelos extremos da rota. Numa rota USDC -> WETH -> LINK as pools
        // gravadas ficam sob USDC/WETH e WETH/LINK; procurar em USDC/LINK da
        // zero e parece que o recordSwap nao correu. Foi o que aconteceu na
        // primeira versao deste teste.
        uint256 gravadas;
        for (uint256 h; h < pv.route.hops.length; ++h) {
            address a = pv.route.hops[h].tokenIn;
            address b = pv.route.hops[h].tokenOut;
            PoolInfo[] memory ps = hub.getActivePools(a, b);
            console2.log("hop", h);
            console2.log("   par:", a, b);
            console2.log("   pools registadas:", ps.length);
            for (uint256 i; i < ps.length; ++i) {
                PoolInfo memory pi = ps[i];
                bytes32 key = hub.keyOf(pi.pool, pi.token0, pi.token1);
                uint256 s = hub.getSlot(key);
                gravadas++;
                console2.log("   pool:", pi.pool);
                console2.log("      kind slot/info:", BPC.decodeKind(s), pi.kind);
                console2.log("      fee  slot/info:", BPC.decodeFee(s), pi.fee);
                console2.log("      swapCount     :", BPC.decodeSwapCount(s));
                console2.log("      lastUpdateTs  :", BPC.decodeLastUpdateTs(s));
                console2.log("      lastBlk       :", BPC.decodeLastBlk(s));
                console2.log("      depthBucket   :", BPC.decodeBucket(s));
                console2.log("      psi (fitness) :", hub.getPsi(pi.pool, pi.token0, pi.token1));
                assertEq(BPC.decodeKind(s), pi.kind, "kind do slot != kind do PoolInfo");
            }
        }
        console2.log("-----------------------------------------");
        console2.log("TOTAL de pools no Monoslot apos 1 execucao:", gravadas);
        assertGt(gravadas, 0, "a execucao nao gravou nada no Monoslot");
    }

    /// Índice do token usado no ciclo de gás. Sobrescrever por chain se o
    /// token no índice 1 não tiver rota.
    function _alvoGas() internal pure virtual returns (uint256) { return 1; }

    /// Recria a stack sobre o fork — registo vazio outra vez.

    /// Procura o primeiro token que nao so COTA como EXECUTA. Os que cotam e
    /// revertem sao contados e impressos: uma cotacao positiva seguida de
    /// reversao na execucao e a assinatura de "quote != execution", e por isso
    /// e METRICA, nao ruido a esconder.
    ///
    /// CORRIGIDO 2026-08-21: a 1a versao executava o SEGUNDO retorno do
    /// previewPlan, que e a `fallbackRoute` — uma rota ALTERNATIVA, nao a que
    /// a Preview descreve. Comparava a cotacao de uma rota com a execucao de
    /// outra e chamava-lhe "quote != execution". A rota da cotacao e `pv.route`.
    function _alvoExecutavel() internal returns (address, uint256) {
        address tIn = _tokenIn();
        uint256 amountIn = _sizes()[1];
        uint256 cotouMasReverteu;
        uint256 n = _tokenCount();
        for (uint256 i; i < n && i < 25; ++i) {
            (string memory sym, address tok) = _tokenAt(i);
            if (tok == tIn || tok == address(0)) continue;
            try quoter.previewPlan(tIn, tok, amountIn)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
            {
                if (pv.grossOut == 0 || !pv.canExecute) continue;
                uint256 snap = vm.snapshotState();
                deal(tIn, user, amountIn * 2);
                vm.prank(user);
                IERC20M(tIn).approve(address(router), type(uint256).max);
                vm.prank(user);
                try router.swapExactIn(pv.route, amountIn, 1, user, block.timestamp + 60) returns (uint256) {
                    vm.revertToState(snap);
                    console2.log(string.concat("alvo executavel: ", sym), tok);
                    if (cotouMasReverteu > 0)
                        console2.log(">> cotaram mas REVERTERAM antes deste:", cotouMasReverteu);
                    return (tok, i);
                } catch {
                    vm.revertToState(snap);
                    cotouMasReverteu++;
                    console2.log(string.concat("[EXEC FALHOU] ", sym), tok);
                }
            } catch { }
        }
        console2.log(">> NENHUM executou nos primeiros 25. cotaram-mas-reverteram:", cotouMasReverteu);
        return (address(0), 0);
    }

    function _reset() internal virtual;
}

// ═══════════════════════════════════════════════════════════════════════════
//  BASE (8453)
// ═══════════════════════════════════════════════════════════════════════════
contract MetricsSweepBaseTest is MetricsSweepBase {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 constant PINNED_BLOCK = 49_800_000;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) return;
        vm.createSelectFork("base", PINNED_BLOCK);
        _reset();
    }

    function _reset() internal override {
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
    }

    function _tokenIn() internal pure override returns (address) { return USDC; }
    function _chainLabel() internal pure override returns (string memory) { return "BASE 8453"; }

    /// Quatro tamanhos: pequeno, medio, grande, muito grande. O impacto e as
    /// legs mudam com o tamanho — um so tamanho mede um so regime.
    function _sizes() internal pure override returns (uint256[4] memory s) {
        s[0] = 100e6; s[1] = 1_000e6; s[2] = 10_000e6; s[3] = 100_000e6;
    }

    function _tokenCount() internal pure override returns (uint256) { return 100; }

    function _tokenAt(uint256 i) internal pure override returns (string memory, address) {
        Top100BaseTokens.Entry[100] memory e = Top100BaseTokens.all();
        return (e[i].symbol, e[i].token);
    }
}
