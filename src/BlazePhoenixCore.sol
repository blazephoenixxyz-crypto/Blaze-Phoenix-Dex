// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixCore
//  Version    : 2.0.0
//  Copyright  : (c) July 2026 – July 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-07-01
//               Change License : GPL-2.0-or-later
//  Fingerprint : 0x0cdf3cc72daa3ca37778f5f6974830edc0020f42cb5c3dc875fe510ea0e3202c
//  Build ref   : 0x5a4c8fb3318679ccd8afce8752c8d272b447abeff6f412a8fc800087b3f9eead
//  Rights      : Original work. Copyright subsists automatically upon creation
//                (Berne Convention, 1886); this code is licensed under BUSL-1.1
//                above, and reproduction outside that grant is infringement.
//                Authorship is provable — the keccak256 preimage of the
//                Fingerprint is a private phrase held by the authors, and
//                revealing it proves origin.
//
//  SINGLE RESPONSIBILITY
//      Arithmetic and shape. The Core knows HOW a price is computed, HOW an
//      address is derived and HOW a state is packed — and nothing more. It has
//      no storage, no owner, no pause, and it never holds a single wei.
//
//  WHAT THIS CONTRACT GUARANTEES
//      C1  Pure by default. All the math is `pure`; whatever reads chain is
//          `view` and says `view` in its name or signature. No third category.
//      C2  One primitive, one producer. Every quantity has exactly ONE function
//          that produces it (`depthFromL` for depth, `ironFloorBps` for the
//          floor, `universalQuote` for a quote). A second producer is a sibling
//          waiting to diverge, and divergence is this codebase's defect
//          signature — confirmed more than ten times.
//      C3  Fail-closed with no default branch. An unknown kind returns theta
//          field 0x0: reads no reserves, not concentrated, not verifiable.
//          There is no `else` for anyone to forget to keep in sync.
//
//  WHAT THIS CONTRACT DELIBERATELY DOES NOT DO
//      It does not decide routes (that is the Solver), does not execute swaps
//      (the Router), does not store pools (the Hub) and holds no opinion about
//      its caller. The value-moving functions are allowance-free transfer
//      primitives — the Router NEVER grants an allowance to anyone, and a
//      static guard in CI keeps that true.
//
//  Shared library for the BlazePhoenix protocol. Provides the arithmetic
//  primitives, AMM quote math, pool-address derivation, packed pool-state
//  encoding and the output floor used by Hub, Solver, Router and Quoter:
//
//    1.  universalQuote(ctx, amountIn) -> (amountOut, depth)
//        AMM quote dispatcher across the live pool kinds (V2, V3, V4,
//        V4-native, Solidly, Algebra).
//
//    2.  deriveAddress(...) -> pool
//        Deterministic pool-address resolution via factory lookup or CREATE2,
//        selected by mode.
//
//    3.  ironFloorBps(impact, legs, sigma) -> floorBps
//        Minimum-output floor in BPS. Tightens with impact and sigma, relaxes
//        with leg count up to the 25% hard loss ceiling. Pure: no storage or
//        oracle reads.
//
//    4.  psi(slot, ...) -> score
//        Pool fitness score derived from the packed state slot, depth bucket,
//        bridge bit and concentration flag.
//
//  Math primitives are defined here only; other contracts import this library
//  as BPC.
// =============================================================================
pragma solidity 0.8.36;

// ─── Shared structs (used by Solver, Router, Quoter) ────────────────────────

struct PoolInfo {
    bool    active;
    bool    stable;
    uint8   kind;
    uint24  fee;
    int24   tickSpacing;
    address token0;
    address token1;
    address pool;
    address hooks;
}

struct Leg {
    address pool;
    address hooks;
    uint8   kind;
    uint24  fee;
    int24   tickSpacing;
    bool    zeroForOne;
    bool    stable;
    uint256 amountIn;
    uint256 expectedOut;
    bytes32 auxId;
}

struct Hop {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 expectedOut;
    Leg[]   legs;
}

struct Route {
    Hop[]   hops;
    uint256 totalOut;
    uint256 singleOut;
    uint256 singleOutFloor;
    uint256 expectedImpactBps;
    uint256 confidenceWad;
    uint256 estGas;
    bool    hasSurplus;
    bool    isV4Bundle;
}

struct RoutePlan {
    Route best;
    Route fallbackRoute;
    bool  hasFallback;
}

// ─── Universal quote context ────────────────────────────────────────────────

struct QuoteCtx {
    uint8   kind;
    address pool;
    bool    zeroForOne;
    uint24  fee;
    int24   tickSpacing;
    bool    stable;
    address tokenIn;
    address tokenOther;
    address hooks;
    address v4Manager;   // V4 PoolManager (for extsload state reads); 0 if N/A
    /// @dev Decimals of both tokens, ENCODED AS `decimals + 1`.
    ///      0 = "not filled in" -> `universalQuote` reads them itself.
    ///
    ///      WHY +1 AND NOT THE RAW VALUE: default memory is zero, and there
    ///      are tokens with GENUINELY 0 decimals. A `0 = not filled in`
    ///      sentinel would treat those as unfilled and, worse, a caller that
    ///      forgot the fields would silently inherit "0 decimals" — depth
    ///      inflated by 1e18. With +1 the two cases are distinguishable and
    ///      correctness NEVER depends on the caller.
    ///
    ///      It exists for HOISTING: the candidates of a pair share the same
    ///      two tokens, and reading `decimals()` per candidate costs 2,339 gas
    ///      (measured; EIP-2929 does not make it free because USDC is a proxy
    ///      with a delegatecall inside). Reading once per PAIR drops the cost
    ///      from +2.2% to +0.7% of the on-chain solve.
    uint8   decIn1;
    uint8   decOther1;
}

