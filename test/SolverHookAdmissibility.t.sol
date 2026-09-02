// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// E3 / P4 — O SOLVER CONSTROI ROTAS QUE O PROPRIO ROUTER RECUSA.
//
// O Router impoe DUAS regras sobre hooks no caminho de execucao:
//   1. hookAltersDeltas(leg.hooks)  => RouterE(9)   — um hook que mexe nos deltas do V4
//   2. ordem canonica: hookless ANTES de hooked dentro de um hop => RouterE(3)
//
// E o Solver nao sabia que nenhuma das duas existia. `hookAltersDeltas` e `isHookLive` tinham
// ZERO ocorrencias no Solver; `_cutByWeight` ordena por peso e nao por hook. O `getActivePools`
// do Hub filtra por `isHookLive` mas NAO por `hookAltersDeltas`.
//
// Resultado: `swapBestExactIn` — a porta canonica, a que calcula a rota 100% on-chain — podia
// montar in-frame uma rota que o proprio Router rejeitava. DoS auto-infligido: o par fica sem
// porta, e o utilizador nao tem como saber porque.
//
// SEVERIDADE HONESTA: e LIVENESS, nao perda. O revert e atomico e desfaz tudo — a formulacao
// "com tokens ja puxados" que uma das investigacoes usou insinua dano que nao existe.
//
// A REGRA 2 DA CASA, EXPLICITA: a verificacao do Router NAO se apaga para os por de acordo. E ela
// que mantem o sistema fail-closed enquanto o Solver nao souber, e o DESACORDO entre os dois e o
// DIAGNOSTICO. Acrescenta-se conhecimento ao Solver; nao se retira ao Router. Por isso este
// ficheiro testa a SAIDA DO SOLVER e nao o sucesso de um swap: o que mudou foi quem sabe o que,
// nao o que e permitido.
//
// E POR ISSO O FILTRO VIVE NO SOLVER E NAO NO getActivePools: esse e um canal de LEITURA
// partilhado, e filtrar la tirava a pool da vista de TODOS os consumidores, incluindo de quem so
// quer inspecionar o registo. Isto e uma decisao de ROTEAMENTO.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Route, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice PoolManager V4 minimo mas COTAVEL: responde a `extsload` com um slot0 e uma
///         liquidez plausiveis, que e o que o `v4SqrtAndLiq` do Core le. Sem isto a pool
///         hooked cotaria zero e sairia do plano por outra razao — e o teste ficaria vacuo.
contract QuotableV4Manager {
    mapping(bytes32 => bytes32) public s;
    function set(bytes32 slot, bytes32 val) external { s[slot] = val; }
    function extsload(bytes32 slot) external view returns (bytes32) { return s[slot]; }

    /// Grava sqrtPriceX96 (word0) e liquidez (word0+3) para um poolId, na forma que o Core espera.
    function arm(bytes32 poolId, uint160 sqrtP, uint128 liq, uint24 lpFee) external {
        bytes32 base = keccak256(abi.encode(poolId, uint256(6)));
        s[base] = bytes32(uint256(sqrtP) | (uint256(lpFee) << 208));
        s[bytes32(uint256(base) + 3)] = bytes32(uint256(liq));
    }
}

contract SolverHookAdmissibilityTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    QuotableV4Manager v4mgr;
    MockERC20 tA;
    MockERC20 tB;
    MockV2Pair v2pair;

    /// Bits 2 e 3 ligados = BEFORE/AFTER_SWAP_RETURNS_DELTA. O `hookAltersDeltas` le-os
    /// diretamente do endereco — determinismo puro, zero chamadas.
    address constant HOOK_DELTA    = address(0x000000000000000000000000000000000000000C); // 0b1100
    /// Bit 0 ligado, bits de delta LIMPOS: hooked, mas admissivel.
    address constant HOOK_INOCENTE = address(0x0000000000000000000000000000000000000001);

    uint160 constant SQRT_1_1 = 79228162514264337593543950336; // preco 1:1

    function setUp() public {
        v4mgr = new QuotableV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(v4mgr));
        solver = new BlazePhoenixSolver(address(hub));
        hub.setRoles(address(this), address(solver), address(this));

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");

        // Uma pool V2 honesta e funda, para haver sempre alternativa.
        v2pair = new MockV2Pair(address(tA), address(tB));
        tA.mint(address(v2pair), 1_000_000e18);
        tB.mint(address(v2pair), 1_000_000e18);
        v2pair.setReserves(1_000_000e18, 1_000_000e18);
        // A V2 tambem tem de ter historia: se uma pool domina a outra por ordens de grandeza, o
        // Solver escolhe UMA perna e nao ha ordem nenhuma a testar. Foi assim que a primeira
        // versao destes testes ficou vacua — e so a pre-condicao explicita o revelou.
        for (uint256 i; i < 30; i++) {
            hub.recordSwap(address(v2pair), BPC.KIND_V2, 30, address(0),
                address(tA), address(tB), 1e18, 1e18, 1_000_000e18);
        }
    }

    /// A pool hooked tem de GANHAR o ranking, senao o teste passa por ela nem sequer ser
    /// escolhida — e nao por estar a ser filtrada. Foi o teste de CONTROLO que apanhou isto:
    /// uma pool V4 acabada de registar tem psi 1 contra os 512 de uma V2 ja rodada, portanto os
    /// dois testes de filtro passavam VACUOS. Liquidez enorme E vitalidade acumulada.
    function _armV4(address hook) private returns (bytes32 pid) {
        hub.allowHook(hook, true);
        (address c0, address c1) = address(tA) < address(tB)
            ? (address(tA), address(tB)) : (address(tB), address(tA));
        pid = BPC.computeV4PoolId(c0, c1, 3000, 60, hook);
        v4mgr.arm(pid, SQRT_1_1, uint128(1_100_000e18), 3000);
        hub.addV4(address(tA), address(tB), 3000, 60, hook);
        address pAddr = address(uint160(uint256(pid)));
        for (uint256 i; i < 40; i++) {
            hub.recordSwap(pAddr, BPC.KIND_V4, 3000, hook,
                address(tA), address(tB), 1e18, 1e18, 1_100_000e18);
        }
        assertGt(
            hub.getPsi(pAddr, c0, c1),
            hub.getPsi(address(v2pair), c0, c1),
            "pre-condicao do teste: a pool hooked TEM de ganhar o ranking"
        );
    }

    function _legs(RoutePlan memory p) private pure returns (Leg[] memory) {
        if (p.best.hops.length == 0) return new Leg[](0);
        return p.best.hops[0].legs;
    }

    // ─────────────────────────────────────────────────────────────────────────

    /// CONTROLO — sem ele o teste seguinte passaria tambem se a pool V4 nunca entrasse no plano
    /// por outra razao. Com um hook ADMISSIVEL, a pool funda TEM de aparecer na rota.
    function test_AdmissibleHookedPoolIsRouted() public {
        _armV4(HOOK_INOCENTE);
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), 1_000e18);
        Leg[] memory legs = _legs(p);
        bool viu;
        for (uint256 i; i < legs.length; i++) if (legs[i].hooks == HOOK_INOCENTE) viu = true;
        assertTrue(viu, "uma pool hooked ADMISSIVEL e funda tem de ser roteada");
    }

    /// O QUE ESTA VERMELHO: uma pool com hook que altera deltas, mais funda que a alternativa,
    /// entra no plano — e o Router reverte-a com RouterE(9) na execucao.
    function test_DeltaAlteringHookIsNeverRouted() public {
        _armV4(HOOK_DELTA);
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), 1_000e18);
        Leg[] memory legs = _legs(p);
        for (uint256 i; i < legs.length; i++) {
            assertFalse(BPC.hookAltersDeltas(legs[i].hooks),
                "o Solver planeou uma perna que o Router recusa com RouterE(9)");
        }
        assertGt(legs.length, 0, "e tem de sobrar rota: a V2 continua la");
    }

    /// A ORDEM CANONICA: dentro de um hop, as pernas hookless vem ANTES das hooked. O Solver
    /// ordenava por peso; com a hooked mais funda, ela ficava em primeiro e o Router revertia
    /// RouterE(3).
    ///
    /// O `assertGe(2)` e o `assertTrue(viuHooked)` NAO sao decoracao: sem eles, este teste
    /// passaria trivialmente numa rota de uma so perna, ou numa em que nenhuma perna e hooked —
    /// exatamente o modo de falha que o teste de controlo apanhou nos outros dois.
    function test_HooklessLegsComeFirst() public {
        _armV4(HOOK_INOCENTE);
        // MONTANTE GRANDE de proposito: com impacto minusculo o Solver escolhe UMA perna, e com
        // razao — dividir custa gas e nao compra nada. So um swap que mova a curva torna o split
        // a melhor rota, e so ai existe uma ORDEM para testar.
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), 400_000e18);
        Leg[] memory legs = _legs(p);
        assertGe(legs.length, 2, "pre-condicao: a rota TEM de ter split, senao nao ha ordem a testar");

        bool viuHooked;
        for (uint256 i; i < legs.length; i++) {
            if (legs[i].hooks != address(0)) viuHooked = true;
            else assertFalse(viuHooked, "uma perna hookless apareceu DEPOIS de uma hooked");
        }
        assertTrue(viuHooked, "pre-condicao: TEM de haver uma perna hooked no plano");
    }

    /// A ORDENACAO SO PODE MEXER NA ORDEM. O que muda e a sequencia das pernas; o multiset
    /// {(pool, amountIn)} tem de ficar intacto — se a particao trocasse montantes entre pernas,
    /// estaria a re-alocar capital em silencio, e a Camada 1 e os pisos por perna passariam a
    /// medir contra uma distribuicao que o ranking nunca escolheu.
    ///
    /// Compara-se com o MESMO plano montado sem a pool hooked no registo: a soma dos montantes e
    /// o conjunto de pools tem de ser os mesmos que o ranking produziu, so noutra ordem. Aqui a
    /// forma mais robusta e a directa: a soma dos amountIn das pernas TEM de ser o input do hop,
    /// e nenhuma perna pode ter montante zero (uma perna vazia seria capital desaparecido).
    function test_OrderingPreservesTheAllocation() public {
        _armV4(HOOK_INOCENTE);
        // MONTANTE GRANDE de proposito: com impacto minusculo o Solver escolhe UMA perna, e com
        // razao — dividir custa gas e nao compra nada. So um swap que mova a curva torna o split
        // a melhor rota, e so ai existe uma ORDEM para testar.
        RoutePlan memory p = solver.findBestRoutePlan(address(tA), address(tB), 400_000e18);
        Leg[] memory legs = _legs(p);
        assertGe(legs.length, 2, "pre-condicao: rota com split");

        uint256 soma;
        for (uint256 i; i < legs.length; i++) {
            assertGt(legs[i].amountIn, 0, "nenhuma perna pode ficar com montante zero");
            soma += legs[i].amountIn;
        }
        assertEq(soma, p.best.hops[0].amountIn,
            "a ordenacao mexeu na ALOCACAO e nao so na ordem");
    }
}
