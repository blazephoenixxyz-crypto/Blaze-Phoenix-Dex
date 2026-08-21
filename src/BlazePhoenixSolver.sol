// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixSolver
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  RESPONSABILIDADE UNICA
//      Decidir por onde passa o dinheiro. O Solver e o unico sitio do protocolo
//      onde existe uma escolha; todo o resto executa, verifica ou lembra.
//
//  O QUE ESTE CONTRATO GARANTE
//      S1  DECIDE 100% ON-CHAIN. Nao ha oraculo, nao ha assinatura off-chain, nao
//          ha parametro de confianca. A rota nasce da cadeia e e reproduzivel por
//          qualquer pessoa que leia os mesmos blocos — custa mais gas e o
//          resultado e fiel ao estado real, que e a troca que o desenho escolhe.
//      S2  COMPARA SO O QUE E COMPARAVEL. Profundidades de familias diferentes
//          vivem em unidades diferentes (reservas de par sao lineares; L esta em
//          escala-raiz). Normalizam-se dentro da FAMILIA, nunca entre familias —
//          senao uma pool concentrada ancora acima de uma pool de par igualmente
//          funda por um fator de raiz-de-preco.
//      S3  NAO ESCREVE NADA. Tudo aqui e `view`. Um erro do Solver custa uma rota
//          pior, nunca um estado corrompido.
//
//  O QUE ESTE CONTRATO NAO FAZ, DELIBERADAMENTE
//      Nao executa e nao tem poder de gastar. E a rota que devolve NAO e uma
//      promessa: o Router volta a medir tudo o que ela afirma, porque uma rota
//      pode chegar-lhe por outro caminho que nao este.
//
//  The Solver selects the output-maximising route for an exact-input swap.
//  For each candidate route it computes the total output, discards routes
//  whose net receive falls below the output floor (driven by impact, leg
//  count and sigma), and returns the best feasible route. Within a hop the
//  input is split across pools weighted by their depth (fitness score), so
//  deeper pools take a larger share.
//
//  Topology choice is exhaustive over three candidates:
//
//      a)  direct        : tIn → tOut, one hop, up to MAX_LEGS=5 splits
//      b)  via bridge[0] : tIn → bridge[0] → tOut, 5 legs total
//      c)  via bridge[1] : tIn → bridge[1] → tOut, 5 legs total
//
//  Bridges are the connective tokens of the liquidity graph: exotic-to-exotic
//  swaps usually route through a bridge because that is where depth lives.
//  The Solver evaluates all three topologies and returns the best plus the
//  runner-up as `fallbackRoute`.
//
//  Budget: MAX_LEGS = 5 globally. Bridge routes split it between the two
//  stages dynamically (typically 3 legs to the bridge, 2 from it).
// =============================================================================
pragma solidity 0.8.36;

import {
    BlazePhoenixCore as BPC,
    PoolInfo, Route, Hop, Leg, RoutePlan, QuoteCtx
} from "./BlazePhoenixCore.sol";

interface IHubR {
    function getActivePools(address tA, address tB) external view returns (PoolInfo[] memory);
    function discoverFor(address tA, address tB) external view returns (PoolInfo[] memory);
    function getPsi(bytes32 key) external view returns (uint256);
    function psisOf(address[] calldata pools, address[] calldata tAs, address[] calldata tBs)
        external view returns (uint256[] memory);
    function getSlot(bytes32 key) external view returns (uint256);
    function keyOf(address pool, address tA, address tB) external pure returns (bytes32);
    function bridge(uint8 i) external view returns (address);
    function isBridgeToken(address t) external view returns (bool);
    function v4PoolManager() external view returns (address);
    function v4EntryCount() external view returns (uint256);
}

