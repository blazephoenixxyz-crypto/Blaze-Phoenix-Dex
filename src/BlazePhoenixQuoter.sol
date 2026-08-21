// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixQuoter
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  RESPONSABILIDADE UNICA
//      Dizer a uma pessoa o que ela vai receber, antes de decidir. Nada mais.
//
//  A FRONTEIRA QUE DEFINE ESTE CONTRATO
//      O QUE O QUOTER DEVOLVE NAO E UMA ROTA SUBMETIVEL. E um PREVIEW: valor
//      esperado, slippage, caminho, para quem vai trocar poder olhar antes de
//      assinar. A rota que executa e calculada on-chain no momento da execucao.
//
//      Isto e uma decisao de desenho, nao uma limitacao. Se a saida de um view
//      pudesse ser submetida como plano, o preview passava a ser uma superficie
//      de ataque: bastava fazer o Quoter dizer o numero certo uma vez e usa-lo
//      quando o estado ja fosse outro. Separando os dois, um Quoter comprometido
//      engana a interface — e nao consegue mover um unico wei, porque o Router
//      volta a medir tudo o que qualquer plano lhe afirme.
//
//  O QUE ESTE CONTRATO GARANTE
//      Q1  Nunca sobrestima de proposito. Onde a medicao exata existe, usa-se a
//          medicao; onde so ha aproximacao, aproxima-se PARA BAIXO.
//      Q2  So `view`. Nao escreve, nao gasta, nao autoriza.
//      Q3  Uma rota que contenha uma pool marcada por abuso de hook, ou um hook
//          em denylist, nao e cotavel — devolve zero em vez de um numero bonito.
//
//  The Quoter is the read-only mirror of the Router. For a route it returns:
//
//      netOut = grossOut · (1 − fee)^H · (1 − safety(n))
//
//  Where:
//
//    grossOut   — Solver's output (already net of pool fees).
//    fee        — Protocol fee, 28 BPS. E O EXPOENTE H QUE MUDOU EM 2026-08-21: a fee deixou de
//                 ser cobrada uma vez sobre a saida cotada e passa a ser cobrada em CADA HOP,
//                 sobre a ENTRADA desse hop e no TOKEN desse hop. Uma rota de H hops paga H
//                 vezes, composto — e por isso o expoente.
//                 A razao esta escrita no Router (`_chargeHopFee`): uma rota e um caminho com
//                 duas pontas e ambas sao coordenadas escritas pelo chamador, logo qualquer fee
//                 ancorada numa PONTA e evadida estendendo a rota para la dessa ponta com um
//                 token sem valor. Foi MEDIDO nas duas direccoes: ancorada na saida, 996 tokens
//                 moveram-se com fee ZERO; ancorada na entrada, o atacante prefixava com um token
//                 que cunhou e recebia MAIS que o utilizador honesto.
//    safety(n)  — Dynamic buffer: 0 BPS at ≤2 legs, +1 BPS per extra leg,
//                 capped at 10 BPS. Accounts for inter-leg drift.
//    A route is unquotable (returns zero) if it contains a pool flagged for
//    hook misuse or a denylisted hook.
//
//  O QUE `protocolFee` SIGNIFICA AGORA, e a mudanca importa para quem le o preview: a fee real e
//  cobrada em VARIOS tokens (um por hop), portanto nao existe um unico numero em tokenOut que
//  seja "a fee". O campo reporta o EFEITO da fee sobre a saida — quanto menos o utilizador recebe
//  por causa dela, expresso em tokenOut. E a grandeza util para quem vai trocar, e e honesta
//  desde que se saiba o que e. As tesourarias recebem outra coisa (os tokens de entrada de cada
//  hop), e o evento `Fee` do Router e que diz o que foi cobrado e em que token.
//
//  E A ISENCAO DO EXCEDENTE MORREU com a mudanca: era uma promessa do lado da saida ("tudo acima
//  da quote e teu, sem fee") e nao tem analogo do lado da entrada. Decisao do dono, 2026-08-21.
//
//  NOTA sobre paridade: este preview parte do `route.totalOut` atestado pelo Solver, tomado pelo
//  valor de face — apropriado aqui, porque o `previewPlan` obtem a `route` de uma chamada VIVA ao
//  Solver no mesmo contexto de view. O Router NAO estende essa confianca ao seu caminho de
//  execucao. A diferenca com a execucao real e deriva normal de cotacao-para-liquidacao (pode
//  passar um bloco ou mais), exatamente como a saida prevista difere da realizada. Nao e uma
//  discrepancia a eliminar: a protecao do utilizador e o userMinOut e os pisos do Router, nao
//  preview's fee line.
// =============================================================================
pragma solidity 0.8.36;

