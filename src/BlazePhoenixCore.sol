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
//  Shared library for the BlazePhoenix protocol. Provides the arithmetic
//  primitives, AMM quote math, pool-address derivation, packed pool-state
//  encoding and the output floor used by Hub, Solver, Router and Quoter:
//
//    1.  universalQuote(ctx, amountIn) -> (amountOut, depth)
//        AMM quote dispatcher across pool kinds (V2, V3, V4, Solidly,
//        Curve stable, Curve crypto, Balancer).
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
}

library BlazePhoenixCore {

    string  internal constant VERSION    = "2.0.0";

    // ─── Universal numerical constants ─────────────────────────────────

    uint256 internal constant WAD        = 1e18;
    uint256 internal constant BPS        = 10_000;
    uint256 internal constant Q96        = 0x1000000000000000000000000;
    uint256 internal constant GAS_CAP    = 100_000;

    // Protocol domain separator.
    bytes32 internal constant DOMAIN     = 0x5a4c8fb3318679ccd8afce8752c8d272b447abeff6f412a8fc800087b3f9eead;

    // ─── Pool kinds (universal taxonomy) ───────────────────────────────

    uint8   internal constant KIND_V2          = 0;
    uint8   internal constant KIND_V3          = 1;
    uint8   internal constant KIND_STABLE      = 2;
    uint8   internal constant KIND_BALANCER_V2 = 3;
    uint8   internal constant KIND_V4          = 4;
    uint8   internal constant KIND_SOLIDLY     = 5;
    uint8   internal constant KIND_ALGEBRA     = 6;
    uint8   internal constant KIND_CURVE_CRYPTO = 7;
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

    // ─── Output-floor constants ────────────────────────────────────────
    // The floor starts tight (96%) for clean, low-impact, single-leg swaps and
    // loosens toward the 80% hard cap as impact, leg count and volatility rise.
    // Base and hard cap are separate so the floor is impact-adaptive while
    // never permitting a result worse than 80% of the quote. Raised from the
    // original 75% floor per the sealed 2026-08-03 design decision (see vault
    // note "010 - Invariantes, Mediana 4% & Padrões Estocásticos").
    uint16  internal constant FLOOR_HARD_MAX_LOSS_BPS = 2_000; // 20% absolute hard cap (floor ≥ 80%)
    uint16  internal constant FLOOR_BASE_BPS          = 9_600; // start at 96% floor for clean swaps
    uint16  internal constant FLOOR_PER_LEG_BPS       = 200;   // each extra leg loosens 2%
    uint16  internal constant FLOOR_IMPACT_FACTOR     = 1;     // 1 BPS floor drop per BPS impact

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
        bool ok;
        assembly ("memory-safe") {
            let p := mload(cd)
            ok := staticcall(GAS_CAP, factory, add(cd, 32), p, 0x00, 0x20)
            if and(ok, eq(returndatasize(), 32)) {
                pool := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff)
            }
        }
        // Algebra fallback (Camelot V3): dynamic-fee factories expose
        // poolByPair(address,address) not getPool(.,.,fee). CALL-based, no
        // initCodeHash. Same try-then-fallback discipline as the Curve adapter.
        if (pool == address(0) && mode == 1) {
            bytes memory cd2 = abi.encodeWithSelector(0xd9a641e1, t0, t1);
            assembly ("memory-safe") {
                let p := mload(cd2)
                let ok2 := staticcall(GAS_CAP, factory, add(cd2, 32), p, 0x00, 0x20)
                if and(ok2, eq(returndatasize(), 32)) {
                    pool := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff)
                }
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

    /// @notice Allowlist-free, deployer-blind discovery of hookless V4 pools for a
    ///         pair. V4 is a singleton: every pool of every deployer is
    ///         keccak256(PoolKey) in the one PoolManager, so a pool is found not by
    ///         trusting who made it but by DERIVING its id. Serious hookless
    ///         liquidity clusters on a tiny canonical (fee, tickSpacing) grid, so we
    ///         derive those ids (hooks = address(0)) and probe each via extsload;
    ///         the ones that read a live price+liquidity exist. `view` → eth_call →
    ///         zero gas, deterministic, no registry, no admin. Replaces a 99-call
    ///         sweep / an admin allowlist with one read.
    ///
    ///         Hooked pools carry an arbitrary 160-bit hook address (only the low 14
    ///         bits are constrained, to permission flags) and are therefore
    ///         unenumerable on-chain by construction — a contract cannot read the
    ///         Initialize logs that are their only registry. They are out of scope
    ///         here; an off-chain feed would supply their (self-proving) keys.
    ///         Produces KIND_V4 (ERC20-pair) pools; native-ETH V4 pools (currency0 =
    ///         address(0), KIND_V4_NATIVE) are a separate axis and not derived here.
    ///         Tiers verified live on Base: all four carry a WETH/USDC pool.
    function discoverV4(address manager, address tokenIn, address tokenOut)
        internal view returns (PoolInfo[] memory found)
    {
        if (manager == address(0)) return new PoolInfo[](0);
        (address c0, address c1) = sortTokens(tokenIn, tokenOut);
        // Canonical hookless (fee, tickSpacing) grid, probed one tier at a time via
        // a shared helper (kept out of an array literal so the optimizer emits one
        // copy, not four inlined ones).
        PoolInfo[] memory tmp = new PoolInfo[](4);
        uint256 cnt;
        cnt = _probeV4Tier(tmp, cnt, manager, c0, c1,   100,   1);
        cnt = _probeV4Tier(tmp, cnt, manager, c0, c1,   500,  10);
        cnt = _probeV4Tier(tmp, cnt, manager, c0, c1,  3000,  60);
        cnt = _probeV4Tier(tmp, cnt, manager, c0, c1, 10000, 200);
        found = new PoolInfo[](cnt);
        for (uint256 i; i < cnt; ) { found[i] = tmp[i]; unchecked { ++i; } }
    }

    /// @dev Derive one canonical hookless V4 PoolId, probe it via extsload, and
    ///      append it to `tmp` if it holds a live price and liquidity. Returns the
    ///      updated count.
    function _probeV4Tier(
        PoolInfo[] memory tmp, uint256 cnt, address manager,
        address c0, address c1, uint24 fee, int24 tickSpacing
    ) internal view returns (uint256) {
        bytes32 pid = computeV4PoolId(c0, c1, fee, tickSpacing, address(0));
        (uint160 sp, uint128 liq, , ) = v4SqrtAndLiq(manager, pid);
        if (sp != 0 && liq != 0) {
            tmp[cnt] = PoolInfo({
                active: true, stable: false, kind: KIND_V4,
                fee: fee, tickSpacing: tickSpacing,
                token0: c0, token1: c1, pool: manager, hooks: address(0)
            });
            unchecked { ++cnt; }
        }
        return cnt;
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
                if eq(returndatasize(), 32) { b := mload(m) }
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
    function _decimalsOf(address token) private view returns (uint8 d) {
        d = 18;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x313ce56700000000000000000000000000000000000000000000000000000000)
            if staticcall(GAS_CAP, token, m, 4, m, 32) {
                if eq(returndatasize(), 32) {
                    let v := mload(m)
                    if lt(v, 256) { d := v }
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

    /// @notice V3 slot0 → sqrtPriceX96.
    function getSqrtPriceX96(address pool) internal view returns (uint160 sp) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            // Uniswap V3 slot0() (0x3850c7bd): sqrtPriceX96 is word 0
            mstore(m, 0x3850c7bd00000000000000000000000000000000000000000000000000000000)
            if staticcall(GAS_CAP, pool, m, 4, m, 64) {
                if iszero(lt(returndatasize(), 32)) { sp := mload(m) }
            }
            // Algebra (Camelot) fallback: globalState() (0xe76c01e4), price word 0
            if iszero(sp) {
                mstore(m, 0xe76c01e400000000000000000000000000000000000000000000000000000000)
                if staticcall(GAS_CAP, pool, m, 4, m, 64) {
                    if iszero(lt(returndatasize(), 32)) { sp := mload(m) }
                }
            }
        }
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
    function outV3(
        uint256 ain, uint160 sqrtP, uint128 liq, uint24 fee, bool zeroForOne
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
            uint256 a = mulDiv(L, sqrtNew - P, sqrtNew);
            outAmt = mulDiv(a, Q96, P);
        }
    }

    // CURVE ADAPTER — ask the pool, never replicate. Quote(get_dy) and exec
    // (exchange) both on the pool => cannot diverge. int128/uint256 variants
    // handled by try-then-fallback. No registry, no formula replication.
    // NOTE (EIP-170): several heavyweight, cold-path view/pure quote helpers
    // below are `public` ON PURPOSE — public library functions compile into
    // the deployed BlazePhoenixCore library (which already exists for
    // universalQuote) and are reached via delegatecall, instead of being
    // inlined into every caller. This is what keeps the Router under the CI
    // size margin. Delegatecall-safe: all of them are view/pure (no storage,
    // no transient state). Do NOT flip them back to internal without
    // re-measuring `FOUNDRY_PROFILE=release forge build --sizes`.
    function curveResolveIndices(address pool, address tokenIn, address tokenOut)
        public view returns (int128 i, int128 j, bool ok) {
        int128 fi = -1; int128 fj = -1;
        for (uint256 k; k < 8; ) {
            address coin = _curveCoin(pool, k);
            if (coin == address(0)) break;
            if (coin == tokenIn)  fi = int128(uint128(k));
            if (coin == tokenOut) fj = int128(uint128(k));
            unchecked { ++k; }
        }
        ok = (fi >= 0 && fj >= 0); i = fi; j = fj;
    }
    function _curveCoin(address pool, uint256 k) internal view returns (address coin) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("coins(uint256)", k));
        if (!ok || ret.length < 32) {
            (ok, ret) = pool.staticcall(abi.encodeWithSignature("coins(int128)", int128(uint128(k))));
            if (!ok || ret.length < 32) return address(0);
        }
        coin = abi.decode(ret, (address));
    }
    function curveGetDy(address pool, int128 i, int128 j, uint256 dx)
        public view returns (uint256 dy) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature(
            "get_dy(int128,int128,uint256)", i, j, dx));
        if (!ok || ret.length < 32) {
            (ok, ret) = pool.staticcall(abi.encodeWithSignature(
                "get_dy(uint256,uint256,uint256)", uint256(uint128(i)), uint256(uint128(j)), dx));
            if (!ok || ret.length < 32) return 0;
        }
        dy = abi.decode(ret, (uint256));
    }

    /// @notice Ask a Solidly-class pair for its own exact output. Same doctrine
    ///         as the Curve adapter (get_dy == exchange => cannot diverge):
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
        fee = cfgFee;
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
        // arithmetic revert (a quote DoS on deep stable pools). See vault 093 M1.
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
        // Curve (raise) / Aerodrome (revert "!y"). Returning 0 here would make
        // the caller compute out = Y - 0 = Y, a catastrophic over-quote.
        return y0;
    }

    // =========================================================================
    //  §5  AMM QUOTE DISPATCHER
    // =========================================================================

    /// @notice AMM quote for a pool of any supported kind.
    /// @return out          amount out for `amountIn` tokens of `ctx.tokenIn`
    /// @return depthWad     pool depth in WAD-equivalent units
    /// @dev    The single quote dispatcher used by Solver and Quoter; kind
    ///         branching lives here only.
    function universalQuote(QuoteCtx memory c, uint256 amountIn)
        public view returns (uint256 out, uint256 depthWad)
    {
        if (amountIn == 0) return (0, 0);
        uint8 k = c.kind;
        // KIND_BALANCER_V2 removed from this arm (EIP-170 dead-code pass): a
        // Balancer Vault pool exposes no getReserves(), so this branch always
        // read (0,0) and quoted 0 — the kind never produced a routable quote.
        // Falling through to the default (0,0) return is byte-for-byte the
        // same observable result.
        if (k == KIND_V2) {
            (uint256 r0, uint256 r1) = getReserves(c.pool);
            (uint256 rI, uint256 rO) = c.zeroForOne ? (r0, r1) : (r1, r0);
            // UniV2/Sushi charge 0.30%. fee==0 (no fee list) -> 30 bps default,
            // so the quote matches the pool's x*y=k (else "K" revert on exec).
            uint24 v2fee = c.fee == 0 ? 30 : c.fee;
            out      = outV2(amountIn, rI, rO, v2fee);
            depthWad = rI < rO ? rI : rO;
            return (out, depthWad);
        }
        if (k == KIND_V3 || k == KIND_ALGEBRA) {
            uint160 sp  = getSqrtPriceX96(c.pool);
            uint128 liq = getLiquidity(c.pool);
            out      = outV3(amountIn, sp, liq, c.fee, c.zeroForOne);
            depthWad = uint256(liq);
            return (out, depthWad);
        }
        if (k == KIND_STABLE) {
            // Curve: ask the pool (get_dy), never replicate. Indices from coins();
            // quote here == exchange() at execution, so they cannot diverge.
            (int128 ci, int128 cj, bool cok) = curveResolveIndices(c.pool, c.tokenIn, c.tokenOther);
            if (!cok) return (0, 0);
            out      = curveGetDy(c.pool, ci, cj, amountIn);
            depthWad = out;
            return (out, depthWad);
        }
        if (k == KIND_SOLIDLY) {
            (uint256 r0, uint256 r1) = getReserves(c.pool);
            (uint256 rI, uint256 rO) = c.zeroForOne ? (r0, r1) : (r1, r0);
            // PRIMARY: ask the pool itself. Exact by construction — the same
            // bytecode that enforces K at execution produced the number, so
            // nothing is left behind in the pool and quote == execution.
            out = solidlyGetAmountOut(c.pool, amountIn, c.tokenIn);
            if (out == 0) {
                // FALLBACK (forks without getAmountOut only): replicate the
                // curve with the live fee, then under-ask by 200 bps so the
                // pool's K rounding — which we cannot observe — always has
                // slack. The haircut is intentionally the pool's gain; it
                // never applies when getAmountOut answered above.
                uint256 liveFee = readDynamicFee(c.pool, c.stable, c.fee);
                if (c.stable) {
                    // Stable invariant needs decimal-normalised reserves so
                    // pairs with mismatched decimals (e.g. DOLA 18 / USDC 6)
                    // quote correctly.
                    uint8 dI = _decimalsOf(c.tokenIn);
                    uint8 dO = _decimalsOf(c.tokenOther);
                    out = outSolidlyStable(amountIn, rI, rO, liveFee, dI, dO);
                } else {
                    out = outSolidly(amountIn, rI, rO, liveFee, false);
                }
                out = (out * 9800) / BPS;
            }
            depthWad = rI < rO ? rI : rO;
            return (out, depthWad);
        }
        if (k == KIND_CURVE_CRYPTO) {
            out = _curveCryptoGetDy(c.pool, c.zeroForOne, amountIn);
            depthWad = 0;
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
            (uint160 sp, uint128 liq, uint24 lpF, uint24 pF) = v4SqrtAndLiq(c.v4Manager, pid);
            if (sp == 0 || liq == 0) return (0, 0);
            out = outV3(amountIn, sp, liq, effV4Fee(c.fee, lpF, pF), c.zeroForOne);
            depthWad = uint256(liq);
            return (out, depthWad);
        }
    }

    /// @notice Read a V4 pool's sqrtPriceX96 and liquidity via extsload on the
    ///         singleton PoolManager. Slot layout verified against the canonical
    ///         StateView on a mainnet fork: base = keccak256(abi.encode(poolId,
    ///         6)); slot0 (offset 0) packs sqrtPriceX96 in its low 160 bits;
    ///         liquidity is at offset +3 (low 128 bits).
    function v4SqrtAndLiq(address manager, bytes32 poolId)
        public view returns (uint160 sqrtP, uint128 liq, uint24 lpFee, uint24 protoFee)
    {
        if (manager == address(0)) return (0, 0, 0, 0);
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

    /// @dev Both guards capture the staticcall result in `ok` FIRST and only
    ///      then test returndatasize(). Do NOT "simplify" this back into a
    ///      single `and(staticcall(...), eq(returndatasize(), 32))`: Yul
    ///      evaluates the arguments of a builtin RIGHT TO LEFT, so the
    ///      returndatasize() term would run BEFORE the staticcall and report
    ///      the size left by the PREVIOUS external call. That breaks the guard
    ///      both ways — a valid quote gets discarded (outAmt stays 0, so the
    ///      protocol floor goes inert for that swap), or a short/oversized
    ///      return passes the check and mload(m) reads stale buffer garbage.
    function _curveCryptoGetDy(address pool, bool zfo, uint256 dx)
        public view returns (uint256 outAmt)
    {
        uint256 i = zfo ? 0 : 1;
        uint256 j = zfo ? 1 : 0;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x556d6e9f00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), i) mstore(add(m, 36), j) mstore(add(m, 68), dx)
            let ok := staticcall(GAS_CAP, pool, m, 100, m, 32)
            if and(ok, eq(returndatasize(), 32)) {
                outAmt := mload(m)
            }
        }
        if (outAmt == 0) {
            assembly ("memory-safe") {
                let m := mload(0x40)
                mstore(m, 0x5e0d443f00000000000000000000000000000000000000000000000000000000)
                mstore(add(m, 4), i) mstore(add(m, 36), j) mstore(add(m, 68), dx)
                let ok := staticcall(GAS_CAP, pool, m, 100, m, 32)
                if and(ok, eq(returndatasize(), 32)) {
                    outAmt := mload(m)
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

    function impactV3Bps(
        uint256 amountIn, uint160 sqrtP, uint128 liq, uint24 feePpm, bool zeroForOne
    ) public pure returns (uint256) {
        if (amountIn == 0 || sqrtP == 0 || liq == 0) return BPS;
        uint256 out = outV3(amountIn, sqrtP, liq, feePpm, zeroForOne);
        if (out == 0) return BPS;
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
}