contract BlazePhoenixSolver {

    string  public constant VERSION                = "2.0.0";

    /// @notice Maximum legs across the entire route, regardless of topology.
    uint8   internal constant MAX_LEGS             = 5;

    /// @notice Stage-A budget for bridge routes.  Stage B gets MAX_LEGS - A_used.
    uint8   internal constant MAX_LEGS_PER_STAGE   = 3;

    /// @notice Candidates PROBED from the Hub per pair. Deliberately wider
    ///         than the leg budget (MAX_LEGS): the probe funnel sees more
    ///         venues than it will use, and the weight-ranked cut down to the
    ///         leg budget happens AFTER the marginal-rate probe and capital
    ///         anchor — so a deep pool listed behind several thin equal-psi
    ///         venues (e.g. a Solidly stable pool sitting behind four V3 fee
    ///         tiers in discovery order) is seen, weighted, and can displace
    ///         them instead of being starved out by list order.
    uint8   internal constant MAX_CANDIDATES       = 8;

    /// @notice Skip the full CREATE2 discovery sweep when the pair already has at
    ///         least this many registered venues active within DISCOVERY_TTL_SECONDS.
    uint8   internal constant MIN_FRESH_VENUES     = 3;

    /// @notice Re-discovery freshness window in WALL-CLOCK SECONDS. Fully chain-
    ///         agnostic and uniform: `block.timestamp` means the same real time on
    ///         every chain, so no per-chain (block-cadence) calibration is needed.
    ///         It is a GAS/COVERAGE knob, never a safety parameter — the on-chain
    ///         floor protects every fill regardless of how stale the registry is.
    uint256 internal constant DISCOVERY_TTL_SECONDS = 3_600; // ~1 hour, every chain

    /// @notice Per-leg conservatism BPS for routes with ≥3 legs.
    uint16  internal constant LEG_SAFETY_BPS       = 5;

    /// @notice A split is accepted only if it beats the single-best leg's
    ///         full-size quote by at least this margin. Each extra leg costs
    ///         real execution gas (~30k measured), and the allocator otherwise
    ///         contains no gas term at all — this bps threshold is the honest,
    ///         oracle-free proxy for that cost (comparing gas in the native
    ///         token against output in tokenOut would need a price, and the
    ///         protocol is deliberately oracle-free). Planning-view only:
    ///         execution floors and userMinOut are untouched.
    uint16  internal constant MIN_SPLIT_IMPROVEMENT_BPS = 20;

    /// @notice Capacity clamp for concentrated (single-tick-quoted) legs, in
    ///         BPS of the pool's REAL tokenOut balance. The single-tick V3 /
    ///         Algebra formula models the current liquidity as if it spanned
    ///         every price, so on a thin pool it can promise far more tokenOut
    ///         than the pool has ever held (observed 117x on a thin USDC/DAI
    ///         V3 pool: 494k quoted from a pool whose whole book paid 4.2k).
    ///         A pool cannot pay out what it does not hold: the attested
    ///         quote is clamped to this fraction of the pool's measured
    ///         tokenOut balance — the same unforgeable capital signal as the
    ///         anchor filter, extended from filtering to capacity. Reserve-
    ///         bounded formulas (V2 / Solidly) cannot
    ///         over-promise and are untouched; a zero balance (V4 singleton
    ///         accounting) skips the clamp.
    ///
    ///         Two-tier: when the quote exceeds the pool's WHOLE holdings the
    ///         promise is physically impossible, and the clamp binds CAPITAL,
    ///         not just the promise — the leg's committed input is cut in the
    ///         same ratio, the freed input cascades to the remaining legs, and
    ///         anything no venue can absorb stays unrouted (the Router sweeps
    ///         it back to the caller). Promise-only clamping left the full
    ///         share walking a thin pool's tick ladder at a collapsing
    ///         marginal price, invisibly to the floors because they derive
    ///         from the already-crushed promise. When the fill is aggressive
    ///         but possible (cap < quote <= holdings) only the promise is
    ///         capped — cutting capital there forced partial fills on pools
    ///         that execute fine (measured: a 43bps full fill halved).
    uint16  internal constant MAX_CONC_DRAIN_BPS   = 3_000; // 30% of real holdings

    /// @notice Filtro de banda para a alocacao do split. Depois de cotar cada candidato, calcula-se
    ///         a base do mercado e excluem-se as pools cujo rate se afasta dela mais que
    ///         MEDIAN_FILTER_BPS.
    ///
    ///         PORQUE UMA MEDIANA E NAO A MELHOR: o rate da melhor pool pode ele proprio estar
    ///         manipulado (uma pool de liquidez baixa com preco velho a fingir que oferece o
    ///         mundo). Para mover uma mediana, um atacante tem de mover mais de METADE — e nao
    ///         basta uma pool.
    ///
    ///         NOTA DE CORRECAO (2026-08-21). Este paragrafo dizia exatamente isto e era FALSO ha
    ///         muito: a base tinha passado a ser o rate da UNICA pool mais funda, um estimador com
    ///         PONTO DE RUTURA ZERO — um sensor forjado capturava-a inteira. A justificacao
    ///         escrita e o estimador real tinham divergido, e a prosa mais tranquilizadora era a
    ///         que descrevia a defesa que ja nao existia.
    ///         Hoje a base e a MEDIANA PONDERADA PELA PROFUNDIDADE (ver `_depthWeightedMedian`),
    ///         que repoe a propriedade que este paragrafo alega — e melhora-a: a maioria e contada
    ///         em MASSA DE PROFUNDIDADE e nao em numero de pools, portanto nem meia duzia de pools
    ///         de po tem voto. Ponto de rutura: 0 -> 50% da massa.
    ///
    ///         BANDA DE 500 bps (±5%) — decisao do dono, 2026-08-21, alargada de 400.
    ///         O objetivo e nao EXCLUIR uma pool genuinamente melhor: a banda e simetrica, logo
    ///         alargar admite tanto quem esta ate 5% acima da base como quem esta 5% abaixo.
    ///         Continua apertada o suficiente para o que ela foi feita: curvas Solidly-stable em
    ///         pares LST/WETH ficam tipicamente 20-40% fora, e essas continuam a ser excluidas.
    ///
    ///         O QUE ISTO CUSTA, dito onde se decide: uma pool 5% pior tambem entra, e como os
    ///         pesos sao por PROFUNDIDADE, uma pool funda e 5% pior pode levar uma fatia grande.
    ///         Se um dia se quiser so o lado bom, a banda tem de deixar de ser simetrica — e isso
    ///         e uma mudanca de PREDICADO e nao de numero, portanto nao se faz por atalho.
    uint16  internal constant MEDIAN_FILTER_BPS    = 500;   // ±5% (decisao do dono, 2026-08-21)

    error SolverE(uint16 code);

    IHubR public immutable hub;

    constructor(address hub_) {
        require(hub_ != address(0), "Solver:hub0");
        hub = IHubR(hub_);
    }

    // =========================================================================
    //  PUBLIC API
    // =========================================================================

    /// @notice Find the U-maximising route plan for an exact-input swap.
    /// @dev    Enumerates direct + via-bridge[0] + via-bridge[1] topologies
    ///         in parallel, returns max-U as `best` and second-best as `fallback`.
    function findBestRoutePlan(address tIn, address tOut, uint256 amountIn)
        external view returns (RoutePlan memory plan)
    {
        if (tIn == address(0) || tOut == address(0) || tIn == tOut || amountIn == 0)
            revert SolverE(4);

        Route memory direct = _planDirect(tIn, tOut, amountIn);
        Route memory viaB1;
        Route memory viaB2;
        // O `bridgeCount()` que aqui estava era REDUNDANTE. As posicoes acima do contador sao
        // SEMPRE address(0) — o `addBridge` preenche em sequencia e o `removeBridge` compacta e
        // zera a que sobra — e as duas guardas ja testavam `!= address(0)`. Era uma travessia de
        // fronteira por solve para responder a uma pergunta que o proprio valor lido ja responde.
        //
        // O BALANCO, honesto: com >= 2 bridges configuradas (o caso de producao) sao 3 travessias
        // a passar a 2. Com o registo VAZIO passa de 1 para 2 — pior, mas um registo sem bridges
        // e uma ma configuracao, nao um regime a optimizar.
        //
        // E AS DUAS LEITURAS DESENROLADAS SAO O `MAX_BRIDGE_ROUTES` DO HUB, ESCRITO AQUI EM
        // CODIGO. E este numero — nao o MAX_BRIDGES — que decide por quantas bridges se roteia, e
        // a diferenca entre os dois era uma assimetria silenciosa: a terceira bridge tinha
        // direitos de admissao e +25% de fitness sem nunca poder ser um hop. Ver a nota do
        // MAX_BRIDGE_ROUTES no Hub e o test/RoutableBridgeAsymmetry.t.sol, que pina os dois lados.
        // Quem acrescentar um `b2` aqui TEM de subir a constante la.
        address b0 = hub.bridge(0);
        if (b0 != address(0) && b0 != tIn && b0 != tOut) {
            viaB1 = _planViaBridge(tIn, tOut, amountIn, b0);
        }
        address b1 = hub.bridge(1);
        if (b1 != address(0) && b1 != tIn && b1 != tOut) {
            viaB2 = _planViaBridge(tIn, tOut, amountIn, b1);
        }

        Route memory best;
        Route memory second;
        uint256 bestU;
        uint256 secondU;

        (bestU, secondU, best, second) = _rank(direct, viaB1, viaB2);
        if (bestU == 0) revert SolverE(5);

        plan.best = best;
        plan.fallbackRoute = second;
        plan.hasFallback = (secondU > 0);
    }

    function _rank(Route memory a, Route memory b, Route memory c)
        private pure returns (uint256 bestU, uint256 secU, Route memory bestR, Route memory secR)
    {
        if (a.totalOut > 0) { bestU = a.totalOut; bestR = a; }
        if (b.totalOut > bestU) { secU = bestU; secR = bestR; bestU = b.totalOut; bestR = b; }
        else if (b.totalOut > secU) { secU = b.totalOut; secR = b; }
        if (c.totalOut > bestU) { secU = bestU; secR = bestR; bestU = c.totalOut; bestR = c; }
        else if (c.totalOut > secU) { secU = c.totalOut; secR = c; }
    }

    // =========================================================================
    //  TOPOLOGY PLANNERS
    // =========================================================================

    function _planDirect(address tIn, address tOut, uint256 amountIn)
        private view returns (Route memory route)
    {
        PoolInfo[] memory cands = _topKPools(tIn, tOut, MAX_CANDIDATES);
        if (cands.length == 0) return route;
        Hop memory hop = _buildHop(tIn, tOut, amountIn, cands, MAX_LEGS, true);
        if (hop.expectedOut == 0) return route;
        return _assembleRoute(hop);
    }

    function _planViaBridge(
        address tIn, address tOut, uint256 amountIn, address bridge_
    ) private view returns (Route memory route) {
        // Stage A: tIn → bridge, budget = MAX_LEGS_PER_STAGE. The funnel probes
        // the full candidate width; _buildHop cuts to the stage budget by weight.
        PoolInfo[] memory candsA = _topKPools(tIn, bridge_, MAX_CANDIDATES);
        if (candsA.length == 0) return route;
        Hop memory hopA = _buildHop(tIn, bridge_, amountIn, candsA, MAX_LEGS_PER_STAGE, true);
        if (hopA.expectedOut == 0 || hopA.legs.length == 0) return route;

        // Stage B: bridge → tOut, budget = MAX_LEGS - legs(A)
        uint256 legsA = hopA.legs.length;
        if (legsA >= MAX_LEGS) return route;   // stage A used the whole budget
        uint8 budgetB = uint8(MAX_LEGS - legsA);
        if (budgetB == 0) return route;
        PoolInfo[] memory candsB = _topKPools(bridge_, tOut, MAX_CANDIDATES);
        if (candsB.length == 0) return route;
        // Stage B may NOT input-cut: the Router rescales its legs against the
        // REAL bridge balance produced by stage A (scale = realIn / sum of
        // quoted leg inputs), so a cut leg would be scaled straight back up —
        // past its cut promise and into a per-leg floor revert (observed: a
        // 2-hop route that filled at 74bps floor-rejected once its stage-B
        // leg was cut). Stage B keeps the promise-only clamp; the input-side
        // cut protects hop 0 / single-hop, where amounts execute as built.
        Hop memory hopB = _buildHop(bridge_, tOut, hopA.expectedOut, candsB, budgetB, false);
        if (hopB.expectedOut == 0 || hopB.legs.length == 0) return route;

        // Two-hop route: stage A (tIn→bridge) and stage B (bridge→tOut)
        // are kept as SEPARATE hops. The Router executes hop A, measures
        // the actual bridge balance received, then rescales hop B's legs
        // proportionally to the real bridge amount. This makes the route
        // robust to stage-A slippage: stage B always spends exactly what
        // stage A produced, never a stale quoted figure.
        uint256 totalLegs = hopA.legs.length + hopB.legs.length;
        if (totalLegs > MAX_LEGS) return route;

        Hop[] memory hops = new Hop[](2);
        hops[0] = hopA;
        hops[1] = hopB;

        return _assembleRouteMulti(hops, tIn, tOut, amountIn, hopB.expectedOut);
    }

    // =========================================================================
    //  HOP CONSTRUCTION — depth-weighted allocation
    // =========================================================================

    function _buildHop(
        address tIn, address tOut, uint256 amountIn,
        PoolInfo[] memory cands, uint8 budget, bool allowCut
    ) private view returns (Hop memory hop) {
        uint256 n = cands.length;
        if (n == 0) return hop;
        // No blind pre-trim: every candidate is probed (rate + depth + real
        // holdings), and the cut to `budget` happens after weighting — see the
        // FUNNEL CUT below. Discovery order can no longer starve a deep venue.
        if (n == 1) return _singleLeg(tIn, tOut, amountIn, cands[0], allowCut);

        // =========================================================================
        //  STAGE 1 — MARGINAL-RATE MEDIAN FILTER  (single probe pass)
        //
        //  We quote each candidate with a PROBE size (= amountIn / 100) that
        //  is small enough that each pool's marginal rate is essentially its
        //  spot price (negligible impact). Then we compute the median of
        //  those marginal rates and filter pools whose marginal rate
        //  deviates from the base by more than MEDIAN_FILTER_BPS (±5%).
        //
        //  GAS: the probe-size quote is computed exactly ONCE per candidate
        //  here, capturing BOTH the marginal rate AND the depth in the same
        //  call (_quoteWithDepth). Previously this identical probe quote was
        //  recomputed three times — once for the median, once for the band
        //  filter, once for the depth pass — each re-reading the pool's
        //  state (V3 sqrtP+liquidity, V2 reserves, or a V4 singleton
        //  extsload) although nothing it reads can change within a single
        //  view call. rates[i] and depths[i] stay index-aligned to cands[i]
        //  (we sort a COPY for the median), so the band filter and the depth
        //  pass reuse the cached values with zero extra staticcalls. Only the
        //  final per-leg allocation re-quotes, because it uses a different
        //  (share) input size and so is genuinely a new computation.
        //
        //  Why marginal, not full-input: full-input rates conflate two
        //  signals — pool quality AND pool depth — because a small pool
        //  absorbing a large input shows a "bad" full-input rate but its
        //  spot price may be fine. Filtering on full-input rates throws
        //  away healthy small pools when the trade is large, leaving the
        //  depth split with only 1 leg — exactly the failure mode this
        //  avoids.
        //
        //  Marginal rates cleanly separate the two:
        //    • A stale-priced LST stable-curve pool has a wrong marginal
        //      rate regardless of trade size → filtered.
        //    • A small but healthy pool has a correct marginal rate; its
        //      poor full-input output reflects depth, not pricing → kept.
        //      The subsequent depth split then allocates correctly by depth,
        //      and a small pool naturally receives proportionally less.
        //
        //  This is the correct division of labour: filter on QUALITY (rate)
        //  with a tight band, then allocate by CAPACITY (depth).
        // =========================================================================
        uint256 probe = amountIn / 100;
        if (probe == 0) probe = amountIn;  // tiny trades — full size is the probe

        // Per-candidate caches, index-aligned to `cands`. Filled by the single
        // probe pass and reused by the band filter and the depth weighting.
        uint256[] memory rates  = new uint256[](n);
        uint256[] memory depths = new uint256[](n);
        // CAPITAL ANCHOR. Truth votes with capital, not with existence: dust
        // pools with stale prices can form a fake majority and vote the
        // honest deep pool out of a plain median (for example: two dead
        // SushiV3 pools agreeing on a stale ~910 rate excluded the 401k-USDC
        // pool quoting the true 1633 as an "outlier"). The pool with the
        // largest REAL tokenOut balance is where arbitrage keeps the price
        // true; faking this anchor requires depositing more real capital
        // than the genuine deep pool — at which point the attacker IS the
        // deep pool and arbitrage corrects it. balanceOf is one staticcall
        // and unforgeable without capital (unlike concentrated L, which is
        // free to inflate with a hair-thin position).
        // Per-candidate real tokenOut holdings, reused by the capacity clamp in
        // the allocation pass (no extra staticcall — read here for the anchor).
        // NOTE: the loop keeps NO scalar accumulators (no validity counter, no
        // running anchor) — dead pools leave rates[i] at zero and the median
        // block below derives the zero count AND the anchor by post-scanning
        // the cached arrays. Keeps this loop's via-IR frame minimal: only the
        // arrays, probe and the index stay live across iterations.
        uint256[] memory balsOut = new uint256[](n);
        for (uint256 i; i < n; ) {
            (uint256 o, uint256 d) = _quoteWithDepth(cands[i], tIn, probe);
            if (o > 0) {
                rates[i]  = BPC.mulDiv(o, 1e18, probe);
                depths[i] = d == 0 ? 1 : d;   // matches the legacy "if (d==0) d=1"
                // V3/BP-18 (CRITICAL, devil's-advocate): a V4 pool's address is a
                // codeless truncated poolId whose balanceOf ANYONE can fund with
                // 1 wei — reading the capital anchor from it lets a dust transfer
                // forge maxBal>0 and steer the band. V4 custodies tokens in the
                // PoolManager singleton, so its true per-pool balance is 0: force
                // it, sourcing the capital anchor only from real token-custodying
                // kinds (also keeps _weights' "V4 reports balance 0" honest).
                balsOut[i] = BPC.kindHasAny(cands[i].kind, BPC.A_CONC_SING)
                    ? 0
                    : BPC.balanceOf(tOut, cands[i].pool);
            }
            unchecked { ++i; }
        }

        // Median + band bounds, scoped so only hi/lo survive into the filter
        // (the sort machinery and the anchor die with the block — stack).
        uint256 hi;
        uint256 lo;
        {
            // Median of the non-zero rates. We sort a COPY of `rates` (insertion
            // sort — n ≤ 8 so cost is negligible) so the per-index association in
            // `rates`/`depths` survives for the band filter below. Zero entries
            // (dead pools) bubble to the bottom of the copy and are skipped.
            uint256[] memory sortedRates = new uint256[](n);
            for (uint256 i; i < n; ) { sortedRates[i] = rates[i]; unchecked { ++i; } }
            for (uint256 i = 1; i < n; ) {
                uint256 key = sortedRates[i];
                uint256 j = i;
                while (j > 0 && sortedRates[j - 1] > key) {
                    sortedRates[j] = sortedRates[j - 1];
                    unchecked { --j; }
                }
                sortedRates[j] = key;
                unchecked { ++i; }
            }
            // sortedRates is now ascending; zeros (dead pools) sit at the
            // front. Count them here — all-zero means nothing quotable.
            uint256 firstNonZero;
            while (firstNonZero < n && sortedRates[firstNonZero] == 0) {
                unchecked { ++firstNonZero; }
            }
            if (firstNonZero == n) return hop;
            uint256 medianIdx = firstNonZero + ((n - firstNonZero) / 2);
            if (medianIdx >= n) medianIdx = n - 1;  // guard: never index past end
            uint256 median = sortedRates[medianIdx];
            if (median == 0) return hop;

            // Band base: the CAPITAL ANCHOR when one exists (any candidate
            // holds a non-zero real tokenOut balance); plain median only as
            // fallback (e.g. V4, whose tokens live in the PoolManager
            // singleton, so per-pool balanceOf is 0 and no anchor forms).
            // The anchor is derived here by post-scanning the cached arrays
            // (first max wins, matching the historical in-loop tracker) so the
            // probe loop above carries no scalar accumulators.
            // V3 / BP-18: use the real capital anchor (largest tokenOut balance of
            // a token-custodying candidate — V4 is forced to 0 above, so this can
            // no longer be dust-forged on a pseudo-address) when one exists.
            // Otherwise (a V4-only set) anchor on the DEEPEST candidate by measured
            // liquidity rather than the plain median: a plain median is shifted for
            // FREE by >=5 stale fakes, whereas out-depthing the honest venue costs
            // real capital in the PoolManager. This RAISES the attack cost from free
            // to capital-at-risk; it does NOT make it impossible — active-tick L is
            // cheap to inflate with a one-spacing position, so a fully robust anchor
            // (L discounted by tick width, or a full-size-quote sanity check on the
            // band base) is deferred WITH the V2 tick-cap work.
            // T2 (Thomas): anchor on MEASURED DEPTH, never raw balanceOf. The old
            // capital anchor read balsOut[i] = balanceOf(tokenOut, pool), which a
            // plain donation (transfer to the pool) inflates WITHOUT moving the
            // reserve or price — and the donation is recoverable (V2 skim / V3 LP
            // claim), so it is not "capital at risk". That let an attacker win the
            // anchor with a donation, center the band on their bad rate, and filter
            // the honest deep pool OUT (~75% user loss, preview gamed identically).
            // depths[] is getReserves (V2/Solidly) / getLiquidity (V3), which a
            // donation cannot move; V4 depth is its measured liquidity. Falls back
            // to the median only when no candidate reports depth.
            uint256 base = _depthWeightedMedian(rates, depths, n);
            // Zero-base guard (devil's-advocate): a live candidate can have
            // rates[i]==0 (mulDiv floor on a tiny raw price) yet depths[i]>=1, so a
            // depth/capital anchor could set base=0 and collapse the band to
            // hi=lo=0, killing an otherwise routable hop. median is guaranteed
            // non-zero here (the median==0 early-return above), so fall back to it.
            if (base == 0) base = median;
            hi = BPC.mulDiv(base, BPC.BPS + MEDIAN_FILTER_BPS, BPC.BPS);
            lo = BPC.mulDiv(base, BPC.BPS - MEDIAN_FILTER_BPS, BPC.BPS);
        }

        // Band filter reuses the cached probe rates — no second probe quote.
        // Survivors are compacted IN PLACE into cands/depths/balsOut (safe:
        // the write index never overtakes the read index), which keeps the
        // arrays index-aligned for the weight/allocation passes without
        // allocating six shadow arrays — leaner on memory AND on the stack
        // frame (the via-IR inliner folds _weights into this function).
        {
            // Scoped so nKept dies here — the via-IR inliner folds _weights
            // into this function and every surviving stack slot counts.
            uint256 nKept;
            for (uint256 i; i < n; ) {
                uint256 r = rates[i];
                if (r > 0 && r >= lo && r <= hi) {
                    if (nKept != i) {
                        cands[nKept]   = cands[i];
                        depths[nKept]  = depths[i];
                        balsOut[nKept] = balsOut[i];
                    }
                    unchecked { ++nKept; }
                }
                unchecked { ++i; }
            }
            if (nKept == 0) return hop;
            if (nKept == 1) return _singleLeg(tIn, tOut, amountIn, cands[0], allowCut);
            n = nKept;
        }

        // =========================================================================
        //  STAGE 2 — DEPTH-WEIGHTED SPLIT (on filtered survivors)
        // =========================================================================
        // Allocate by REAL depth, normalised within each pool KIND. Psi is 1
        // for every never-swapped pool, which splits a trade evenly across a
        // 790-WETH pool and a 0.34-WETH dust pool — destroying ~20% of value
        // (measured for a WETH/USDC pair: 50/50 gave 1302 USDC vs 1638
        // when concentrated in the deep pool). depthWad reflects current
        // capacity, so weighting by it converges on the optimal allocation
        // (depth-weighted gave 1638, matching deep-only).
        //
        // CORRIGIDO 2026-08-21. Este paragrafo afirmava que "depthWad so e comparavel dentro de
        // uma FAMILIA DE UNIDADES" e descrevia dois modos de peso: normalizacao por familia, e um
        // fallback para o saldo cru quando o conjunto cruzava familias.
        // A PREMISSA CAIU com o `depthFromL`: a conversao passou a dar profundidade
        // TOKEN-denominada em TODAS as familias, e a guarda do CI diz textualmente que ela "tem de
        // ser token-denominada PARA SER COMPARAVEL ENTRE FAMILIAS". O repositorio tinha as duas
        // afirmacoes opostas escritas ao mesmo tempo — e era sobre a errada que os dois modos
        // estavam construidos.
        // Hoje ha UMA normalizacao, contra o maximo GLOBAL — que resolve melhor o mesmo problema
        // (uma pool fina de um kind raro compara-se com TODAS, nao so com as da sua familia; o
        // caso medido foi uma V4 fina a levar ~49% de 25k USDC e a custar ~31% vs justo). E o
        // fallback para o saldo cru desapareceu com eles: era uma ancora de `balanceOf`, que a
        // doutrina do T2 proibe porque uma doacao a infla sem custo para quem doa.
        (uint256[] memory psis, uint256 sumPsi) = _weights(cands, depths, balsOut, n);

        // ─── FUNNEL CUT (see MAX_CANDIDATES) ───
        // The funnel probed more venues than the leg budget allows; commit to
        // the top-`budget` survivors by WEIGHT (not discovery order), so a deep
        // late-listed pool displaces thin early-listed ones. Extracted to keep
        // this function's stack shallow.
        if (n > budget) (n, sumPsi) = _cutByWeight(cands, psis, balsOut, budget, n);
        Leg[] memory tmpLegs = new Leg[](n);
        uint256 legCount;
        uint256 totalOut;
        uint256 allocated;
        for (uint256 i; i < n; ) {
            uint256 share;
            if (i == n - 1) {
                // Last leg takes the remainder. Guard against rounding
                // overshoot in the preceding mulDiv allocations: if the
                // accumulated total already meets or exceeds amountIn,
                // this leg gets nothing rather than underflowing.
                share = allocated >= amountIn ? 0 : amountIn - allocated;
            } else {
                share = BPC.mulDiv(amountIn, psis[i], sumPsi);
            }
            allocated += share;
            if (share == 0) { unchecked { ++i; } continue; }
            uint256 outL = _quote(cands[i], tIn, share);
            if (outL == 0) { unchecked { ++i; } continue; }
            // ─── Capacity clamp (see MAX_CONC_DRAIN_BPS) ───
            // Uma cotacao concentrada de tick unico e limitada a uma fraccao das existencias
            // REAIS de tokenOut da pool, para que uma pool fina nao possa inflar o totalOut acima
            // do que consegue FISICAMENTE pagar. Saldo zero (contabilidade no singleton do V4)
            // deixa a cotacao intacta.
            //
            // PORQUE AQUI E `balanceOf` E NAO A PROFUNDIDADE MEDIDA — e porque a doutrina do T2
            // NAO se aplica a este sitio, apesar de ele ler a mesma funcao. Uma auditoria propos
            // trocar por `depths[i]` invocando o T2 ("nunca balanceOf cru"), e a troca foi
            // TENTADA E MEDIDA: para uma pool V3, `depthFromL` da a reserva VIRTUAL derivada de L,
            // que pode ser muito MAIOR que as existencias fisicas — 3.327e18 contra 1.600e18 no
            // caso de teste. O teto ficava mais FROUXO, o oposto da intencao.
            //
            // A distincao que isto ensina, e que vale para o proximo sitio que leia balanceOf:
            //   · a ANCORA DA BANDA faz uma pergunta RELATIVA ("qual destas pools e a boa?").
            //     Uma doacao distorce a comparacao sem custo para quem doa — T2 aplica-se, e a
            //     ancora usa profundidade medida.
            //   · este TETO faz uma pergunta FISICA ("esta pool consegue pagar isto?"). Uma
            //     doacao sobe o teto E sobe o que a pool consegue mesmo pagar, e os tokens doados
            //     sao CONSUMIDOS no pagamento ao utilizador. Nao e ataque, e subsidio.
            // Ler a mesma grandeza nao implica fazer a mesma pergunta.
            if (BPC.kindHas(cands[i].kind, BPC.A_CONC_POOL)
                && balsOut[i] > 0)
            {
                uint256 cap = BPC.mulDiv(balsOut[i], MAX_CONC_DRAIN_BPS, BPC.BPS);
                if (allowCut && outL > balsOut[i]) {
                    // ─── Input-side clamp: capital follows the promise ───
                    // The quote exceeds the pool's WHOLE holdings — physically
                    // impossible, the promise is phantom (measured on a Base
                    // stable pair: 89% of a 10k order sent into a pool holding
                    // 6.2k of tokenOut — a 27% one-way loss walking its tick
                    // ladder and 7M gas crossing it, masked as "surplus"
                    // because the floors derive from the crushed promise). Cut
                    // the committed input in the promise's ratio; the freed
                    // input flows to the LAST leg via the remainder mechanism
                    // (re-clamped there if that leg is also phantom-thin), and
                    // whatever no surviving venue can absorb stays unrouted —
                    // the Router's residual sweep returns it to the caller.
                    // Fills that are aggressive but PHYSICALLY POSSIBLE
                    // (cap < quote <= holdings) keep their full share and only
                    // the promise is capped: cutting those forced partial
                    // fills on healthy pools (measured: a 43bps full fill
                    // degraded to a half-filled order).
                    uint256 keep = BPC.mulDiv(share, cap, outL);
                    allocated -= share - keep;
                    share = keep;
                    outL = cap;
                    if (share == 0) { unchecked { ++i; } continue; }
                } else if (outL > cap) {
                    outL = cap;
                }
                if (outL == 0) { unchecked { ++i; } continue; }
            }
            tmpLegs[legCount] = Leg({
                pool:        cands[i].pool,
                hooks:       cands[i].hooks,
                kind:        cands[i].kind,
                fee:         cands[i].fee,
                tickSpacing: cands[i].tickSpacing,
                zeroForOne:  cands[i].token0 == tIn,
                stable:      cands[i].stable,
                amountIn:    share,
                expectedOut: outL,
                auxId:       BPC.kindHasAny(cands[i].kind, BPC.A_CONC_SING)
                    ? bytes32(uint256(uint160(cands[i].token0 == tIn ? cands[i].token1 : cands[i].token0)))
                    : bytes32(0)
            });
            totalOut += outL;
            unchecked { ++legCount; ++i; }
        }
        if (legCount == 0) return hop;

        Leg[] memory legs = new Leg[](legCount);
        // Σ of the COMMITTED (post-clamp) leg inputs — the honest hop.amountIn.
        // Accumulated in the copy loop that already runs, so no extra pass and
        // no hot-loop local (issue #1): when a phantom cut freed capital that no
        // surviving venue could reabsorb, this is < the caller's amountIn and the
        // Router's residual sweep returns the difference.
        uint256 committedIn;
        for (uint256 i; i < legCount; ) { legs[i] = tmpLegs[i]; committedIn += tmpLegs[i].amountIn; unchecked { ++i; } }

        // Multi-leg conservatism (≥3 legs): shave each expectedOut by legCount × 5 BPS.
        if (legCount >= 3) {
            uint256 shave = legCount * LEG_SAFETY_BPS;
            if (shave > BPC.BPS) shave = BPC.BPS;
            totalOut = 0;
            for (uint256 i; i < legCount; ) {
                legs[i].expectedOut = BPC.mulDiv(legs[i].expectedOut, BPC.BPS - shave, BPC.BPS);
                totalOut += legs[i].expectedOut;
                unchecked { ++i; }
            }
        }
        // MIN-SPLIT IMPROVEMENT GATE. A multi-leg split must EARN its legs:
        // unless it beats the top-weight survivor's single-leg full-size quote
        // by >= MIN_SPLIT_IMPROVEMENT_BPS, collapse to that single leg. Kills
        // micro-splits whose marginal output gain is smaller than the real
        // gas cost of the extra legs. cands[0] is the top-weight survivor
        // (post FUNNEL CUT); one extra full-size quote in the view path only.
        if (legCount >= 2) {
            Hop memory single = _singleLeg(tIn, tOut, amountIn, cands[0], allowCut);
            if (
                single.legs.length != 0 && single.expectedOut > 0 &&
                totalOut < BPC.mulDiv(single.expectedOut, BPC.BPS + MIN_SPLIT_IMPROVEMENT_BPS, BPC.BPS)
            ) {
                return single;
            }
        }
        hop = Hop({
            tokenIn: tIn, tokenOut: tOut,
            amountIn: committedIn, expectedOut: totalOut, legs: legs
        });
    }

    /// @dev Selection-sort the top-`budget` survivors by weight to the front of
    ///      cands/psis/bals (swapped in lockstep so they stay index-aligned),
    ///      then return the trimmed count and the re-summed weight. Isolated
    ///      from _buildHop so its sort locals do not deepen that stack frame.
    function _cutByWeight(
        PoolInfo[] memory cands, uint256[] memory psis, uint256[] memory bals,
        uint256 budget, uint256 n
    ) private pure returns (uint256, uint256) {
        for (uint256 ki; ki < budget; ) {
            uint256 bi = ki;
            for (uint256 j = ki + 1; j < n; ) {
                if (psis[j] > psis[bi]) bi = j;
                unchecked { ++j; }
            }
            if (bi != ki) {
                (cands[ki], cands[bi]) = (cands[bi], cands[ki]);
                (psis[ki], psis[bi])   = (psis[bi], psis[ki]);
                (bals[ki], bals[bi])   = (bals[bi], bals[ki]);
            }
            unchecked { ++ki; }
        }
        uint256 sumPsi;
        for (uint256 i; i < budget; ) { sumPsi += psis[i]; unchecked { ++i; } }
        return (budget, sumPsi);
    }

    /// @dev ORDEM CANONICA (Camada 2), do lado de quem PLANEIA. Particao ESTAVEL das pernas de
    ///      um hop: hookless para a frente, ordem relativa PRESERVADA dentro de cada grupo.
    ///
    ///      PORQUE EXISTE. O Router exige hookless ANTES de hooked dentro de um hop e reverte
    ///      RouterE(3) se nao for o caso — um hook ganha controlo de EVM durante o swap e pode
    ///      tocar no pool de uma perna ainda por executar da MESMA rota. O Solver ordenava por
    ///      PESO, portanto uma pool hooked mais funda ficava em primeiro e a rota que ele proprio
    ///      construiu revertia na execucao. Auto-DoS na porta canonica.
    ///
    ///      PORQUE AQUI E NAO NO CRITERIO DE RANKING, que era onde parecia pertencer. O
    ///      `_buildHop` esta cronicamente a um slot do limite de stack do via_ir — o proprio
    ///      `_cutByWeight` ja tinha sido extraido por essa razao, e o compilador volta a inlina-lo
    ///      la dentro, pelo que qualquer local acrescentado ao comparador conta para aquele frame
    ///      e rebenta-o. Tentei tres formas antes desta e as tres rebentaram.
    ///      A restricao material acabou por apontar ao sitio mais honesto: a ordem das pernas e
    ///      uma propriedade da ROTA, nao do criterio de selecao de POOLS. Aqui opera-se sobre o
    ///      hop ja construido, e le-se exatamente como a regra que o Router verifica.
    ///
    ///      A ESTABILIDADE NAO E ESTETICA: a ordem dentro de cada grupo veio do peso, e uma troca
    ///      simples destrui-la-ia. E o que esta funcao pode mudar e so a ORDEM — o multiset
    ///      {(pool, amountIn)} fica intacto, porque cada perna viaja inteira.
    function _orderLegs(Hop memory hop) private pure {
        Leg[] memory legs = hop.legs;
        uint256 k = legs.length;
        uint256 w;
        for (uint256 i; i < k; ) {
            if (legs[i].hooks == address(0)) {
                if (i != w) {
                    Leg memory tmp = legs[i];
                    for (uint256 j = i; j > w; ) {
                        legs[j] = legs[j - 1];
                        unchecked { --j; }
                    }
                    legs[w] = tmp;
                }
                unchecked { ++w; }
            }
            unchecked { ++i; }
        }
    }


    /// @dev A MEDIANA PONDERADA PELA PROFUNDIDADE dos rates. E a base da banda.
    ///
    ///      O QUE SUBSTITUI, E PORQUE. A base era o rate da UNICA pool mais funda
    ///      (`maxDepth`/`depthRate`). Em estatistica robusta isso e um estimador com PONTO DE
    ///      RUTURA ZERO: basta UM sensor forjado — a pool mais funda — para capturar a base
    ///      inteira. E o proprio codigo confessava a fraqueza, a poucas linhas daqui: "active-tick
    ///      L is cheap to inflate with a one-spacing position... does NOT make it impossible...
    ///      deferred".
    ///      Pior, havia um FACTO ERRADO ESCRITO: o comentario do `MEDIAN_FILTER_BPS` justificava
    ///      a seguranca com "para mover a mediana, um atacante tem de mover mais de metade das
    ///      pools" — quando a base ja NAO era a mediana havia muito.
    ///
    ///      O QUE ISTO REPOE: exatamente a propriedade que esse comentario alegava, e com os pesos
    ///      que o fix T2 tornou nao-forjaveis. Para capturar a base o atacante deixa de precisar
    ///      de out-depth UMA pool e passa a precisar de mais de METADE da massa de profundidade do
    ///      conjunto inteiro. Ponto de rutura: 0 -> 50%.
    ///
    ///      PORQUE SOMAR MASSA E LEGITIMO: desde o `depthFromL` a profundidade e token-denominada
    ///      em TODAS as familias (min(x0,x1) para concentrada, min(r0,r1) para par), logo a soma
    ///      tem sentido. Era esta a premissa que faltava antes — e e a mesma que permitiu remover
    ///      a normalizacao por familia dos pesos.
    ///
    ///      DEGENERA BEM: uma pool que sozinha detem >50% da massa devolve o seu proprio rate, que
    ///      e o comportamento antigo — e correto, porque nesse caso ela E o mercado. Com pesos
    ///      iguais, e a mediana simples.
    function _depthWeightedMedian(uint256[] memory rates, uint256[] memory depths, uint256 n)
        private pure returns (uint256)
    {
        uint256[] memory r = new uint256[](n);
        uint256[] memory d = new uint256[](n);
        uint256 m;
        uint256 massa;
        for (uint256 i; i < n; ) {
            // Pools mortas (rate 0) nao votam: nao tem opiniao sobre o preco.
            if (rates[i] > 0) {
                r[m] = rates[i];
                d[m] = depths[i];
                massa += depths[i];
                unchecked { ++m; }
            }
            unchecked { ++i; }
        }
        if (m == 0 || massa == 0) return 0;
        // Insertion sort dos PARES por rate — n <= 8, custo desprezavel. Ordenar os pares e o que
        // distingue isto de ordenar so os rates: a massa tem de viajar com o seu rate.
        for (uint256 i = 1; i < m; ) {
            uint256 kr = r[i];
            uint256 kd = d[i];
            uint256 j = i;
            while (j > 0 && r[j - 1] > kr) {
                r[j] = r[j - 1];
                d[j] = d[j - 1];
                unchecked { --j; }
            }
            r[j] = kr;
            d[j] = kd;
            unchecked { ++i; }
        }
        // Caminha-se ate METADE da massa. `(massa + 1) / 2` em vez de `acc * 2 >= massa` para nao
        // haver hipotese de transbordo no dobro de uma soma de profundidades.
        uint256 metade = (massa + 1) / 2;
        uint256 acc;
        for (uint256 i; i < m; ) {
            acc += d[i];
            if (acc >= metade) return r[i];
            unchecked { ++i; }
        }
        return r[m - 1];
    }

    /// @dev Pesos de alocacao para os sobreviventes da banda, normalizados a [1..10000]:
    ///      a profundidade MEDIDA de cada pool contra a MAIOR profundidade do conjunto.
    ///
    ///      DUAS COISAS FORAM REMOVIDAS DAQUI EM 2026-08-21, e as duas pela MESMA razao.
    ///
    ///      (1) O MODO CAPITAL. Quando o conjunto cruzava familias e todos tinham saldo, o peso
    ///          passava a ser `balanceOf(tokenOut, pool)`. Isso era uma ANCORA lida do saldo cru
    ///          — exatamente o que a doutrina do fix T2 proibe, escrita a poucas linhas daqui:
    ///          "ancora na profundidade MEDIDA, NUNCA no balanceOf cru, porque uma doacao infla-o
    ///          SEM mover a reserva nem o preco, e a doacao e recuperavel". O T2 foi aplicado a
    ///          ancora da BANDA e nao a este peso, que decide a FATIA do split. Assinatura de
    ///          defeito da casa: um fix aplicado a UM de dois canais que fazem a MESMA pergunta
    ///          relativa ("qual destas pools merece mais?").
    ///          (NOTA: o teto de capacidade tambem le `balanceOf` e NAO foi mudado — la a pergunta
    ///          e FISICA, "consegue pagar isto?", e a doacao sobe genuinamente o que a pool paga.
    ///          Ler a mesma grandeza nao implica fazer a mesma pergunta.)
    ///
    ///      (2) A NORMALIZACAO POR FAMILIA. Existia porque "depthWad so e comparavel dentro de uma
    ///          familia de unidades". Essa premissa CAIU com o `depthFromL`: a conversao passou a
    ///          dar profundidade TOKEN-denominada em todas as familias, e a propria guarda do CI
    ///          diz textualmente que ela "tem de ser token-denominada PARA SER COMPARAVEL ENTRE
    ///          FAMILIAS". O repositorio tinha as duas afirmacoes opostas escritas ao mesmo tempo.
    ///          Com profundidades globalmente comparaveis, normalizar contra o maximo GLOBAL e
    ///          estritamente mais correto — e resolve melhor o problema que a normalizacao por
    ///          familia resolvia (uma pool fina de um kind raro nao ganha peso maximo por ser a
    ///          unica do seu kind: agora compara-se com TODAS, nao so com as da sua familia).
    ///
    ///      O que sai com elas: `_famOf`, o array `maxByFam`, o predicado `st` empacotado e o
    ///      ramo. O que fica e uma normalizacao, sem modos.
    function _weights(
        PoolInfo[] memory cands, uint256[] memory depth, uint256[] memory bals, uint256 n
    ) private pure returns (uint256[] memory psis, uint256 sumPsi) {
        cands; bals;   // mantidos na assinatura: o chamador passa-os em lockstep com psis
        psis = new uint256[](n);
        uint256 mx;
        for (uint256 i; i < n; ) {
            if (depth[i] > mx) mx = depth[i];
            unchecked { ++i; }
        }
        for (uint256 i; i < n; ) {
            // `mx == 0` so acontece se NENHUM candidato reportou profundidade: entao todos ficam
            // com peso 1 e o split e uniforme, que e a unica coisa honesta a fazer sem medicao.
            uint256 w = mx == 0 ? 1 : BPC.mulDiv(depth[i], 10_000, mx);
            if (w == 0) w = 1;   // profundidade nao-nula mas minuscula nao desaparece do split
            psis[i] = w;
            sumPsi += w;
            unchecked { ++i; }
        }
    }

    function _singleLeg(
        address tIn, address tOut, uint256 amountIn, PoolInfo memory cand, bool allowCut
    ) private view returns (Hop memory hop) {
        uint256 out_ = _quote(cand, tIn, amountIn);
        if (out_ == 0) return hop;
        // Capacity clamp — same two-tier doctrine as the split path (see
        // MAX_CONC_DRAIN_BPS). Quote > the pool's WHOLE holdings: physically
        // impossible, so the committed input is cut in the promise's ratio and
        // the route executes a small honest fill (the Router sweeps the
        // uncommitted remainder back to the caller) instead of walking the
        // pool's tick ladder at a collapsing marginal price. Aggressive but
        // possible (cap < quote <= holdings): full commit, promise capped.
        uint256 legIn = amountIn;
        if (BPC.kindHas(cand.kind, BPC.A_CONC_POOL)) {
            uint256 balOut = BPC.balanceOf(tOut, cand.pool);
            if (balOut > 0) {
                uint256 cap = BPC.mulDiv(balOut, MAX_CONC_DRAIN_BPS, BPC.BPS);
                if (allowCut && out_ > balOut) {
                    legIn = BPC.mulDiv(amountIn, cap, out_);
                    out_ = cap;
                    if (legIn == 0 || out_ == 0) return hop;
                } else if (out_ > cap) {
                    out_ = cap;
                }
            }
        }
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: cand.pool, hooks: cand.hooks, kind: cand.kind,
            fee: cand.fee, tickSpacing: cand.tickSpacing,
            zeroForOne: cand.token0 == tIn, stable: cand.stable,
            amountIn: legIn, expectedOut: out_,
            auxId: BPC.kindHasAny(cand.kind, BPC.A_CONC_SING)
                ? bytes32(uint256(uint160(cand.token0 == tIn ? cand.token1 : cand.token0)))
                : bytes32(0)
        });
        hop = Hop({
            tokenIn: tIn, tokenOut: tOut,
            // Report the COMMITTED input (post-clamp legIn), not the caller's
            // original order, so hop.amountIn can never disagree with the leg it
            // actually carries. The Router derives the spend cap from Σ leg.amountIn
            // regardless, but an honest hop.amountIn keeps previewPlan and every
            // off-chain reader truthful — issue #1 (NetGakarot).
            amountIn: legIn, expectedOut: out_, legs: legs
        });
    }

    function _quoteWithDepth(PoolInfo memory cand, address tIn, uint256 amt)
        private view returns (uint256 out, uint256 depth)
    {
        bool zfo = cand.token0 == tIn;
        address qIn = tIn;
        address other = zfo ? cand.token1 : cand.token0;
        if (cand.kind == BPC.KIND_V4_NATIVE) {
            // Native V4: PoolInfo carries the pair in WETH-canonical form
            // with token0 = the wrapped-native side (the registry's
            // orientation contract — see Hub._readPoolInfo). The pool's REAL
            // currency0 is address(0): substitute it on whichever side is
            // token0 before the quote sorts the pair, so universalQuote
            // derives the native poolId (address(0) sorts first by
            // construction). zeroForOne needs no branch: token0 == tIn
            // already means "input is currency0" under this orientation.
            if (zfo) qIn = address(0); else other = address(0);
        }
        QuoteCtx memory c = QuoteCtx({
            kind:        cand.kind,
            pool:        cand.pool,
            zeroForOne:  zfo,
            fee:         cand.fee,
            tickSpacing: cand.tickSpacing,
            stable:      cand.stable,
            tokenIn:     qIn,
            tokenOther:  other,
            hooks:       cand.hooks,
            v4Manager:   BPC.kindHasAny(cand.kind, BPC.A_CONC_SING)
                ? hub.v4PoolManager() : address(0)
        });
        (out, depth) = BPC.universalQuote(c, amt);
    }

    /// @dev Depth-free quote. Delegates to `_quoteWithDepth` and drops the depth rather than
    ///      rebuilding an identical QuoteCtx and calling `universalQuote` a second time.
    ///
    ///      NOTA DE CORRECAO: este paragrafo dizia que o `BPC.universalQuote` e `internal`. E
    ///      `public` (ver Core) — logo cada sitio de chamada NAO inlina uma copia, faz
    ///      DELEGATECALL a biblioteca ja implantada. O argumento de bytecode abaixo aplicava-se a
    ///      um mundo anterior; hoje o motivo para nao duplicar o sitio de chamada e outro, e vale
    ///      na mesma: dois sitios sao dois canais para divergir.
    ///      This matters for BYTECODE, not just tidiness: se fosse `internal`, cada call site
    ///      levava a sua propria copia INLINADA do
    ///      multi-venue quote engine (V2, V3, Solidly, V4). Two call sites meant two
    ///      copies inside this contract. The Solver is the largest contract in the protocol and
    ///      the one closest to the EIP-170 ceiling, so a duplicated call site is a duplicated
    ///      quote engine. R5, "one implementation per published quantity" — deduplication is a
    ///      size measure here, not a style preference.
    function _quote(PoolInfo memory cand, address tIn, uint256 amt)
        private view returns (uint256 out)
    {
        (out, ) = _quoteWithDepth(cand, tIn, amt);
    }

    // =========================================================================
    //  CANDIDATE SELECTION  (lazy discovery + top-K by fitness)
    // =========================================================================

    function _topKPools(address tA, address tB, uint8 keep)
        private view returns (PoolInfo[] memory out)
    {
        // Combine registered pools with discovered ones — never let one suppress
        // the other. Previously "if empty then discover" meant that once any pool
        // was registered for a pair, discovery stopped, so the most-used pairs saw
        // the fewest venues. Union both and dedup by pool address.
        PoolInfo[] memory reg = hub.getActivePools(tA, tB);
        // Gas path: trust a healthy, recently-ticked registry and SKIP the full
        // CREATE2 discovery sweep. New / thin / quiet pairs (registry not fresh)
        // still run discovery so freshly-deployed pools are picked up. Trade-off:
        // an actively-traded pair won't see a brand-new venue until it goes quiet
        // for DISCOVERY_TTL_SECONDS — tune the constants for coverage vs gas. This
        // re-introduces, behind a freshness gate, the "prefer registered" shortcut
        // that was previously removed for permanently suppressing discovery.
        PoolInfo[] memory dis;
        if (!_registryFresh(reg)) dis = hub.discoverFor(tA, tB);
        uint256 rn = reg.length;
        uint256 dn = dis.length;
        PoolInfo[] memory merged = new PoolInfo[](rn + dn);
        uint256 n;
        // ─── ADMISSIBILIDADE DE HOOKS ───
        // O Router recusa na EXECUCAO qualquer perna cujo hook altere deltas (RouterE(9)), e o
        // Solver nao sabia que essa regra existia: o `getActivePools` do Hub filtra por
        // `isHookLive` mas NAO por isto. O resultado era uma auto-DoS na porta canonica — o
        // `swapBestExactIn` montava in-frame uma rota que o proprio Router rejeitava, e o par
        // ficava sem porta sem que ninguem soubesse porque.
        //
        // A REGRA DA CASA, EXPLICITA: a verificacao do Router NAO se apaga para os por de acordo.
        // E ela que mantem o sistema fail-closed enquanto ISTO nao existir, e o desacordo entre
        // os dois e o DIAGNOSTICO. Acrescenta-se conhecimento ao Solver; nao se retira ao Router.
        //
        // VIVE AQUI E NAO NO `getActivePools` porque isto e uma decisao de ROTEAMENTO. O
        // `getActivePools` e um canal de LEITURA partilhado; filtrar la tirava a pool da vista de
        // TODOS os consumidores, incluindo de quem so quer inspecionar o registo.
        //
        // E VIVE DENTRO DESTES DOIS LOOPS, e nao num passo proprio a seguir, por uma restricao
        // material: sob via_ir esta funcao e inlinada no mesmo frame que o `_buildHop`, que esta
        // cronicamente a um slot do limite — um unico contador novo rebentava-o. Aqui reutiliza-se
        // o `n` que ja existe.
        //
        // CUSTO ZERO em chamadas: `hookAltersDeltas` le bits do proprio endereco do hook.
        for (uint256 i; i < rn; ) {
            if (!BPC.hookAltersDeltas(reg[i].hooks)) { merged[n] = reg[i]; unchecked { ++n; } }
            unchecked { ++i; }
        }
        for (uint256 i; i < dn; ) {
            bool dup;
            for (uint256 j; j < rn; ) { if (dis[i].pool == reg[j].pool) { dup = true; break; } unchecked { ++j; } }
            if (!dup && !BPC.hookAltersDeltas(dis[i].hooks)) { merged[n] = dis[i]; unchecked { ++n; } }
            unchecked { ++i; }
        }
        if (n == 0) return new PoolInfo[](0);

        PoolInfo[] memory active = new PoolInfo[](n);
        for (uint256 i; i < n; ) { active[i] = merged[i]; unchecked { ++i; } }

        // Compute fitness for each and select top-K with selection sort.
        // ONE batched external call for the whole candidate set (previously
        // keyOf + getPsi per candidate = 2n calls): pure view-path saving.
        uint256[] memory ps;
        {
            address[] memory pls = new address[](n);
            address[] memory t0s = new address[](n);
            address[] memory t1s = new address[](n);
            for (uint256 i; i < n; ) {
                pls[i] = active[i].pool;
                t0s[i] = active[i].token0;
                t1s[i] = active[i].token1;
                unchecked { ++i; }
            }
            ps = hub.psisOf(pls, t0s, t1s);
        }
        for (uint256 i; i < n; ) { if (ps[i] == 0) ps[i] = 1; unchecked { ++i; } }
        uint256 k = n < keep ? n : keep;
        out = new PoolInfo[](k);
        for (uint256 ki; ki < k; ) {
            uint256 bestI = ki;
            for (uint256 j = ki + 1; j < n; ) {
                if (ps[j] > ps[bestI]) bestI = j;
                unchecked { ++j; }
            }
            if (bestI != ki) {
                (active[ki], active[bestI]) = (active[bestI], active[ki]);
                (ps[ki],     ps[bestI])     = (ps[bestI],     ps[ki]);
            }
            out[ki] = active[ki];
            unchecked { ++ki; }
        }
    }

    /// @notice True when the pair's registered set is rich and recent enough to
    ///         trust without a fresh discovery sweep: at least MIN_FRESH_VENUES
    ///         registered pools saw activity within DISCOVERY_TTL_SECONDS (wall
    ///         clock). A pool never ticked (lastUpdateTs == 0) counts as stale, so
    ///         genuinely new pairs always fall through to discovery.
    function _registryFresh(PoolInfo[] memory reg) private view returns (bool) {
        uint256 rn = reg.length;
        if (rn < MIN_FRESH_VENUES) return false;
        uint256 fresh;
        for (uint256 i; i < rn; ) {
            uint256 s = hub.getSlot(hub.keyOf(reg[i].pool, reg[i].token0, reg[i].token1));
            uint256 last = uint256(BPC.decodeLastUpdateTs(s));
            if (last != 0 && block.timestamp - last <= DISCOVERY_TTL_SECONDS) {
                unchecked { ++fresh; }
                // Early exit: once enough fresh venues are found, the
                // remaining Hub staticcalls cannot change the answer.
                if (fresh >= MIN_FRESH_VENUES) return true;
            }
            unchecked { ++i; }
        }
        return false;
    }

    // =========================================================================
    //  FLOOR APPLICATION — assemble Route with the output floor
    // =========================================================================

    function _assembleRoute(Hop memory hop) private view returns (Route memory route) {
        _orderLegs(hop);
        Hop[] memory hops = new Hop[](1);
        hops[0] = hop;
        uint256 legs = hop.legs.length;

        uint256 totalImpactBps;
        for (uint256 i; i < legs; ) {
            uint256 d;
            if (BPC.kindHas(hop.legs[i].kind, BPC.A_RESERVES)) {
                (uint256 r0, uint256 r1) = BPC.getReserves(hop.legs[i].pool);
                uint256 rIn = hop.legs[i].zeroForOne ? r0 : r1;
                d = BPC.impactV2Bps(hop.legs[i].amountIn, rIn);
            } else if (BPC.kindHas(hop.legs[i].kind, BPC.A_CONC_POOL)) {
                uint128 liq  = BPC.getLiquidity(hop.legs[i].pool);
                uint160 sp   = BPC.getSqrtPriceX96(hop.legs[i].pool);
                d = BPC.impactV3Bps(
                        hop.legs[i].amountIn, sp, liq,
                        uint24(hop.legs[i].fee),
                        hop.legs[i].zeroForOne
                    );
            } else {
                d = 50; // conservative default for stable / V4 paths
            }
            totalImpactBps += d;
            unchecked { ++i; }
        }
        if (legs > 0) totalImpactBps = totalImpactBps / legs;

        uint256 floorBps = BPC.ironFloorBps(totalImpactBps, legs, 0);
        uint256 floorOut = BPC.mulDiv(hop.expectedOut, floorBps, BPC.BPS);

        route = Route({
            hops:              hops,
            totalOut:          hop.expectedOut,
            singleOut:         hop.expectedOut,
            singleOutFloor:    floorOut,
            expectedImpactBps: totalImpactBps,
            confidenceWad:     0,
            estGas:            _estGas(hop),
            hasSurplus:        hop.expectedOut > floorOut,
            isV4Bundle:        false
        });
    }

    /// @notice Assemble a multi-hop (bridge) route. Aggregates impact across
    ///         both stages and derives the output floor from the FINAL
    ///         output. Hops stay separate so the Router can rescale stage B
    ///         against the real bridge balance produced by stage A.
    function _assembleRouteMulti(
        Hop[] memory hops, address tIn, address tOut,
        uint256 amountIn, uint256 finalOut
    ) private view returns (Route memory route) {
        tIn; tOut; amountIn;   // retained for signature clarity
        for (uint256 i; i < hops.length; ) { _orderLegs(hops[i]); unchecked { ++i; } }
        uint256 totalImpactBps;
        uint256 totalLegs;
        for (uint256 h; h < hops.length; ) {
            uint256 legs = hops[h].legs.length;
            uint256 hopImpact;
            for (uint256 i; i < legs; ) {
                uint256 d;
                Leg memory L = hops[h].legs[i];
                if (BPC.kindHas(L.kind, BPC.A_RESERVES)) {
                    (uint256 r0, uint256 r1) = BPC.getReserves(L.pool);
                    uint256 rIn = L.zeroForOne ? r0 : r1;
                    d = BPC.impactV2Bps(L.amountIn, rIn);
                } else if (BPC.kindHas(L.kind, BPC.A_CONC_POOL)) {
                    uint128 liq2 = BPC.getLiquidity(L.pool);
                    uint160 sp2  = BPC.getSqrtPriceX96(L.pool);
                    d = BPC.impactV3Bps(
                            L.amountIn, sp2, liq2,
                            uint24(L.fee),
                            L.zeroForOne
                        );
                } else {
                    d = 50;
                }
                hopImpact += d;
                unchecked { ++i; }
            }
            if (legs > 0) hopImpact = hopImpact / legs;
            totalImpactBps += hopImpact;  // linear sum: safe over-estimate
            totalLegs += legs;
            unchecked { ++h; }
        }

        uint256 floorBps = BPC.ironFloorBps(totalImpactBps, totalLegs, 0);
        uint256 floorOut = BPC.mulDiv(finalOut, floorBps, BPC.BPS);

        route = Route({
            hops:              hops,
            totalOut:          finalOut,
            singleOut:         finalOut,
            singleOutFloor:    floorOut,
            expectedImpactBps: totalImpactBps,
            confidenceWad:     0,
            estGas:            _estGas(hops[0]) + _estGas(hops[1]),
            hasSurplus:        finalOut > floorOut,
            isV4Bundle:        false
        });
    }

    function _estGas(Hop memory hop) private pure returns (uint256 g) {
        g = 30_000;
        uint256 n = hop.legs.length;
        for (uint256 i; i < n; ) {
            // A escada vive na THETA_GAS (8 bits por kind, unidades de 5.000) e SO e lida
            // aqui — por isso e uma palavra separada da THETA_ATTR, que o Router, o Hub e o
            // Quoter carregam. O V4 nativo paga o mesmo unlock mais o unwrap/wrap JIT (~35k
            // estimados para WETH withdraw+deposit em slots quentes; re-medir no ensaio).
            g += BPC.kindGasBase(hop.legs[i].kind);
            unchecked { ++i; }
        }
    }
}