import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg, RoutePlan, QuoteCtx
} from "./BlazePhoenixCore.sol";

interface ISolverQ {
    function findBestRoutePlan(address tIn, address tOut, uint256 amountIn)
        external view returns (RoutePlan memory);
}

interface IV4Q {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(V4PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
}

interface IConcPoolQ {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified,
                  uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

interface IHubQ {
    function v4PoolManager() external view returns (address);
    function bridgeCount() external view returns (uint8);
    function bridge(uint8 i) external view returns (address);
    function isBridgeToken(address t) external view returns (bool);
}

contract BlazePhoenixQuoter {

    string  public constant VERSION             = "2.0.0";

    uint16  internal constant PROTOCOL_FEE_BPS  = 28;     // 0.28%
    uint16  internal constant BASE_SAFETY_BPS   = 0;
    uint16  internal constant PER_LEG_SAFETY    = 1;
    uint16  internal constant SAFETY_CAP_BPS    = 10;
    uint16  internal constant MAX_BATCH         = 32;

    ISolverQ public immutable solver;
    IHubQ    public immutable hub;

    error QuoterE(uint16 code);

    constructor(address hub_, address solver_) {
        if (hub_ == address(0) || solver_ == address(0)) revert QuoterE(3);
        hub    = IHubQ(hub_);
        solver = ISolverQ(solver_);
    }

    // =========================================================================
    //  Preview API
    // =========================================================================

    struct Preview {
        Route   route;
        uint256 grossOut;          // U(route)
        uint256 protocolFee;       // o EFEITO da fee sobre a saida, em tokenOut (ver cabecalho)
        uint256 safetyBuffer;      // safety(n) × afterFee
        uint256 netOut;            // grossOut · (1 − fee)^H · (1 − safety)
        uint256 ironFloor;         // output floor supplied by the Solver
        uint256 userMinOut;        // user-supplied tighter floor (optional)
        uint256 effectiveMinOut;   // max(userMinOut, ironFloor)
        uint256 estGas;
        uint256 hops;
        uint256 legs;
        uint8   topology;          // 0 = direct, 1 = via bridge
        address bridgeUsed;
        bool    canExecute;
    }

    struct BatchEntry {
        address tIn;
        address tOut;
        uint256 amountIn;
        uint256 userMinOut;
    }

    /// @notice Primary preview entry. Asks the Solver for the U-maximiser and
    ///         returns the full 𝒬(route) breakdown plus the fallback route.
    function previewPlan(address tIn, address tOut, uint256 amountIn)
        external view returns (Preview memory pv, Route memory fallbackRoute, bool hasFallback)
    {
        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, amountIn);
        pv = _pack(plan.best, 0);
        fallbackRoute = plan.fallbackRoute;
        hasFallback   = plan.hasFallback;
    }

    /// @notice Same as previewPlan but accepts a user-tightened minOut.
    ///         effectiveMinOut = max(userMinOut, ironFloor) — the user can
    ///         only tighten the floor, never weaken it.
    function previewPlanWithMinOut(
        address tIn, address tOut, uint256 amountIn, uint256 userMinOut
    ) external view returns (Preview memory pv, Route memory fallbackRoute, bool hasFallback) {
        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, amountIn);
        pv = _pack(plan.best, userMinOut);
        fallbackRoute = plan.fallbackRoute;
        hasFallback   = plan.hasFallback;
    }

