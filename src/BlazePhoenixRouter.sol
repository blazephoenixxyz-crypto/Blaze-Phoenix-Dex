// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixRouter
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  The Router executes a route leg by leg. A leg's kind selects the AMM
//  interaction shape, and the calldata is built by a single dispatcher
//  rather than per-DEX functions. The Router consists of:
//
//      • one entry per auth scheme: classic, Permit2, EIP-7702
//      • one swap-callback fallback that handles every V3-shaped DEX
//      • one V4 unlock-and-settle sequence for PoolManager singletons
//      • a 0.28% protocol fee on the quoted output, split 30/70 between two
//        treasuries; any output above the quoted amount (surplus) is paid in
//        full to the user and is fee-exempt.
//
//  Each leg's output is computed via the Core quote dispatcher before the
//  on-chain swap, and the received amount is checked against the output
//  floor. Registry feedback (Hub.recordSwap) is sent only on the success
//  path, so no storage is written when the floor rejects.
// =============================================================================
pragma solidity 0.8.36;

import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg
} from "./BlazePhoenixCore.sol";

interface IHubW {
    function recordSwap(
        address pool, uint8 kind, uint24 fee, address hooks,
        address tA, address tB, uint256 amtIn, uint256 amtOut, uint256 depthWad
    ) external;
    function v4PoolManager() external view returns (address);
    function bridge(uint8 i) external view returns (address);
    function bridgeCount() external view returns (uint8);
}

interface IPermit2 {
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
    struct TokenPermissions { address token; uint256 amount; }
    struct SignatureTransferDetails { address to; uint256 requestedAmount; }
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner, bytes calldata signature
    ) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV3PoolMin {
    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 sqrtPriceLimitX96, bytes calldata data
    ) external returns (int256, int256);
}

interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    struct V4PoolKey {
        address currency0; address currency1; uint24 fee;
        int24 tickSpacing; address hooks;
    }
    struct SwapParams {
        bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96;
    }
    function swap(
        V4PoolKey calldata key, SwapParams calldata params, bytes calldata hookData
    ) external returns (int256 balanceDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

contract BlazePhoenixRouter {

    string  public constant VERSION             = "2.0.0";

    uint16  internal constant PROTOCOL_FEE_BPS  = 28;       // 0.28%
    /// @dev Treasury 1 takes 30% of the fee; treasury 2 takes the remainder (70%), computed as
    ///      `fee - t1` so the two always sum to exactly `fee` with no rounding dust left behind.
    ///      Deliberately NOT paired with a TREASURY2_SHARE constant: a second constant would be
    ///      dead (nothing could read it) and would silently drift into a lie the moment this one
    ///      changed.
    uint16  internal constant TREASURY1_SHARE   = 3_000;
    uint8   internal constant MAX_LEGS_PER_HOP  = 5;

    /// @notice Per-leg output floor, in BPS of the leg's pro-rata attested
    ///         quote. Bounds the damage any single manipulated / sandwiched
    ///         pool can inflict REGARDLESS of how loose the caller's aggregate
    ///         userMinOut is: each leg must deliver at least this fraction of
    ///         its own quote, rescaled to the input it actually spent. Raised
    ///         to 80% to match the aggregate hard floor (BlazePhoenixCore.
    ///         FLOOR_HARD_MAX_LOSS_BPS): the protocol runs across Ethereum L1
    ///         and multiple L2s where public mempools make single-pool
    ///         manipulation a live threat, so the per-leg guard is tightened
    ///         rather than left looser than the aggregate.
    uint16  internal constant LEG_FLOOR_BPS     = 8_000;

    /// @notice Transient storage slots — used to pass per-swap context to
    ///         the universal callback fallback without dirtying state.
    uint256 private constant TSLOT_POOL  = uint256(keccak256("blaze.r.pool"));
    uint256 private constant TSLOT_TOKEN = uint256(keccak256("blaze.r.token"));
    uint256 private constant TSLOT_AMT   = uint256(keccak256("blaze.r.amt"));
    uint256 private constant TSLOT_V4IN  = uint256(keccak256("blaze.r.v4in"));
    uint256 private constant TSLOT_V4OUT = uint256(keccak256("blaze.r.v4out"));
    uint256 private constant TSLOT_LOCK  = uint256(keccak256("blaze.r.lock"));
    uint256 private constant TSLOT_FOT   = uint256(keccak256("blaze.r.fot"));

    IHubW public immutable hub;
    address public immutable solver;

    address public admin;
    address public treasury1;
    address public treasury2;
    address public permit2;
    bool    public paused;
    bool    public controlRenounced;

    event Swap(
        address indexed user, address indexed tokenIn, address indexed tokenOut,
        uint256 amountIn, uint256 amountOut, uint256 legs
    );
    event Fee(address indexed token, uint256 amount, uint256 toT1, uint256 toT2);
    event Surplus(address indexed token, uint256 amount);
    event Cfg(uint8 id, address who);

    error RouterE(uint16 code);
    // 1 = unauthorized, 2 = paused, 3 = bad input, 4 = deadline,
    // 5 = slippage, 6 = callback auth, 7 = reentrancy, 8 = swap failed,
    // 9 = disallowed V4 hook, 10 = userMinOut == 0 with amountIn > 0 (BP-04)

    modifier onlyAdmin() { if (msg.sender != admin) revert RouterE(1); _; }
    // Control powers (treasuries, permit2, pause, admin transfer) are disabled
    // forever once renounceControl() is called.
    modifier onlyControl() { if (msg.sender != admin || controlRenounced) revert RouterE(1); _; }
    modifier whenLive()  { if (paused) revert RouterE(2); _; }
    modifier nrEntrant() {
        uint256 s = TSLOT_LOCK;
        uint256 v; assembly { v := tload(s) }
        if (v != 0) revert RouterE(7);
        assembly { tstore(s, 1) }
        _;
        assembly { tstore(s, 0) }
    }

    constructor(address hub_, address solver_, address admin_, address t1, address t2) {
        if (hub_ == address(0) || solver_ == address(0) || admin_ == address(0)) revert RouterE(3);
        hub      = IHubW(hub_);
        solver   = solver_;
        admin    = admin_;
        treasury1 = t1 == address(0) ? admin_ : t1;
        treasury2 = t2 == address(0) ? admin_ : t2;
        permit2   = BPC.PERMIT2_DEFAULT;
    }

    // ─── Admin (compacted) ────────────────────────────────────────────

    function setAdmin(address a)            external onlyControl { if(a==address(0))revert RouterE(3); admin=a; emit Cfg(0,a); }
    function setTreasuries(address t1, address t2) external onlyControl {
        if (t1==address(0)||t2==address(0)) revert RouterE(3);
        treasury1=t1; treasury2=t2; emit Cfg(1,t1); emit Cfg(2,t2);
    }
    function setPermit2(address p)          external onlyControl { permit2=p; emit Cfg(3,p); }
    function setPaused(bool b)              external onlyControl { paused=b; }

    /// @notice Permanently surrender every control power. Treasuries, the
    ///         Permit2 address, the pause flag and admin transfer are frozen at
    ///         their current values forever. The Router keeps executing swaps
    ///         under that fixed configuration. Irreversible.
    function renounceControl() external onlyControl { controlRenounced = true; emit Cfg(0, address(0)); }

    // =========================================================================
    //  ENTRY POINTS — three auth schemes, one execution core
    // =========================================================================

    /// @notice Classic exact-input swap. User pre-approves the Router.
    /// @dev    userMinOut is the PRIMARY slippage guard — derive it from a
    ///         fresh quote (Quoter.previewPlanExact) on every call. BP-04:
    ///         passing 0 with a non-zero amountIn REVERTS (RouterE(10)) in
    ///         all three entry points — the protocol floors alone (hard-
    ///         capped at 25% below the attested quote per leg, 20% below
    ///         the realised total in aggregate) only BOUND sandwich loss,
    ///         they do not eliminate it, so a real bound is mandatory.
    ///         I8 (idempotence) is preserved: the guard is conditioned on
    ///         amountIn > 0, so a zero-amount call never reverts solely
    ///         because userMinOut is 0.
    function swapExactIn(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) external whenLive nrEntrant returns (uint256) {
        if (amountIn > 0 && userMinOut == 0) revert RouterE(10);
        return _swap(route, amountIn, userMinOut, recipient, deadline);
    }

    /// @notice Permit2 SignatureTransfer — zero standing allowance.
    function swapExactInWithPermit2(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline,
        IPermit2.PermitTransferFrom calldata permit, bytes calldata signature
    ) external whenLive nrEntrant returns (uint256) {
        if (amountIn > 0 && userMinOut == 0) revert RouterE(10);
        if (permit.permitted.amount < amountIn) revert RouterE(3);
        IPermit2(permit2).permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({ to: address(this), requestedAmount: amountIn }),
            msg.sender, signature
        );
        // Tokens are now on the Router; skip the user-pull in the core path.
        return _swapPrePulled(route, amountIn, userMinOut, recipient, deadline);
    }

    /// @notice EIP-7702 entry point — a NAMED ALIAS of `swapExactIn`, deliberately.
    /// @dev    Under EIP-7702 the EOA delegates code to itself for the transaction, so
    ///         `msg.sender` is still the EOA and the classic pull path already works unchanged —
    ///         there is no 7702-specific logic to run, and this body is byte-for-byte identical
    ///         to `swapExactIn`. It exists so a 7702 integrator can express intent at the call
    ///         site, and is kept for interface stability.
    ///
    ///         Be precise about where the 7702 saving comes from: it is the *transaction
    ///         structure* (bundling `approve` + `swap` into one tx, removing a ~21k base cost
    ///         plus the allowance SSTORE), NOT this function. Calling this instead of
    ///         `swapExactIn` saves nothing on its own. See
    ///         `test_7702_IsAnExactAliasOfSwapExactIn` for the executable statement of that.
    function swapExactInWith7702(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) external whenLive nrEntrant returns (uint256) {
        if (amountIn > 0 && userMinOut == 0) revert RouterE(10);
        return _swap(route, amountIn, userMinOut, recipient, deadline);
    }

    // =========================================================================
    //  CORE EXECUTION
    // =========================================================================

    function _swap(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) private returns (uint256) {
        if (block.timestamp > deadline) revert RouterE(4);
        if (route.hops.length == 0 || amountIn == 0) revert RouterE(3);
        address tokenIn  = route.hops[0].tokenIn;
        // Measure the actual receive against the requested pull. Fee-on-
        // transfer / deflationary tokens deliver less than they advertise; we
        // work with what was actually received.
        uint256 balBefore = BPC.balanceOf(tokenIn, address(this));
        BPC.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        uint256 received = BPC.balanceOf(tokenIn, address(this)) - balBefore;
        if (received == 0) revert RouterE(8);
        return _execute(route, received, userMinOut, recipient, tokenIn);
    }

    function _swapPrePulled(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) private returns (uint256) {
        if (block.timestamp > deadline) revert RouterE(4);
        if (route.hops.length == 0 || amountIn == 0) revert RouterE(3);
        address tokenIn = route.hops[0].tokenIn;
        return _execute(route, amountIn, userMinOut, recipient, tokenIn);
    }

    /// @notice Per-hop real-balance-ratio scaling AND price impact (BPS) AND
    ///         the on-chain quote for the legs as actually executed, all
    ///         computed in one pass so V2/Solidly reserves and V3/Algebra
    ///         sqrtPrice+liquidity are read once and reused — zero extra
    ///         staticcalls for the two dominant leg kinds. Merged with the
    ///         scale computation (rather than two separate functions) so the
    ///         intermediate realIn/quotedIn values never need to live in
    ///         _execute's own frame between two calls — via-IR inlines small
    ///         private functions back into their single call site, and two
    ///         separate calls each pushed the combined stack 1 slot too deep.
    ///
    ///         Scaling: every leg's planned share is rescaled against how
    ///         much of hop.tokenIn the Router ACTUALLY has available
    ///         (scaleNum) versus how much the Solver's plan assumed it would
    ///         have (scaleDen = sum of this hop's leg.amountIn). For hop 0,
    ///         scaleNum is the amountIn parameter itself — already measured
    ///         via one balance-delta in _swap (covers a fee-on-transfer
    ///         tokenIn without a second staticcall). For hop 1+, scaleNum is
    ///         a fresh balanceOf() of the bridge token actually received
    ///         from the previous hop (covers that hop's own slippage).
    ///
    ///         The quote return feeds the fee-base re-derivation in _execute
    ///         (see "Fee base" below): it replaces the caller-supplied,
    ///         unverified route.totalOut, so a crafted Route can no longer
    ///         understate its own quote to shrink the protocol's fee base.
    ///         Curve/V4 branches ask the pool / read the PoolManager using
    ///         the exact same key construction execution uses, so they
    ///         cannot diverge from what actually settles — if auxId is wrong
    ///         the leg fails identically in both places.
    function _hopScaleImpactAndQuote(Hop calldata hop, uint256 h, uint256 amountIn)
        private view returns (uint256 scaleNum, uint256 scaleDen, uint256 impactAcc, uint256 quoteAcc)
    {
        uint256 legs = hop.legs.length;
        {
            uint256 realIn = h == 0 ? amountIn : BPC.balanceOf(hop.tokenIn, address(this));
            uint256 quotedIn;
            for (uint256 l; l < legs; ) { quotedIn += hop.legs[l].amountIn; unchecked { ++l; } }
            // SECURITY (issue #1 cap × BP-02 floor seam): the hop-0 cap is
            // applied HERE, BEFORE the quote loop below, so hopQuote/hopImpact
            // are priced on the SAME legAmt _execute later spends. Capping
            // only in _execute (as before) let the quote scale UP past the
            // plan's committed Σ leg.amountIn while execution stayed capped —
            // quote > realised on every input-surplus swap, so the 96%
            // protocol floor rejected legitimate fills (CI 2026-08-09).
            // Single source of truth: do NOT re-add a cap in _execute.
            // The cap mutates existing named returns only — no new locals —
            // so the razor-thin via-IR stack budget is untouched. If a future
            // edit still trips stack-too-deep here, fold it into the
            // assignment: scaleNum = (h == 0 && realIn > scaleDen) ? scaleDen : realIn;
            scaleNum = realIn;
            scaleDen = quotedIn == 0 ? 1 : quotedIn;
            if (h == 0 && scaleNum > scaleDen) scaleNum = scaleDen;
        }
        address v4mgr;
        for (uint256 l; l < legs; ) {
            Leg calldata leg = hop.legs[l];
            uint256 legAmt = BPC.mulDiv(leg.amountIn, scaleNum, scaleDen);

            if (leg.kind == BPC.KIND_V2 || leg.kind == BPC.KIND_SOLIDLY) {
                (uint256 ir0, uint256 ir1) = BPC.getReserves(leg.pool);
                uint256 rIn  = leg.zeroForOne ? ir0 : ir1;
                uint256 rOut = leg.zeroForOne ? ir1 : ir0;
                if (rIn != 0) {
                    impactAcc += BPC.impactV2Bps(legAmt, rIn);
                    if (leg.kind == BPC.KIND_V2) {
                        uint24 v2fee = leg.fee == 0 ? 30 : leg.fee;
                        quoteAcc += BPC.outV2(legAmt, rIn, rOut, v2fee);
                    } else {
                        uint256 liveFee = BPC.readDynamicFee(leg.pool, leg.stable, leg.fee);
                        quoteAcc += BPC.outSolidly(legAmt, rIn, rOut, liveFee, leg.stable);
                    }
                } else { impactAcc += 50; }
            } else if (leg.kind == BPC.KIND_V3 || leg.kind == BPC.KIND_ALGEBRA) {
                // Real concentrated-liquidity impact, matching the Solver's
                // plan-time computation (Core.impactV3Bps). A dead read
                // (sp/liq == 0) falls back to the conservative constant.
                uint160 sp = BPC.getSqrtPriceX96(leg.pool);
                uint128 lq = BPC.getLiquidity(leg.pool);
                if (legAmt != 0 && sp != 0 && lq != 0) {
                    impactAcc += BPC.impactV3Bps(legAmt, sp, lq, leg.fee, leg.zeroForOne);
                    quoteAcc  += BPC.outV3(legAmt, sp, lq, leg.fee, leg.zeroForOne);
                } else { impactAcc += 50; }
            } else if (leg.kind == BPC.KIND_STABLE) {
                quoteAcc += _stableLegQuote(leg, hop.tokenIn, legAmt);
                impactAcc += 50;
            } else if (leg.kind == BPC.KIND_CURVE_CRYPTO) {
                quoteAcc += BPC._curveCryptoGetDy(leg.pool, leg.zeroForOne, legAmt);
                impactAcc += 50;
            } else if (leg.kind == BPC.KIND_V4) {
                if (v4mgr == address(0)) v4mgr = hub.v4PoolManager();
                quoteAcc += _v4LegQuote(leg, hop.tokenIn, legAmt, v4mgr);
                impactAcc += 50;
            } else { impactAcc += 50; }
            unchecked { ++l; }
        }
    }

    /// @dev Extracted from _hopScaleImpactAndQuote: via-IR inlines that function
    ///      into _execute's own frame, and the STABLE branch's locals
    ///      (tokenOut, ci, cj, ok) pushed the combined stack past the 16-slot
    ///      EVM limit ("stack too deep"). A separate call keeps only this
    ///      branch's return value live in the caller's frame.
    function _stableLegQuote(Leg calldata leg, address tokenIn, uint256 legAmt)
        private view returns (uint256 quote)
    {
        address tokenOut = address(uint160(uint256(leg.auxId)));
        (int128 ci, int128 cj, bool ok) = BPC.curveResolveIndices(leg.pool, tokenIn, tokenOut);
        if (ok) quote = BPC.curveGetDy(leg.pool, ci, cj, legAmt);
    }

    /// @dev Extracted from _hopScaleImpactAndQuote for the same stack-depth reason
    ///      as _stableLegQuote — the V4 branch's locals (tokenOther, t0, t1,
    ///      pid, sp4, lq4) were the other major contributor.
    function _v4LegQuote(Leg calldata leg, address tokenIn, uint256 legAmt, address v4mgr)
        private view returns (uint256 quote)
    {
        address tokenOther = address(uint160(uint256(leg.auxId)));
        if (tokenOther == address(0)) return 0;
        (address t0, address t1) = BPC.sortTokens(tokenIn, tokenOther);
        bytes32 pid = BPC.computeV4PoolId(t0, t1, leg.fee, leg.tickSpacing, leg.hooks);
        (uint160 sp4, uint128 lq4) = BPC.v4SqrtAndLiq(v4mgr, pid);
        if (sp4 != 0 && lq4 != 0) quote = BPC.outV3(legAmt, sp4, lq4, leg.fee, leg.zeroForOne);
    }

    function _execute(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, address tokenIn
    ) private returns (uint256 amountOut) {
        address tokenOut = route.hops[route.hops.length - 1].tokenOut;
        // Input-token balance at entry (the input is already in the Router).
        // Every unit pulled for this swap MUST be consumed by the legs; the
        // holds-nothing check after the hop loop enforces it.
        uint256 tinStart = BPC.balanceOf(tokenIn, address(this));
        uint256 totalLegs;
        // Floor re-derivation: sum of per-leg real impact (BPS), averaged later.
        uint256 impactAcc;
        // On-chain quote for the legs as actually executed — replaces the
        // caller-supplied route.totalOut as the fee-base reference (see the
        // "Fee base" section below).
        uint256 onchainQuoteAcc;
        // Quote of the FINAL hop only, denominated in tokenOut — the correct
        // reference for the protocol floor. onchainQuoteAcc SUMS the per-hop
        // quotes, whose units differ across a multi-hop route, so it cannot
        // serve as a tokenOut-denominated floor; the last hop's quote can.
        uint256 finalHopQuote;

        // Pre-swap balance of every intermediate (bridge) token, so the residual
        // sweep below returns only what THIS swap produced — never a balance the
        // Router happened to hold at entry. Mirrors the tokenIn sweep's baseIn
        // guard, making both sweeps symmetric (finding: NetGakarot-class review —
        // the bridge sweep otherwise handed a crafted route the Router's
        // dust/mis-sent balance of any caller-named intermediate token).
        uint256[] memory bridgeBase = new uint256[](route.hops.length);
        for (uint256 bh; bh + 1 < route.hops.length; ) {
            address bt = route.hops[bh].tokenOut;
            if (bt != tokenIn && bt != tokenOut) bridgeBase[bh] = BPC.balanceOf(bt, address(this));
            unchecked { ++bh; }
        }

        for (uint256 h; h < route.hops.length; ) {
            Hop calldata hop = route.hops[h];
            uint256 legs = hop.legs.length;
            if (legs == 0 || legs > MAX_LEGS_PER_HOP) revert RouterE(3);

            // Real-balance-ratio scaling for EVERY hop, not just h>0, AND
            // this hop's real impact/on-chain quote — all in one call (see
            // _hopScaleImpactAndQuote's docs) to keep this loop's via-IR
            // stack frame shallow.
            (uint256 scaleNum, uint256 scaleDen, uint256 hopImpact, uint256 hopQuote) =
                _hopScaleImpactAndQuote(hop, h, amountIn);
            // SECURITY (issue #1, reported by NetGakarot): on hop 0 the Router
            // may hold MORE input than the plan committed (the phantom-tier
            // capacity clamp cuts leg.amountIn on purpose); spending past
            // Σ leg.amountIn would force-feed the pre-cut order into a thin
            // pool (a revert with the per-leg floor, or a ~20–27% one-way
            // loss without it). The cap (scaleNum = min(scaleNum, scaleDen)
            // for h == 0) lives INSIDE _hopScaleImpactAndQuote, applied
            // BEFORE its quote loop, so the scaleNum returned above is
            // already capped and hopQuote/hopImpact price the SAME legAmt
            // the loop below executes — the BP-02 floor compares realised
            // output with a quote of the amounts actually spent, never a
            // scaled-up phantom. Single source of truth: do NOT re-cap here —
            // a second cap site is exactly the seam that broke on 2026-08-09.
            // Fee-on-transfer is unaffected: there scaleNum (received) < scaleDen,
            // so the cap never fires and the existing scale-DOWN still applies.
            // Hop 1+ is untouched — realIn is the true bridge output, all spent.
            impactAcc += hopImpact;
            onchainQuoteAcc += hopQuote;
            if (h + 1 == route.hops.length) finalHopQuote = hopQuote;

            for (uint256 l; l < legs; ) {
                Leg calldata leg = hop.legs[l];
                address legIn = _legTokenIn(leg);
                // V4 legs return address(0) from _legTokenIn (their pool field
                // holds the *other* token, not a Uniswap-style pair). Resolve
                // the real tokenIn from the hop context so _execV4Amt writes the
                // correct token into transient storage for the unlock callback.
                if (legIn == address(0)) legIn = hop.tokenIn;
                uint256 scaledAmt = BPC.mulDiv(leg.amountIn, scaleNum, scaleDen);
                if (l == legs - 1) {
                    uint256 remaining = BPC.balanceOf(legIn, address(this));
                    if (remaining < scaledAmt) scaledAmt = remaining;
                }
                _execScaled(leg, legIn, scaledAmt);
                unchecked { ++l; }
            }
            totalLegs += legs;
            unchecked { ++h; }
        }

        // ─── Holds-nothing enforcement (sweep, don't revert) ───
        // Real routes leave residual input / bridge tokens: a V3/V4 leg that
        // partial-fills at its price limit, mulDiv rounding across split legs,
        // or a non-conforming pool that declined to collect what it was handed.
        // Return every such residual to the caller instead of stranding it
        // (sweepable by a later crafted route) or reverting a legitimate swap.
        // The Router is left holding nothing, and the user gets their unused
        // funds back. Only this swap's residual is swept — the pre-swap balance
        // (baseIn, normally zero since the Router holds nothing at rest) is
        // left untouched so a caller can never sweep prior funds. tokenOut is
        // excluded (it is paid out below), as is the degenerate
        // tokenIn == tokenOut case.
        if (tokenIn != tokenOut) {
            uint256 baseIn  = tinStart > amountIn ? tinStart - amountIn : 0;
            uint256 residIn = BPC.balanceOf(tokenIn, address(this));
            if (residIn > baseIn) BPC.safeTransfer(tokenIn, msg.sender, residIn - baseIn);
        }
        for (uint256 h; h + 1 < route.hops.length; ) {
            address bridge = route.hops[h].tokenOut;
            if (bridge != tokenIn && bridge != tokenOut) {
                uint256 rb = BPC.balanceOf(bridge, address(this));
                uint256 bb = bridgeBase[h];
                if (rb > bb) BPC.safeTransfer(bridge, msg.sender, rb - bb);
            }
            unchecked { ++h; }
        }

        // Measure final balance.
        uint256 totalReceived = BPC.balanceOf(tokenOut, address(this));
        if (totalReceived == 0) revert RouterE(8);
        amountOut = totalReceived;

        // ─── Floor re-derivation ───
        // The floor is NOT read from the caller-supplied route. It is computed
        // on-chain from the real impact measured above and the real leg count,
        // exactly as the Solver would, then applied to the measured output.
        // This makes the protocol floor an enforced invariant regardless of
        // what the caller put in route.singleOutFloor.
        //
        // IMPORTANT: the protocol floor is a fraction of the REALISED output —
        // it is a secondary safety net against pathological execution, not the
        // primary slippage guard. The primary guard is userMinOut, which the
        // user sets from the quote they saw. A caller can no longer RELAX
        // protection via route fields, but users must still pass a real
        // userMinOut to be protected against a bad quote-to-fill gap.
        uint256 avgImpact = totalLegs > 0 ? impactAcc / totalLegs : 0;
        uint256 floorBps  = BPC.ironFloorBps(avgImpact, totalLegs, 0);

        // The caller's singleOutFloor and userMinOut may TIGHTEN the floor
        // (user wants more protection) but can never RELAX the protocol floor.
        // protocolFloorOut is a fraction of the in-frame on-chain quote of the
        // final hop (denominated in tokenOut, unforgeable by calldata), NOT of
        // the realised output. Anchoring it to the realised output made it
        // mathematically inert: with floorBps <= BPS it could never exceed the
        // realised amount, so the guard below never fired. Deriving it from the
        // measured final-hop quote lets a fill that lands far below the quote
        // revert. userMinOut is an absolute amount; effMin is the strictest of
        // all three. If the final-hop quote is unavailable (finalHopQuote == 0)
        // the protocol floor is inert for this swap and userMinOut, which the
        // entrypoints force to be non-zero, remains the backstop.
        uint256 protocolFloorOut = BPC.mulDiv(finalHopQuote, floorBps, BPC.BPS);
        uint256 effMin = userMinOut;
        // Fee-on-transfer (MEASURED during execution, unforgeable by a crafted
        // Route): the quote-derived singleOutFloor assumed no transfer fee and
        // is inflated, so it would reject a correct fill. Drop it for this
        // swap only; the user stays protected by userMinOut (their own bound)
        // and protocolFloorOut (an ironFloor fraction of the REAL output).
        // Honest tokens never set the flag — behaviour unchanged for them.
        uint256 sF = TSLOT_FOT;
        uint256 fotSeen; assembly { fotSeen := tload(sF) }
        if (fotSeen == 0) {
            if (route.singleOutFloor > effMin) effMin = route.singleOutFloor;
        } else {
            assembly { tstore(sF, 0) }
        }
        if (protocolFloorOut    > effMin) effMin = protocolFloorOut;
        if (amountOut < effMin) revert RouterE(5);

        // ─── Fee base ───
        // The fee is charged on the ON-CHAIN quote for the legs as actually
        // executed (onchainQuoteAcc, accumulated above in the same pass as
        // the impact measurement) — never on the caller-supplied
        // route.totalOut. A crafted Route can no longer understate its own
        // quote to shrink the fee base: the reference figure is derived from
        // pool state read during THIS execution, not from calldata. The
        // surplus policy is unchanged: any amount ABOVE this quote is still
        // fee-exempt and paid to the user in full.
        uint256 feeBase = totalReceived > onchainQuoteAcc ? onchainQuoteAcc : totalReceived;
        // Still floored at protocolFloorOut as defence-in-depth, in case a
        // pool kind's on-chain quote path reads stale/zero state.
        if (feeBase < protocolFloorOut) feeBase = protocolFloorOut;
        if (feeBase > totalReceived)    feeBase = totalReceived;

        uint256 surplus = totalReceived > feeBase ? totalReceived - feeBase : 0;
        uint256 fee = BPC.mulDiv(feeBase, PROTOCOL_FEE_BPS, BPC.BPS);
        if (fee >= amountOut) revert RouterE(8);
        uint256 net = amountOut - fee;

        // Fee split 30/70 to the two treasuries.
        if (fee > 0) {
            uint256 t1 = BPC.mulDiv(fee, TREASURY1_SHARE, BPC.BPS);
            uint256 t2 = fee - t1;
            if (t1 > 0) BPC.safeTransfer(tokenOut, treasury1, t1);
            if (t2 > 0) BPC.safeTransfer(tokenOut, treasury2, t2);
            emit Fee(tokenOut, fee, t1, t2);
        }
        if (surplus > 0) emit Surplus(tokenOut, surplus);

        // The full net (= quoted + surplus − fee) goes to the recipient.
        // Measure the recipient's ACTUAL balance delta: fee-on-transfer tokens
        // deliver less than the nominal `net`, so we must report and protect on
        // what the user truly receives, not the nominal figure. For normal
        // tokens this delta equals `net` exactly (no behaviour change).
        uint256 recipBefore = BPC.balanceOf(tokenOut, recipient);
        BPC.safeTransfer(tokenOut, recipient, net);
        uint256 delivered = BPC.balanceOf(tokenOut, recipient) - recipBefore;

        // Slippage protection is enforced on the DELIVERED amount: a fee-on-
        // transfer token cannot be used to slip the user below their userMinOut.
        if (delivered < userMinOut) revert RouterE(5);

        amountOut = delivered;
        _recordHits(route);
        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, delivered, totalLegs);
        return delivered;
    }

    // =========================================================================
    //  LEG DISPATCH
    // =========================================================================
    //
    //  One function selects the AMM shape for any kind:
    //    V2 / Balancer V2 → push-then-swap with computed amountOut
    //    V3 / Algebra      → callback-style with transient pool + token
    //    Solidly           → push-then-swap with stable-aware amountOut
    //    Stable / Curve    → approve + exchange dual-signature
    //    V4                → unlock → swap → sync → settle → take

    /// @notice Execute a leg with an explicit input amount that may differ
    ///         from leg.amountIn. Every hop rescales against the REAL
    ///         balance available to it (see the realIn/quotedIn scaling in
    ///         _execute) — hop 0 against the measured post-pull amountIn
    ///         (covers a fee-on-transfer tokenIn), hop 1+ against the
    ///         measured bridge balance. When nothing shrank the input,
    ///         amt == leg.amountIn exactly (mulDiv with equal num/den).
    function _execScaled(Leg calldata leg, address tokenIn, uint256 amt) private {
        // A zero-input leg is a no-op: skip it entirely. This also closes the
        // maxAmt == 0 "no cap" path in _v3Callback — a leg scaled to zero input
        // (for example the last leg when the Router holds no remaining input)
        // must never reach pool.swap(), where the transient amount cap would be
        // 0 and therefore unbounded. The residual sweep returns unspent input.
        if (amt == 0) return;
        // ─── Per-leg iron floor (see LEG_FLOOR_BPS) ───
        // Measure THIS leg's real contribution to the Router's tokenOut
        // balance and require ≥ 75% of its pro-rata attested quote. The
        // aggregate floors run only once, at the end of _execute; bounding
        // each leg means a single sandwiched or manipulated pool reverts the
        // swap immediately instead of hiding its loss inside an otherwise
        // healthy total. Purely additive: it can only revert, never relax.
        // Legs without an attested quote (expectedOut == 0) fail open to the
        // aggregate floors — a caller weakening its own crafted route gains
        // nothing that userMinOut and the protocol floor don't already bound.
        address legOut = _legTokenOut(leg, tokenIn);
        bool guard = legOut != address(0)
            && leg.expectedOut != 0 && leg.amountIn != 0 && amt != 0;
        uint256 balBefore;
        if (guard) balBefore = BPC.balanceOf(legOut, address(this));

        uint8 k = leg.kind;
        if (k == BPC.KIND_V2 || k == BPC.KIND_BALANCER_V2) {
            _execV2Amt(leg, tokenIn, amt);
        } else if (k == BPC.KIND_V3 || k == BPC.KIND_ALGEBRA) {
            _execV3Amt(leg, tokenIn, amt);
        } else if (k == BPC.KIND_SOLIDLY) {
            _execSolidlyAmt(leg, tokenIn, amt);
        } else if (k == BPC.KIND_STABLE || k == BPC.KIND_CURVE_CRYPTO) {
            _execCurveAmt(leg, tokenIn, amt);
        } else if (k == BPC.KIND_V4) {
            _execV4Amt(leg, tokenIn, amt);
        } else {
            revert RouterE(8);
        }

        if (guard) {
            uint256 got = BPC.balanceOf(legOut, address(this)) - balBefore;
            uint256 minLeg = BPC.mulDiv(
                BPC.mulDiv(leg.expectedOut, amt, leg.amountIn),
                LEG_FLOOR_BPS, BPC.BPS
            );
            if (got < minLeg) revert RouterE(5);
        }
    }

    /// @notice Resolve a leg's OUTPUT token: pair reads for pool-shaped kinds,
    ///         auxId for V4/Curve (whose pool field is not a pair). Returns
    ///         address(0) when the output token cannot be resolved — that leg
    ///         then fails open to the aggregate floors (the per-leg guard is
    ///         an extra bound, never a gate on execution).
    function _legTokenOut(Leg calldata leg, address tokenIn) private view returns (address) {
        if (leg.kind == BPC.KIND_V4 ||
            leg.kind == BPC.KIND_STABLE || leg.kind == BPC.KIND_CURVE_CRYPTO) {
            return address(uint160(uint256(leg.auxId)));
        }
        address t0 = BPC.token0Of(leg.pool);
        address t1 = BPC.token1Of(leg.pool);
        address outT = leg.zeroForOne ? t1 : t0;
        return outT == tokenIn ? address(0) : outT;
    }

    /// @notice Resolve the actual tokenIn for a leg by inspecting its pool.
    ///         This is robust against bridge collapsing where two stages with
    ///         different token pairs share a single hop wrapper.
    function _legTokenIn(Leg calldata leg) private view returns (address) {
        if (leg.kind == BPC.KIND_V4) {
            // V4 pools store the "other" token in leg.pool; tokenIn is the
            // implicit counterpart resolved by the unlock callback. The caller
            // path uses the hop-level tracking, so we fall back to that.
            return address(0);
        }
        address t0 = BPC.token0Of(leg.pool);
        address t1 = BPC.token1Of(leg.pool);
        return leg.zeroForOne ? t0 : t1;
    }

    function _execV2Amt(Leg calldata leg, address tokenIn, uint256 amt) private {
        // Reserves BEFORE transfer: outV2 expects the pre-swap reserveIn.
        // Reading after the transfer double-counts `amt` in rIn and inflates
        // the computed output.
        (uint256 r0, uint256 r1) = BPC.getReserves(leg.pool);
        uint256 rIn  = leg.zeroForOne ? r0 : r1;
        uint256 rOut = leg.zeroForOne ? r1 : r0;
        // Mirror Core: fee==0 -> 30 bps (UniV2/Sushi). Must match quote or K revert.
        uint24 v2fee = leg.fee == 0 ? 30 : leg.fee;
        uint256 balBefore = BPC.balanceOf(tokenIn, leg.pool);
        BPC.safeTransfer(tokenIn, leg.pool, amt);
        uint256 outAmt;
        if (BPC.balanceOf(tokenIn, leg.pool) - balBefore == amt) {
            // Normal token: identical to the historical path (pre-transfer
            // reserves, nominal amount) — zero behavioural change.
            outAmt = BPC.outV2(amt, rIn, rOut, v2fee);
        } else {
            // Fee-on-transfer MEASURED (pool received less than sent). The
            // canonical SupportingFeeOnTransferTokens recompute: read reserves
            // and balance in the SAME post-transfer state. This is robust even
            // when the token's transfer hook trades on THIS pair mid-transfer
            // (FLOKI does exactly that): realIn = balance − synced reserve is
            // precisely what the pair's K check will see, so the ask below is
            // the pair's own maximum — the number is born on-path, it cannot
            // diverge. Same doctrine as the Curve get_dy and the exact pass.
            (uint256 r0b, uint256 r1b) = BPC.getReserves(leg.pool);
            uint256 rInB  = leg.zeroForOne ? r0b : r1b;
            uint256 rOutB = leg.zeroForOne ? r1b : r0b;
            uint256 realIn = BPC.balanceOf(tokenIn, leg.pool) - rInB;
            if (realIn == 0) revert RouterE(8);
            outAmt = BPC.outV2(realIn, rInB, rOutB, v2fee);
            // Flag (transient) so the floor drops the fee-blind quote floor.
            uint256 sF = TSLOT_FOT;
            assembly { tstore(sF, 1) }
        }
        if (outAmt == 0) revert RouterE(8);
        uint256 a0 = leg.zeroForOne ? 0 : outAmt;
        uint256 a1 = leg.zeroForOne ? outAmt : 0;
        IUniswapV2Pair(leg.pool).swap(a0, a1, address(this), "");
    }

    /// @notice Solidly-class execution, pool-priced. The pair's own
    ///         getAmountOut(amountIn, tokenIn) — live fee, stable curve and
    ///         rounding included — is the exact maximum its K check will
    ///         accept, so we request it (minus 1 wei of rounding armour
    ///         against non-canonical forks) and leave nothing behind. Only
    ///         when the selector is absent do we fall back to replicating the
    ///         curve with the live factory fee and a 200 bps K-margin, the
    ///         historical conservative path.
    function _execSolidlyAmt(Leg calldata leg, address tokenIn, uint256 amt) private {
        // Quote BEFORE transfer — getAmountOut reads current reserves.
        uint256 outAmt = BPC.solidlyGetAmountOut(leg.pool, amt, tokenIn);
        if (outAmt > 1) {
            unchecked { outAmt -= 1; }
        } else {
            // Fallback for forks without getAmountOut. Reserves BEFORE
            // transfer — same fix as _execV2Amt.
            (uint256 r0, uint256 r1) = BPC.getReserves(leg.pool);
            uint256 rIn  = leg.zeroForOne ? r0 : r1;
            uint256 rOut = leg.zeroForOne ? r1 : r0;
            uint256 liveFee = BPC.readDynamicFee(leg.pool, leg.stable, leg.fee);
            outAmt = BPC.outSolidly(amt, rIn, rOut, liveFee, leg.stable);
            outAmt = (outAmt * 9800) / BPC.BPS;
        }
        if (outAmt == 0) revert RouterE(8);
        BPC.safeTransfer(tokenIn, leg.pool, amt);
        uint256 a0 = leg.zeroForOne ? 0 : outAmt;
        uint256 a1 = leg.zeroForOne ? outAmt : 0;
        IUniswapV2Pair(leg.pool).swap(a0, a1, address(this), "");
    }

    function _execV3Amt(Leg calldata leg, address tokenIn, uint256 amt) private {
        uint256 sP = TSLOT_POOL;
        uint256 sT = TSLOT_TOKEN;
        uint256 sA = TSLOT_AMT;
        address pool = leg.pool;
        // Record the max input the callback is allowed to pull. A V3-shaped
        // pool that demands more than `amt` is rejected.
        assembly { tstore(sP, pool) tstore(sT, tokenIn) tstore(sA, amt) }
        uint160 limit = leg.zeroForOne
            ? BPC.MIN_SQRT_PRICE_PLUS_ONE
            : BPC.MAX_SQRT_PRICE_MINUS_ONE;
        IUniswapV3PoolMin(pool).swap(
            address(this), leg.zeroForOne, int256(amt), limit, ""
        );
        assembly { tstore(sP, 0) tstore(sT, 0) tstore(sA, 0) }
    }

    /// @notice Curve exchange with coins()-resolved indices. tokenOut is carried
    ///         in leg.auxId (low 160 bits), set by the Solver, so indices need not
    ///         be assumed. Realised output is bounded by the Router's Omega floor.
    function _execCurveAmt(Leg calldata leg, address tokenIn, uint256 amt) private {
        address tokenOut = address(uint160(uint256(leg.auxId)));
        if (tokenOut == address(0)) revert RouterE(8);
        (int128 i, int128 j, bool ok) = BPC.curveResolveIndices(leg.pool, tokenIn, tokenOut);
        if (!ok) revert RouterE(8);
        BPC.safeApprove(tokenIn, leg.pool, amt);

        // Verify the RESULT, not just the call's success. tricrypto-NG pools
        // (uint256 exchange signature) ACCEPT the int128 selector without
        // reverting but yield 0 — so trusting `done` alone silently drops the
        // leg. Measure tokenOut and
        // fall through to the uint256 signature if int128 produced nothing.
        uint256 balBefore = BPC.balanceOf(tokenOut, address(this));
        (bool ok1, ) = leg.pool.call(abi.encodeWithSignature(
            "exchange(int128,int128,uint256,uint256)", i, j, amt, uint256(0)));
        if (!ok1) { /* tolerated: the result is verified by the tokenOut balance delta */ }
        uint256 got = BPC.balanceOf(tokenOut, address(this)) - balBefore;
        if (got == 0) {
            // int128 path yielded nothing — try uint256. The earlier approval
            // is untouched (no tokens moved), so reuse it. Do NOT re-approve:
            // a second non-zero approve reverts on strict tokens (BPC:approve).
            (bool ok2, ) = leg.pool.call(abi.encodeWithSignature(
                "exchange(uint256,uint256,uint256,uint256)",
                uint256(uint128(i)), uint256(uint128(j)), amt, uint256(0)));
            if (!ok2) { /* tolerated: the result is verified by the tokenOut balance delta */ }
            got = BPC.balanceOf(tokenOut, address(this)) - balBefore;
            if (got == 0) revert RouterE(8);
        }
    }

    function _execV4Amt(Leg calldata leg, address tokenIn, uint256 amt) private {
        address mgr = hub.v4PoolManager();
        if (mgr == address(0)) revert RouterE(8);
        if (leg.hooks != address(0) && BPC.hookAltersDeltas(leg.hooks)) revert RouterE(9);
        // V4 has no pool address — leg.pool holds the truncated poolId, not a
        // token. The counterpart currency travels in auxId (low 160 bits).
        address tokenOther = address(uint160(uint256(leg.auxId)));
        if (tokenOther == address(0)) revert RouterE(8);
        (address c0, address c1) = BPC.sortTokens(tokenIn, tokenOther);
        uint256 sI = TSLOT_V4IN;
        uint256 sO = TSLOT_V4OUT;
        assembly { tstore(sI, tokenIn) tstore(sO, tokenOther) }
        IV4PoolManager.V4PoolKey memory key = IV4PoolManager.V4PoolKey({
            currency0: c0, currency1: c1, fee: leg.fee,
            tickSpacing: leg.tickSpacing, hooks: leg.hooks
        });
        IV4PoolManager(mgr).unlock(abi.encode(key, leg.zeroForOne, amt, bytes("")));
        assembly { tstore(sI, 0) tstore(sO, 0) }
    }

    // =========================================================================
    //  UNIVERSAL CALLBACK FALLBACK
    //
    //  Any V3-shaped callback (Uniswap V3, PancakeSwap V3, SushiSwap V3,
    //  Algebra, DackieSwap V3, SolidV3, …) hits this fallback. The callback's
    //  selector is irrelevant — what matters is that the calldata layout is
    //  (int256, int256, bytes) and the caller is the committed pool.
    // =========================================================================

    fallback() external payable {
        if (msg.value > 0) revert RouterE(3);
        if (msg.data.length < 4 + 64) revert RouterE(3);
        int256 a0;
        int256 a1;
        assembly {
            a0 := calldataload(4)
            a1 := calldataload(36)
        }
        _v3Callback(a0, a1);
    }

    // Deliberately no receive(): a plain ETH transfer (empty calldata) would
    // otherwise be silently trapped forever (no sweep function exists). With
    // no receive() defined, an empty-calldata call falls through to the
    // payable fallback above, whose `msg.value > 0` check at the top already
    // reverts it with RouterE(3) — no new code needed, just the absence of a
    // receive() that would have intercepted it first. Native ETH in/out is a
    // deliberately deferred feature (see vault note "053 - Primitiva de ETH
    // Nativo como WETH"), not implemented in this version.

    function _v3Callback(int256 a0, int256 a1) private {
        uint256 sP = TSLOT_POOL;
        uint256 sT = TSLOT_TOKEN;
        uint256 sA = TSLOT_AMT;
        address expected;
        address tIn;
        uint256 maxAmt;
        assembly { expected := tload(sP) tIn := tload(sT) maxAmt := tload(sA) }
        if (msg.sender != expected || expected == address(0)) revert RouterE(6);
        uint256 owed = a0 > 0 ? uint256(a0) : (a1 > 0 ? uint256(a1) : 0);
        if (owed == 0) revert RouterE(8);
        // The pool cannot demand more than the input we intended to spend.
        // Bounds a malicious registered pool to the current leg's budget.
        if (maxAmt != 0 && owed > maxAmt) revert RouterE(8);
        // Single-shot (checks-effects-interactions): clear the transient auth
        // context BEFORE paying, so a pool that re-enters this callback during
        // its own swap() reads expected == 0 on the second entry and reverts(6).
        // Without this a malicious registered pool could pull the committed
        // input more than once, draining the input budgeted to sibling legs.
        assembly { tstore(sP, 0) tstore(sT, 0) tstore(sA, 0) }
        BPC.safeTransfer(tIn, msg.sender, owed);
    }

    /// @notice V4 unlockCallback — invoked by the PoolManager after unlock().
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        address mgr = hub.v4PoolManager();
        if (msg.sender != mgr) revert RouterE(6);
        (IV4PoolManager.V4PoolKey memory key, bool zfo, uint256 amt, bytes memory hookData)
            = abi.decode(data, (IV4PoolManager.V4PoolKey, bool, uint256, bytes));
        uint256 sI = TSLOT_V4IN;
        uint256 sO = TSLOT_V4OUT;
        address tIn;
        address tOut;
        assembly { tIn := tload(sI) tOut := tload(sO) }
        if (tIn == address(0) || tOut == address(0)) revert RouterE(6);
        IV4PoolManager.SwapParams memory p = IV4PoolManager.SwapParams({
            zeroForOne:        zfo,
            amountSpecified:   -int256(amt),
            sqrtPriceLimitX96: zfo ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE
        });
        int256 bd = IV4PoolManager(mgr).swap(key, p, hookData);
        // V4 returns a packed BalanceDelta: amount0 high 128 bits, amount1 low
        // 128 bits, each int128. The mock returned two int256s; the real
        // PoolManager packs them. This was only visible on a real fork.
        int256 d0 = int256(int128(bd >> 128));
        int256 d1 = int256(int128(bd));
        int256 owedDelta     = zfo ? d0 : d1;
        int256 receivedDelta = zfo ? d1 : d0;
        if (owedDelta > 0 || receivedDelta < 0) revert RouterE(8);
        uint256 owe  = uint256(-owedDelta);
        uint256 recv = uint256(receivedDelta);
        // The pool cannot demand more input than the amount committed to this
        // leg — mirrors the V3 callback's maxAmt cap. Bounds a malicious pool
        // or hook to the current leg's budget so it cannot pull the input
        // budgeted to sibling legs.
        if (owe > amt) revert RouterE(8);
        // Single-shot (checks-effects-interactions): clear the transient unlock
        // context before settling, so any re-entry into this callback reads
        // tIn == 0 and reverts(6).
        assembly { tstore(sI, 0) tstore(sO, 0) }
        IV4PoolManager(mgr).sync(tIn);
        BPC.safeTransfer(tIn, mgr, owe);
        IV4PoolManager(mgr).settle();
        IV4PoolManager(mgr).take(tOut, address(this), recv);
        return "";
    }

    // =========================================================================
    //  HUB FEEDBACK
    // =========================================================================

    function _recordHits(Route calldata route) private {
        address v4mgr;
        for (uint256 h; h < route.hops.length; ) {
            Hop calldata hop = route.hops[h];
            for (uint256 l; l < hop.legs.length; ) {
                Leg calldata leg = hop.legs[l];
                // t0/t1 are always derivable from the hop's own tokenIn/
                // tokenOut via zeroForOne — every leg in a hop trades the
                // same pair by construction, so no staticcall is needed here
                // for ANY kind (a prior version re-derived this via
                // token0Of/token1Of for non-V4/Curve legs: redundant, since
                // calldata already determines it).
                address t0 = leg.zeroForOne ? hop.tokenIn  : hop.tokenOut;
                address t1 = leg.zeroForOne ? hop.tokenOut : hop.tokenIn;
                bool curveLike = (leg.kind == BPC.KIND_STABLE || leg.kind == BPC.KIND_CURVE_CRYPTO);
                uint256 depth;
                if (leg.kind == BPC.KIND_V2 || leg.kind == BPC.KIND_SOLIDLY) {
                    depth = _v2Depth(leg.pool);
                } else if (curveLike) {
                    depth = leg.expectedOut;
                } else if (leg.kind == BPC.KIND_V4) {
                    // leg.pool is the truncated poolId-as-address (no
                    // bytecode): getLiquidity(leg.pool) would silently
                    // staticcall a non-contract and read 0, so every V4 pool
                    // was permanently scored at the bottom depth bucket.
                    // Recompute the real bytes32 poolId from (t0, t1, fee,
                    // tickSpacing, hooks) — t0/t1 above are already the
                    // pool's real (currency0, currency1) ordering by
                    // construction of zeroForOne — and read liquidity from
                    // the PoolManager singleton directly.
                    if (v4mgr == address(0)) v4mgr = hub.v4PoolManager();
                    bytes32 pid = BPC.computeV4PoolId(t0, t1, leg.fee, leg.tickSpacing, leg.hooks);
                    ( , uint128 liq) = BPC.v4SqrtAndLiq(v4mgr, pid);
                    depth = uint256(liq);
                } else {
                    depth = uint256(BPC.getLiquidity(leg.pool));
                }
                try hub.recordSwap(
                    leg.pool, leg.kind, leg.fee, leg.hooks,
                    t0, t1, leg.amountIn, leg.expectedOut, depth
                ) {} catch {}
                unchecked { ++l; }
            }
            unchecked { ++h; }
        }
    }

    function _v2Depth(address pool) private view returns (uint256) {
        (uint256 r0, uint256 r1) = BPC.getReserves(pool);
        return r0 < r1 ? r0 : r1;
    }
}
