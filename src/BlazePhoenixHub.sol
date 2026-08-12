// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixHub
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  The Hub is the on-chain pool registry. Each pool's state is encoded in a
//  single packed 256-bit slot (vitality, depth bucket, kind, timestamps,
//  bridge bit), so reading its fitness score costs one SLOAD. Storage is
//  three mappings:
//
//    1.  slot[key]        → packed pool state
//    2.  poolOf[key]      → address of the pool
//    3.  pairKeys[t0][t1] → slot keys for the (t0, t1) pair
//
//  Registration is automatic: a swap routed through a previously unknown
//  pool inserts it on the success path with vitality = 1 and a depth bucket
//  derived from the current pool depth. When a pair already holds MAX_SLOTS
//  pools, the lowest-scoring occupant is overwritten only if the newcomer's
//  projected score improves on it by at least EVICTION_IMPROVE_BPS.
//
//  Discovery is permissionless and factory/CREATE2-driven. Factory entries
//  describe the supported DEXs; for any (t0, t1) the Hub iterates the factory
//  list, derives candidate addresses and includes those with code. V4 is
//  handled separately: the PoolManager singleton has no per-pair factory, so
//  admins register V4 keys directly.
//
//  Storage layout follows ERC-7201 namespacing for proxy compatibility.
// =============================================================================
pragma solidity 0.8.36;

import {
    BlazePhoenixCore as BPC,
    PoolInfo
} from "./BlazePhoenixCore.sol";