    /// @notice Preview an already-built Route (e.g. one returned previously
    ///         and persisted off-chain) without re-running the Solver.
    function previewRoute(Route memory route, uint256 userMinOut)
        external pure returns (Preview memory)
    {
        return _pack(route, userMinOut);
    }

    /// @notice Batch quote — up to MAX_BATCH tuples per call.
    function batchQuote(BatchEntry[] calldata entries)
        external view returns (Preview[] memory previews)
    {
        uint256 n = entries.length;
        if (n > MAX_BATCH) revert QuoterE(4);
        previews = new Preview[](n);
        for (uint256 i; i < n; ) {
            BatchEntry calldata e = entries[i];
            try solver.findBestRoutePlan(e.tIn, e.tOut, e.amountIn) returns (RoutePlan memory p) {
                previews[i] = _pack(p.best, e.userMinOut);
            } catch { /* leave zero-initialised */ }
            unchecked { ++i; }
        }
    }

    // =========================================================================
    //  Preview packer
    // =========================================================================

    function _pack(Route memory route, uint256 userMinOut)
        private pure returns (Preview memory pv)
    {
        pv.route       = route;
        pv.grossOut    = route.totalOut;
        // A FEE E POR HOP, E COMPOE. Cada hop cobra sobre a SUA entrada, portanto a saida sofre
        // o desconto uma vez por hop, multiplicativamente — nao uma vez sobre o total. Uma rota
        // de dois hops perde ~56 bps, nao 28. Iterar (H <= 3 neste desenho) e exato; uma
        // aproximacao linear `H * 28 bps` sobre-estimava a perda e faria o preview mentir para
        // baixo, que e o lado errado para mentir.
        uint256 afterFee = route.totalOut;
        for (uint256 h; h < route.hops.length; ) {
            afterFee -= BPC.mulDiv(afterFee, PROTOCOL_FEE_BPS, BPC.BPS);
            unchecked { ++h; }
        }
        // O EFEITO da fee sobre a saida, em tokenOut. Nao e o que as tesourarias recebem — elas
        // recebem os tokens de ENTRADA de cada hop. Ver o cabecalho.
        pv.protocolFee = route.totalOut > afterFee ? route.totalOut - afterFee : 0;

        uint256 legs;
        for (uint256 h; h < route.hops.length; ) {
            legs += route.hops[h].legs.length;
            unchecked { ++h; }
        }
        pv.hops = route.hops.length;
        pv.legs = legs;

        // safety(n): 0 at legs ≤ 2; +1 BPS per leg above 2; cap 10
        uint16 sBps;
        if (legs > 2) {
            unchecked {
                uint256 calc = BASE_SAFETY_BPS + (legs - 2) * PER_LEG_SAFETY;
                if (calc > SAFETY_CAP_BPS) calc = SAFETY_CAP_BPS;
                sBps = uint16(calc);
            }
        }
        pv.safetyBuffer = BPC.mulDiv(afterFee, sBps, BPC.BPS);
        pv.netOut       = afterFee > pv.safetyBuffer ? afterFee - pv.safetyBuffer : 0;

        // Output floor
        pv.ironFloor       = route.singleOutFloor;
        pv.userMinOut      = userMinOut;
        pv.effectiveMinOut = userMinOut > pv.ironFloor ? userMinOut : pv.ironFloor;

        pv.estGas     = route.estGas;
        pv.canExecute = pv.netOut > 0 && pv.netOut >= pv.effectiveMinOut;
        (pv.topology, pv.bridgeUsed) = _classify(route);
    }