library BlazePhoenixCore {

    string  internal constant VERSION    = "2.0.0";

    // ─── Universal numerical constants ─────────────────────────────────

    uint256 internal constant WAD        = 1e18;
    uint256 internal constant BPS        = 10_000;
    uint256 internal constant Q96        = 0x1000000000000000000000000;
    uint256 internal constant GAS_CAP    = 100_000;

    /// @notice Impact charged to a leg the impact model does not cover
    ///         (stable curves, V4 paths), in bps.
    /// @dev    SINGLE PRODUCER of a literal that was hand-written SIX times
    ///         (Router x4, Solver x2). Same defect signature effV2Fee's doc
    ///         already names for the V2 `30`: the sites feed avgImpact ->
    ///         ironFloorBps -> protocolFloorOut, so raising one copy and not
    ///         the others makes the Solver's floor and the Router's disagree
    ///         about the same route. A library constant inlines at compile
    ///         time — zero bytes, zero gas, one knob.
    uint256 internal constant DEFAULT_IMPACT_BPS = 50;

    // Protocol domain separator.
    bytes32 internal constant DOMAIN     = 0x5a4c8fb3318679ccd8afce8752c8d272b447abeff6f412a8fc800087b3f9eead;

    // ─── Pool kinds (universal taxonomy) ───────────────────────────────

    uint8   internal constant KIND_V2          = 0;
    uint8   internal constant KIND_V3          = 1;
    uint8   internal constant KIND_V4          = 4;
    uint8   internal constant KIND_SOLIDLY     = 5;
    uint8   internal constant KIND_ALGEBRA     = 6;

    // TOMBSTONES — 2, 3 and 7. No constant names them: there is no kind 2, 3 or 7 in this system.
    //
    // The NUMBERS stay burned forever, and that is not ceremony: `decodeKind` reads the kind from
    // the Monoslot bits, so assigning 2 to a new venue would make EVERY pool already recorded
    // under 2 be reinterpreted as that venue. A tombstone without an epitaph protects nothing —
    // the only reason the historical record is written down is to prevent reuse: they were Curve
    // stable (2), Balancer V2 (3) and Curve crypto (7), removed by the owner's call on 2026-08-20.
    //
    // They fail closed in four independent places, all by CONSTRUCTION and none by branch: theta
    // field 0x0 (no attribute, no query answers), outside KINDS_ROUTABLE (the Hub's `addFactory`
    // and `recordSwap` refuse them), and the Router's execution dispatch falls into the `else`
    // and reverts RouterE(8) before touching the pool.
    /// @notice A V4 pool one of whose currencies is NATIVE (address(0)).
    /// @dev    A separate kind rather than a runtime `currency == address(0)`
    ///         test, and the distinction is the whole point: native settlement
    ///         is the ONE place where the router's "every asset is an ERC-20
    ///         with balanceOf" invariant does not hold. Encoding that as a kind
    ///         makes the exception a TYPE — visible in the pool record, carried
    ///         in the route plan, greppable by an auditor — instead of a
    ///         condition rediscovered at each call site. Every other kind keeps
    ///         the invariant unconditionally.
    ///
    ///         The quote math needs no branch: it sorts the two currencies and
    ///         derives the pool id, and address(0) sorts first by construction.
    ///
    ///         Measured 2026-08-13 across the chains served: 62.9% of the
    ///         ETH-denominated liquidity inside V4 sits in native pools
    ///         (Arbitrum 99.6%, Optimism 95.0%, Base 48.9%). Wrapping at the
    ///         edge made all of it unreachable.
    ///
    ///         address(0) is also the only token identifier that is genuinely
    ///         chain-agnostic — it is the same on every EVM chain, so a native
    ///         route depends on no per-chain configuration at all.
    uint8   internal constant KIND_V4_NATIVE   = 8;

    // ─── θ — the taxonomy as DATA ──────────────────────────────────────
    //
    // HOW TO READ THIS, if it is the first time. Each kind occupies a fixed bit field inside ONE
    // constant. Asking "does this kind have attribute X?" becomes a shift and an AND, instead of
    // a chain of `if (k == A || k == B || ...)` repeated in every contract.
    //
    // WHY THIS EXISTS. This codebase's defect signature, confirmed more than ten times, is "a fix
    // applied to ONE of two symmetric channels". Every place that enumerates kinds by hand is one
    // of those channels: when a new kind arrives (KIND_V4_NATIVE brought not ONE LINE of new
    // pricing math and still forced changes in all five contracts), whoever forgets one of the
    // places creates the divergence. A set expressed as bits has no sibling to diverge from:
    // diversity becomes a COORDINATE, not a BRANCH.
    //
    // WHAT DOES NOT COLLAPSE, and why. Only MEMBERSHIP tests belong here ("does this kind read
    // reserves?", "does this kind expose token0/token1?"). IDENTITY tests
    // (`k == KIND_V4_NATIVE`, when the question really is about THAT kind and not about a class)
    // stay as they are — forcing them into the table would trade clarity for nothing. And the
    // SETTLEMENT engines do not collapse either: `CALLBACK`, `EXCHANGE` and `UNLOCK` are ABIs of
    // the outside world, shapes that are not ours. The criterion, for each remaining branch: can
    // you name the external reality that forces it? If yes, it is honest and it stays.
    //
    // TWO WORDS, NOT ONE. The single-word version (16 bits per kind, 144 useful) had the right
    // arithmetic but spent bits where EIP-170 hurts: half the attributes were read by no
    // production line, and those were the ones pushing the field to 16 bits — an 18-byte literal,
    // PUSH18, 19 B emitted at EVERY site, including in contracts that never read the gas ladder.
    // Split apart, Router/Hub/Quoter carry 6 B and the ladder lives in one place only.
    //
    // FAIL-CLOSED FOR FREE. A kind with no bits (tombstones 2, 3 and 7) has field 0x0: it reads
    // no reserves, is not concentrated, is not pair-verifiable. No default branch for anyone to
    // forget. See the tombstone note above for why the numbers never come back.

    /// @dev Attributes per kind, 4 bits each. Kind `k` occupies [4k+3 : 4k].
    ///      bit 0  A_RESERVES  — depth and impact come from getReserves(); min(r0,r1) is the depth
    ///      bit 1  A_CONC_POOL — sqrtPriceX96 and L read AT THE POOL ADDRESS
    ///      bit 2  A_CONC_SING — state via extsload on the singleton; `pool` is not a pair; tokenOut travels in auxId
    ///      bit 3  A_PAIR_VER  — token0()/token1() exist, so the Hub's authenticity proof applies
    uint256 internal constant THETA_ATTR = 0x040A9400A9;

    uint8 internal constant A_RESERVES  = 0x1;
    uint8 internal constant A_CONC_POOL = 0x2;
    uint8 internal constant A_CONC_SING = 0x4;
    uint8 internal constant A_PAIR_VER  = 0x8;

    /// @dev Gas ladder per kind, 8 bits each, in units of 5,000. Read ONLY by the Solver, which
    ///      has wide headroom — hence it lives apart from THETA_ATTR, which everyone carries.
    ///      A zero field returns the historical default of 90,000, preserving today's exact
    ///      behaviour for an unknown kind.
    uint256 internal constant THETA_GAS = 0x2B0016122400001612;

    /// @notice The 4 attribute bits of a kind. A kind above 8 returns 0 — fail-closed.
    function thetaOf(uint8 kind) internal pure returns (uint8) {
        return uint8((THETA_ATTR >> (uint256(kind) << 2)) & 0xF);
    }

    /// @notice Does `kind` have ALL the attributes in `mask`? Replaces the `k == A || k == B` chains.
    function kindHas(uint8 kind, uint8 mask) internal pure returns (bool) {
        return (thetaOf(kind) & mask) == mask;
    }

    /// @notice Does `kind` have ANY of the attributes in `mask`? For questions like "is it concentrated?",
    ///         written today as `k == V3 || k == ALGEBRA || k == V4 || k == V4_NATIVE`.
    function kindHasAny(uint8 kind, uint8 mask) internal pure returns (bool) {
        return (thetaOf(kind) & mask) != 0;
    }

    /// @notice Base gas estimate per leg, per kind. Zero => the historical default of 90,000.
    function kindGasBase(uint8 kind) internal pure returns (uint256) {
        uint256 g8 = (THETA_GAS >> (uint256(kind) << 3)) & 0xFF;
        return g8 == 0 ? 90_000 : g8 * 5_000;
    }

    // ─── Output-floor constants ────────────────────────────────────────
    // The floor starts tight (96%) for clean, low-impact, single-leg swaps and
    // loosens toward the 80% hard cap as impact, leg count and volatility rise.
    // Base and hard cap are separate so the floor is impact-adaptive while
    // never permitting a result worse than 80% of the quote. Raised from the
    // original 75% floor per the sealed 2026-08-03 design decision (see the
    // internal notes on invariants, the 4% median and stochastic patterns).
    uint16  internal constant FLOOR_HARD_MAX_LOSS_BPS = 2_000; // 20% absolute hard cap (floor ≥ 80%)
    uint16  internal constant FLOOR_BASE_BPS          = 9_600; // start at 96% floor for clean swaps
    uint16  internal constant FLOOR_PER_LEG_BPS       = 200;   // each extra leg loosens 2%
    uint16  internal constant FLOOR_IMPACT_FACTOR     = 1;     // 1 BPS floor drop per BPS impact
    // The PER-LEG floor lived alone in the Router while its three siblings lived here. It moves
    // next to them: a local per-pool cap, the same number the aggregate composition uses.
    uint16  internal constant LEG_FLOOR_BPS           = 8_000; // each leg delivers >= 80% of the bound

    // ─── Protocol fee — SINGLE PRODUCER ────────────────────────────────────────────────────
    // It was declared TWICE, once in the Router and once in the Quoter, with the same value. The
    // comment that accompanied it in the Router explained — correctly — why a second constant is
    // dangerous ("would silently drift into a lie the moment this one changed") and refused to
    // create TREASURY2_SHARE for that very reason. The rule was written in the exact place where
    // it was being violated: the very constant the comment clung to had a twin. And that twin
    // had already cost this protocol a Quoter that lied about the fee for two whole
    // generations.
    //
    // It lives here for a MECHANICAL reason, not an aesthetic one: a CONTRACT's `internal
    // constant` is not readable from outside, which is why four tests — including a security one
    // about fee coverage — re-declared it as the literal 28. That left the suite red-first
    // against CODE changes and BLIND to CONSTANT changes: moving the fee to 30 left four tests
    // asserting 28 against a copy, and the formal proof proving the old floor. In a LIBRARY the
    // constant is readable by whoever imports it, and the measuring apparatus ends up bolted to
    // the object it measures — corollary (c) of the I-measure, applied to the suite.
    uint16  internal constant PROTOCOL_FEE_BPS        = 28;    // 0.28%

    // ─── V3 sqrt-price bounds ──────────────────────────────────────────

    uint160 internal constant MIN_SQRT_PRICE_PLUS_ONE = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_ONE
        = 1461446703485210103287273052203988822378723970341;

    // ─── Per-chain canonical addresses ─────────────────────────────────

    address internal constant PERMIT2_DEFAULT
        = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // =========================================================================
    //  §1  PURE ARITHMETIC PRIMITIVES
    // =========================================================================

    /// @notice Full-precision a × b ÷ d with no overflow on the multiplication.
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 r) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / d;
            require(d > prod1, "BPC:mulDiv");
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (~d + 1);
            assembly {
                d     := div(d, twos)
                prod0 := div(prod0, twos)
                twos  := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            // XOR intended, not exponentiation: (3*d)^2 is the Newton-Raphson
            // seed with d*inv = 1 mod 2^4; the six doublings below lift it to
            // 2^256 (canonical 512-bit mulDiv construction).
            // slither-disable-next-line incorrect-exp
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            r = prod0 * inv;
        }
    }

    /// @notice Round-up variant of mulDiv. Used for conservative impact bounds.
    function mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 r) {
        r = mulDiv(a, b, d);
        if (mulmod(a, b, d) != 0) {
            require(r < type(uint256).max, "BPC:mulDivUp");
            unchecked { r += 1; }
        }
    }

    /// @notice Integer log10 (5 comparisons max for inputs up to 1e77).
    function ilog10(uint256 x) internal pure returns (uint256 n) {
        unchecked {
            if (x >= 1e64) { x /= 1e64; n += 64; }
            if (x >= 1e32) { x /= 1e32; n += 32; }
            if (x >= 1e16) { x /= 1e16; n += 16; }
            if (x >= 1e8)  { x /= 1e8;  n += 8;  }
            if (x >= 1e4)  { x /= 1e4;  n += 4;  }
            if (x >= 1e2)  { x /= 1e2;  n += 2;  }
            if (x >= 1e1)  {            n += 1;  }
        }
    }

    // =========================================================================
    //  §2  POOL-ADDRESS DERIVATION (factory lookup + CREATE2)
    // =========================================================================

    /// @notice Universal CREATE2 derivation. The salt polynomial is selected
    ///         from (t0, t1, fee, stable, tickSpacing) by `mode`:
    ///           mode 0 → V2:        salt = keccak(t0, t1)
    ///           mode 1 → V3:        salt = keccak(t0, t1, fee)
    ///           mode 2 → Solidly:   salt = keccak(t0, t1, stable)
    ///           mode 3 → V3-CL:     salt = keccak(t0, t1, tickSpacing)
    /// @notice Resolve a pool address. The `mode` parameter selects the
    ///         strategy for resolving the address from (factory, t0, t1,
    ///         params). Two families are supported:
    ///
    ///             FACTORY-CALL family (1 staticcall, always works):
    ///               mode 0 → V2:        factory.getPair(t0, t1)
    ///               mode 1 → V3:        factory.getPool(t0, t1, fee)
    ///               mode 2 → Solidly:   factory.getPool(t0, t1, stable)
    ///               mode 3 → V3-CL:     factory.getPool(t0, t1, tickSpacing)
    ///
    ///             CREATE2 family (0 calls, requires correct initCodeHash):
    ///               mode 4 → V2 CREATE2:        keccak(t0, t1)            packed
    ///               mode 5 → V3 CREATE2:        keccak(t0, t1, fee)       abi.encode
    ///               mode 6 → Solidly CREATE2:   keccak(t0, t1, stable)    packed
    ///               mode 7 → V3-CL CREATE2:     keccak(t0, t1, spacing)   abi.encode
    ///
    ///         The `hasCode` guard applied by the Hub after derivation
    ///         discards any derivation that resolves to an address with no
    ///         bytecode.
    function deriveAddress(
        address factory, address tA, address tB,
        uint24  fee, bool stable, int24 tickSpacing,
        uint8   mode, bytes32 initCodeHash
    ) internal view returns (address pool) {
        (address t0, address t1) = tA < tB ? (tA, tB) : (tB, tA);
        if (mode < 4) {
            return _factoryLookup(factory, t0, t1, fee, stable, tickSpacing, mode);
        }
        // CREATE2 family — sub-mode = mode - 4
        bytes32 salt;
        uint8 sub = mode - 4;
        // Algebra (Camelot V3) is detected as the V3-salt slot with a zero
        // fee (dynamic-fee sentinel). Its salt is keccak(encode(t0,t1)) with
        // NO fee component — fees are dynamic, so they never enter the salt.
        // A normal Uniswap-V3 pool in this slot (non-zero fee) keeps the
        // fee in its salt.
        bool isAlgebra = (sub == 1 && fee == 0);
        if      (sub == 0) salt = keccak256(abi.encodePacked(t0, t1));
        else if (sub == 1) salt = isAlgebra
                                    ? keccak256(abi.encode(t0, t1))
                                    : keccak256(abi.encode(t0, t1, fee));
        else if (sub == 2) salt = keccak256(abi.encodePacked(t0, t1, stable));
        else               salt = keccak256(abi.encode(t0, t1, tickSpacing));

        // CREATE2 origin resolution. For most families the factory itself is
        // the CREATE2 deployer. Algebra-based DEXes (e.g. Camelot V3) deploy
        // pools from a SEPARATE PoolDeployer contract, which the factory
        // exposes via poolDeployer(). For an Algebra pool we staticcall
        // poolDeployer() and use the returned address as the CREATE2 origin.
        // If the call fails (a plain V3 factory has no such selector) we fall
        // back to the factory itself — so a non-Algebra V3 in this slot still
        // derives correctly, and a wrong slot is later discarded by the Hub's
        // hasCode guard.
        address origin = factory;
        if (isAlgebra) {
            address dep = _resolvePoolDeployer(factory);
            if (dep != address(0)) origin = dep;
        }

        pool = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", origin, salt, initCodeHash
        )))));
    }

    /// @dev Staticcall factory.poolDeployer() (selector 0x3119049a). Returns
    ///      the deployer address on success, or address(0) if the selector is
    ///      absent / reverts, signalling the caller to fall back to `factory`.
    function _resolvePoolDeployer(address factory) private view returns (address dep) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 0x3119049a00000000000000000000000000000000000000000000000000000000)
            let ok := staticcall(GAS_CAP, factory, p, 0x04, 0x00, 0x20)
            if and(ok, eq(returndatasize(), 32)) {
                dep := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff)
            }
        }
    }

    /// @dev Factory staticcall dispatcher. Each AMM family exposes its lookup
    ///      under a different selector; we cover the four canonical shapes.
    function _factoryLookup(
        address factory, address t0, address t1,
        uint24 fee, bool stable, int24 tickSpacing, uint8 mode
    ) private view returns (address pool) {
        bytes memory cd;
        if (mode == 0) {
            // V2.getPair(address,address) -> 0xe6a43905
            cd = abi.encodeWithSelector(0xe6a43905, t0, t1);
        } else if (mode == 1) {
            // V3.getPool(address,address,uint24) -> 0x1698ee82
            cd = abi.encodeWithSelector(0x1698ee82, t0, t1, fee);
        } else if (mode == 2) {
            // Solidly.getPool(address,address,bool) -> 0x79bc57d5
            cd = abi.encodeWithSelector(0x79bc57d5, t0, t1, stable);
        } else {
            // Aerodrome Slipstream.getPool(address,address,int24) -> 0x28af8d0b
            cd = abi.encodeWithSelector(0x28af8d0b, t0, t1, tickSpacing);
        }
        pool = _askPool(factory, cd);
        // Dialect fallbacks — same try-then-fallback discipline for both
        // call families, and factories that answer the canonical selector
        // never pay them:
        //   mode 1, Algebra (Camelot V3): dynamic-fee factories expose
        //   poolByPair(address,address), not getPool(.,.,fee).
        if (pool == address(0) && mode == 1) {
            pool = _askPool(factory, abi.encodeWithSelector(0xd9a641e1, t0, t1));
        }
        //   mode 2, classic Solidly (Velodrome V1): getPair(address,address,
        //   bool), not the V2/Aerodrome getPool. The identity gate accepted
        //   such a factory (allPairsLength answers) while discovery never
        //   reached a single pair — 0 candidates in 62 pair-hops in the
        //   census (MEASURED on OP 2026-08-24: getPair(WETH,USDC,false)
        //   answers the live pair; getPool reverts).
        if (pool == address(0) && mode == 2) {
            pool = _askPool(factory, abi.encodeWithSelector(0x6801cc30, t0, t1, stable));
        }
    }

    /// @dev THE ONLY staticcall body for "ask a factory for its pool" — the
    ///      canonical ask and both dialect fallbacks route through it. Was
    ///      three inline assembly copies of the same shape; on the tightest
    ///      contract of the protocol (the Hub inlines this library), three
    ///      copies were also three times the bytes.
    function _askPool(address factory, bytes memory cd) private view returns (address pool) {
        assembly ("memory-safe") {
            let ok := staticcall(GAS_CAP, factory, add(cd, 32), mload(cd), 0x00, 0x20)
            if and(ok, eq(returndatasize(), 32)) {
                pool := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff)
            }
        }
    }

    /// @notice Canonical V4 pool id from a PoolKey.
    function computeV4PoolId(
        address currency0, address currency1, uint24 fee,
        int24 tickSpacing, address hooks
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks));
    }

    /// @notice True if `a` has runtime bytecode.
    function hasCode(address a) internal view returns (bool ok) {
        uint256 sz;
        assembly ("memory-safe") { sz := extcodesize(a) }
        ok = sz > 0;
    }

    // =========================================================================
    //  §3  Token sorting + safe transfers
    // =========================================================================

    function sortTokens(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    /// @notice Selector-driven safe transfer that tolerates non-standard ERC20s.
    function safeTransfer(address token, address to, uint256 amt) internal {
        bool ok;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4),  and(to,  0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 36), amt)
            ok := call(gas(), token, 0, m, 68, 0, 32)
            if ok {
                switch returndatasize()
                case 0 { ok := iszero(iszero(extcodesize(token))) }
                case 32 { ok := and(ok, gt(mload(0), 0)) }
                default { ok := 0 }
            }
        }
        require(ok, "BPC:transfer");
    }

    function safeTransferFrom(address token, address from, address to, uint256 amt) internal {
        bool ok;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4),  and(from, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 36), and(to,   0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 68), amt)
            ok := call(gas(), token, 0, m, 100, 0, 32)
            if ok {
                switch returndatasize()
                case 0 { ok := iszero(iszero(extcodesize(token))) }
                case 32 { ok := and(ok, gt(mload(0), 0)) }
                default { ok := 0 }
            }
        }
        require(ok, "BPC:transferFrom");
    }

    /// @dev ORPHANED SINCE 2026-08-20, AND THEY STAY. They served the Router's
    ///      `_execCurveAmt`; with Curve and Balancer excised there is not a
    ///      single call site left in `src/`.
    ///
    ///      MEASURED 2026-08-21, which is why they are not deleted: they are
    ///      `internal` in a LIBRARY, so the compiler only emits them if called.
    ///      Core build WITH them: 6,519 bytes. WITHOUT them: 6,519 bytes.
    ///      **Zero delta** — they are already out of the deployed bytecode.
    ///
    ///      Deleting would cost two test files and a harness to save NOTHING,
    ///      and would lose tested USDT-safe approval logic, for the day a venue
    ///      of that family returns. "Dead code" in an internal library is not
    ///      BYTECODE debt, it is READING debt — and this note pays it.
    function safeApprove(address token, address spender, uint256 amt) internal {
        bool ok;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4),  and(spender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 36), amt)
            ok := call(gas(), token, 0, m, 68, 0, 32)
        }
        require(ok, "BPC:approve");
    }

    /// @notice USDT-safe approval. A leg that leaves a non-zero residual
    ///         allowance (a partial/fee-on-transfer pull) would make the NEXT
    ///         approval revert on USDT-family tokens, whose approve() reverts
    ///         when going non-zero -> non-zero. So: try approve(amt) directly
    ///         (the common, zero-residual case — cheap, one call); only if that
    ///         fails or the token signals false, reset to 0 and set again. The
    ///         reset path is off the hot path for well-behaved tokens.
    function forceApprove(address token, address spender, uint256 amt) internal {
        bool ok;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4),  and(spender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 36), amt)
            ok := call(gas(), token, 0, m, 68, 0, 32)
            // A token that returns an explicit `false` (rather than reverting)
            // counts as failure too.
            if and(ok, eq(returndatasize(), 32)) { ok := iszero(iszero(mload(0))) }
        }
        if (!ok) {
            safeApprove(token, spender, 0);
            safeApprove(token, spender, amt);
        }
    }

    /// @dev Guards on returndatasize()==32 before reading the result — a
    ///      staticcall to a CODELESS address (EOA, an unset/garbage token
    ///      address) still returns success trivially with zero returndata,
    ///      and the EVM leaves the destination memory untouched rather than
    ///      zeroing it, so an unguarded read would return the leftover
    ///      selector/argument bytes written just above instead of 0. Matches
    ///      the same defensive pattern already used by safeTransfer /
    ///      safeTransferFrom in this file.
    function balanceOf(address token, address who) internal view returns (uint256 b) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), and(who, 0xffffffffffffffffffffffffffffffffffffffff))
            if staticcall(gas(), token, m, 36, m, 32) {
                // `>= 32`, NOT `== 32` — aligned with this file's own stated
                // returndata policy (see getReserves): a non-conformant ERC-20
                // that returns MORE than one word still has a balance in word
                // 0, and this reader feeds the measured floor. `eq` silently
                // read such tokens as balance 0. (`gas()` vs GAS_CAP here is a
                // separate, still-open question: this call sits on the
                // EXECUTION path, and capping it changes swap behavior for
                // gas-hungry tokens — that change needs its own red test.)
                if iszero(lt(returndatasize(), 32)) { b := mload(m) }
            }
        }
    }

    // =========================================================================
    //  §4  AMM PRIMITIVES (V2, V3, Stable, Solidly, V4)
    // =========================================================================

    /// @notice Read V2-style reserves.
    function getReserves(address pool) internal view returns (uint256 r0, uint256 r1) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x0902f1ac00000000000000000000000000000000000000000000000000000000)
            // Guard returndatasize >= 64 (two words): a codeless address makes
            // staticcall succeed with empty returndata, so an unguarded mload
            // would read stale memory as reserves. >= (not ==) because a real
            // getReserves() returns 96 bytes (uint112,uint112,uint32).
            if staticcall(GAS_CAP, pool, m, 4, m, 64) {
                if iszero(lt(returndatasize(), 64)) {
                    r0 := and(mload(m), 0xffffffffffffffffffffffffffff)
                    r1 := and(mload(add(m, 32)), 0xffffffffffffffffffffffffffff)
                }
            }
        }
    }

    /// @notice Read an ERC-20's decimals(), defaulting to 18 if absent.
    ///         Used by the stable solver to normalise reserves to 1e18.
    /// @notice A token's decimals, with 18 as the safe default. INTERNAL because
    ///         the REGISTRATION path (Router and Hub) needs it too: the bucket
    ///         that goes into the Monoslot is born there, and a decimals-blind
    ///         bucket collapses the depth signal of 6/8-decimal pairs — see
    ///         `shortSide18` and test/DepthBucketDecimals.t.sol.
    function decimalsOf(address token) internal view returns (uint8) { return _decimalsOf(token); }

    /// @dev Decimals from the ctx, with a fallback read. Correctness does not
    ///      depend on the caller having filled them in: if not, we read them.
    function _decIn(QuoteCtx memory c) private view returns (uint8) {
        return c.decIn1 != 0 ? c.decIn1 - 1 : _decimalsOf(c.tokenIn);
    }
    function _decOther(QuoteCtx memory c) private view returns (uint8) {
        return c.decOther1 != 0 ? c.decOther1 - 1 : _decimalsOf(c.tokenOther);
    }

    function _decimalsOf(address token) private view returns (uint8 d) {
        d = 18;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x313ce56700000000000000000000000000000000000000000000000000000000)
            if staticcall(GAS_CAP, token, m, 4, m, 32) {
                if eq(returndatasize(), 32) {
                    let v := mload(m)
                    // SEVENTY-EIGHT, not 256. `to18` does `10 ** (dec - 18)`
                    // in CHECKED arithmetic: with `dec >= 96` that overflows
                    // uint256 and gives Panic 0x11 — which violates the
                    // contract written in this file ("SATURATES instead of
                    // reverting") and opens a real griefing vector: a token
                    // with `decimals() = 200` makes the swap EXECUTE every leg
                    // and only then revert in the Router's `_recordHits`, which
                    // runs OUTSIDE the try/catch. The user's gas burns in full.
                    // It also kills the Solver's `decimalsOf(tIn) + 1`, which
                    // overflows the uint8 with `decimals() == 255`.
                    // 10^77 is the largest value that fits in uint256, so 77 is
                    // the largest usable exponent; above that we fall back to
                    // the default of 18 (fail-open, coherent with the rest).
                    if lt(v, 78) { d := v }
                }
            }
        }
    }

    /// @notice Read concentrated-liquidity active liquidity.
    function getLiquidity(address pool) internal view returns (uint128 liq) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x1a68650200000000000000000000000000000000000000000000000000000000)
            if staticcall(GAS_CAP, pool, m, 4, m, 32) {
                if iszero(lt(returndatasize(), 32)) { liq := mload(m) }
            }
        }
    }

    /// @notice Uniswap-V3 pool fee via the immutable fee() getter (0xddca3f43).
    /// @dev    Returns 0 when unreadable — Algebra's fee is dynamic and lives in
    ///         globalState(), not fee(), so an Algebra pool reads 0 here and the
    ///         caller must fail closed (never trust caller-supplied leg.fee for
    ///         the protocol-fee base: execution charges the pool's own fee).
    function getV3Fee(address pool) internal view returns (uint24 f) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xddca3f4300000000000000000000000000000000000000000000000000000000)
            if staticcall(GAS_CAP, pool, m, 4, m, 32) {
                if iszero(lt(returndatasize(), 32)) { f := and(mload(m), 0xffffff) }
            }
        }
    }

    /// @notice V3 slot0 → sqrtPriceX96.
    /// @dev L -> TOKEN-DENOMINATED depth. THE ONLY copy.
    ///      `depthWad` has to be comparable across venue families: V2 reports min(r0,r1),
    ///      linear token units. L is on a SQRT scale, so handing it over raw makes a
    ///      concentrated pool out-anchor an equally deep V2 by ~sqrt(price) — a systematic
    ///      bias in any pair whose price is far from 1, not an edge case.
    ///      Convert L into the virtual reserves it represents at the current price, short side:
    ///          x0 = L / sqrtP  (token0)      x1 = L * sqrtP  (token1)
    ///      mulDiv carries the 512-bit intermediate (L*sp overflows uint256).
    ///
    ///      WHY A PRIMITIVE AND NOT THREE COPIES: this conversion existed inline in THREE
    ///      places (universalQuote V3, universalQuote V4, Hub.claimV4) and was missing entirely
    ///      in a FOURTH (Router._recordHits), which runs on every executed swap. Sibling copies
    ///      that diverge are this codebase's defect signature — the 512-bit mulDiv and the live
    ///      Algebra fee were the same thing. A copy cannot diverge from itself.
    ///      `sp == 0` (failed read) returns raw L, preserving the previous behaviour.
    /// @dev NO PRICE, NO DEPTH. This function used to return raw `liq` when the price was not
    ///      readable — that is, it returned a number IN OTHER UNITS, which is exactly the bug it
    ///      exists to eliminate. L is on a SQRT scale; delivered raw it makes a concentrated pool
    ///      out-anchor an equally deep pair pool by a factor of sqrt-of-price.
    ///      Rule: the ABSENCE of a measurement is not a value. The correct return is zero.
    ///      Consumers handle it safely: the Solver's `_weights` normalises against the family
    ///      maximum and gives a zero the minimum weight (`if (w == 0) w = 1`), with no division
    ///      by zero. It fails SOFT — the pool loses priority, it does not poison the comparison.
    /// @notice Normalise a token-denominated quantity to 18 decimals.
    /// @dev SATURATES instead of reverting: an absurd depth must degrade to
    ///      "very deep", never make the whole quote fail.
    function to18(uint256 v, uint8 dec) internal pure returns (uint256) {
        if (v == 0 || dec == 18) return v;
        if (dec > 18) return v / (10 ** (uint256(dec) - 18));
        uint256 f = 10 ** (18 - uint256(dec));
        unchecked {
            uint256 r = v * f;
            return r / f == v ? r : type(uint256).max;
        }
    }

    /// @notice The SHORT side of a pair, already in 18 decimals — comparable depth.
    ///
    /// @dev WHY THIS EXISTS, instead of the raw `min` it used to be.
    ///
    ///      The previous version did `min(a0, a1)` over RAW units. That has two
    ///      defects, and the second one is the serious one:
    ///
    ///      1. The MINIMUM is decided by the DECIMALS, not by the depth. In a
    ///         USDC(6)/WETH(18) pair the USDC side has 1e12 times fewer units
    ///         for the same value, so it wins the `min` almost always — even
    ///         when it is economically the DEEP side.
    ///
    ///      2. `depthBucket` cuts at 1e15 raw units. Translated:
    ///           18 decimals (WETH): leaves bucket 0 at ~3 dollars
    ///            6 decimals (USDC): only leaves bucket 0 at ONE BILLION dollars
    ///            8 decimals (WBTC): only leaves bucket 0 at 650 BILLION
    ///         So EVERY pool of any 6- or 8-decimal pair fell into bucket 0,
    ///         and `bucketWeight(0) = 1` for all of them. The 1.4-billion pool
    ///         and the 100-dollar pool carried the SAME weight.
    ///
    ///      The damage is not inverted rankings across pairs — `_canInsert` only
    ///      compares candidates of the SAME pair, and there the bias cancels. The
    ///      damage is that the depth signal COLLAPSES into a single bucket inside
    ///      those pairs, and `psi = vitality x bucketWeight x bonus` degenerates
    ///      into `vitality x 1`. And the depth defence is exactly what the
    ///      `Hub:_canInsert` comment says it was added to prevent: "an attacker
    ///      can no longer keep a deep pool out merely by sending dust through 16
    ///      shallow slots to hold their vitality at 1". With everything in bucket
    ///      0 that defence was INERT.
    ///
    ///      Measured on a Base fork, block 49,800,000: the ~1.43-billion-dollar
    ///      USDC/WETH pool came out with bucket 0 and psi 1; WETH/LINK, 3,481
    ///      times shallower, came out with bucket 5 and psi 42. Red-first in
    ///      test/DepthBucketDecimals.t.sol.
    function shortSide18(uint256 a0, uint8 d0, uint256 a1, uint8 d1)
        internal pure returns (uint256)
    {
        uint256 n0 = to18(a0, d0);
        uint256 n1 = to18(a1, d1);
        return n0 < n1 ? n0 : n1;
    }

    /// @notice `depthFromL` with decimal normalisation — the version to use.
    /// @param d0 decimals of the pool's token0, d1 those of token1.
    function depthFromL18(uint128 liq, uint160 sp, uint8 d0, uint8 d1)
        internal pure returns (uint256)
    {
        if (sp == 0) return 0;
        return shortSide18(mulDiv(uint256(liq), Q96, sp), d0,
                           mulDiv(uint256(liq), sp, Q96), d1);
    }

    function depthFromL(uint128 liq, uint160 sp) internal pure returns (uint256) {
        if (sp == 0) return 0;
        uint256 x0 = mulDiv(uint256(liq), Q96, sp);
        uint256 x1 = mulDiv(uint256(liq), sp, Q96);
        return x0 < x1 ? x0 : x1;
    }

    // getSqrtPriceX96 lived here — the degraded twin of v3StateAndDynFee (same
    // slot0 + globalState reads, DIFFERENT returndata guards, so the register
    // and the quote could disagree about the same pool). Guards were split in
    // the survivor and the last caller (Router._recordHits) migrated; a copy
    // cannot diverge from itself.

    /// @notice Concentrated-liquidity state read that also MEASURES a dynamic
    ///         fee — the Algebra counterpart of INV-20's effV4Fee.
    /// @dev    Uniswap V3 answers slot0() and carries its fee in the immutable
    ///         fee() getter, so `dyn` stays false and the caller keeps the
    ///         configured fee. Algebra (Camelot) has no slot0(): its price AND
    ///         its live dynamic fee both live in globalState() — word 0 and
    ///         word 2 of the same return payload. Reading them together costs
    ///         one call, the same call the price already required, so measuring
    ///         the fee adds no call shape this library did not already make.
    ///
    ///         This exists because the V3/ALGEBRA quote branch used to pass the
    ///         Hub's 0 sentinel (Hub:361-366 forces every declared Algebra fee
    ///         to 0) straight into outV3, pricing every Algebra pool as if it
    ///         charged NO fee while execution paid the real one — a systematic
    ///         over-quote in the direction that harms the user. getV3Fee's own
    ///         doc already said the caller "must fail closed" here; nothing did.
    /// @return sp   sqrtPriceX96, or 0 when unreadable
    /// @return f    the measured dynamic fee (only meaningful when `dyn`)
    /// @return dyn  true when the pool answered globalState() (Algebra-shaped)
    function v3StateAndDynFee(address pool)
        internal view returns (uint160 sp, uint24 f, bool dyn)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            // Uniswap V3 slot0() (0x3850c7bd): sqrtPriceX96 is word 0.
            mstore(m, 0x3850c7bd00000000000000000000000000000000000000000000000000000000)
            let ok := staticcall(GAS_CAP, pool, m, 4, m, 64)
            if ok {
                if iszero(lt(returndatasize(), 32)) { sp := mload(m) }
            }
            // Algebra fallback globalState() (0xe76c01e4):
            //   word 0 = price, word 1 = tick, word 2 = fee (uint16 on both
            //   Algebra V1 and Integral; the wider mask is harmless).
            //
            // SPLIT GUARDS, and the reason is a measured divergence: the
            // sibling reader (getSqrtPriceX96) accepts the price at >= 32
            // bytes while this one demanded the full 96 — so a pool whose
            // globalState returns 32-64 bytes PRICED in one reader and read
            // as dead in the other, and the quote and the depth register
            // disagreed about the same pool. Price needs word 0 only; the
            // fee claim needs word 2, so `dyn` is only asserted with the
            // full payload — a partial answer falls through to the
            // fail-closed fee path exactly as before.
            if iszero(sp) {
                mstore(m, 0xe76c01e400000000000000000000000000000000000000000000000000000000)
                let ok2 := staticcall(GAS_CAP, pool, m, 4, m, 96)
                if ok2 {
                    if iszero(lt(returndatasize(), 32)) { sp := mload(m) }
                    if iszero(lt(returndatasize(), 96)) {
                        f   := and(mload(add(m, 0x40)), 0xffffff)
                        dyn := 1
                    }
                }
            }
        }
    }

    /// @notice Effective fee for a V3/Algebra-family pool — measure, don't take
    ///         the nominal. The exact sibling of effV4Fee (INV-20).
    /// @dev    A static V3 key is truth: a non-zero configured fee wins and no
    ///         extra read happens. A 0 configured fee is the Hub's dynamic-fee
    ///         sentinel for Algebra (Hub:361-366), so the live fee measured from
    ///         globalState() is used instead. When the pool is dynamic-shaped
    ///         but its fee could not be measured, this FAILS CLOSED with a
    ///         sentinel >= 1e6 — outV3's own guard then quotes 0 — rather than
    ///         quoting a fee-free number that execution will not honour. Same
    ///         fail-closed shape effV4Fee uses for a non-zero protocolFee.
    /// @notice The fee a V2 pool charges when the pair does not declare it.
    /// @dev    SINGLE PRODUCER of a number that was hand-written in THREE places: the Router's
    ///         QUOTE path, the Router's EXECUTION path, and `universalQuote` here. The first two
    ///         are the pair that MUST agree — if they diverge, the quote lies about what the
    ///         execution will do, which is the exact shape of the fee leaks already closed in
    ///         this codebase. Three copies of a literal are this codebase's defect signature
    ///         waiting to happen, not a style.
    ///
    ///         30 bps is the historical default of Uniswap V2 and of the forks that do not expose
    ///         the fee. It is not a conservative guess: a fee ASSUMED BELOW the real one makes
    ///         the quote promise more than the pool delivers, and execution finds the difference.
    ///
    ///         AND A CEILING, because a V2 pair has no `fee()` to read (unlike V3's quoteV3Fee):
    ///         the number can only come from calldata, and calldata is the adversary's. An
    ///         over-declared fee (measured: 9_900 = 99%) deflated the in-frame quote to ~1% and,
    ///         through `protocolFloorOut = mulDiv(finalHopQuote, floorBps, BPS)`, collapsed the
    ///         protocol floor with it — the SAME T1/INV-20 class the concentrated arm closed by
    ///         refusing to take the fee from calldata. There the fix is "read the pool"; here no
    ///         pool answers, so the fix is a ceiling: anything above a plausible V2 fee (100 bps
    ///         = 1%, well past every real deployment) falls back to the house default. Both sides
    ///         of "the pair that MUST agree" call this, so clamping HERE keeps quote and
    ///         execution byte-identical — a ceiling in only one would make them disagree and
    ///         trip the floor on honest routes. Units are BPS (outV2 does BPS - fee), not ppm.
    ///
    ///         `internal` on purpose: inlined, zero traversal cost, and the gain here is one of
    ///         CORRECTNESS and not of gas — three places that cannot diverge now cannot.
    uint24 internal constant V2_FEE_CEILING_BPS = 100;
    function effV2Fee(uint24 declared) internal pure returns (uint24) {
        return (declared == 0 || declared > V2_FEE_CEILING_BPS) ? 30 : declared;
    }

    // effV3Fee (pure) lived here; quoteV3Fee below absorbed it. The Router's
    // hand-built ternary over it was proved identical branch-by-branch and
    // migrated — one producer remains for "the effective concentrated fee".

    /// @notice Effective V3-family fee for the QUOTE/IMPACT path — the
    ///         measured sibling of effV4Fee (INV-20), and the fix for a
    ///         family-wide zero.
    /// @dev    THE CL FAMILY QUOTED 0 BY CONSTRUCTION. CL rows (Aerodrome
    ///         Slipstream, Velodrome CL) register with an EMPTY fee list —
    ///         their fee is keyed by tickSpacing — so discovery stamps the
    ///         same `fee = 0` that Hub rule R2 reserves as the ALGEBRA
    ///         dynamic-fee sentinel. A CL pool answers slot0() (dyn = false),
    ///         so effV3Fee fail-closed at 0xFFFFFF and outV3 quoted 0: the
    ///         2nd-deepest factory on Base (1,479 WETH in USDC/WETH sp=100 at
    ///         measurement, 2026-08-24) never won a single pair-hop in a
    ///         122-pair census. The EXECUTION path always knew the remedy —
    ///         Router:774 reads the pool's own fee() — this is the same
    ///         remedy applied to the quote side. MEASURED: that pool's fee()
    ///         is 334, DYNAMIC (not even the nominal 500 of its tier), so a
    ///         static fee table would mis-price; reading the pool is the only
    ///         correct source. A pool where fee() also fails still fail-closes
    ///         exactly as before — this can only widen coverage, never weaken
    ///         the INV-20 guarantee.
    function quoteV3Fee(address pool, uint24 cfgFee, uint24 dynFee, bool dyn)
        internal view returns (uint24)
    {
        if (cfgFee != 0) return cfgFee;   // static key is truth
        if (dyn) return dynFee;           // Algebra: measured live fee
        uint24 f = getV3Fee(pool);        // CL: the fee lives on the pool
        return f != 0 ? f : 0xFFFFFF;     // still unmeasurable -> fail closed
    }

    function token0Of(address pool) internal view returns (address t) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x0dfe168100000000000000000000000000000000000000000000000000000000)
            if staticcall(GAS_CAP, pool, m, 4, m, 32) {
                if iszero(lt(returndatasize(), 32)) { t := mload(m) }
            }
        }
    }

    function token1Of(address pool) internal view returns (address t) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xd21220a700000000000000000000000000000000000000000000000000000000)
            if staticcall(GAS_CAP, pool, m, 4, m, 32) {
                if iszero(lt(returndatasize(), 32)) { t := mload(m) }
            }
        }
    }

    /// @notice V2 constant-product output.
    function outV2(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee)
        internal pure returns (uint256)
    {
        if (ain == 0 || rIn == 0 || rOut == 0) return 0;
        if (fee >= BPS) return 0;   // guard: fee ≥ 100% → pool unquotable
        uint256 amtFee = ain * (BPS - fee);
        return (amtFee * rOut) / (rIn * BPS + amtFee);
    }

    /// @notice V3 single-pool exact-in via sqrtPrice (Q96-arithmetic).
    /// @notice Single-pool V3 exact-input quote in Q96 sqrt-price space.
    /// @dev    Two branches mirror the canonical Uniswap V3 SwapMath:
    ///
    ///         zeroForOne = true   (token0 in → token1 out):
    ///             sqrtNew = (L · sqrtP · Q96) / (L · Q96 + amtIn · sqrtP)
    ///             amtOut1 = L · (sqrtP − sqrtNew) / Q96
    ///
    ///         zeroForOne = false  (token1 in → token0 out):
    ///             sqrtNew = sqrtP + amtIn · Q96 / L
    ///             amtOut0 = L · Q96 · (sqrtNew − sqrtP) / (sqrtP · sqrtNew)
    ///
    ///         Fee is applied to the input as the canonical (1 − fee/1e6) ratio.
    /// @param sqrtLimit Price boundary where the swap is TRUNCATED, or 0 for no
    ///        truncation. See `sqrtBoundary`: between initialized ticks `L` does
    ///        not change, so truncating at the current range's boundary gives
    ///        EXACT for what fits inside it and STRICTLY BELOW for the rest —
    ///        never above, whatever the liquidity distribution ahead. That is
    ///        the only acceptable direction of error: over-estimating promises
    ///        what is not delivered, and the iron floor does not protect because
    ///        it is derived from this very quote.
    function outV3(
        uint256 ain, uint160 sqrtP, uint128 liq, uint24 fee, bool zeroForOne,
        uint160 sqrtLimit
    ) internal pure returns (uint256 outAmt) {
        if (ain == 0 || liq == 0 || sqrtP == 0) return 0;
        if (fee >= 1_000_000) return 0;   // guard: fee ≥ 100% → unquotable
        uint256 amtAfterFee = (ain * (1_000_000 - fee)) / 1_000_000;
        uint256 L = uint256(liq);
        uint256 P = uint256(sqrtP);
        if (zeroForOne) {
            // Canonical Uniswap V3 SqrtPriceMath.getNextSqrtPriceFromAmount0:
            //     sqrtNew = (L · sqrtP) / (L + amtIn · sqrtP / Q96)
            //
            // To avoid the L·P overflow path (L ≤ 2¹²⁸, P ≤ 2¹⁶⁰ → 2²⁸⁸),
            // we factor through mulDiv so every intermediate fits in 256 bits.
            uint256 product = mulDiv(amtAfterFee, P, Q96);
            uint256 sqrtNew = mulDiv(L, P, L + product);
            if (sqrtNew >= P || sqrtNew == 0) return 0;
            // zeroForOne: the price FALLS. Truncating means not letting it drop
            // below the boundary.
            if (sqrtLimit != 0 && sqrtNew < sqrtLimit) sqrtNew = sqrtLimit;
            outAmt = mulDiv(L, P - sqrtNew, Q96);
        } else {
            // Uniswap V3 SqrtPriceMath.getNextSqrtPriceFromAmount1:
            //     sqrtNew = sqrtP + amtIn · Q96 / L
            //     amtOut0 = L · Q96 · (sqrtNew − sqrtP) / (sqrtP · sqrtNew)
            //
            // sqrtP · sqrtNew may exceed 2²⁵⁶, so we split the division into
            // two stages: first scale by sqrtNew, then by sqrtP.
            uint256 dSqrt = mulDiv(amtAfterFee, Q96, L);
            uint256 sqrtNew = P + dSqrt;
            if (sqrtNew <= P) return 0;
            // oneForZero: the price RISES. The boundary is a ceiling.
            if (sqrtLimit != 0 && sqrtNew > sqrtLimit) sqrtNew = sqrtLimit;
            uint256 a = mulDiv(L, sqrtNew - P, sqrtNew);
            outAmt = mulDiv(a, Q96, P);
        }
    }


    /// @notice `sqrtPrice` boundary of the current tick range, in the direction
    ///         of the swap. Returns 0 (no limit) when `spacing` is 0.
    ///
    /// @dev WHY THIS IS A VALID LIMIT. A liquidity position can only start and
    ///      end at multiples of `tickSpacing`, so the INITIALIZED ticks are
    ///      exactly those multiples. Between two of them the active `L` does not
    ///      change — which is precisely the hypothesis `outV3` assumes and that
    ///      stops holding on a crossing. Truncating here makes the hypothesis
    ///      true by construction.
    ///
    /// @dev THE APPROXIMATION, and its direction. The boundary `d` ticks away is
    ///      at a ratio of `1.0001^(d/2)` in sqrtPrice. Exponentiating would cost
    ///      a whole TickMath (~300-500 B and a loop); instead we use
    ///      `1 + d/20000`. Since `e^x >= 1 + x`, the true ratio is ALWAYS larger
    ///      than this one, so the computed boundary lands CLOSER than the real
    ///      one: we clamp too early, never too late. For `spacing = 200` the
    ///      difference is 0.005%.
    ///
    ///      If one day the cost in lost routes justifies exactness, the
    ///      replacement is local: only this function changes.
    function sqrtBoundary(uint160 sqrtP, int24 tick, int24 spacing, bool zeroForOne)
        internal pure returns (uint160)
    {
        if (spacing <= 0 || sqrtP == 0) return 0;
        int256 sp_ = int256(spacing);
        // Distance in ticks to the boundary, in the swap's direction. Solidity's
        // `%` truncates toward zero, so a negative tick needs a correction so
        // that `r` is always the position INSIDE the range (0 <= r < S).
        int256 r = int256(tick) % sp_;
        if (r < 0) r += sp_;
        uint256 d = zeroForOne ? uint256(r) : uint256(sp_ - r);
        // We are already ON the boundary: the whole range lies ahead.
        if (d == 0) d = uint256(sp_);
        uint256 P = uint256(sqrtP);
        // THE TWO DIRECTIONS ARE NOT SYMMETRIC, and assuming so was a defect.
        // The boundary `d` ticks away sits at `P * r` going up and `P / r` going
        // down, with `r = 1.0001^(d/2)`. So the relative displacement is `r - 1`
        // upward but `1 - 1/r = (r-1)/r` downward — SMALLER. Using the same
        // delta on both sides let the price fall past the real boundary: it
        // clamped LATE and over-estimated, which is exactly what this clamp
        // exists to prevent.
        //
        // 20_001 and not 20_000: with 20_000 the linear approximation exceeds
        // the true value at `d = 1` (by ~1e-9, which at this scale is ~1e20 wei,
        // not one wei). Verified by sweeping d = 1 to 1000 in both directions:
        // zero violations, and the extra conservatism stays below 0.5% at the
        // canonical spacings (1, 10, 60, 200).
        if (zeroForOne) {
            uint256 dn = (P * d) / (20_001 + d);
            return dn >= P ? uint160(1) : uint160(P - dn);
        }
        uint256 up = P + (P * d) / 20_001;
        return up > type(uint160).max ? type(uint160).max : uint160(up);
    }

    /// @notice Ask a Solidly-class pair for its own exact output. Same doctrine
    ///         as an ask-the-pool adapter (quote fn == exec fn => cannot diverge):
    ///         getAmountOut(amountIn, tokenIn) is computed by the pair's own
    ///         bytecode — live fee, stable curve and rounding included — so a
    ///         swap requesting exactly this figure satisfies the K invariant by
    ///         construction and no safety haircut is needed. Returns 0 when the
    ///         pool does not expose the selector (caller falls back to the
    ///         replicated curve with a conservative haircut).
    function solidlyGetAmountOut(address pool, uint256 amountIn, address tokenIn)
        public view returns (uint256 out)
    {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature(
            "getAmountOut(uint256,address)", amountIn, tokenIn));
        if (ok && ret.length >= 32) out = abi.decode(ret, (uint256));
    }

    function outSolidly(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, bool stable
    ) public pure returns (uint256) {
        if (ain == 0 || rIn == 0 || rOut == 0) return 0;
        if (!stable) return outV2(ain, rIn, rOut, fee);
        if (fee >= BPS) return 0;
        // Stable path with EQUAL decimals (the common case: USDC/USDbC, etc.).
        // The k = x³y+xy³ invariant is homogeneous of degree 4, so when both
        // reserves share a scale the result is scale-invariant and no decimal
        // normalisation is needed. For pairs with DIFFERENT decimals the caller
        // must use outSolidlyStable(...,dIn,dOut) instead, which normalises.
        return _solidlyStable(ain, rIn, rOut, fee, 0, 0);
    }

    /// @notice The WETH -> address(0) substitution of a native V4 key. SINGLE producer.
    ///
    /// @dev    WHY IT EXISTS. The same derivation lived hand-written in TWO places of the Router
    ///         — the quote arm and the execution arm — and the comment on one of them SWORE it
    ///         "cannot diverge" with no mechanism whatsoever guaranteeing it. It is exactly the
    ///         situation that gave rise to `depthFromL`, whose comment says the same in other
    ///         words: a copy cannot diverge from itself, but two copies can diverge from each
    ///         other. And here the divergence would be silent and severe: the two sides would
    ///         derive DIFFERENT poolIds, and "quote and execute read the same pool" would fall.
    ///
    ///         WHY IT DOES NOT RETURN AN `ok`. The obvious version returns `(a, b, bool ok)` and
    ///         leaves the verdict to the caller. But in Solidity `(a, b, ) = f(...)` compiles with
    ///         NO WARNING — so a future site can ignore the `ok`, and if the failure value is
    ///         usable, it proceeds with `tokenIn == WETH` and builds the ERC20 pool key instead
    ///         of the native one: it reads a DIFFERENT pool and returns a perfectly valid number
    ///         from the wrong place, with no symptom. Corollary (c) of the Meta-Supreme Axiom.
    ///
    ///         THE ALTERNATIVE IS BETTER THAN THE `ok`: the failure value is `(0, 0)`, which is
    ///         SELF-IDENTIFYING (on success exactly ONE of the two is zero, never both) and
    ///         IMPOSSIBLE as a V4 key — V4 requires `currency0 < currency1`, so a (0,0) pool does
    ///         not exist and cannot come to exist. Whoever forgets the check gets a key that does
    ///         not resolve: `sp == 0` on the quote side (zero quote) and an `unlock` that reverts
    ///         on the execution side. There is no `ok` to forget, because there is no `ok`.
    ///         Fail-closed by CONSTRUCTION, and not by the caller's discipline.
    function nativeMapVerified(address tokenIn, address tokenOther, address weth)
        internal pure returns (address, address)
    {
        if (weth == address(0))  return (address(0), address(0));
        if (tokenIn == weth)     return (address(0), tokenOther);
        if (tokenOther == weth)  return (tokenIn, address(0));
        return (address(0), address(0));
    }

    /// @notice The Solidly CURVE with the right decimals — the ONLY producer of this quantity.
    ///
    ///         WHY IT EXISTS. The same question ("how much does this pool return?") was answered
    ///         in THREE places with THREE policies: here (decimals YES), in the Router's quoter
    ///         (decimals NO) and in the Router's executor (decimals NO). On the primary path all
    ///         three make the same call to the same pool and agree by construction; the
    ///         divergence lived entirely in the fallback. This codebase's defect signature, N=3.
    ///
    ///         WHY THE DECIMALS. The stable invariant k = x3y + xy3 is homogeneous of degree 4,
    ///         so with reserves at the SAME scale the result is scale-invariant — which is why
    ///         the equal-decimals path passes (0,0) and normalises nothing. With 18/6 the raw
    ///         reserves are 12 orders of magnitude apart and the curve returns garbage. The real
    ///         pair normalises internally because it KNOWS its decimals; whoever asks it has to
    ///         know them too.
    ///
    ///         IT DERIVES THE PAIR FROM THE POOL, NOT FROM THE CALLER. The other token is read
    ///         from the pool itself rather than passed in — deliberately. A single-producer
    ///         primitive that accepts its caller's coordinate goes back to the shape that allows
    ///         divergence: one of the three places passing the wrong token would suffice. It only
    ///         runs in the fallback, so the two staticcalls are paid on the rare path.
    ///
    ///         WHAT THIS PRIMITIVE DOES NOT DO: the haircut. See `universalQuote` and
    ///         `_execSolidlyAmt` — that is the margin of a REQUEST, not a property of the curve,
    ///         and it does not travel into the quote channels. A single policy means a single
    ///         CURVE, not a single set of adjustments.
    function solidlyCurveOut(
        address pool, uint256 ain, uint256 rIn, uint256 rOut,
        bool stable, uint256 cfgFee, address tokenIn
    ) public view returns (uint256) {
        uint256 liveFee = readDynamicFee(pool, stable, cfgFee);
        if (!stable) return outSolidly(ain, rIn, rOut, liveFee, false);
        address t0 = token0Of(pool);
        address other = t0 == tokenIn ? token1Of(pool) : t0;
        return outSolidlyStable(ain, rIn, rOut, liveFee, _decimalsOf(tokenIn), _decimalsOf(other));
    }

    /// @notice Solidly stable quote with explicit token decimals. Normalises
    ///         both reserves and the input to 1e18 before solving the
    ///         invariant, then de-normalises the output — required when the two
    ///         tokens have different decimals (e.g. DOLA 18 / USDC 6). This is
    ///         the validated DexStableFix algorithm (matches live getAmountOut
    ///         within 0.5% across balanced and skewed pools).
    function outSolidlyStable(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee,
        uint8 dIn, uint8 dOut
    ) internal pure returns (uint256) {
        if (ain == 0 || rIn == 0 || rOut == 0) return 0;
        if (fee >= BPS) return 0;
        return _solidlyStable(ain, rIn, rOut, fee, dIn, dOut);
    }

    /// @dev Core stable solver. When dIn==dOut==0 the reserves are used as-is
    ///      (equal-decimal fast path); otherwise each side is scaled to 1e18.
    function _solidlyStable(
        uint256 ain, uint256 rIn, uint256 rOut, uint256 fee,
        uint8 dIn, uint8 dOut
    ) private pure returns (uint256) {
        // Fail-closed on tokens with >18 decimals: 10**(18-d) would underflow
        // and revert on the hot path. Return 0 so the per-leg / aggregate floors
        // absorb the pool instead of bricking the whole route (keeps the eval total).
        if (dIn > 18 || dOut > 18) return 0;
        uint256 sIn  = (dIn  == 0) ? 1 : 10 ** (18 - dIn);
        uint256 sOut = (dOut == 0) ? 1 : 10 ** (18 - dOut);
        uint256 X = rIn  * sIn;
        uint256 Y = rOut * sOut;
        // Guard the cubic terms against uint256 overflow on absurd reserves.
        if (X > 3.4e38 || Y > 3.4e38) return 0;
        uint256 A = (ain * sIn * (BPS - fee)) / BPS;
        if (X + A > 3.4e38) return 0;
        uint256 K = _solK(X, Y);
        uint256 y = _solY(X + A, K, Y);   // seed at opposite reserve
        if (y >= Y) return 0;
        return (Y - y) / sOut;
    }

    /// @notice Read the dynamic fee for a Solidly-class pool (Aerodrome family).
    ///         Falls back to the configured fee if the factory does not expose
    ///         getFee(pool, stable). Used by both the quote path (off-chain
    ///         preview) and the execution path (Router) to ensure they always
    ///         agree on the fee the pool will actually charge at swap time —
    ///         eliminating the K() over-quote race that would otherwise revert.
    function readDynamicFee(address pool, bool stable, uint256 cfgFee)
        public view returns (uint256 fee)
    {
        // CEILING ON THE DECLARED FALLBACK — the sibling of `effV2Fee`.
        // `cfgFee` is `leg.fee`, i.e. CALLDATA, at all three call sites of
        // `solidlyCurveOut` (Router quote, Router execution, Core.universalQuote).
        // A Solidly-shaped pair that exposes neither `getAmountOut` nor a working
        // `factory()`/`getFee` leaves this declaration as the ONLY fee source, and
        // an over-declared value (9_900 = 99%) collapses the leg's on-chain quote
        // to ~1% of the truth. When that leg is the final hop it drags
        // `finalHopQuote` — and therefore `protocolFloorOut`, the figure this
        // protocol advertises as unforgeable by calldata — down with it.
        // The V2 arm closed exactly this in `effV2Fee` (V2_FEE_CEILING_BPS); the
        // Solidly arm reached the same primitive through here and was missed.
        // House rule B8: a defect found once is a pattern to hunt everywhere.
        fee = (cfgFee == 0 || cfgFee > V2_FEE_CEILING_BPS) ? 30 : cfgFee;
        (bool ok, bytes memory ret) = pool.staticcall(
            abi.encodeWithSignature("factory()")
        );
        if (!ok || ret.length < 32) return fee;
        address fac = abi.decode(ret, (address));
        if (fac == address(0)) return fee;
        (ok, ret) = fac.staticcall(
            abi.encodeWithSignature("getFee(address,bool)", pool, stable)
        );
        if (ok && ret.length >= 32) {
            uint256 f = abi.decode(ret, (uint256));
            if (f > 0 && f < BPS) fee = f;
        }
    }

    function _solK(uint256 x, uint256 y) private pure returns (uint256) {
        // 512-bit intermediates (mulDiv) so the Solidly cubic invariant does not
        // revert on large stable reserves: the raw products x*y, x*x, y*y and
        // a*b overflow around x ~ 1.5e28, turning a quote into a checked-
        // arithmetic revert (a quote DoS on deep stable pools). See the corpus, M1.
        uint256 a = mulDiv(x, y, WAD);
        uint256 b = mulDiv(x, x, WAD) + mulDiv(y, y, WAD);
        return mulDiv(a, b, WAD);
    }

    /// @notice Solve the Solidly stable invariant k = x³y + xy³ for y, given
    ///         x and target k, using Newton's method seeded at y0 (the opposite
    ///         reserve). This is the validated DexStableFix algorithm: seeding
    ///         at the opposite reserve and stepping bidirectionally (up when
    ///         k(x,y) < K, down when k(x,y) > K) converges for both balanced
    ///         and heavily-skewed pools, matching Aerodrome's live getAmountOut
    ///         within 0.5%. Inputs are expected pre-normalised to 1e18 by the
    ///         caller (outSolidlyStable), so x and y share the same scale.
    /// @param  x  post-trade input-side balance (normalised)
    /// @param  K  target invariant computed from the pre-trade reserves
    /// @param  y0 initial guess — the pre-trade output reserve (normalised)
    function _solY(uint256 x, uint256 K, uint256 y0)
        private pure returns (uint256 y)
    {
        if (x == 0 || K == 0) return y0;
        y = y0;
        for (uint256 i; i < 64; ) {
            uint256 ky = _solK(x, y);
            // f'(y) = x·(x² + 3y²)/WAD² — the invariant's derivative in y.
            // 512-bit intermediates (mulDiv) so a deep stable pool cannot make
            // this overflow into a checked-arithmetic revert (a quote DoS).
            uint256 fp = mulDiv(x, mulDiv(x, x, WAD) + 3 * mulDiv(y, y, WAD), WAD);
            if (fp == 0) return y0;  // derivative vanished -> caller maps to out = 0
            uint256 yPrev = y;
            if (ky < K) {
                uint256 dy = mulDiv(K - ky, WAD, fp);
                y += (dy == 0 ? 1 : dy);
            } else {
                uint256 dy = mulDiv(ky - K, WAD, fp);
                if (dy == 0) dy = 1;
                if (dy >= y) dy = y / 2;   // never step past zero
                y -= dy;
            }
            uint256 d = y > yPrev ? y - yPrev : yPrev - y;
            if (d <= 1) {
                // INV-11/INV-10: land the converged exit on the residual-safe
                // side (K_post >= K_pre => rounding against the taker). _solK is
                // increasing in y for x > 0, so bumping y by one whenever the
                // residual is K-deficient guarantees the safe side; O(1) gas.
                if (_solK(x, y) < K) y += 1;
                return y;   // converged
            }
            unchecked { ++i; }
        }
        // Iteration cap reached without convergence: fail closed. Return y0 —
        // the seed, equal to the output reserve Y — so the caller's `y >= Y`
        // guard maps this to out = 0 (pool treated as unpriceable), matching
        // some forks (raise) / Aerodrome (revert "!y"). Returning 0 here would make
        // the caller compute out = Y - 0 = Y, a catastrophic over-quote.
        return y0;
    }

    // =========================================================================
    //  §5  AMM QUOTE DISPATCHER
    // =========================================================================

    /// @notice AMM quote for a pool of any supported kind.
    /// @return out          amount out for `amountIn` tokens of `ctx.tokenIn`
    /// @return depthWad     pool depth in WAD-equivalent units
    /// @dev    The quote dispatcher for the Solver and the Quoter.
    ///
    ///         IT IS NOT THE ONLY ONE. This line used to say "kind branching lives here only" and
    ///         it was FALSE: the Router has its own quote dispatcher (`_hopScaleImpactAndQuote`)
    ///         and the Quoter another (`previewPlanExact`). Both are DELIBERATE — the Router's
    ///         exists for gas and stack depth, the Quoter's because the exact-pass is a different
    ///         question — and both are recorded in the Seam Register. What was wrong was the
    ///         prose, not the design. Criterion 7: a wrong fact written down is worse than none,
    ///         because it biases the reader against going to look for the siblings.
    function universalQuote(QuoteCtx memory c, uint256 amountIn)
        public view returns (uint256 out, uint256 depthWad)
    {
        if (amountIn == 0) return (0, 0);
        uint8 k = c.kind;
        // Tombstone 3 left this branch (an EIP-170 dead-code pass): the venue
        // that lived there did not expose getReserves(), so this branch always
        // read (0,0) and quoted 0 — the kind never produced a routable quote.
        // Falling through to the default (0,0) return is byte-for-byte the
        // same observable result.
        if (k == KIND_V2) {
            (uint256 r0, uint256 r1) = getReserves(c.pool);
            (uint256 rI, uint256 rO) = c.zeroForOne ? (r0, r1) : (r1, r0);
            // UniV2/Sushi charge 0.30%. fee==0 (no fee list) -> 30 bps default,
            // so the quote matches the pool's x*y=k (else "K" revert on exec).
            uint24 v2fee = effV2Fee(c.fee);
            out      = outV2(amountIn, rI, rO, v2fee);
            depthWad = shortSide18(rI, _decIn(c), rO, _decOther(c));
            return (out, depthWad);
        }
        if (k == KIND_V3 || k == KIND_ALGEBRA) {
            // One read yields the price AND, for a dynamic-fee (Algebra) pool,
            // the live fee — measured, never the Hub's 0 sentinel. See
            // v3StateAndDynFee / quoteV3Fee: the INV-20 "measure, don't take the
            // nominal" rule, applied to the OTHER dynamic-fee family in this
            // same dispatcher. Static V3 keys are untouched (cfgFee wins, no
            // extra read, byte-identical quote and gas).
            (uint160 sp, uint24 dynFee, bool isDyn) = v3StateAndDynFee(c.pool);
            uint128 liq = getLiquidity(c.pool);
            // NO boundary clamp, for now: `v3StateAndDynFee` does not yet return
            // the tick, and the per-crossing cost in V3 is ~2x that of V4 (the
            // `ticks()` getter drags 4 slots the quote does not use, against one
            // batchable `extsload`). V4 goes first because that is where the
            // error was measured; extending to V3 is the same change, one read up.
            out      = outV3(amountIn, sp, liq, quoteV3Fee(c.pool, c.fee, dynFee, isDyn), c.zeroForOne, 0);
            // depthWad must be TOKEN-DENOMINATED to be comparable across venue
            // families: the Solver's band anchor picks max(depths[]) across V2
            // (min(r0,r1), linear token units) and V3 candidates alike. Raw L is
            // on a sqrt scale, so returning it made a V3 pool out-anchor an
            // equally-deep V2 pool by a factor of ~sqrt(price) — a systematic
            // bias at any price away from 1, not an edge case. Convert L to the
            // virtual reserves it represents at the current price and take the
            // short side, the same quantity V2 reports:
            //     x0 = L / sqrtP  (token0)      x1 = L * sqrtP  (token1)
            // mulDiv carries the 512-bit intermediate (L*sp overflows uint256).
            // This tightens NO tolerance and adds NO revert path — it only fixes
            // the unit of an existing comparison. Within a family the price
            // cancels in _weights' depth[i]/maxByFam ratio, so allocation is
            // unchanged; only the cross-family anchor choice is corrected.
            uint8 dIn3 = _decIn(c);
            uint8 dOt3 = _decOther(c);
            (uint8 b0, uint8 b1) = c.zeroForOne ? (dIn3, dOt3) : (dOt3, dIn3);
            depthWad = depthFromL18(liq, sp, b0, b1);
            return (out, depthWad);
        }
        if (k == KIND_SOLIDLY) {
            (uint256 r0, uint256 r1) = getReserves(c.pool);
            (uint256 rI, uint256 rO) = c.zeroForOne ? (r0, r1) : (r1, r0);
            // PRIMARY: ask the pool itself. Exact by construction — the same
            // bytecode that enforces K at execution produced the number, so
            // nothing is left behind in the pool and quote == execution.
            out = solidlyGetAmountOut(c.pool, amountIn, c.tokenIn);
            // `<= 1`, NOT `== 0`: the Router's quote channel aligned this
            // trigger with the executor (`_execSolidlyAmt` treats <= 1 as "no
            // answer") for the stated reason that a pool returning exactly 1
            // made two symmetric channels take DIFFERENT branches. This copy —
            // the Quoter's door — was the THIRD channel of the same fact and
            // kept the old trigger; the fix had reached 2 of 3.
            if (out <= 1) {
                // FALLBACK (forks without getAmountOut only): replicate the
                // curve with the live fee, then under-ask by 200 bps so the
                // pool's K rounding — which we cannot observe — always has
                // slack. The haircut is intentionally the pool's gain; it
                // never applies when getAmountOut answered above.
                out = solidlyCurveOut(c.pool, amountIn, rI, rO, c.stable, c.fee, c.tokenIn);
                out = (out * 9800) / BPS;
            }
            depthWad = shortSide18(rI, _decIn(c), rO, _decOther(c));
            return (out, depthWad);
        }
        if (k == KIND_V4 || k == KIND_V4_NATIVE) {
            // Both V4 kinds quote identically and deliberately share this branch:
            // the pool id is derived from the two sorted currencies, and a native
            // currency is just address(0), which sorts first. Nothing in the
            // pricing depends on whether a currency is native — only settlement
            // does, and settlement lives in the Router.
            //
            // V4 quote: extsload state read + V3 concentrated-liquidity formula.
            // Current-tick approximation (no tick-crossing, ignores hooks).
            // Hook seam (INV-20): a dynamic-fee pool's hook can override the
            // fee per-swap in beforeSwap (needs only BEFORE_SWAP_FLAG — the
            // delta-flag reject does NOT gate it) or move it mid-block via
            // updateDynamicLPFee, so slot0's lpFee is the stored fee, not
            // necessarily the executed one. The defenses are the Hub's manual
            // hook allow-list (admission) and the Router's iron floor re-derived
            // from realised output (execution), which bound a hostile override
            // to a revert or a within-slack shortfall — never a bad fill.
            (address s0, address s1) = sortTokens(c.tokenIn, c.tokenOther);
            bytes32 pid = computeV4PoolId(s0, s1, c.fee, c.tickSpacing, c.hooks);
            // The `tick` is left unread HERE on purpose: the boundary clamp
            // belongs to the PROMISE layer and not to RANKING (see the long note
            // on `outV3`). It is discarded with a hole rather than a name, so as
            // not to leave a solc 2072 warning masking real warnings.
            (uint160 sp, uint128 liq, uint24 lpF, uint24 pF, ) =
                v4SqrtAndLiq(c.v4Manager, pid);
            if (sp == 0 || liq == 0) return (0, 0);
            // NO BOUNDARY CLAMP HERE, and the reason is a measured lesson.
            //
            // `universalQuote` serves TWO different questions: "which pool
            // delivers more?" (ranking) and "how much can I guarantee?"
            // (promise). The tick-boundary clamp (`sqrtBoundary` plus the
            // `sqrtLimit` parameter of `outV3`) answers the SECOND — it is an
            // honest lower bound. Applying it here answers the first with the
            // wrong tool.
            //
            // The damage is asymmetric and it was observed: V2 has no tick
            // structure, so it is not clampable; clamping only the concentrated
            // families makes the ranking compare quantities under different
            // conventions, and a shallow V2 starts beating a deep V4 on any
            // trade that leaves the current range. With `spacing = 60` that is
            // ~0.6% of price — routine. It is the SAME class as the `depthBucket`
            // defect (comparing without normalising), which already cost a session.
            //
            // And the measurement says the clamp would under-estimate: on the
            // ENA/USDC pool at 1,000 USDC the REAL output was 14.5% above the
            // model — there really was more liquidity beyond the boundary.
            //
            // The right place is the PROMISE layer: the `expectedOut` of the
            // already-sized leg, the Preview's `netOut` and the `ironFloor`.
            // There a lower bound is exactly what is wanted, and there is no
            // cross-family comparison to bias.
            out = outV3(amountIn, sp, liq, effV4Fee(c.fee, lpF, pF), c.zeroForOne, 0);
            // Same token-denomination as the V3 branch above: the band anchor
            // compares depths[] ACROSS families, so a V4 pool reporting raw L
            // (sqrt scale) would out-anchor an equally-deep V2 pool by
            // ~sqrt(price). sp is non-zero here (guarded on entry).
            uint8 dIn4 = _decIn(c);
            uint8 dOt4 = _decOther(c);
            (uint8 a0, uint8 a1) = c.zeroForOne ? (dIn4, dOt4) : (dOt4, dIn4);
            depthWad = depthFromL18(liq, sp, a0, a1);
            return (out, depthWad);
        }
    }

    /// @notice Read a V4 pool's sqrtPriceX96 and liquidity via extsload on the
    ///         singleton PoolManager. Slot layout verified against the canonical
    ///         StateView on a mainnet fork: base = keccak256(abi.encode(poolId,
    ///         6)); slot0 (offset 0) packs sqrtPriceX96 in its low 160 bits;
    ///         liquidity is at offset +3 (low 128 bits).
    /// @dev The returned `tick` comes for FREE: it lives in the same slot0 word
    ///      already read for `sqrtPriceX96`, bits [160,184). It is what lets
    ///      `sqrtBoundary` know how far away the range boundary is — without it
    ///      the only safe limit would be "zero distance", which would give a
    ///      null output.
    function v4SqrtAndLiq(address manager, bytes32 poolId)
        public view
        returns (uint160 sqrtP, uint128 liq, uint24 lpFee, uint24 protoFee, int24 tick)
    {
        if (manager == address(0)) return (0, 0, 0, 0, 0);
        bytes32 base = keccak256(abi.encode(poolId, uint256(6)));
        bytes32 word0;
        bytes32 word3;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x1e2eaeaf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), base)
            // Codeless-address guard (same doctrine as balanceOf/getReserves):
            // staticcall to an empty account succeeds with no returndata, and
            // an unguarded mload would read the selector/arg bytes as state.
            if staticcall(GAS_CAP, manager, m, 36, m, 32) {
                if eq(returndatasize(), 32) { word0 := mload(m) }
            }
            mstore(m, 0x1e2eaeaf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), add(base, 3))
            if staticcall(GAS_CAP, manager, m, 36, m, 32) {
                if eq(returndatasize(), 32) { word3 := mload(m) }
            }
        }
        sqrtP    = uint160(uint256(word0));
        liq      = uint128(uint256(word3));
        // slot0 packing (verified vs StateView): [0,160) sqrtPriceX96 |
        // [160,184) tick | [184,208) protocolFee | [208,232) lpFee.
        protoFee = uint24(uint256(word0) >> 184);
        lpFee    = uint24(uint256(word0) >> 208);
        tick     = int24(uint24(uint256(word0) >> 160));
    }

    /// @notice INV-20 (V4-FEE-MEASURED): the effective swap fee for a V4 leg.
    ///         A static-fee key carries the real fee in the key itself. A
    ///         dynamic-fee key uses the sentinel 0x800000 — its true fee lives
    ///         only in slot0's lpFee (measure-not-nominal). Fail closed while a
    ///         non-zero protocolFee is present: its composition with lpFee is
    ///         not yet anchored, so we return an unquotable fee (outV3 → 0)
    ///         rather than under-charge. Measured protocolFee on Base = 0 today,
    ///         so this loses nothing in practice.
    function effV4Fee(uint24 keyFee, uint24 lpFee, uint24 protoFee)
        internal pure returns (uint24)
    {
        if (keyFee != 0x800000) return keyFee;      // static: the key is truth
        if (protoFee != 0)      return 0xFFFFFF;     // dynamic + protoFee: fail-closed (≥1e6 → outV3 returns 0)
        return lpFee;                                 // dynamic: the measured slot0 fee
    }

    /// @notice Batch slot0 read for many V4 poolIds in ONE staticcall via the
    ///         PoolManager's `extsload(bytes32[])` (selector 0xdbd035ff). Used
    ///         by the Hub's derive-scan to filter candidate tiers: a candidate
    ///         earns the full `v4SqrtAndLiq` verification only if its slot0
    ///         word is non-zero, which roughly halves the cost of a miss (one
    ///         batched SLOAD instead of two single-slot calls). Same guarded
    ///         doctrine as `v4SqrtAndLiq`: a codeless or non-conforming
    ///         manager yields all-zero words (fail-closed), never a revert.
    /// @return word0s Raw slot0 word per poolId (zero => uninitialized pool).
    function v4Slot0Batch(address manager, bytes32[] memory poolIds)
        internal view returns (bytes32[] memory word0s)
    {
        uint256 n = poolIds.length;
        word0s = new bytes32[](n);
        if (manager == address(0) || n == 0) return word0s;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xdbd035ff00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), 0x20)  // abi offset of the slots array
            mstore(add(m, 36), n)    // array length
            // Per poolId the argument is the pool's base storage slot,
            // keccak256(abi.encode(poolId, POOLS_SLOT = 6)); slot0 sits at
            // offset 0, so the base IS the slot0 key. The hash preimage uses
            // scratch space (0x00..0x3f), as memory-safe rules allow.
            let src := add(poolIds, 32)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(0x00, mload(add(src, shl(5, i))))
                mstore(0x20, 6)
                mstore(add(add(m, 68), shl(5, i)), keccak256(0x00, 0x40))
            }
            let cdLen := add(68, shl(5, n))
            // Expected return: abi-encoded bytes32[] = offset ++ length ++ words.
            let retLen := add(64, shl(5, n))
            let rp := add(m, cdLen)
            // Gas cap scales with the batch (~2100 per cold SLOAD plus call/abi
            // overhead): generous but bounded, so a hostile or bloated manager
            // can never consume the whole scan's gas.
            if staticcall(add(30000, mul(n, 3000)), manager, m, cdLen, rp, retLen) {
                if and(
                    eq(returndatasize(), retLen),
                    and(eq(mload(rp), 0x20), eq(mload(add(rp, 32)), n))
                ) {
                    let dst := add(word0s, 32)
                    let sw := add(rp, 64)
                    for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                        mstore(add(dst, shl(5, i)), mload(add(sw, shl(5, i))))
                    }
                }
            }
        }
    }


    // =========================================================================
    //  §6  POOL FITNESS SCORE (psi)
    // =========================================================================
    //
    //  score(pool) = vitality × bucketWeight(depth) × (1 + bridgeBonus)
    //                         × (1 + concentrationBonus)
    //
    //  All factors live in a single packed uint256 slot, so reading the score
    //  costs one SLOAD. Slot layout:
    //
    //      bits  [  0:0  ] = active flag
    //      bits  [  7:1  ] = reserved (bit 7 = bridge flag, set by Hub)
    //      bits  [ 31:8  ] = fee tier (uint24)
    //      bits  [ 39:32 ] = pool kind (uint8)
    //      bits  [ 47:40 ] = risk tier (uint8)
    //      bits  [ 59:48 ] = concentration bonus BPS (uint12, max 4095)
    //      bits  [ 63:60 ] = depth bucket (uint4) — no overlap with conc bits
    //      bits  [ 95:64 ] = lastUpdateTs (uint32)
    //      bits  [127:96 ] = emaIn (uint32)
    //      bits  [159:128] = emaOut (uint32)
    //      bits  [191:160] = swapCount (uint32)
    //      bits  [223:192] = regBlk (uint32)
    //      bits  [255:224] = lastBlk (uint32)

    function encodeSlot(
        bool   active,
        uint24 fee,
        uint8  kind,
        uint8  tier,
        uint16 conc,
        uint32 ts,
        uint32 emaIn,
        uint32 emaOut,
        uint32 swapCount,
        uint32 regBlk,
        uint32 lastBlk
    ) internal pure returns (uint256 s) {
        unchecked {
            s = active ? uint256(1) : uint256(0);
            s |= uint256(fee)        << 8;
            s |= uint256(kind)       << 32;
            s |= uint256(tier)       << 40;
            // conc confined to bits [59:48] (12 bits) so it can never touch the
            // depth bucket at [63:60]: mask before shifting.
            s |= (uint256(conc) & 0xFFF) << 48;
            s |= uint256(ts)         << 64;
            s |= uint256(emaIn)      << 96;
            s |= uint256(emaOut)     << 128;
            s |= uint256(swapCount)  << 160;
            s |= uint256(regBlk)     << 192;
            s |= uint256(lastBlk)    << 224;
        }
    }

    function isActive(uint256 s)        internal pure returns (bool)    { return (s & 1) == 1; }
    function decodeKind(uint256 s)      internal pure returns (uint8)   { return uint8(s >> 32); }
    function decodeFee(uint256 s)       internal pure returns (uint24)  { return uint24(s >> 8); }
    function decodeSwapCount(uint256 s) internal pure returns (uint32)  { return uint32(s >> 160); }
    function decodeLastBlk(uint256 s)   internal pure returns (uint32)  { return uint32(s >> 224); }
    function decodeLastUpdateTs(uint256 s) internal pure returns (uint32) { return uint32(s >> 64); }
    function decodeBucket(uint256 s)    internal pure returns (uint8)   { return uint8((s >> 60) & 0xF); }

    function setBucket(uint256 s, uint8 b) internal pure returns (uint256) {
        unchecked {
            // Clear bits [63:60] then set new bucket
            return (s & ~(uint256(0xF) << 60)) | (uint256(b & 0xF) << 60);
        }
    }

    /// @notice depth → bucket via log10. Bucket b = min(15, floor(log10(d/1e15)))
    function depthBucket(uint256 depthWad) internal pure returns (uint8) {
        if (depthWad < 1e15) return 0;
        uint256 b = ilog10(depthWad / 1e15);
        return b > 15 ? 15 : uint8(b);
    }

    function bucketWeight(uint8 b) internal pure returns (uint256) {
        return uint256(1) << b;
    }

    /// @notice Decay step, in wall-clock seconds. Vitality is right-shifted
    ///         once per step elapsed since lastUpdateTs; full decay (shift >
    ///         31) hits at 32 × this constant ≈ 9.1 days. Expressed in real
    ///         time (not blocks) so the decay window means the same duration
    ///         on every chain — Base/Arbitrum block times differ from L1 by
    ///         6-50×, which silently warped a block-counted window. Matches
    ///         the original design intent (65 536 blocks @ 12s ≈ 9 days); the
    ///         previous implementation shifted every 16 blocks instead of
    ///         every 2 048, decaying to zero ~128× faster than documented.
    uint256 internal constant VITALITY_DECAY_STEP_SECONDS = 24_576;

    /// @notice Vitality score from slot (decay over a wall-clock window).
    /// @dev    Reads lastUpdateTs (bits [95:64]), stamped in wall-clock time
    ///         by the Hub on every tick/register (see
    ///         BlazePhoenixHub._stampTs) — no new slot field needed.
    function vitality(uint256 slot, uint32 currentTs) internal pure returns (uint256 v) {
        // Single source of truth for the decay arithmetic (see _decayedSwapCount) —
        // vitality() adds only its ranking policy on top, never a second copy of the
        // maths. R5: a figure computed in two places will diverge.
        v = uint256(_decayedSwapCount(slot, currentTs));
        if (v != 0) return v;
        // v == 0 covers two states the scorer must tell apart: (a) the slot is DEAD —
        // empty, never ticked, or past the 32-step full-decay horizon — which scores a
        // true 0 and drops the pool from ranking, and (b) a LIVE slot whose count merely
        // rounded away under the shift, floored to 1 so a real pool never vanishes.
        if (slot == 0) return 0;
        uint32 lastTs = decodeLastUpdateTs(slot);
        if (lastTs == 0) return 0;
        uint32 age = currentTs > lastTs ? currentTs - lastTs : 0;
        if (age / VITALITY_DECAY_STEP_SECONDS > 31) return 0;
        return 1;
    }

    /// @notice Composite fitness of a pool given its slot, bridge bit and
    ///         concentration flag, in BPS form.
    function psi(
        uint256 slot, uint32 currentTs,
        bool isBridge, bool isConcentrated
    ) internal pure returns (uint256 f) {
        uint256 v = vitality(slot, currentTs);
        if (v == 0) return 0;
        uint256 w = bucketWeight(decodeBucket(slot));
        if (w == 0) w = 1;
        f = v * w;
        if (isBridge)        f += (f * 2_500) / BPS;
        if (isConcentrated)  f += (f * 500)   / BPS;
    }

    /// @dev True decayed swapCount as of currentTs — no scoring floor (unlike vitality(), which
    ///      floors a decayed-to-zero live slot to 1 for display/ranking). 0 here genuinely means
    ///      no activity survives the decay window. Shared by vitality() and tickSlot() so a
    ///      reactivation counts from what actually remains, never from the pre-decay historical
    ///      total (see docs/INVARIANTS_AND_TIME.md R3: "price by what remains, never a historical
    ///      scalar" — swapCount was previously a raw cumulative counter that never reset in
    ///      storage, so a single dust swap after a full decay instantly restored the pool's
    ///      entire historical vitality). vitality() delegates its decay arithmetic here and adds
    ///      only its dead-vs-floored ranking policy, so the maths exists in exactly one place.
    function _decayedSwapCount(uint256 slot, uint32 currentTs) internal pure returns (uint32) {
        if (slot == 0) return 0;
        uint32 lastTs = decodeLastUpdateTs(slot);
        if (lastTs == 0) return 0;
        uint32 swapCount = decodeSwapCount(slot);
        uint32 age = currentTs > lastTs ? currentTs - lastTs : 0;
        if (age < VITALITY_DECAY_STEP_SECONDS) return swapCount;
        uint256 shift = age / VITALITY_DECAY_STEP_SECONDS;
        if (shift > 31) return 0;
        return uint32(uint256(swapCount) >> shift);
    }

    /// @notice Update the slot after a swap. Increments swap count (from its currently-decayed
    ///         base, not the raw historical total), refreshes last-block, and (optionally)
    ///         re-buckets depth.
    function tickSlot(
        uint256 slot, uint32 currentBlock, uint256 newDepthWad, uint32 currentTs
    ) internal pure returns (uint256) {
        uint32 sc = _decayedSwapCount(slot, currentTs);
        unchecked { sc = sc == type(uint32).max ? sc : sc + 1; }
        // clear swapCount + lastBlk + bucket
        uint256 s = slot
            & ~((uint256(0xFFFFFFFF) << 160) | (uint256(0xFFFFFFFF) << 224) | (uint256(0xF) << 60));
        s |= uint256(sc) << 160;
        s |= uint256(currentBlock) << 224;
        s |= uint256(depthBucket(newDepthWad)) << 60;
        return s;
    }

    // =========================================================================
    //  §7  OUTPUT FLOOR
    // =========================================================================
    //
    //  floorBps is computed as:
    //
    //     base   = FLOOR_BASE_BPS                          (9 600)
    //     legShv = FLOOR_PER_LEG_BPS × max(0, legs - 1)    (200 per extra leg)
    //     impShv = FLOOR_IMPACT_FACTOR × impactBps         (1:1 BPS)
    //     sigShv = sigmaLn / 1e14                          (clamped)
    //     floor  = max(base − legShv − impShv − sigShv, BPS − FLOOR_HARD_MAX_LOSS_BPS)
    //
    //  i.e. starts at 96% for clean single-leg swaps, loosens with impact and
    //  leg count, and is clamped so it never drops below the 80% hard cap
    //  (BPS − 2 000 = 8 000) regardless of inputs.

    function ironFloorBps(
        uint256 impactBps, uint256 legCount, uint256 sigmaLn
    ) internal pure returns (uint256 floorBps) {
        unchecked {
            uint256 base = FLOOR_BASE_BPS;
            uint256 legShv = legCount > 1 ? (legCount - 1) * FLOOR_PER_LEG_BPS : 0;
            uint256 impShv = impactBps > BPS ? BPS : impactBps;
            uint256 sigShv = sigmaLn / 1e14;
            uint256 hardFloor = BPS - FLOOR_HARD_MAX_LOSS_BPS;
            uint256 total = legShv + impShv + sigShv;
            floorBps = total >= base ? hardFloor : base - total;
            if (floorBps < hardFloor) floorBps = hardFloor;
        }
    }

    /// @notice V2-style impact in BPS (round-up).
    function impactV2Bps(uint256 amountIn, uint256 reserveIn)
        internal pure returns (uint256)
    {
        if (reserveIn == 0) return BPS;
        uint256 i = mulDivUp(amountIn, BPS, reserveIn + amountIn);
        return i > BPS ? BPS : i;
    }

    /// @notice Dimensionally-correct V3 price impact in BPS (monotonic).
    /// @dev    Impact = 1 - effectivePrice/spotPrice via outV3 + sqrtPriceX96.
    ///         Quote-time estimate; execution protection is the Omega floor.
    /// @notice V4 hook policy read from the hook ADDRESS bits (CREATE2-style).
    /// @dev    V4 encodes permissions in the lowest 14 bits of the hook address
    ///         (immutable). A single AND tells us if the hook can return swap
    ///         deltas (BEFORE/AFTER_SWAP_RETURNS_DELTA = 1<<3 | 1<<2), which can
    ///         alter accounting / create free-swap risk. No call to the hook.
    function hookAltersDeltas(address hook) internal pure returns (bool) {
        uint256 bits = uint160(hook) & 0x3FFF;
        uint256 deltaFlags = (1 << 3) | (1 << 2);
        return (bits & deltaFlags) != 0;
    }

    /// @notice Impact in BPS from an ALREADY COMPUTED output — the primitive.
    /// @dev    THE PATTERN THIS KILLS: "impact re-derives the quote". An impact function that
    ///         embeds the curve forces its caller to pay the curve TWICE, because whoever wants
    ///         impact already has the quote in hand. That was the case in the Router: one line
    ///         called `impactV3Bps(legAmt, sp, lq, live, zfo)` — which runs `outV3` inside — and
    ///         the NEXT line called `outV3` with BYTE-IDENTICAL arguments. A whole extra run of
    ///         the curve and one extra delegatecall, on EVERY concentrated leg, across all FOUR
    ///         swap entry points.
    ///
    ///         The cure is not to duplicate the ratio maths: it is to extract it here and make
    ///         `impactV3Bps` build on top of it. There is still ONE producer of the ratio; what
    ///         stops existing is the obligation to recompute the curve to reach it.
    ///
    ///         It stays `public` (delegatecall) and not `internal` on purpose: `internal` would
    ///         be inlined into every caller and the ratio arithmetic (4 mulDiv) would be paid in
    ///         BYTES in the Router, the contract with the least headroom after the Hub. The gain
    ///         here is not running the CURVE twice — it is not about saving the traversal.
    ///
    ///         `out == 0` returns BPS (the maximum, conservative), exactly as before: a pool that
    ///         does not quote is treated as total impact, never as zero impact.
    function impactV3FromOut(uint256 out, uint256 amountIn, uint160 sqrtP, bool zeroForOne)
        public pure returns (uint256)
    {
        if (out == 0 || amountIn == 0 || sqrtP == 0) return BPS;
        uint256 P = uint256(sqrtP);
        uint256 ratioBps;
        if (zeroForOne) {
            uint256 t1 = mulDiv(out, Q96, amountIn);
            uint256 t2 = mulDiv(t1, Q96, P);
            ratioBps   = mulDiv(t2, BPS, P);
        } else {
            uint256 t1 = mulDiv(out, P, amountIn);
            uint256 t2 = mulDiv(t1, P, Q96);
            ratioBps   = mulDiv(t2, BPS, Q96);
        }
        if (ratioBps >= BPS) return 0;
        return BPS - ratioBps;
    }

    /// @notice Impact in BPS from the INPUTS — for callers that do not have the output yet.
    /// @dev    Delegates to `impactV3FromOut` so a single implementation of the ratio exists.
    ///         Whoever ALREADY has `out` should call the primitive directly, not this one.
    function impactV3Bps(
        uint256 amountIn, uint160 sqrtP, uint128 liq, uint24 feePpm, bool zeroForOne
    ) public pure returns (uint256) {
        if (amountIn == 0 || sqrtP == 0 || liq == 0) return BPS;
        return impactV3FromOut(outV3(amountIn, sqrtP, liq, feePpm, zeroForOne, 0), amountIn, sqrtP, zeroForOne);
    }
}
