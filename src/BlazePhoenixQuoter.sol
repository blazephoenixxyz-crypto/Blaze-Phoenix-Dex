// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixQuoter
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  SINGLE RESPONSIBILITY
//      Tell a person what they will receive, before they decide. Nothing else.
//
//  THE BOUNDARY THAT DEFINES THIS CONTRACT
//      WHAT THE QUOTER RETURNS IS NOT A SUBMITTABLE ROUTE. It is a PREVIEW:
//      expected value, slippage, path — so whoever is about to swap can look
//      before signing. The route that executes is computed on-chain at
//      execution time.
//
//      That is a design decision, not a limitation. If the output of a view
//      could be submitted as a plan, the preview would become an attack
//      surface: make the Quoter say the right number once, then use it when
//      state has already moved. Keeping the two apart means a compromised
//      Quoter fools the interface — and cannot move a single wei, because the
//      Router re-measures everything any plan asserts to it.
//
//  WHAT THIS CONTRACT GUARANTEES
//      Q1  Never overestimates on purpose. Where an exact measurement exists,
//          it is used; where only an approximation exists, it rounds DOWN.
//      Q2  `view` only. It does not write, does not spend, does not approve.
//      Q3  A route containing a pool flagged for hook misuse, or a denylisted
//          hook, is unquotable — it returns zero rather than a pretty number.
//
//  The Quoter is the read-only mirror of the Router. For a route it returns:
//
//      netOut = grossOut · (1 − fee) · (1 − safety(n))   [one single fee since 2026-08-22]
//
//  Where:
//
//    grossOut   — Solver's output (already net of pool fees).
//    fee        — Protocol fee, 28 BPS. THE EXPONENT H IS WHAT CHANGED ON 2026-08-21: the fee
//                 stopped being charged once on the quoted output and is now charged on EVERY
//                 HOP, on that hop's INPUT and in that hop's TOKEN. An H-hop route pays H times,
//                 compounded — hence the exponent.
//                 The reason is written in the Router (`_chargeHopFee`): a route is a path with
//                 two ends, and both are coordinates written by the caller, so any fee anchored
//                 to one END is evaded by extending the route past that end with a worthless
//                 token. It was MEASURED in both directions: anchored on the output, 996 tokens
//                 moved with ZERO fee; anchored on the input, the attacker prefixed a token they
//                 had minted themselves and received MORE than an honest user.
//    safety(n)  — Dynamic buffer: 0 BPS at ≤2 legs, +1 BPS per extra leg,
//                 capped at 10 BPS. Accounts for inter-leg drift.
//    A route is unquotable (returns zero) if it contains a pool flagged for
//    hook misuse or a denylisted hook.
//
//  WHAT `protocolFee` MEANS NOW, and the change matters to whoever reads the preview: the real
//  fee is charged in SEVERAL tokens (one per hop), so there is no single number in tokenOut that
//  is "the fee". The field reports the EFFECT of the fee on the output — how much less the user
//  receives because of it, expressed in tokenOut. That is the useful quantity for whoever is
//  about to swap, and it is honest as long as you know what it is. The treasuries receive
//  something else (each hop's input tokens), and it is the Router's `Fee` event that says what
//  was charged and in which token.
//
//  AND THE SURPLUS EXEMPTION DIED with the change: it was an output-side promise ("everything
//  above the quote is yours, fee-free") and it has no input-side analogue. Owner's decision,
//  2026-08-21.
//
//  NOTE on parity: this preview starts from the `route.totalOut` attested by the Solver, taken at
//  face value — appropriate here, because `previewPlan` obtains the `route` from a LIVE call to
//  the Solver in the same view context. The Router does NOT extend that trust to its execution
//  path. The difference from real execution is ordinary quote-to-settlement drift (a block or
//  more may pass), exactly as predicted output differs from realised output. It is not a
//  discrepancy to eliminate: the user's protection is userMinOut and the Router's floors, not the
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

    uint16  internal constant BASE_SAFETY_BPS   = 0;
    uint16  internal constant PER_LEG_SAFETY    = 1;
    uint16  internal constant SAFETY_CAP_BPS    = 10;
    /// @notice Extra buffer, per leg, for a leg whose fee was ASSUMED rather
    ///         than asked of the pool.
    /// @dev    `safety(n)` counted LEGS and ignored HOW each one was priced. A
    ///         Solidly leg asks the pool (`getAmountOut`), a V4 leg reads state
    ///         (`extsload`), a V3 leg reads `fee()` — model error ~0. A V2 leg
    ///         cannot: MEASURED 2026-08-25 on Base, the USDC/WETH pairs of all
    ///         four wired V2 venues (UniV2, PancakeV2, SushiV2, BaseSwap)
    ///         answer NONE of `swapFee()` / `fee()` / `feeRate()`. There is
    ///         nobody to ask, so the 30 bps default is unavoidable — and its
    ///         uncertainty is real and belongs in the published number.
    ///
    ///         WHY 5, AND WHAT IT DOES NOT COVER. Only ONE direction hurts:
    ///         assuming 30 where the pool charges LESS (Pancake's 25)
    ///         under-quotes and is harmless; assuming 30 where it charges MORE
    ///         over-quotes, and execution then delivers under `effectiveMinOut`
    ///         and reverts. The wired venues publish 25-30, so 5 bps covers the
    ///         realistic spread with margin while staying the same order as
    ///         PER_LEG_SAFETY. It deliberately does NOT cover the worst case
    ///         the V2 fee ceiling still admits (100 - 30 = 70 bps): a buffer
    ///         sized for the worst case IS a floor, and the floor already
    ///         exists (iron floor + the execution revert). This buffer exists
    ///         so `netOut` stops being silent about an assumed leg, not to
    ///         re-underwrite it.
    uint16  internal constant ASSUMED_FEE_SAFETY = 5;
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
        uint256 netOut;            // grossOut · (1 − fee) · (1 − safety)
        uint256 ironFloor;         // output floor supplied by the Solver
        uint256 userMinOut;        // user-supplied tighter floor (optional)
        uint256 effectiveMinOut;   // max(userMinOut, ironFloor)
        uint256 estGas;
        uint256 hops;
        uint256 legs;
        uint8   topology;          // 0 = direct, 1 = one bridge, 2 = two bridges
        //                            (= hops - 1; was ALWAYS 0 until 2026-08-22)
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
        external view returns (Preview memory)
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
        private view returns (Preview memory pv)
    {
        pv.route       = route;
        pv.grossOut    = route.totalOut;
        // THE FEE IS A SINGLE ONE, SINCE 2026-08-22. This loop used to compound
        // `(1-fee)^H` because the Router charged on EVERY hop: a 2-hop route lost
        // ~56 bps and a 3-hop one would lose ~84, when the constant says 28. With
        // three-hop topologies H was only going to grow.
        //
        // The Router now charges ONCE, on the first bridge currency it holds
        // (hop 1's input, or the output when a direct swap already ends in a
        // bridge). The effect on the output stops compounding: it is a single
        // discount.
        //
        // THIS IS THE SIBLING CHANNEL of `_chargeHopFee`. If one changes without
        // the other, the quote starts lying about what execution does again — the
        // defect signature of this codebase, recorded with N=3 in the corpus.
        uint256 afterFee = route.totalOut;
        // HOW MANY TIMES THE ROUTER WILL CHARGE (review 2026-09-04, FEE_01).
        // Everything above is true of the ANCHORED regime ONLY. `Router:1032-1036`
        // looks for the first hop whose input is a registered bridge; when there is
        // none, `feeHop` stays at `type(uint256).max` and the predicate at
        // `Router:1111` is TRUE FOR EVERY HOP. That is deliberate -- `Router:1021-1027`
        // calls it immunity by exhaustion, the only rule with no index at which to
        // insert a dust prefix -- and the sibling channel was never told. A preview
        // that always deducted once answered 28 bps while execution took ~56, which is
        // exactly the failure the comment above predicts for this pair of channels.
        //
        // THE SIGNAL IS ASKED OF THE PRODUCER, never re-derived: the same
        // `hub.isBridgeToken` the Router asks, in the same scan order. Iterating
        // `hub.bridge(i)` here instead would read the ARRAY while the Router reads the
        // MAPPING -- the desync reported by bai bo in the 4th wave and closed by making
        // `addBridge` idempotent. One question, one producer.
        // A single hop is charged ONCE under either regime: when its output is a bridge the
        // fee comes off the output (`Router:1408`), and the `!feeOnOut` guard at `Router:1111`
        // stops the input arm from doubling it. So the registry is only consulted when the
        // answer can actually differ - at two hops or more. That is not an optimisation
        // dressed up as a rule: asking a question whose answer cannot change the result is
        // how a `view` creeps into a path that had no business leaving its own frame, and
        // `test/QuoterAssumedFeeMargin.t.sol` depends on exactly that (it drives single-hop
        // routes against a Quoter built with a hub address that has no code).
        uint256 charges = 1;
        if (route.hops.length > 1) {
            bool anchored;
            for (uint256 fi; fi < route.hops.length; ) {
                if (hub.isBridgeToken(route.hops[fi].tokenIn)) { anchored = true; break; }
                unchecked { ++fi; }
            }
            if (!anchored) charges = route.hops.length;
        }
        for (uint256 c; c < charges; ) {
            // Round the fee UP here too, matching both Router sites. Rounding the
            // deduction up makes the preview understate netOut by at most 1 wei,
            // which is the safe direction: a preview must never promise more than
            // execution delivers.
            afterFee -= BPC.mulDivUp(afterFee, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
            unchecked { ++c; }
        }
        // The EFFECT of the fee on the output, in tokenOut. It is not what the
        // treasuries receive — they receive ONE BRIDGE token (WETH/USDC). See the
        // file header.
        pv.protocolFee = route.totalOut > afterFee ? route.totalOut - afterFee : 0;

        uint256 legs;
        // Legs priced on an ASSUMED fee. THE SIGNAL IS ASKED OF THE PRODUCER,
        // never re-derived: `effV2Fee(fee) != fee` means "the single producer
        // substituted", which is exactly the definition of an assumption — a
        // declared 0 (no fee known) and a declared 9_900 (above the ceiling)
        // are the same epistemic state and must be charged the same. Writing
        // `fee == 0 || fee > CEILING` here instead would be a second copy of
        // the producer's rule, which is the defect this codebase is named for
        // and which cost two fixes today alone (CoreV2QuoteParity, _gateCtx).
        // ONLY KIND_V2: Solidly is A_RESERVES too but asks the pool via
        // `getAmountOut`, so its zero fee is not a sentinel and charging it
        // would penalise the most exact family we have.
        uint256 assumedFeeLegs;
        for (uint256 h; h < route.hops.length; ) {
            Leg[] memory ls = route.hops[h].legs;
            legs += ls.length;
            for (uint256 i; i < ls.length; ) {
                if (ls[i].kind == BPC.KIND_V2 && BPC.effV2Fee(ls[i].fee) != ls[i].fee) {
                    unchecked { ++assumedFeeLegs; }
                }
                unchecked { ++i; }
            }
            unchecked { ++h; }
        }
        pv.hops = route.hops.length;
        pv.legs = legs;

        // safety(n): 0 at legs ≤ 2; +1 BPS per leg above 2; +ASSUMED_FEE_SAFETY
        // per leg priced on an assumed fee; cap 10. The composition-risk term
        // (leg count) and the model-error term (assumed fees) are independent
        // sources of the same uncertainty and add, under one shared cap — a
        // buffer without a ceiling stops being a buffer and becomes a floor.
        uint16 sBps;
        unchecked {
            uint256 calc = legs > 2 ? BASE_SAFETY_BPS + (legs - 2) * PER_LEG_SAFETY : 0;
            calc += assumedFeeLegs * ASSUMED_FEE_SAFETY;
            if (calc > SAFETY_CAP_BPS) calc = SAFETY_CAP_BPS;
            sBps = uint16(calc);
        }
        // R-C: the buffer is SUBTRACTED from the published netOut, so rounding it
        // up understates netOut — a preview must never promise more than
        // execution delivers.
        pv.safetyBuffer = BPC.mulDivUp(afterFee, sBps, BPC.BPS);
        pv.netOut       = afterFee > pv.safetyBuffer ? afterFee - pv.safetyBuffer : 0;

        // Output floor
        pv.ironFloor       = route.singleOutFloor;
        pv.userMinOut      = userMinOut;
        pv.effectiveMinOut = userMinOut > pv.ironFloor ? userMinOut : pv.ironFloor;

        pv.estGas     = route.estGas;
        pv.canExecute = pv.netOut > 0 && pv.netOut >= pv.effectiveMinOut;
        (pv.topology, pv.bridgeUsed) = _classify(route);
    }

    /// @dev A REAL CLASSIFIER since 2026-08-22. It used to be dead: it always
    ///      returned `(0, address(0))` and justified itself with "the Solver
    ///      collapses bridge routes into a single hop". **That is false** —
    ///      `_planViaBridge` has always returned `new Hop[](2)`, and there are
    ///      now three-hop routes as well. Consequence: `pv.topology` was ALWAYS 0
    ///      and `pv.bridgeUsed` ALWAYS zero, so any reader (the UI, a metrics
    ///      sweep) using them was reading a constant, not a measurement.
    ///
    ///      Topology derives from the NUMBER OF HOPS, which is the definition:
    ///      one hop is direct, two go through a bridge, three through two. And
    ///      the bridge used is hop 0's `tokenOut` — the first intermediate token
    ///      the route touches, which is also where the fee is charged.
    function _classify(Route memory route)
        private pure returns (uint8 topology, address bridgeUsed)
    {
        uint256 n = route.hops.length;
        if (n == 0 || route.hops[0].legs.length == 0) return (0, address(0));
        if (n == 1) return (0, address(0));                 // directo
        // 1 = via one bridge (2 hops), 2 = via two bridges (3 hops), ...
        return (uint8(n - 1), route.hops[0].tokenOut);
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
    ///         amounts across hops. `exactOut` is the execution-grade NET
    ///         output: the dry-run total less the protocol fee, deducted once
    ///         and rounded up exactly as `_pack` and the Router do, so it is
    ///         the floor the Router honours in this block — derive userMinOut
    ///         from it. The returned `route` keeps the pool-math attestation
    ///         (totalOut/singleOut gross) that the Router compares against;
    ///         the floor ratio chosen by the Solver is preserved and applied
    ///         to the exact total. Additive & opt-in:
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
                    // FALLBACK DIRECTION (Q1): the pool refused the dry-run, so
                    // the only known point is the plan's (amountIn, expectedOut).
                    // AMM output is concave: the linear rescale is the chord
                    // BELOW that point (understates — safe) and the tangent
                    // ABOVE it (overstates). Cap the ratio at 1: a refused leg
                    // may keep the plan's own claim, never exceed it.
                    if (legOut == 0)
                        legOut = BPC.mulDiv(
                            leg.expectedOut, legIn > base ? base : legIn, base);
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
                    // Same clamp as the A_CONC_POOL fallback above: the
                    // singleton could not price the leg (no manager, hook
                    // fail-closed, oversize amount), so never extrapolate the
                    // plan's point upward along the tangent.
                    if (legOut == 0)
                        legOut = BPC.mulDiv(
                            leg.expectedOut, legIn > base ? base : legIn, base);
                } else {
                    // SOLIDLY — priced via the ONE Core dispatcher, exactly like
                    // the V2 branch above (DEDUP BP-14/P4). universalQuote's
                    // KIND_SOLIDLY arm asks the pool itself first
                    // (solidlyGetAmountOut: the pair's own bytecode, so quote ==
                    // execution by construction); a fork without the selector
                    // falls to the replicated curve at the live fee with a
                    // 200 bps under-ask; a pool that answers nothing quotes 0.
                    // Every arm lands AT or BELOW execution truth. The previous
                    // linear rescale walked the TANGENT of a concave curve and
                    // OVERSTATED whenever carry outgrew the plan (reported at up
                    // to ~907 bps on a thin pool) — pinned RED-first by
                    // test/QuoterOverQuote.t.sol. Tombstone kinds also land here
                    // and now quote 0 (universalQuote's fail-closed default)
                    // instead of a rescaled ghost. NOTE: a FRESH ctx — the `qc`
                    // above is PINNED to KIND_V2, and reusing it would price
                    // Solidly on the constant-product arm. tokenIn is REQUIRED
                    // (getAmountOut is direction-keyed on it); tokenOther only
                    // feeds the depth read, which is discarded here.
                    QuoteCtx memory sc;
                    sc.kind       = BPC.KIND_SOLIDLY;
                    sc.pool       = leg.pool;
                    sc.zeroForOne = leg.zeroForOne;
                    sc.fee        = leg.fee;
                    sc.stable     = leg.stable;
                    sc.tokenIn    = route.hops[h].tokenIn;
                    sc.tokenOther = route.hops[h].tokenOut;
                    (legOut, ) = BPC.universalQuote(sc, legIn);
                }
                route.hops[h].legs[l].amountIn    = legIn;
                route.hops[h].legs[l].expectedOut = legOut;
                hopOut += legOut;
            }
            route.hops[h].amountIn    = carry;
            route.hops[h].expectedOut = hopOut;
            carry = hopOut;
        }
        // The route keeps the POOL-MATH attestation: totalOut/singleOut are
        // what the Router compares realised leg output against, and the fee is
        // the Router's own deduction on the way out — exactly as `_pack` reads
        // `route.totalOut` gross and derives `netOut` from it.
        uint256 gross = carry;
        uint256 floorExact = route.totalOut == 0
            ? 0 : BPC.mulDiv(route.singleOutFloor, gross, route.totalOut);
        route.totalOut       = gross;
        route.singleOut      = gross;
        route.singleOutFloor = floorExact;
        route.hasSurplus     = gross > floorExact;
        // FEE-02 (register row PROTOCOL_FEE_BPS; PoC in the eighth disclosure
        // round, closed 2026-09-03). The scalar an integrator turns into
        // `userMinOut` must be NET: the Router charges PROTOCOL_FEE_BPS on the
        // output of every route, so a dry-run total returned as "execution-
        // grade" over-promised by exactly the fee, and a minOut derived from it
        // with a buffer under 28 bps died in RouterE(5) every time. One
        // deduction, rounded UP — so the preview never promises a wei more than
        // delivery.
        //
        // ONE DEDUCTION IS CORRECT HERE FOR A REASON THIS LINE DOES NOT STATE, so it is
        // stated now (review 2026-09-04, FEE_01). `_pack` no longer deducts unconditionally:
        // it asks whether the route touches a bridge, because `Router:1111` charges EVERY hop
        // when none does. This entry point takes no Route — only (tIn, tOut, amountIn) — so the
        // route is the Solver's, and the Solver composes multi-hop only through registered
        // bridges. The exhaustion regime is therefore unreachable from here.
        //
        // That is safety by CONSTRUCTION OF THE INPUT, not by this function's own logic. The
        // day the Solver composes a bridgeless multi-hop route, this line is wrong and nothing
        // here will say so. If that day comes, this must borrow `_pack`'s scan.
        exactOut = gross - BPC.mulDivUp(gross, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function bridgeAt(uint8 i) external view returns (address) { return hub.bridge(i); }
    function bridgesCount() external view returns (uint8) { return hub.bridgeCount(); }
    function isBridge(address t) external view returns (bool) { return hub.isBridgeToken(t); }
}