    function _classify(Route memory route)
        private pure returns (uint8 topology, address bridgeUsed)
    {
        if (route.hops.length == 0) return (0, address(0));
        if (route.hops[0].legs.length == 0) return (0, address(0));
        // v2.0.0: the Solver collapses bridge routes into a single hop, so the
        // classifier reports a flat (direct) topology. Richer bridge inspection
        // for the UI is deferred to a later version.
        return (0, address(0));
    }

    // =========================================================================
    //  Bridge inspection (for UI / classifier)
    // =========================================================================

    // =========================================================================
    //  EXACT PASS — "the quote IS the execution" (revert-extraction dry-run)
    //
    //  The ask-the-pool doctrine (quote fn == exec fn => cannot diverge),
    //  generalised to every concentrated venue: the only number
    //  that cannot diverge from the swap is the swap itself. We call the
    //  pool's REAL swap; our fallback intercepts the universal V3-shaped
    //  callback and reverts with the two deltas; the revert unwinds ALL
    //  state (stateless by construction) and we decode the exact output
    //  from the revert data. No tick math, no replication — both directions
    //  run the pool's own bytecode, so the replication-bug class is
    //  structurally impossible. Mirrors the official QuoterV2 / V4Quoter
    //  mechanism and the Router's universal execution fallback.
    // =========================================================================

    /// @dev Universal QUOTE callback: any V3-shaped pool callback
    ///      ((int256,int256,bytes), any selector) lands here and is answered
    ///      with a revert carrying the deltas. The Quoter never pays, never
    ///      holds funds, and no state can persist through this path.
    fallback() external {
        if (msg.data.length < 4 + 64) revert QuoterE(6);
        int256 a0; int256 a1;
        assembly { a0 := calldataload(4) a1 := calldataload(36) }
        bytes memory payload = abi.encode(a0, a1);
        assembly { revert(add(payload, 32), mload(payload)) }
    }

    /// @notice Exact-in dry-run on a concentrated pool (V3/Algebra family).
    ///         Returns the pool-computed output; 0 if the pool refused.
    function _simConc(address pool, bool zfo, uint256 amtIn)
        internal returns (uint256 out)
    {
        if (amtIn == 0 || amtIn > uint256(type(int256).max)) return 0;
        uint160 limit = zfo ? BPC.MIN_SQRT_PRICE_PLUS_ONE
                            : BPC.MAX_SQRT_PRICE_MINUS_ONE;
        try IConcPoolQ(pool).swap(address(this), zfo, int256(amtIn), limit, "")
            returns (int256, int256)
        {
            return 0; // cannot happen: we never pay; treat as no-quote
        } catch (bytes memory reason) {
            if (reason.length != 64) return 0; // pool-side revert, not our payload
            (int256 a0, int256 a1) = abi.decode(reason, (int256, int256));
            int256 recv = zfo ? a1 : a0;
            if (recv >= 0) return 0;
            out = uint256(-recv);
        }
    }