contract BlazePhoenixHub {

    string  public constant VERSION = "2.0.0";

    // ─── Pool-fitness constants ────────────────────────────────────────

    uint8   internal constant MAX_SLOTS              = 16;
    uint8   internal constant MAX_BRIDGES            = 3;
    uint8   internal constant MAX_FACTORIES          = 16;
    uint16  internal constant EVICTION_IMPROVE_BPS   = 1_000;

    // ─── addFactory coherence-guard constants ────────────────────────────
    // KIND enumeration (mirrors Core): the highest valid kind is CURVE (7).
    uint8   internal constant KIND_V2                = 0;
    uint8   internal constant KIND_V3                = 1;
    uint8   internal constant KIND_STABLE            = 2;
    uint8   internal constant KIND_SOLIDLY           = 5;
    uint8   internal constant KIND_ALGEBRA           = 6;
    uint8   internal constant KIND_CURVE             = 7;
    // MODE enumeration: 0-3 are factory-call (getPair/getPool variants);
    // 4-7 are CREATE2 salt families (V2 salt, V3 salt, EIP-1167 clone, V3-CL).
    uint8   internal constant MODE_CREATE2_V2        = 4;
    uint8   internal constant MODE_CREATE2_V3        = 5;
    uint8   internal constant MODE_CREATE2_CLONE     = 6;
    // Live, but dispatched by arithmetic (`sub = mode - 4`) inside BPC.deriveAddress rather than
    // by name, so a naive "unreferenced identifier" scan will flag it as dead. It is not: mode 7
    // is the V3-CL salt family (keccak(t0, t1, tickSpacing) — Velodrome/Aerodrome CL).
    uint8   internal constant MODE_CREATE2_V3CL      = 7;
    uint8   internal constant MODE_CURVE_META        = 8;

    // ─── ERC-7201 namespace ────────────────────────────────────────────

    bytes32 private constant HUB_SLOT
        = keccak256(abi.encode(uint256(keccak256("blazephoenix.hub.v1")) - 1))
        & ~bytes32(uint256(0xff));

    struct Factory {
        address factory;
        uint8   kind;
        uint8   mode;        // CREATE2 salt mode (see BPC.deriveAddress)
        bytes32 initHash;
        uint24[] fees;
        int24[]  spacings;
    }

    struct V4Entry {
        address currency0;
        address currency1;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
    }

    struct HubStore {
        // access
        address admin;
        address router;
        address solver;
        address quoter;
        mapping(address => bool) operator;
        // pool registry
        mapping(bytes32 => uint256) slot;       // packed pool state per key (kind lives HERE, encodeSlot)
        mapping(bytes32 => address) poolOf;     // pool address per key
        // kindOf mapping DELETED (2026-08-11 gas audit): it was write-only dead
        // storage — kind is decoded from the packed slot by every consumer —
        // and cost 22.1k per fresh pool registration for nothing.
        mapping(bytes32 => address) hooksOf;    // hooks per key (V4 only; zero-guarded write)
        // pair index
        mapping(address => mapping(address => bytes32[])) pairKeys;
        // bridges
        address[MAX_BRIDGES] bridges;
        uint8 bridgeCount_;
        mapping(address => bool) isBridge;
        // factories
        Factory[] factories;
        // V4 registry (singleton-managed, manual entries)
        V4Entry[] v4Entries;
        address v4PoolManager;
        // hooks allow-list + codehash pin (Layer 3: auto-pause on code change)
        mapping(address => bool) hookAllowed;
        mapping(address => bytes32) hookCodehash;
        // status
        bool paused;
        bool initialized;
        bool controlRenounced;
    }

    function _store() private pure returns (HubStore storage $) {
        bytes32 s = HUB_SLOT;
        assembly { $.slot := s }
    }

    // ─── Events ────────────────────────────────────────────────────────

    event Registered(bytes32 indexed key, address indexed pool, uint8 kind);
    event Evicted(bytes32 indexed key, address indexed pool);
    event Volume(bytes32 indexed key, uint256 amtIn, uint256 amtOut);
    event Factory_(address indexed factory, uint8 kind, uint8 mode);
    event Bridge_(address indexed token, bool added);
    event V4Add(uint256 indexed idx, address c0, address c1, uint24 fee);
    event RoleSet(uint8 role, address who);
    event ControlRenounced();

    // ─── Single error path ─────────────────────────────────────────────

    error HubE(uint16 code);

    // 1 = unauthorized, 2 = paused, 3 = zero address, 4 = bad input
    // 5 = unknown pool, 6 = max slots, 7 = bridge cap, 8 = hook denied
    // 9 = V4 claim ineligible (no bridge anchor / not a live hookless pool /
    //     unresolved dynamic fee)

    function _auth(bool ok) internal pure { if (!ok) revert HubE(1); }
    function _ne0 (address a) internal pure { if (a == address(0)) revert HubE(3); }

    // ─── Constructor / initializer ─────────────────────────────────────

    constructor(address admin_) {
        // The admin is fixed at construction (an explicit argument, NOT
        // msg.sender) so the Hub can be deployed through a CREATE3 factory —
        // where msg.sender is the one-shot proxy that could never call
        // initialize, which would otherwise brick the registry permanently.
        // Only this admin may initialize, so the front-running window stays shut.
        _ne0(admin_);
        _store().admin = admin_;
    }

    function initialize(address admin_, address v4Manager_) external {
        HubStore storage $ = _store();
        // Only the deployer can initialize, and only once.
        if ($.initialized || msg.sender != $.admin) revert HubE(1);
        _ne0(admin_);
        $.initialized = true;
        $.admin = admin_;
        $.operator[admin_] = true;
        $.v4PoolManager = v4Manager_;
        emit RoleSet(0, admin_);
    }

    /// @notice Permanently surrender the CONTROL powers — the ones that can
    ///         redirect or freeze the protocol: setRoles, setOperator,
    ///         setPaused, setV4Manager and removeBridge can never be used
    ///         again. The CURATOR powers that only grow the registry —
    ///         addFactory, addBridge, allowHook — remain available so new
    ///         venues can still be listed (a malicious listing cannot drain:
    ///         pools are validated at quote and execution and bounded by the
    ///         output floor and the caller's userMinOut). Irreversible.
    function renounceControl() external onlyAdmin {
        _store().controlRenounced = true;
        emit ControlRenounced();
    }

    // ─── Modifiers ─────────────────────────────────────────────────────

    // Curator: addFactory / addBridge / allowHook — grows the registry only.
    modifier onlyAdmin()    { _auth(msg.sender == _store().admin); _; }
    // Control: redirect/freeze powers. Disabled forever by renounceControl().
    modifier onlyControl()  {
        HubStore storage $ = _store();
        _auth(msg.sender == $.admin && !$.controlRenounced);
        _;
    }
    modifier onlyOperator() { _auth(_store().operator[msg.sender] || msg.sender == _store().admin); _; }
    modifier onlyRouter()   { _auth(msg.sender == _store().router); _; }
    modifier whenLive()     { if (_store().paused) revert HubE(2); _; }

    // ─── Control (frozen by renounceControl) ───────────────────────────

    function setRoles(address r, address s, address q) external onlyControl {
        HubStore storage $ = _store();
        $.router = r; $.solver = s; $.quoter = q;
        emit RoleSet(1, r); emit RoleSet(2, s); emit RoleSet(3, q);
    }
    function setOperator(address who, bool ok) external onlyControl {
        _store().operator[who] = ok; emit RoleSet(4, who);
    }
    function setPaused(bool b) external onlyControl { _store().paused = b; }
    function setV4Manager(address m) external onlyControl { _store().v4PoolManager = m; }

    // ─── Curator (permanent: grows the registry only) ──────────────────

    function allowHook(address h, bool ok) external onlyAdmin {
        HubStore storage $ = _store();
        $.hookAllowed[h] = ok;
        // Pin the code at admission (Layer 3). A later code change (proxy
        // upgrade, selfdestruct+redeploy) makes isHookLive() false → the hook is
        // auto-paused (not routable) WITHOUT eviction; re-admitting re-pins it.
        if (ok) $.hookCodehash[h] = h.codehash; else delete $.hookCodehash[h];
    }

    /// @notice A hook is routable only while allow-listed AND its runtime code
    ///         still matches the codehash pinned at admission. A hook whose code
    ///         changes is auto-paused (not routable) with its pools' registry
    ///         state preserved (read-only) — it resumes only if re-admitted. A
    ///         hookless pool (h == 0) is always live.
    function isHookLive(address h) public view returns (bool) {
        if (h == address(0)) return true;
        HubStore storage $ = _store();
        return $.hookAllowed[h] && h.codehash == $.hookCodehash[h];
    }

    // ─── Bridges (max 2) ───────────────────────────────────────────────

    function addBridge(address t) external onlyAdmin {
        _ne0(t);
        HubStore storage $ = _store();
        if ($.bridgeCount_ >= MAX_BRIDGES) revert HubE(7);
        $.bridges[$.bridgeCount_] = t;
        $.isBridge[t] = true;
        unchecked { $.bridgeCount_++; }
        emit Bridge_(t, true);
    }

    function removeBridge(uint8 idx) external onlyControl {
        HubStore storage $ = _store();
        if (idx >= $.bridgeCount_) revert HubE(4);
        address t = $.bridges[idx];
        $.isBridge[t] = false;
        for (uint8 i = idx; i + 1 < $.bridgeCount_; ) {
            $.bridges[i] = $.bridges[i + 1];
            unchecked { ++i; }
        }
        $.bridges[$.bridgeCount_ - 1] = address(0);
        unchecked { $.bridgeCount_--; }
        emit Bridge_(t, false);
    }

    function bridge(uint8 i) external view returns (address) { return _store().bridges[i]; }
    function bridgeCount() external view returns (uint8) { return _store().bridgeCount_; }
    function isBridgeToken(address t) external view returns (bool) { return _store().isBridge[t]; }

    // ─── Factory registry ──────────────────────────────────────────────

    /// @notice Register a DEX factory adapter.
    /// @dev    Enforces configuration coherence between (kind, mode, initHash,
    ///         fees) before storing. A mis-configured adapter would otherwise
    ///         derive wrong pool addresses silently, so every structurally
    ///         impossible combination reverts with HubE(5). Rules:
    ///           * kind  <= KIND_MAX (7)                          [invalidKind]
    ///           * mode  <= MODE_MAX (7): 0-3 factory-call, 4-7 CREATE2
    ///           * CREATE2 modes (mode >= 4) require initHash != 0      [R1]
    ///           * mode 4 (V2 salt)  is only valid for kind V2
    ///           * mode 6 (clone)    is only valid for kind SOLIDLY
    ///           * mode 5 (V3 salt)  is valid for V3 or ALGEBRA; ALGEBRA
    ///             additionally requires every fee == 0 (dynamic-fee sentinel) [R2]
    ///         Factory-call modes (mode < 4) carry no initHash requirement.
    function addFactory(
        address factory, uint8 kind, uint8 mode, bytes32 initHash,
        uint24[] calldata fees, int24[] calldata spacings
    ) external onlyAdmin returns (uint8) {
        _ne0(factory);

        // 1) kind / mode domain
        if (kind > KIND_CURVE)               revert HubE(5); // invalidKind
        // Curve-style kinds (STABLE=2, CURVE=7) are NOT supported in v1.0:
        // their exec path needs the coins() interface the Router does not
        // implement, and quote/exec use inconsistent pool interfaces. Reject
        // at registration so the Solver never routes through them. Re-enable
        // with proper coins() resolution + dedicated tests in v1.1.
        if ((kind == KIND_STABLE || kind == KIND_CURVE) && mode != MODE_CURVE_META) revert HubE(5);
        if (mode > MODE_CURVE_META)          revert HubE(5); // invalidMode

        // 2) CREATE2 modes require a non-zero init-code hash (R1)
        if (mode >= MODE_CREATE2_V2 && mode != MODE_CURVE_META && initHash == bytes32(0)) revert HubE(5);

        // 3) salt-slot ↔ kind coherence
        if (mode == MODE_CREATE2_V2 && kind != KIND_V2)      revert HubE(5);
        if (mode == MODE_CREATE2_CLONE && kind != KIND_SOLIDLY) revert HubE(5);
        if (mode == MODE_CREATE2_V3) {
            // V3 salt slot accepts V3 or Algebra only
            if (kind != KIND_V3 && kind != KIND_ALGEBRA) revert HubE(5);
            // Algebra is dynamic-fee: every declared fee must be the 0 sentinel (R2)
            if (kind == KIND_ALGEBRA) {
                for (uint256 i; i < fees.length; ) {
                    if (fees[i] != 0) revert HubE(5);
                    unchecked { ++i; }
                }
            }
        }

        HubStore storage $ = _store();
        if ($.factories.length >= MAX_FACTORIES) revert HubE(4);
        $.factories.push(Factory({
            factory: factory, kind: kind, mode: mode,
            initHash: initHash, fees: fees, spacings: spacings
        }));
        emit Factory_(factory, kind, mode);
        return uint8($.factories.length - 1);
    }

    function factoryCount() external view returns (uint256) { return _store().factories.length; }

    // ─── V4 explicit registration ──────────────────────────────────────

    function addV4(
        address c0, address c1, uint24 fee, int24 tickSpacing, address hooks
    ) external onlyOperator returns (bytes32 key) {
        _ne0(c0); _ne0(c1);
        if (c0 == c1) revert HubE(4);
        HubStore storage $ = _store();
        if (hooks != address(0) && !$.hookAllowed[hooks]) revert HubE(8);
        (address s0, address s1) = BPC.sortTokens(c0, c1);
        $.v4Entries.push(V4Entry({
            currency0: s0, currency1: s1, fee: fee,
            tickSpacing: tickSpacing, hooks: hooks
        }));
        // Register under the SAME key formula recordSwap will later look up
        // (keyOf, keyed on the truncated poolId-as-address). A prior version
        // hashed a bespoke (pid, t0, t1) tuple here (_poolKeyV4) whose
        // preimage width could never match keyOf's (pool, t0, t1) — so this
        // pool's first real swap silently created a duplicate registry entry
        // instead of ticking this one. keyOf is the single source of truth
        // for "how do we key a pool" now.
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, tickSpacing, hooks);
        address poolAddr = address(uint160(uint256(pid)));
        key = keyOf(poolAddr, s0, s1);
        _register(key, poolAddr, BPC.KIND_V4, fee, hooks, s0, s1, true);
        emit V4Add($.v4Entries.length - 1, s0, s1, fee);
    }

    /// @notice Permissionless, on-chain-VERIFIED registration of a HOOKLESS V4
    ///         pool. Unlike addV4 (operator-trusted), anyone may call this: the
    ///         trust comes from the chain, not a role. Uniswap V4 has no
    ///         factory/pair enumeration (a singleton PoolManager), so the only
    ///         autonomous discovery shape is populate-once / read-forever — and
    ///         the population is made safe by proving the pool on-chain rather
    ///         than trusting the caller.
    ///
    ///         SAFE-GATE (quote == exec by construction):
    ///           - hookless only (the poolId is derived with hooks == 0), so the
    ///             vanilla V4 quote prices the pool exactly; delta-altering hooks
    ///             cannot be admitted here — their hookless poolId does not exist
    ///             and the existence proof below fails closed;
    ///           - native-currency keys are rejected (_ne0 on both currencies);
    ///           - a dynamic-fee pool is admitted only if its effective fee
    ///             resolves from slot0 (INV-20), else it fails closed;
    ///           - at least one side must be a protocol bridge anchor: anti-spam,
    ///             and it guarantees the pool composes with the routing graph;
    ///           - the pool must be initialized AND hold real liquidity in the
    ///             configured PoolManager (proven by extsload, unforgeable —
    ///             faking either costs capital).
    ///
    ///         Entries are provisional (trusted = false): a permissionlessly
    ///         claimed pool must earn fitness and is weighted by MEASURED
    ///         marginal output, so a thin or hostile venue self-weights toward
    ///         zero (INV-16).
    /// @return key The registry key. Idempotent: re-claiming a live pool returns
    ///         the existing key without creating a duplicate entry.
    function claimV4(address c0, address c1, uint24 fee, int24 tickSpacing)
        external returns (bytes32 key)
    {
        _ne0(c0); _ne0(c1);                 // native currency (address(0)) rejected
        if (c0 == c1) revert HubE(4);
        HubStore storage $ = _store();
        // Anchor gate: one side must be a trusted bridge.
        if (!$.isBridge[c0] && !$.isBridge[c1]) revert HubE(9);
        (address s0, address s1) = BPC.sortTokens(c0, c1);
        // HOOKLESS ONLY — the poolId is derived with hooks == address(0).
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, tickSpacing, address(0));
        // On-chain existence + liquidity proof (unforgeable).
        (uint160 sp, uint128 liq, uint24 lpF, uint24 pF) =
            BPC.v4SqrtAndLiq($.v4PoolManager, pid);
        if (sp == 0 || liq == 0) revert HubE(9);
        // Dynamic fee must resolve to a quotable value (INV-20), else fail closed.
        if (BPC.effV4Fee(fee, lpF, pF) >= 1_000_000) revert HubE(9);
        address poolAddr = address(uint160(uint256(pid)));
        key = keyOf(poolAddr, s0, s1);
        // Idempotent: a live re-claim must not push a duplicate V4Entry nor
        // re-register (which would thrash the fitness-ranked eviction).
        if ($.poolOf[key] != address(0)) return key;
        $.v4Entries.push(V4Entry({
            currency0: s0, currency1: s1, fee: fee,
            tickSpacing: tickSpacing, hooks: address(0)
        }));
        _register(key, poolAddr, BPC.KIND_V4, fee, address(0), s0, s1, false);
        emit V4Add($.v4Entries.length - 1, s0, s1, fee);
    }

    // ─── Discovery ──────────────────────────────────────────────────────

    /// @notice Permissionless discovery for (t0, t1).  Iterates the factory
    ///         list, derives candidates, returns the live ones.
    function discoverFor(address tA, address tB) public view returns (PoolInfo[] memory hits) {
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        HubStore storage $ = _store();
        uint256 maxOut;
        for (uint256 i; i < $.factories.length; ) {
            Factory storage fac = $.factories[i];
            uint256 fc = fac.fees.length == 0 ? 1 : fac.fees.length;
            uint256 sc = fac.spacings.length == 0 ? 1 : fac.spacings.length;
            uint256 mul = (fac.mode == 2 || fac.mode == 6) ? 2 : 1;
            if (fac.mode == MODE_CURVE_META) { maxOut += 4; } else { maxOut += fc * sc * mul; }
            unchecked { ++i; }
        }
        hits = new PoolInfo[](maxOut);
        uint256 k;
        for (uint256 i; i < $.factories.length; ) {
            Factory storage fac = $.factories[i];
            k = _scanFactory(fac, t0, t1, hits, k);
            unchecked { ++i; }
        }
        assembly { mstore(hits, k) }
    }

    function _scanFactory(
        Factory storage fac, address t0, address t1, PoolInfo[] memory hits, uint256 k
    ) private view returns (uint256) {
        if (fac.mode == MODE_CURVE_META) return _scanCurve(fac, t0, t1, hits, k);
        uint24[] storage fees = fac.fees;
        int24[]  storage sps  = fac.spacings;
        uint256 fc = fees.length == 0 ? 1 : fees.length;
        uint256 sc = sps.length == 0  ? 1 : sps.length;
        bool solidly = (fac.mode == 2 || fac.mode == 6);
        for (uint256 fi; fi < fc; ) {
            uint24 fee = fees.length == 0 ? 0 : fees[fi];
            for (uint256 si; si < sc; ) {
                int24 sp = sps.length == 0 ? int24(0) : sps[si];
                if (solidly) {
                    k = _probe(fac, t0, t1, fee, false, sp, hits, k);
                    k = _probe(fac, t0, t1, fee, true,  sp, hits, k);
                } else {
                    k = _probe(fac, t0, t1, fee, false, sp, hits, k);
                }
                unchecked { ++si; }
            }
            unchecked { ++fi; }
        }
        return k;
    }

    function _scanCurve(
        Factory storage fac, address t0, address t1, PoolInfo[] memory hits, uint256 k
    ) private view returns (uint256) {
        address meta = fac.factory;
        for (uint256 i; i < 4; ) {
            (bool ok, bytes memory ret) = meta.staticcall(abi.encodeWithSignature(
                "find_pool_for_coins(address,address,uint256)", t0, t1, i));
            if (!ok || ret.length < 32) break;
            address p = abi.decode(ret, (address));
            if (p == address(0)) break;
            if (k >= hits.length) break;
            bool dup;
            for (uint256 d; d < k; ) { if (hits[d].pool == p) { dup = true; break; } unchecked { ++d; } }
            if (!dup) {
                hits[k] = PoolInfo({ active: true, stable: true, kind: KIND_STABLE, fee: 0,
                    tickSpacing: 0, token0: t0, token1: t1, pool: p, hooks: address(0) });
                unchecked { k++; }
            }
            unchecked { ++i; }
        }
        return k;
    }

    function _probe(
        Factory storage fac, address t0, address t1, uint24 fee,
        bool stable, int24 sp, PoolInfo[] memory hits, uint256 k
    ) private view returns (uint256) {
        // CREATE2 modes (≥4) require an init-code hash. Factory-call modes
        // (<4) work without one — the staticcall does the lookup.
        if (fac.mode >= 4 && fac.initHash == bytes32(0)) return k;
        address p = BPC.deriveAddress(fac.factory, t0, t1, fee, stable, sp, fac.mode, fac.initHash);
        if (p != address(0) && BPC.hasCode(p)) {
            // Dedup: the same pool address can be derived for several
            // (fee, spacing) combinations. Listing it multiple times saturates
            // the Solver's top-K with one venue and starves deeper pools.
            for (uint256 d; d < k; ) {
                if (hits[d].pool == p) return k;
                unchecked { ++d; }
            }
            hits[k] = PoolInfo({
                active: true, stable: stable, kind: fac.kind, fee: fee,
                tickSpacing: sp, token0: t0, token1: t1, pool: p, hooks: address(0)
            });
            unchecked { k++; }
        }
        return k;
    }

    // ─── Registry reads ────────────────────────────────────────────────

    function getActivePools(address tA, address tB) external view returns (PoolInfo[] memory out) {
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        bytes32[] storage ks = _store().pairKeys[t0][t1];
        uint256 n = ks.length;
        out = new PoolInfo[](n);
        uint256 w;
        for (uint256 i; i < n; ) {
            bytes32 key = ks[i];
            uint256 s = _store().slot[key];
            if (BPC.isActive(s)) {
                PoolInfo memory pi = _readPoolInfo(key, t0, t1, s);
                // A V4 pool whose hook is paused (code changed since admission,
                // or de-listed) stays in the registry (read-only) but is not a
                // routable candidate — resumes automatically once re-admitted.
                if (pi.kind != BPC.KIND_V4 || pi.hooks == address(0) || isHookLive(pi.hooks)) {
                    out[w] = pi;
                    unchecked { ++w; }
                }
            }
            unchecked { ++i; }
        }
        assembly { mstore(out, w) }
    }

    function _readPoolInfo(bytes32 key, address t0, address t1, uint256 s)
        private view returns (PoolInfo memory p)
    {
        HubStore storage $ = _store();
        p.active      = true;
        p.kind        = BPC.decodeKind(s);
        p.fee         = BPC.decodeFee(s);
        p.token0      = t0;
        p.token1      = t1;
        p.pool        = $.poolOf[key];
        p.hooks       = $.hooksOf[key];
        p.stable      = false;
        // tickSpacing is not packed in the pool slot. V3-style kinds derive
        // pools from the fee (0 is fine), but V4 needs the real tickSpacing —
        // it is part of the poolId the quote recomputes — so recover it from
        // the matching V4Entry.
        p.tickSpacing = 0;
        if (p.kind == BPC.KIND_V4) {
            uint256 vn = $.v4Entries.length;
            for (uint256 vi; vi < vn; ) {
                V4Entry storage e = $.v4Entries[vi];
                if (e.currency0 == t0 && e.currency1 == t1 && e.fee == p.fee && e.hooks == p.hooks) {
                    p.tickSpacing = e.tickSpacing;
                    break;
                }
                unchecked { ++vi; }
            }
        }
    }

    function getPsi(bytes32 key) external view returns (uint256) { return _psi(key); }

    function _psi(bytes32 key) private view returns (uint256) {
        HubStore storage $ = _store();
        uint256 s = $.slot[key];
        if (s == 0) return 0;
        uint8 kind = BPC.decodeKind(s);
        bool conc  = (kind == BPC.KIND_V3 || kind == BPC.KIND_ALGEBRA || kind == BPC.KIND_V4);
        return BPC.psi(s, uint32(block.timestamp), _isBridged(s), conc);
    }

    /// @notice Batch fitness read: one external call for a whole candidate set
    ///         (each pool with its pair tokens), replacing two calls per
    ///         candidate (keyOf + getPsi) in the Solver's top-K selection.
    ///         Pure view addition — buys eth_call gas headroom and RPC latency
    ///         on the (free) planning path, zero new state surface.
    function psisOf(address[] calldata pools, address[] calldata tAs, address[] calldata tBs)
        external view returns (uint256[] memory ps)
    {
        uint256 n = pools.length;
        if (tAs.length != n || tBs.length != n) revert HubE(4);
        ps = new uint256[](n);
        for (uint256 i; i < n; ) {
            ps[i] = _psi(keyOf(pools[i], tAs[i], tBs[i]));
            unchecked { ++i; }
        }
    }

    /// @notice True when either side of the pair is a registered bridge token.
    ///         Packed at slot bit 7 (within the [7:1] reserved span) at the
    ///         moment of registration, so reading it is part of the same SLOAD
    ///         that fetches the rest of the pool state.
    function _isBridged(uint256 slot) private pure returns (bool) {
        return (slot >> 7) & 1 == 1;
    }

    function _markBridged(uint256 slot, bool b) private pure returns (uint256) {
        return b ? (slot | (uint256(1) << 7)) : (slot & ~(uint256(1) << 7));
    }

    function getSlot(bytes32 key) external view returns (uint256) { return _store().slot[key]; }
    function getPool(bytes32 key) external view returns (address) { return _store().poolOf[key]; }
    function v4PoolManager() external view returns (address) { return _store().v4PoolManager; }
    function v4EntryCount() external view returns (uint256) { return _store().v4Entries.length; }
    function v4EntryAt(uint256 i) external view returns (V4Entry memory) { return _store().v4Entries[i]; }

    function keyOf(address pool, address tA, address tB) public pure returns (bytes32) {
        (address s0, address s1) = BPC.sortTokens(tA, tB);
        return keccak256(abi.encodePacked(pool, s0, s1));
    }

    // ─── Promotion via swap (Router-only) ──────────────────────────────

    /// @notice Called by the Router on every successful leg. If the pool is
    ///         already registered, we tick its slot. If not, and the pair has
    ///         room or the newcomer beats the weakest occupant by
    ///         EVICTION_IMPROVE_BPS, we register it.
    function recordSwap(
        address pool, uint8 kind, uint24 fee, address hooks,
        address tA, address tB, uint256 amtIn, uint256 amtOut, uint256 depthWad
    ) external onlyRouter whenLive {
        if (pool == address(0) || amtIn == 0) return;
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        bytes32 key = keyOf(pool, t0, t1);
        HubStore storage $ = _store();
        uint256 s = $.slot[key];
        if (s != 0) {
            // existing pool — tick + stamp wall-clock activity time
            uint256 newSlot = BPC.tickSlot(s, uint32(block.number), depthWad, uint32(block.timestamp));
            $.slot[key] = _stampTs(newSlot);
            emit Volume(key, amtIn, amtOut);
            return;
        }
        // unknown — attempt insert
        if (!_canInsert($.pairKeys[t0][t1], depthWad)) return;
        _register(key, pool, kind, fee, hooks, t0, t1, false);
        // initial tick + stamp wall-clock activity time
        $.slot[key] = _stampTs(BPC.tickSlot($.slot[key], uint32(block.number), depthWad, uint32(block.timestamp)));
        emit Volume(key, amtIn, amtOut);
    }

    /// @dev Refresh the slot's lastUpdateTs (bits [95:64]) to the current
    ///      wall-clock time. The field is otherwise write-once at registration and
    ///      is read by nothing on-chain except the Solver's discovery-freshness
    ///      gate — so repurposing it as "last activity time" is behaviour-neutral
    ///      for fitness/eviction (which key off lastBlk + swapCount).
    function _stampTs(uint256 s) private view returns (uint256) {
        return (s & ~(uint256(0xFFFFFFFF) << 64)) | (uint256(uint32(block.timestamp)) << 64);
    }

    function _canInsert(bytes32[] storage ks, uint256 newDepth) private view returns (bool) {
        if (ks.length < MAX_SLOTS) return true;
        // ─── Insertion ranking ───
        // Rank incumbents by full fitness (vitality × depth-bucket weight × bonuses),
        // not raw vitality, and admit the newcomer only if its projected fitness
        // strictly beats the weakest incumbent by a margin. A deep newcomer can
        // now displace a shallow-but-warm incumbent (as the design intends),
        // and an attacker can no longer keep a deep pool out merely by sending
        // dust through 16 shallow slots to hold their vitality at 1.
        if (newDepth == 0) return false;
        HubStore storage $ = _store();
        uint256 worstPsi = type(uint256).max;
        for (uint256 i; i < ks.length; ) {
            uint256 p = _psiOfSlot($.slot[ks[i]]);
            if (p < worstPsi) worstPsi = p;
            unchecked { ++i; }
        }
        // Newcomer's projected fitness: vitality starts at 1, weighted by the depth
        // bucket it will occupy. No bridge/conc bonus assumed (conservative).
        uint256 newcomerPsi = BPC.bucketWeight(BPC.depthBucket(newDepth));
        // Require a strict 25% margin so admission is decisive, not a knife-edge.
        return newcomerPsi > worstPsi + (worstPsi / 4);
    }

    /// @notice Fitness of a slot using its packed bridge bit and kind-derived conc.
    function _psiOfSlot(uint256 s) private view returns (uint256) {
        if (s == 0) return 0;
        uint8 kind = BPC.decodeKind(s);
        bool conc = (kind == BPC.KIND_V3 || kind == BPC.KIND_ALGEBRA || kind == BPC.KIND_V4);
        return BPC.psi(s, uint32(block.timestamp), _isBridged(s), conc);
    }

    function _register(
        bytes32 key, address pool, uint8 kind, uint24 fee, address hooks,
        address t0, address t1, bool trusted
    ) private {
        HubStore storage $ = _store();
        bytes32[] storage ks = $.pairKeys[t0][t1];
        if (ks.length >= MAX_SLOTS) {
            // Evict the lowest-scoring slot (rank by fitness, not vitality,
            // consistent with _canInsert so the pool we admit is the pool we
            // chose to make room for).
            uint256 worstIdx;
            uint256 worst = type(uint256).max;
            for (uint256 i; i < ks.length; ) {
                uint256 v = _psiOfSlot($.slot[ks[i]]);
                if (v < worst) { worst = v; worstIdx = i; }
                unchecked { ++i; }
            }
            bytes32 evictKey = ks[worstIdx];
            address evictPool = $.poolOf[evictKey];
            $.slot[evictKey] = 0;
            $.poolOf[evictKey] = address(0);
            // hooksOf: clear only when set — non-V4 pools never wrote it, and
            // a 0→0 SSTORE still costs 2.2k cold for nothing.
            if ($.hooksOf[evictKey] != address(0)) $.hooksOf[evictKey] = address(0);
            ks[worstIdx] = key;
            emit Evicted(evictKey, evictPool);
        } else {
            ks.push(key);
        }
        bool bridged = $.isBridge[t0] || $.isBridge[t1];
        uint256 s = BPC.encodeSlot(
            true, fee, kind, trusted ? 0 : 2, 0,
            uint32(block.timestamp), 0, 0, 0,
            uint32(block.number), uint32(block.number)
        );
        $.slot[key]    = _markBridged(s, bridged);
        $.poolOf[key]  = pool;
        if (hooks != address(0)) $.hooksOf[key] = hooks;
        emit Registered(key, pool, kind);
    }

    /// @notice Operator entry-point for seeding the registry up-front.
    function seedPool(
        address pool, uint8 kind, uint24 fee, address hooks,
        address tA, address tB
    ) external onlyOperator returns (bytes32 key) {
        _ne0(pool); _ne0(tA); _ne0(tB);
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        key = keyOf(pool, t0, t1);
        _register(key, pool, kind, fee, hooks, t0, t1, true);
    }
}