    /// @dev V4 QUOTE callback: the PoolManager calls this BY NAME during
    ///      unlock(). We run the REAL swap and revert with the deltas — the
    ///      official V4Quoter uses this exact mechanism. The revert unwinds
    ///      all PoolManager state; nothing persists, nothing is owed (the
    ///      lock dissolves with the revert).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        address mgr = hub.v4PoolManager();
        if (msg.sender != mgr) revert QuoterE(6);
        (IV4Q.V4PoolKey memory key, bool zfo, uint256 amt)
            = abi.decode(data, (IV4Q.V4PoolKey, bool, uint256));
        IV4Q.SwapParams memory p = IV4Q.SwapParams({
            zeroForOne:        zfo,
            amountSpecified:   -int256(amt),   // negative = exact input (V4)
            sqrtPriceLimitX96: zfo ? BPC.MIN_SQRT_PRICE_PLUS_ONE
                                   : BPC.MAX_SQRT_PRICE_MINUS_ONE
        });
        int256 bd = IV4Q(mgr).swap(key, p, "");
        int256 d0 = int256(int128(bd >> 128));
        int256 d1 = int256(int128(bd));
        bytes memory payload = abi.encode(d0, d1);
        assembly { revert(add(payload, 32), mload(payload)) }
    }

    /// @notice Exact-in dry-run on a V4 pool via unlock+revert. Mirrors the
    ///         Router execution exactly: same key construction (sortTokens of
    ///         hop tokenIn and auxId counterpart), same fail-closed policy
    ///         for delta-altering hooks. Returns 0 when the dry-run cannot
    ///         speak (caller falls back to the plan-time approximation).
    function _simV4(Leg memory leg, address tokenIn, uint256 amtIn)
        internal returns (uint256 out)
    {
        if (amtIn == 0 || amtIn > uint256(uint128(type(int128).max))) return 0;
        address mgr = hub.v4PoolManager();
        if (mgr == address(0)) return 0;
        if (leg.hooks != address(0) && BPC.hookAltersDeltas(leg.hooks)) return 0;
        address tokenOther = address(uint160(uint256(leg.auxId)));
        if (tokenOther == address(0)) return 0;
        if (leg.kind == BPC.KIND_V4_NATIVE) {
            // Native pool: substitute address(0) for the wrapped-native side.
            // Which side that is falls out of zeroForOne alone (the Solver's
            // orientation contract: zeroForOne ⇔ the input is the pool's
            // currency0, and a native pool's currency0 is ALWAYS address(0)
            // since it sorts first) — so no WETH address is needed here, and
            // the Quoter never settles anything: the dry-run reverts before
            // any payment, making a wrong key merely a 0-quote, never a loss.
            // For a well-formed leg this derivation agrees exactly with the
            // Router's weth-verified substitution — same key, same poolId.
            if (leg.zeroForOne) tokenIn = address(0);
            else tokenOther = address(0);
        }
        (address c0, address c1) = BPC.sortTokens(tokenIn, tokenOther);
        IV4Q.V4PoolKey memory key = IV4Q.V4PoolKey({
            currency0: c0, currency1: c1, fee: leg.fee,
            tickSpacing: leg.tickSpacing, hooks: leg.hooks
        });
        try IV4Q(mgr).unlock(abi.encode(key, leg.zeroForOne, amtIn))
            returns (bytes memory)
        {
            return 0;
        } catch (bytes memory reason) {
            if (reason.length != 64) return 0;
            (int256 d0, int256 d1) = abi.decode(reason, (int256, int256));
            int256 rv = leg.zeroForOne ? d1 : d0;
            if (rv <= 0) return 0;
            out = uint256(rv);
        }
    }

    /// @notice Truth-corrected plan: explore with the Solver (view formulas),
    ///         then re-price the chosen route by dry-running every
    ///         concentrated leg on the pool itself, propagating exact
    ///         amounts across hops. totalOut/singleOutFloor become
    ///         execution-grade; the floor ratio chosen by the Solver is
    ///         preserved and applied to the exact total. Additive & opt-in:
    ///         no existing path is modified. Call via eth_call (non-view by
    ///         necessity, like the official quoters; reverts make it
    ///         state-free).
    function previewPlanExact(address tIn, address tOut, uint256 amountIn)
        external returns (Route memory route, uint256 exactOut)
    {
        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, amountIn);
        route = plan.best;
        if (route.hops.length == 0) return (route, 0);
        uint256 carry = amountIn; // exact input entering the current hop
        for (uint256 h; h < route.hops.length; h++) {
            uint256 plannedIn = route.hops[h].amountIn == 0
                ? carry : route.hops[h].amountIn;
            // HOP-0 CAP — the quote-side twin of BlazePhoenixRouter.sol:514.
            // carry starts at the caller's FULL order, but when the Solver's
            // capacity clamp fired the plan committed LESS than that, so
            // carry/plannedIn > 1 would rescale every leg back to its
            // PRE-clamp size and dry-run the pool with liquidity the plan
            // never committed — an "execution-grade" quote that no execution
            // can fill (the NetGakarot shape the Router already caps). The
            // Router never spends more than the committed Σ leg.amountIn on
            // hop 0; the quote must not price more than the Router spends.
            // Later hops legitimately scale: their carry is a real output.
            if (h == 0 && carry > plannedIn) carry = plannedIn;
            uint256 hopOut;
            for (uint256 l; l < route.hops[h].legs.length; l++) {
                Leg memory leg = route.hops[h].legs[l];
                uint256 base   = leg.amountIn == 0 ? 1 : leg.amountIn;
                uint256 legIn  = plannedIn == 0
                    ? 0 : BPC.mulDiv(leg.amountIn, carry, plannedIn);
                uint256 legOut;
                if (BPC.kindHas(leg.kind, BPC.A_CONC_POOL)) {
                    legOut = _simConc(leg.pool, leg.zeroForOne, legIn);
                    if (legOut == 0)
                        legOut = BPC.mulDiv(leg.expectedOut, legIn, base);
                } else if (leg.kind == BPC.KIND_V2) {
                    // DEDUP BP-14/P4: price via the ONE Core dispatcher — the
                    // same deployed library bytecode the Solver links — not a
                    // local re-implementation of the V2 branch. The 0 -> 30
                    // bps fee default now lives in universalQuote alone
                    // (parity pinned by test/CoreV2QuoteParity.t.sol). The
                    // ctx carries coordinates only; the KIND_V2 branch reads
                    // pool/zeroForOne/fee and nothing else. NOTE: structural
                    // quote==exec coherence holds for Solver<->Quoter here;
                    // the Router keeps its own inlined copies (gas/stack) —
                    // compile-time coherence, registered in the Seam Register.
                    QuoteCtx memory qc;
                    qc.kind       = BPC.KIND_V2;
                    qc.pool       = leg.pool;
                    qc.zeroForOne = leg.zeroForOne;
                    qc.fee        = leg.fee;
                    (legOut, ) = BPC.universalQuote(qc, legIn);
                } else if (BPC.kindHas(leg.kind, BPC.A_CONC_SING)) {
                    legOut = _simV4(leg, route.hops[h].tokenIn, legIn);
                    if (legOut == 0)
                        legOut = BPC.mulDiv(leg.expectedOut, legIn, base);
                } else {
                    // SOLIDLY e hoje o UNICO kind VIVO a aterrar aqui — os outros
                    // dois que ca caiam eram lapides. A escala linear e uma
                    // APROXIMACAO num sitio onde a medicao exacta existe
                    // (solidlyGetAmountOut). ARMADILHA, antes de alguem a corrigir:
                    // o `qc.kind` acima esta FIXADO em KIND_V2, portanto encaminhar
                    // este ramo por universalQuote sem tocar nessa linha passaria a
                    // cotar Solidly pelo braco constant-product — pior que hoje.
                    legOut = BPC.mulDiv(leg.expectedOut, legIn, base);
                }
                route.hops[h].legs[l].amountIn    = legIn;
                route.hops[h].legs[l].expectedOut = legOut;
                hopOut += legOut;
            }
            route.hops[h].amountIn    = carry;
            route.hops[h].expectedOut = hopOut;
            carry = hopOut;
        }
        exactOut = carry;
        uint256 floorExact = route.totalOut == 0
            ? 0 : BPC.mulDiv(route.singleOutFloor, exactOut, route.totalOut);
        route.totalOut       = exactOut;
        route.singleOut      = exactOut;
        route.singleOutFloor = floorExact;
        route.hasSurplus     = exactOut > floorExact;
    }

    function bridgeAt(uint8 i) external view returns (address) { return hub.bridge(i); }
    function bridgesCount() external view returns (uint8) { return hub.bridgeCount(); }
    function isBridge(address t) external view returns (bool) { return hub.isBridgeToken(t); }
}
