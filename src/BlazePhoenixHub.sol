// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixHub
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  SINGLE RESPONSIBILITY
//      Know which pools exist and what they are worth. The Hub is the protocol's
//      memory — and memory is the most dangerous surface there is, because
//      anything that enters it wrong comes out wrong for everyone, forever.
//
//  WHAT THIS CONTRACT GUARANTEES
//      H1  NOTHING ENTERS WITHOUT PROOF. Every registration argument is the
//          caller's calldata — pool, kind and depth. A kind whose `pool` is a
//          pair must PROVE it really trades that pair (token0/token1) before
//          being written; a V4 must recompute its own poolId. Without this, one
//          would register a contract written by the attacker, under a pair
//          chosen by them, at a depth chosen by them, holding neither of the
//          two tokens.
//      H2  BOTH DOORS CLOSE — EACH WITH ITS OWN MASK. Two write paths exist,
//          `addFactory` and `recordSwap`, and both filter kinds. A fix applied to
//          only one of them is this codebase's defect signature; it happened here
//          and is fixed. But the correction is NOT that both use the same
//          constant: they close with `KINDS_ROUTABLE` and `KINDS_EXECUTABLE`,
//          which today differ by one bit (V4_NATIVE, which no factory registers
//          and the Router executes). Using the same constant is not asking the
//          same question — the first attempt shared the mask and silently killed
//          all native-pool registration. And there is a THIRD door, the operator's
//          `seedPool`, which deliberately does not filter kind: it is the only one
//          whose caller is trusted, and it closes downstream (theta quotes 0x0 as 0).
//      H3  THE DEFENCE IS LOCAL. `$.router` is swappable, so the single producer
//          of kinds is not immutable: the Hub does not delegate its own admission
//          to an address that may stop being what it was on deploy day.
//      H4  REFUSING NEVER REVERTS A SWAP. The user's swap has already executed; a
//          registration decision cannot fail what already settled. We fail closed
//          on the REGISTRY, and fail open on the USER.
//
//  WHAT THIS CONTRACT DELIBERATELY DOES NOT DO
//      It is not a price source — vitality and depth are DISCOVERY hints, never
//      inputs to quote mathematics. It does not decide routes. And it has no
//      venue allow-list: admission is by proof, not by trust.
//
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

/// @dev The Router is the SINGLE PRODUCER of "which WETH is canonical on this chain".
///      The Hub asks it instead of keeping a second copy — a constant duplicated
///      here could diverge from the one the Router uses to validate the unwrap,
///      and the divergence would be exploited from the wrap side.
interface IRouterWeth { function weth() external view returns (address); }

contract BlazePhoenixHub {

    string  internal constant VERSION = "2.0.0";

    // ─── Pool-fitness constants ────────────────────────────────────────

    uint8   internal constant MAX_SLOTS              = 16;
    /// 3 BRIDGES. It dropped to 2 on 2026-08-21 and went BACK to 3 the same day,
    /// because the measurement that justified the cut was looking at the wrong door.
    ///
    /// WHAT WAS MEASURED: the 3rd bridge costs +760,125 gas per cold solve (+32.5%).
    /// WHAT WAS MISSED: that cost sits ENTIRELY in the SOLVE, and the solve only
    /// runs on-chain at entry point B (`swapBestExactIn`). At the other three doors
    /// the route arrives already solved from outside, via `eth_call` — for free.
    ///
    /// And `_rank` picks ONE route among the candidates: more bridges evaluated do
    /// not make the executed route bigger. Measured: `swapExactIn` calldata depends
    /// on the TOPOLOGY (1,028 bytes at 1 hop/1 leg, +544 per hop, +320 per leg),
    /// never on how many bridges the Solver considered.
    ///
    /// So at entry point A — the one the four deploy chains should use — the 3rd
    /// bridge costs ZERO on-chain and only adds one candidate topology. Cutting it
    /// was optimizing the door nobody pays for: the same mistake as SSTORE2
    /// (-48,772 gas measured, expected value ~0).
    uint8   internal constant MAX_BRIDGES            = 3;
    /// @dev How many bridges the Solver ACTUALLY routes through. NOT the same as MAX_BRIDGES,
    ///      and the difference between the two was a silent asymmetry: the Solver expands the
    ///      bridges HAND-UNROLLED (`b0`, `b1` in Solver:203-215) and `_rank` has three seats —
    ///      direct + two. The third bridge could never be a hop.
    ///
    ///      AND IT STILL HAD POWERS. `isBridge[t]` opens the permissionless `claimV4` door
    ///      ("one of the sides must be a trusted bridge") and sets the `bridged` flag in the
    ///      Monoslot, worth +25% fitness in `psi` (Core). In a CAPPED registry with
    ///      fitness-ranked eviction, that means a third bridge filled the registry with
    ///      well-ranked, UNREACHABLE pools, evicting the ones the router can use. The bonus
    ///      was paid on liquidity the router never touches.
    ///
    ///      THESE ARE TWO QUESTIONS — "is this token a trusted anchor?" (`isBridge`) and "can
    ///      a hop pass through here?" (`_isRoutableBridge`) — and TODAY THEY HAVE THE SAME
    ///      ANSWER, because the Solver expands EVERY configured bridge and lets `_rank` decide
    ///      by measured `totalOut`. Two questions with two names remain: the equality is a
    ///      FACT, not a definition, and `test_NenhumaBridgeConfiguradaEFantasma` is what pins it.
    ///      The day someone raises MAX_BRIDGES without adding an arm to the Solver, that test
    ///      explains the divergence instead of it happening silently all over again.
    ///
    ///      WHY NOT PICK "THE BEST 2": because that would be a SECOND producer of the judgment
    ///      "which route is better", alongside `_rank` — which already produces it, and better.
    ///      Registered depth is a proxy; `totalOut` is the built and measured output. A proxy
    ///      pre-filter could only discard the route the true producer would have chosen.
    ///
    ///      PINNED by `test_RoutableBridgesMatchSolverExpansion`: if someone adds a `b2` to the
    ///      Solver without touching this, or touches this without touching that, the test
    ///      explains the divergence instead of leaving it silent.
    uint8   internal constant MAX_BRIDGE_ROUTES      = MAX_BRIDGES;
    uint8   internal constant MAX_FACTORIES          = 16;
    uint16  internal constant EVICTION_IMPROVE_BPS   = 1_000;

    // ─── addFactory coherence-guard constants ────────────────────────────
    // Kind enumeration: SINGLE PRODUCER in the Core (`BPC.KIND_*`). This file used to keep a
    // local copy here that advertised itself as "mirrors the Core" — and the mirror was
    // INCOMPLETE: it stopped at ALGEBRA and had no name at all for KIND_V4_NATIVE (8). A mask
    // written with the available names could not even EXPRESS bit 8, and that is the door the
    // regression came through (see KINDS_EXECUTABLE below). The numbers 2, 3 and 7 are TOMBSTONES
    // and are named neither here nor there — see the Core's tombstone note on why they never return.
    //
    // WHY THIS COLLAPSE IS LEGITIMATE AND THE PREDICATE ONE IS NOT: a kind number is a PRIMITIVE
    // (a producer of a value). Primitives want a single producer — duplicating them creates
    // siblings that diverge, as this one diverged. An ACCEPTANCE PREDICATE wants the opposite:
    // keeping two judges that agree today is what lets us detect the day they stop agreeing. See
    // the KINDS_PAIR_PROOF note just below, where two coincident masks are kept DELIBERATELY
    // separate — and where a harness mutant once hid.

    /// @notice The kinds a factory may register — the set, as a bit word.
    /// @dev    Bit `k` set = kind `k` admissible. Cleared bits are TOMBSTONES, not gaps:
    ///
    ///           bits 2, 3, 7 (the TOMBSTONES)   — venues withdrawn by the owner's decision on
    ///                                             2026-08-20: almost no L2 carried them and
    ///                                             they cost bytecode in five contracts. With
    ///                                             them went the Router's only `approve` (where
    ///                                             HUNT-001 lived), the only caller-attested
    ///                                             depth producer, and the only deliberate hole
    ///                                             in the authenticity proof here.
    ///                                             The number stays burned; see the Core.
    ///           bit 8 (V4_NATIVE)               — never registered by factory: they derive from
    ///                                             the singleton. Never had a bit, never will.
    ///
    ///         THE NUMBERS ARE NEVER REUSED. `decodeKind` reads the kind from the Monoslot bits:
    ///         giving 2 to a new venue would reinterpret already-written pools as that venue. A
    ///         new venue takes a new number and sets its bit — one data line, zero branches.
    uint256 internal constant KINDS_ROUTABLE =
          (uint256(1) << BPC.KIND_V2)      // 0 — constant-product
        | (uint256(1) << BPC.KIND_V3)      // 1 — concentrated
        | (uint256(1) << BPC.KIND_V4)      // 4 — singleton, via MODE_V4_DERIVE
        | (uint256(1) << BPC.KIND_SOLIDLY) // 5 — stable/volatile pairs
        | (uint256(1) << BPC.KIND_ALGEBRA);// 6 — concentrated, dynamic fee

    /// @notice The kinds the Router KNOWS HOW TO EXECUTE — the legitimate set at the
    ///         `recordSwap` door, which runs after the leg has already executed.
    /// @dev    IT IS NOT `KINDS_ROUTABLE`, AND THAT DISTINCTION IS THE POINT OF THIS CONSTANT.
    ///
    ///         `KINDS_ROUTABLE` answers "which kinds may a FACTORY register?". Bit 8 is clear
    ///         there for a reason that holds only for THAT question: native V4 pools come from
    ///         no factory at all, they derive from the singleton. This constant answers "which
    ///         kinds can the Router have just executed?" — and V4_NATIVE is one of them: the
    ///         Router derives the native poolId before calling this `recordSwap` with that kind.
    ///
    ///         USING THE SAME CONSTANT IS NOT ASKING THE SAME QUESTION. The two masks share
    ///         five of the six bits; sharing bits is not sharing semantics. Reusing the
    ///         factory mask here dropped ALL native V4 swaps silently — the native insert
    ///         branch became unreachable, and already-registered native pools stopped being
    ///         refreshed until they aged out of the registry. Measured, and pinned by
    ///         `test_RecordSwapRefreshesNativeV4Pool`.
    ///
    ///         Written out in full, and NOT derived from `KINDS_ROUTABLE | (1 << KIND_V4_NATIVE)`:
    ///         deriving it would retie the two questions to each other and hand the defect back
    ///         through the side door, disguised as elegance.
    uint256 internal constant KINDS_EXECUTABLE =
          (uint256(1) << BPC.KIND_V2)        // 0 — constant-product
        | (uint256(1) << BPC.KIND_V3)        // 1 — concentrated
        | (uint256(1) << BPC.KIND_V4)        // 4 — singleton
        | (uint256(1) << BPC.KIND_SOLIDLY)   // 5 — stable/volatile pairs
        | (uint256(1) << BPC.KIND_ALGEBRA)   // 6 — concentrated, dynamic fee
        | (uint256(1) << BPC.KIND_V4_NATIVE);// 8 — singleton, native-ETH leg

    /// @notice The valid discovery modes, by the same criterion.
    /// @dev    0-3 call the factory (getPair/getPool); 4-7 derive by CREATE2; 9 is the V4 derive.
    ///         Bit 8 is clear: it was the meta-registry of a withdrawn venue and left with it.
    ///         Without this mask it would stay accepted for ANY kind, because the only previous
    ///         bound was `mode > MODE_V4_DERIVE` and 8 fitted inside it — a mode that only made
    ///         sense for a removed venue would remain open to every other one.
    /// @dev Kinds whose `pool` field is a pair exposing token0()/token1() — so `recordSwap`'s
    ///      authenticity proof applies to them. It used to be the literal 0x6b, which had bit 3
    ///      set for an already-withdrawn venue.
    ///
    ///      IT IS NOT THE SAME QUESTION AS THETA'S A_PAIR_VER, and that is why it lives here and
    ///      not there: A_PAIR_VER describes the SHAPE of the state ("does token0() exist?"); this
    ///      is an ACCEPTANCE predicate ("which kinds must PROVE the pair before entering the
    ///      registry?"). That they coincide today is a measured fact, not a definition — and the
    ///      test pins the equality by construction so that, the day they diverge, it is the
    ///      divergence that gets explained and not the silence. Collapsing the two because the
    ///      bits line up would trade a check for a coincidence.
    uint256 internal constant KINDS_PAIR_PROOF =
          (uint256(1) << BPC.KIND_V2) | (uint256(1) << BPC.KIND_V3)
        | (uint256(1) << BPC.KIND_SOLIDLY) | (uint256(1) << BPC.KIND_ALGEBRA);

    uint256 internal constant MODES_VALID = 0x2FF; // bits 0-7 and 9; bit 8 is a tombstone
    // MODE enumeration: 0-3 are factory-call (getPair/getPool variants);
    // 4-7 are CREATE2 salt families (V2 salt, V3 salt, EIP-1167 clone, V3-CL).
    uint8   internal constant MODE_CREATE2_V2        = 4;
    uint8   internal constant MODE_CREATE2_V3        = 5;
    uint8   internal constant MODE_CREATE2_CLONE     = 6;
    // Live, but dispatched by arithmetic (`sub = mode - 4`) inside BPC.deriveAddress rather than
    // by name, so a naive "unreferenced identifier" scan will flag it as dead. It is not: mode 7
    // is the V3-CL salt family (keccak(t0, t1, tickSpacing) — Velodrome/Aerodrome CL).
    uint8   internal constant MODE_CREATE2_V3CL      = 7;
    // MODE_V4_DERIVE: Uniswap-V4 derive-scan. V4's singleton PoolManager has
    // no factory/pair enumeration, so this mode DERIVES hookless candidate
    // poolIds (learned per-token pattern code -> canonical tiers -> the row's
    // paired extras -> a bounded generator grid) and emits only the ones
    // proven live on the PoolManager via extsload. The row's `factory` field
    // records the PoolManager for operator legibility (and `_ne0`); the scan
    // itself always reads `$.v4PoolManager` — the single source of truth,
    // which `setV4Manager` can still rotate while control lasts.
    uint8   internal constant MODE_V4_DERIVE         = 9;

    // ─── V4 derive-scan bounds ─────────────────────────────────────────
    // Per-scan cap on emitted V4 pools (early-stop), sized to the Solver's
    // appetite for parallel candidates on one pair.
    uint256 internal constant V4_CAP                 = 8;
    // Generator Pi_K: fee = 10_000*j, tickSpacing = 100*j, hookless — the
    // observed launchpad family ("ratio-100" pools). j descends from
    // V4_GRID_MAX so the high-fee launch tiers (the ones that exist before a
    // token matures into canonical tiers) are probed first; V4_GRID_PROBES
    // caps what a cold miss can cost. Must satisfy V4_GRID_PROBES <= V4_GRID_MAX.
    uint256 internal constant V4_GRID_MAX            = 99;
    uint256 internal constant V4_GRID_PROBES         = 40;

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
        // The same pin, for the factory-call modes (0-3): see _scanFactory.
        mapping(address => bytes32) factoryCodehash;
        // status
        bool paused;
        bool initialized;
        bool controlRenounced;
        // V4 derive-discovery: learned per-token "pattern code" — the packed
        // (fee << 24 | uint24(tickSpacing)) hookless tier this token's V4
        // pool was last PROVEN at (claimV4 or a routed V4 swap). 0 = unknown
        // (a real tier always has tickSpacing >= 1, so a valid code is never
        // zero). DISCOVERY-HINT METADATA ONLY (INV-16 boundary): read
        // exclusively by the derive-scan and the recordSwap healer — never by
        // psi/fitness/eviction/route-ranking — so a stale or manipulated code
        // can only ever waste one probe: every candidate is re-proven live
        // before emission and proven again at quote time.
        mapping(address => uint256) v4CodeOf;
        // V1 / invariant I11 (no unbounded scan on the hot path): O(1) recovery of
        // a V4 pool's V4Entry by its registry key (stored value is index+1 into
        // v4Entries; 0 = absent). The global v4Entries array is append-only and
        // permissionlessly grown by claimV4, so scanning it in _readPoolInfo made
        // every V4 quote pay O(#entries) on the per-solve getActivePools path.
        mapping(bytes32 => uint256) v4EntryOf;
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
    /// @dev ids: 0 admin · 1 router · 2 solver · 3 quoter · 4 operator · 5 v4PoolManager.
    ///      5 is not a "role" in the permission sense — it is the SINGLETON against which the
    ///      extsloads that constitute claimV4's authenticity proof run. It goes here instead of
    ///      in its own event because it IS a protocol address and fits the shape at no cost.
    ///      What could not continue was changing silently: the Meta-Supreme Axiom presupposes a
    ///      fixed measurement APPARATUS, and a mutable, unobservable instrument returns a
    ///      perfectly valid number from the wrong place, with no symptom at all.
    event RoleSet(uint8 role, address who);
    /// @notice The emergency switch changed.
    event PausedSet(bool paused);
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
    function setPaused(bool b) external onlyControl { _store().paused = b; emit PausedSet(b); }
    function setV4Manager(address m) external onlyControl { _store().v4PoolManager = m; emit RoleSet(5, m); }

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
    /// @dev    WHAT THIS PIN DOES NOT COVER, stated where the guarantee is made
    ///         (reported externally 2026-08-26). The pin binds RUNTIME CODE, so
    ///         it catches a redeploy at the same address and any direct mutation
    ///         — and it does NOT catch a DELEGATE PROXY, whose implementation can
    ///         be swapped while its own runtime stays byte-identical. Nor can it:
    ///         the EVM gives a contract no way to read another contract's storage,
    ///         so the EIP-1967 implementation slot cannot be pinned on-chain. The
    ///         allow-list is therefore load-bearing exactly here — admitting an
    ///         upgradeable hook is a human judgement this pin cannot replace, and
    ///         the honest reading of `isHookLive` is "still allow-listed, and not
    ///         mutated in a way the chain lets us see". The layers that do not
    ///         depend on it stand regardless: the immutable address bits reject
    ///         the delta-altering class before any token moves, and the floors are
    ///         re-derived from measured output at execution.
    function isHookLive(address h) public view returns (bool) {
        if (h == address(0)) return true;
        HubStore storage $ = _store();
        return $.hookAllowed[h] && h.codehash == $.hookCodehash[h];
    }

    // ─── Bridges (MAX_BRIDGES configurable, MAX_BRIDGE_ROUTES routable) ─────────────────────────────────────────────────

    /// @dev IDEMPOTENT BY CONSTRUCTION. Two producers answer "is this a
    ///      bridge?" — `bridge(i)` reads the array, `isBridgeToken(t)` reads
    ///      the mapping — and `isBridge` is a plain bool with no refcount. A
    ///      second seat for the same token therefore split them: after
    ///      `addBridge(x); addBridge(x); removeBridge(0)`, compaction kept `x`
    ///      in the array while the unconditional mapping clear said it was not
    ///      a bridge. The Solver kept routing through `x` off the array; the
    ///      Router's fee anchor read the mapping, found no bridge, and dropped
    ///      into the per-hop exhaustion regime while the Quoter still previewed
    ///      a single charge.
    ///
    ///      Worse, the repair is asymmetric: `addBridge` is `onlyAdmin` but
    ///      `removeBridge` is `onlyControl`, so a desync planted with the table
    ///      full (`bridgeCount_ == MAX_BRIDGES`) is PERMANENT after
    ///      `renounceControl()` — the remove is dead and the re-add reverts
    ///      HubE(7).
    ///
    ///      A duplicate add is a no-op rather than a revert: the end state the
    ///      caller asked for already holds, and reverting would make an
    ///      idempotent administrative call fail on a retry.
    function addBridge(address t) external onlyAdmin {
        _ne0(t);
        HubStore storage $ = _store();
        if ($.isBridge[t]) return;
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

    /// @dev "Can a hop pass through this token?" — distinct from `isBridge`, which answers "is it
    ///      a trusted anchor?". Only the first MAX_BRIDGE_ROUTES positions are routable, because
    ///      only those does the Solver expand. The early-out on `isBridge` keeps the common case
    ///      (neither token is a bridge) at exactly today's cost: one SLOAD.
    function _isRoutableBridge(HubStore storage $, address t) private view returns (bool) {
        if (!$.isBridge[t]) return false;
        for (uint8 i; i < MAX_BRIDGE_ROUTES; ) {
            if ($.bridges[i] == t) return true;
            unchecked { ++i; }
        }
        return false;
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
    ///           * kind belongs to KINDS_ROUTABLE                 [invalidKind]
    ///           * mode belongs to MODES_VALID: 0-3 factory-call,
    ///             4-7 CREATE2, 9 V4 derive-scan (8 is a tombstone) [invalidMode]
    ///           * CREATE2 modes (mode >= 4) require initHash != 0, except
    ///             modes 8 and 9 which derive nothing via CREATE2         [R1]
    ///           * mode 4 (V2 salt)  is only valid for kind V2
    ///           * mode 6 (clone)    is only valid for kind SOLIDLY
    ///           * mode 5 (V3 salt)  is valid for V3 or ALGEBRA; ALGEBRA
    ///             additionally requires every fee == 0 (dynamic-fee sentinel) [R2]
    ///           * mode 9 (V4 derive) is only valid for kind V4, and its
    ///             fees/spacings are PAIRED explicit extras (fees[i] with
    ///             spacings[i], never a cross-product) — equal length required
    ///         Factory-call modes (mode < 4) carry no initHash requirement.
    function addFactory(
        address factory, uint8 kind, uint8 mode, bytes32 initHash,
        uint24[] calldata fees, int24[] calldata spacings
    ) external onlyAdmin returns (uint8) {
        _ne0(factory);

        // 1) kind / mode domain — TWO sets, expressed as DATA.
        //
        // HOW TO READ THIS, if it is your first time. Each bit of the constant is a kind: bit
        // number `k` set means "kind k is admissible". The check `(MASK >> kind) & 1` asks "is
        // this kind's bit set?" — a single operation, instead of a chain of `if`s naming every
        // kind by hand.
        //
        // WHY LIKE THIS. This contract has a well-documented defect meta-pattern: a fix applied
        // to ONE of two symmetric channels, and the sibling forgotten. It happened 10+ times. A
        // chain of `if`s is exactly that happening: every site that enumerates kinds by hand is
        // a site that can drift out of sync with the others. A set expressed as a bit word has
        // no sibling to diverge from — the diversity becomes a COORDINATE (one bit) and not a
        // BRANCH.
        //
        // NOT A NEW PATTERN: the Hub already uses it in `_register` (the mask of "pair-shaped"
        // kinds, the ones exposing token0()/token1()). This only gives it a name and a sibling,
        // instead of leaving it as a magic literal loose in the middle of the code.
        //
        // FAIL-CLOSED FOR FREE. A kind outside the set has bit 0 and reverts. A kind above 255
        // does not exist (the type is uint8) and a high shift returns 0 — it reverts anyway.
        // There is no "default" branch for anyone to forget.
        if (((KINDS_ROUTABLE >> kind) & 1) == 0) revert HubE(5); // invalidKind
        if (((MODES_VALID    >> mode) & 1) == 0) revert HubE(5); // invalidMode

        // 2) CREATE2 modes require a non-zero init-code hash (R1). The high modes that
        //    do NOT derive by CREATE2 are exempt; of those only 9 survives — 8 is a
        //    tombstone and MODES_VALID refuses it before it ever gets here.
        if (
            mode >= MODE_CREATE2_V2
                && mode != MODE_V4_DERIVE && initHash == bytes32(0)
        ) revert HubE(5);

        // 3) salt-slot ↔ kind coherence
        if (mode == MODE_CREATE2_V2 && kind != BPC.KIND_V2)      revert HubE(5);
        if (mode == MODE_CREATE2_CLONE && kind != BPC.KIND_SOLIDLY) revert HubE(5);
        if (mode == MODE_CREATE2_V3) {
            // V3 salt slot accepts V3 or Algebra only
            if (kind != BPC.KIND_V3 && kind != BPC.KIND_ALGEBRA) revert HubE(5);
            // Algebra is dynamic-fee: every declared fee must be the 0 sentinel (R2)
            if (kind == BPC.KIND_ALGEBRA) {
                for (uint256 i; i < fees.length; ) {
                    if (fees[i] != 0) revert HubE(5);
                    unchecked { ++i; }
                }
            }
        }
        // V4 derive-scan coherence: mode 9 is only meaningful for the V4
        // kind, and its fees/spacings are PAIRED explicit extras — enforce
        // equal length so a misregistered row cannot silently mispair them.
        if (mode == MODE_V4_DERIVE) {
            if (kind != BPC.KIND_V4) revert HubE(5);
            if (fees.length != spacings.length) revert HubE(5);
        }

        HubStore storage $ = _store();
        if ($.factories.length >= MAX_FACTORIES) revert HubE(4);
        $.factories.push(Factory({
            factory: factory, kind: kind, mode: mode,
            initHash: initHash, fees: fees, spacings: spacings
        }));
        $.factoryCodehash[factory] = factory.codehash;
        emit Factory_(factory, kind, mode);
        return uint8($.factories.length - 1);
    }

    function factoryCount() external view returns (uint256) { return _store().factories.length; }

    // ─── V4 explicit registration ──────────────────────────────────────

    function addV4(
        address c0, address c1, uint24 fee, int24 tickSpacing, address hooks
    ) external onlyOperator returns (bytes32 key) {
        _ne0(c1);
        if (c0 == c1) revert HubE(4);
        HubStore storage $ = _store();
        if (hooks != address(0) && !$.hookAllowed[hooks]) revert HubE(8);

        // ─── POOL OF NATIVE ETH ───────────────────────────────────────────
        // In V4 native ETH IS `address(0)` as a currency, and it ALWAYS sorts
        // first. It was rejected here by `_ne0(c0)`, so the whole family was
        // unreachable: the Router KNOWS how to execute it (KIND_V4_NATIVE,
        // `nativeMapVerified`, the JIT unwrap/wrap stitching in unlockCallback),
        // but no discovery door let it into the registry — and with no registry
        // entry the Solver never proposes it. Chicken and egg.
        //
        // THE POOL KEY uses the REAL currencies (native = address(0)); the
        // REGISTRY speaks WETH, so the Solver finds it when routing WETH->c1.
        // It is the same split the Router already makes: "the route speaks
        // WETH, the execution speaks native".
        bool nat = c0 == address(0);
        address w;
        if (nat) {
            w = IRouterWeth($.router).weth();
            // Fail-closed: with no WETH wired there is no possible translation,
            // and a WETH/WETH pool does not exist.
            if (w == address(0) || c1 == w) revert HubE(3);
        } else {
            _ne0(c0);
        }
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
        (address r0, address r1) = nat ? BPC.sortTokens(w, c1) : (s0, s1);
        key = keyOf(poolAddr, r0, r1);
        $.v4EntryOf[key] = $.v4Entries.length; // V1/I11: O(1) key -> V4Entry
        _register(key, poolAddr, nat ? BPC.KIND_V4_NATIVE : BPC.KIND_V4,
                  fee, hooks, r0, r1, true);
        // If sorting did not leave WETH in token0, mark the inversion so that
        // `_readPoolInfo` undoes it when reporting.
        if (nat && r0 != w) $.slot[key] = _markNativeSwapped($.slot[key], true);
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
        // Anchor gate: one side must be a ROUTABLE bridge. Being a trusted anchor is
        // not enough — this door is permissionless, and admitting a pair the router
        // can never cross only burns a seat in the capped registry.
        if (!_isRoutableBridge($, c0) && !_isRoutableBridge($, c1)) revert HubE(9);
        (address s0, address s1) = BPC.sortTokens(c0, c1);
        // HOOKLESS ONLY — the poolId is derived with hooks == address(0).
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, tickSpacing, address(0));
        // On-chain existence + liquidity proof (unforgeable).
        (uint160 sp, uint128 liq, uint24 lpF, uint24 pF, ) =
            BPC.v4SqrtAndLiq($.v4PoolManager, pid);
        if (sp == 0 || liq == 0) revert HubE(9);
        // Dynamic fee must resolve to a quotable value (INV-20), else fail closed.
        if (BPC.effV4Fee(fee, lpF, pF) >= 1_000_000) revert HubE(9);
        // Learn the token-side pattern code from every successful on-chain
        // proof — idempotent re-claims included, so a stale hint self-heals.
        _writeV4Code(s0, s1, fee, tickSpacing);
        address poolAddr = address(uint160(uint256(pid)));
        key = keyOf(poolAddr, s0, s1);
        // Idempotent: a live re-claim must not push a duplicate V4Entry nor
        // re-register (which would thrash the fitness-ranked eviction).
        if ($.poolOf[key] != address(0)) return key;
        // A4: a permissionless claim must clear the SAME admission margin a
        // swap-driven registration does (recordSwap -> _canInsert). _register
        // evicts the weakest incumbent UNCONDITIONALLY, so on a FULL pair a dust
        // claim would displace a healthy pool with no 25% margin. depth = the
        // pool's MEASURED liquidity (liq), the exact signal _recordHits feeds
        // recordSwap for a V4 leg. HONEST SCOPE (devil's-advocate): liq is read
        // live, so it is JIT / flash-liquidity-inflatable within one tx (the same
        // bound recordSwap already carries) — this RAISES the griefing bar, it is
        // NOT "unforgeable". Vitality floors at 1 and decays to 0 in ~9 days, so an
        // emptied squatter self-weights down (INV-16) and the pool it evicted
        // re-registers on its next routed swap.
        // UNITS: L is root-scale; depth here must be token-denominated, like V2's
        // min(r0,r1) — otherwise a pool at an extreme price tier enters with depth
        // inflated by ~sqrt(price), clears _canInsert's 25% margin and evicts a
        // legitimate, deeper pool. Same conversion as universalQuote (Core):
        // virtual reserves at the current price, short side. sp != 0 granted above.
        uint256 depthTok;
        {
            // Normalized: _canInsert compares buckets, and a bucket blind to
            // decimals makes the deep pool and the dust pool project the same psi.
            depthTok = BPC.depthFromL18(liq, sp, BPC.decimalsOf(s0), BPC.decimalsOf(s1));
        }
        if (!_canInsert($.pairKeys[s0][s1], depthTok)) return key;
        $.v4Entries.push(V4Entry({
            currency0: s0, currency1: s1, fee: fee,
            tickSpacing: tickSpacing, hooks: address(0)
        }));
        $.v4EntryOf[key] = $.v4Entries.length; // V1/I11: O(1) key -> V4Entry
        _register(key, poolAddr, BPC.KIND_V4, fee, address(0), s0, s1, false);
        // A4: persist the MEASURED depth bucket (mirrors recordSwap's new-pool
        // path) so a claimed pool is fitness-ranked on its real liquidity instead
        // of defaulting to bucket 0 (psi ~1) — otherwise the pool that just won
        // admission on its depth becomes the pair's weakest slot / next eviction
        // target the instant it is registered.
        $.slot[key] = _stampTs(BPC.tickSlot($.slot[key], uint32(block.number), depthTok, uint32(block.timestamp)));
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
            // The mode-8 branch left with the excision; a factory with that mode can only
            // exist in a legacy Hub and `_scanFactory` stops on it without producing hits,
            // so it does not contribute to the ceiling. The accounting must mirror the scan
            // loop: `_probe` writes into `hits[k]` with no bounds check of its own.
            if (fac.mode == MODE_V4_DERIVE) { maxOut += V4_CAP; }
            else { maxOut += fc * sc * mul; }
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
        // GENERALIZED GUARD. It used to be an IDENTITY test against the mode-8 constant, against
        // a tombstone. It is now a MEMBERSHIP test against the SAME mask that
        // `addFactory` uses to admit. Here the morphism really does apply — the two sites
        // literally ask the same question ("is this mode admissible?") — and it now covers
        // any mode withdrawn in the future, without anyone having to come back here.
        //
        // WHY STOPPING MATTERS: a factory with an inadmissible mode can only exist in a legacy
        // Hub (today's `addFactory` refuses it). If it falls into the generic `_probe`,
        // `deriveAddress` computes `sub = mode - 4` and lands in the V3CL salt catch-all,
        // deriving phantom addresses on every scan. Stopping makes it PROVABLY inert
        // instead of accidentally inert.
        if (((MODES_VALID >> fac.mode) & 1) == 0) return k;
        // THE APPARATUS MUST BE FIXED, TOO (the third corollary of I-measure).
        // Modes 0-3 ASK the factory where a pool lives; modes 4-7 DERIVE it, and a
        // derivation is a theorem the factory cannot influence. So only the asking
        // modes depend on the factory's future behaviour — and an upgradeable proxy
        // can change what it answers without its own runtime code ever changing.
        // Hooks already carry this pin (`isHookLive`); factories did not, and there
        // is no removeFactory, so after renunciation a mutated factory would steer
        // discovery with no remaining control-plane response.
        // Fail CLOSED, never revert: a stale dependency stops producing candidates,
        // and every other factory keeps serving the pair (a new revert here would
        // let one dependency brick discovery outright).
        if (fac.mode < 4 && fac.factory.codehash != _store().factoryCodehash[fac.factory]) return k;
        if (fac.mode == MODE_V4_DERIVE)  return _scanV4(fac, t0, t1, hits, k);
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

    // ─── V4 derive-scan (MODE_V4_DERIVE) ───────────────────────────────
    //
    //  Uniswap V4 has no factory enumeration, so candidates are DERIVED —
    //  hookless poolIds recomputed from (t0, t1, fee, tickSpacing, hooks=0) —
    //  and only the ones PROVEN live on the PoolManager (sqrtP != 0 &&
    //  liquidity != 0, unforgeable extsload reads) are emitted. Probe order
    //  is cheapest-first:
    //    (a) learned per-token pattern codes — the steady-state ONE-probe path
    //    (c) canonical Uniswap tiers, one batched extsload
    //    (d) the row's paired explicit extras, one batched extsload
    //    (e) generator Pi_K cold-start grid, one batched extsload, entered
    //        ONLY when (a)-(d) found nothing: the grid bootstraps unknown
    //        tokens, and once any pool is proven the residual exotic tiers
    //        are left to claimV4/learning instead of being paid on every scan
    //  Early-stop at V4_CAP emitted pools.
    //
    //  NATIVE ETH: the (ETH, X) pair has TWO pool keys in V4 — native
    //  (currency0 = address(0)) and wrapped (currency0 = WETH). They are
    //  DISTINCT pools, with distinct poolIds and liquidity, and the native one is
    //  systematically the deeper: MEASURED 292x on Robinhood (USDG/ETH 100/1) and
    //  3.76x on Base (USDC/ETH 500/10). Deriving only the wrapped never errors —
    //  it quotes worse, silently. BOTH are emitted and the funnel picks by depth.
    //  A hooked pool cannot be emitted: its HOOKLESS poolId does not exist in
    //  the PoolManager, so it fails the live proof by construction.
    //
    //  `kf` packs the two scan counters into one word — low 128 bits: the
    //  global hits write-cursor `k`; high 128 bits: pools found by THIS scan.

    function _scanV4(
        Factory storage fac, address t0, address t1, PoolInfo[] memory hits, uint256 k
    ) private view returns (uint256) {
        if (t0 == address(0)) return k;      // native currency: out of scope
        HubStore storage $ = _store();
        address mgr = $.v4PoolManager;
        if (mgr == address(0)) return k;     // unconfigured manager: fail closed
        uint256 kf = k;
        // (0) NATIVE ETH FIRST. Probed before the wrapped one because of
        //     `V4_CAP` (8): a pair with many wrapped pools would exhaust the
        //     slots before the native one was even built. The order IS the
        //     policy.
        //
        //     There is NO new parameter on the probing functions, and the
        //     reason is MEASURED: the first version of this passed an
        //     `address w` through `_probeV4Batch` and `_admitV4`, and cost
        //     1,227 bytes — the optimizer stops inlining and replicates whole
        //     bodies. Here the native pair is passed DIRECTLY as (address(0),
        //     other): zero already sorts first, so `computeV4PoolId` gets it in
        //     the right position without a single ternary. Only the shape of the
        //     emitted PoolInfo needs fixing, and that fits in one loop here.
        address rt = $.router;
        address w = rt == address(0) ? address(0) : IRouterWeth(rt).weth();
        if (w != address(0) && (t0 == w || t1 == w)) {
            address other = t0 == w ? t1 : t0;
            uint256 ini = uint256(uint128(kf));
            // Canonicals AND extras, just like the wrapped pass. Cutting the
            // extras here saved 33 bytes of Hub (measured, not estimated) and
            // opened a coverage hole in exotic tiers — the owner chose coverage.
            // The cold-start grid stays out: it only enters when NOTHING was
            // found, and the native pass runs first.
            kf = _probeV4Batch(mgr, address(0), other, _v4CanonicalTiers(), hits, kf);
            kf = _probeV4Batch(mgr, address(0), other, _v4ExtraTiers(fac), hits, kf);
            // `_admitV4` emitted them as KIND_V4 with token0 = address(0).
            // Rewrite to the WETH-canonical form: the ORIENTATION CONTRACT
            // requires token0 = the wrapped-native side, because the Solver
            // derives `zeroForOne = (token0 == tokenIn)` and maps the native
            // currency by ORIENTATION. Without this the pool would be invisible
            // to half the token space — the same defect as Monoslot bit 6.
            for (uint256 z = ini; z < uint256(uint128(kf)); ) {
                // `token1` is NOT rewritten: `_admitV4` already stored it as
                // `other` (it was the t1 we passed in). Only `kind` and `token0`
                // are lying.
                hits[z].kind   = BPC.KIND_V4_NATIVE;
                hits[z].token0 = w;
                unchecked { ++z; }
            }
        }
        // (a) learned pattern codes of both tokens (identical codes dedup)
        uint256 cA = $.v4CodeOf[t0];
        uint256 cB = $.v4CodeOf[t1];
        if (cA != 0) kf = _admitV4(mgr, t0, t1, cA, hits, kf);
        if (cB != 0 && cB != cA) kf = _admitV4(mgr, t0, t1, cB, hits, kf);
        // A LEARNED CODE IS A HINT, AND A HINT MAY NOT SUPPRESS A SEARCH.
        // Stage (a) above and the probes below shared ONE counter, so a hit from
        // the learned code counted as if this pair's own tiers had been probed.
        // `v4CodeOf` is writable by anyone through the permissionless `claimV4`,
        // so planting a dust pool at any valid tier set the code, produced a
        // hit here, and switched off (e) — the ONLY probe that reaches
        // non-canonical tiers. A legitimate deep pool at such a tier then
        // vanished from discovery entirely, and the honest path never restored
        // it. Reported by Mohd Huzaifa, who also supplied the shape of this fix.
        uint256 kfBeforeOwnProbes = kf >> 128;
        // (c) canonical tiers, then (d) paired extras — one batch each
        kf = _probeV4Batch(mgr, t0, t1, _v4CanonicalTiers(), hits, kf);
        kf = _probeV4Batch(mgr, t0, t1, _v4ExtraTiers(fac), hits, kf);
        // (e) generator cold-start — only when THIS PAIR's own tiers found
        // nothing. Gating on the total again would let a learned code speak for
        // a search that never ran. Costs nothing in the honest case: the grid
        // still runs exactly when it is genuinely needed.
        if (kf >> 128 == kfBeforeOwnProbes) kf = _probeV4Batch(mgr, t0, t1, _v4GridTiers(), hits, kf);
        return uint256(uint128(kf));
    }

    /// @dev Probe a packed tier list against (t0, t1) with ONE batched
    ///      extsload for all slot0 words, then fully verify only the non-zero
    ///      survivors — a miss costs one batched SLOAD, not a full read pair.
    function _probeV4Batch(
        address mgr, address t0, address t1, uint256[] memory tiers,
        PoolInfo[] memory hits, uint256 kf
    ) private view returns (uint256) {
        uint256 n = tiers.length;
        if (n == 0 || kf >> 128 >= V4_CAP) return kf;
        bytes32[] memory pids = new bytes32[](n);
        for (uint256 i; i < n; ) {
            pids[i] = BPC.computeV4PoolId(
                t0, t1, uint24(tiers[i] >> 24), int24(uint24(tiers[i])), address(0)
            );
            unchecked { ++i; }
        }
        bytes32[] memory w0 = BPC.v4Slot0Batch(mgr, pids);
        for (uint256 i; i < n; ) {
            if (kf >> 128 >= V4_CAP) break;
            // sqrtPriceX96 occupies slot0's low 160 bits; zero = uninitialized.
            if (uint160(uint256(w0[i])) != 0) {
                kf = _admitV4(mgr, t0, t1, tiers[i], hits, kf);
            }
            unchecked { ++i; }
        }
        return kf;
    }

    /// @dev Fully verify ONE hookless candidate tier and emit it if live:
    ///      re-reads slot0 + liquidity through the audited single-read path
    ///      (belt-and-braces over the batch filter; the re-read is warm),
    ///      applies the INV-20 dynamic-fee gate, and dedups by pool address
    ///      (existing doctrine — one venue must not saturate the top-K).
    ///      `code` is the packed tier (fee << 24 | uint24(tickSpacing)).
    function _admitV4(
        address mgr, address t0, address t1, uint256 code,
        PoolInfo[] memory hits, uint256 kf
    ) private view returns (uint256) {
        uint256 k = uint256(uint128(kf));
        if (kf >> 128 >= V4_CAP || k >= hits.length) return kf;
        uint24 fee = uint24(code >> 24);
        int24  ts  = int24(uint24(code));
        bytes32 pid = BPC.computeV4PoolId(t0, t1, fee, ts, address(0));
        (uint160 sp, uint128 liq, uint24 lpF, uint24 pF, ) = BPC.v4SqrtAndLiq(mgr, pid);
        if (sp == 0 || liq == 0) return kf;                      // not live: fail closed
        if (BPC.effV4Fee(fee, lpF, pF) >= 1_000_000) return kf;  // unresolvable dynamic fee
        address p = address(uint160(uint256(pid)));
        for (uint256 d; d < k; ) {
            if (hits[d].pool == p) return kf;
            unchecked { ++d; }
        }
        hits[k] = PoolInfo({
            active: true, stable: false, kind: BPC.KIND_V4, fee: fee,
            tickSpacing: ts, token0: t0, token1: t1, pool: p, hooks: address(0)
        });
        unchecked { return kf + 1 + (uint256(1) << 128); }
    }

    /// @dev Canonical Uniswap fee tiers — the most common hookless configs.
    function _v4CanonicalTiers() private pure returns (uint256[] memory t) {
        t = new uint256[](4);
        t[0] = _v4Code(500, 10);
        t[1] = _v4Code(3000, 60);
        t[2] = _v4Code(10_000, 200);
        t[3] = _v4Code(100, 1);
    }

    /// @dev The row's paired explicit extras: fees[i] with spacings[i], never
    ///      a cross-product. addFactory enforces equal length; min() is a
    ///      defensive belt for rows registered before that rule existed.
    function _v4ExtraTiers(Factory storage fac) private view returns (uint256[] memory t) {
        uint256 fn = fac.fees.length;
        uint256 sn = fac.spacings.length;
        uint256 n = fn < sn ? fn : sn;
        t = new uint256[](n);
        for (uint256 i; i < n; ) {
            t[i] = _v4Code(fac.fees[i], fac.spacings[i]);
            unchecked { ++i; }
        }
    }

    /// @dev Generator Pi_K cold-start grid: fee = 10_000*j, ts = 100*j, j
    ///      descending from V4_GRID_MAX, capped at V4_GRID_PROBES candidates
    ///      (j never underflows: V4_GRID_PROBES <= V4_GRID_MAX).
    function _v4GridTiers() private pure returns (uint256[] memory t) {
        t = new uint256[](V4_GRID_PROBES);
        uint256 j = V4_GRID_MAX;
        for (uint256 i; i < V4_GRID_PROBES; ) {
            t[i] = _v4Code(uint24(10_000 * j), int24(uint24(100 * j)));
            unchecked { ++i; --j; }
        }
    }

    /// @dev Pack a tier into a pattern code. A valid V4 tickSpacing is >= 1,
    ///      so a real code is never 0 (0 = "no code learned").
    function _v4Code(uint24 fee, int24 ts) private pure returns (uint256) {
        return (uint256(fee) << 24) | uint256(uint24(ts));
    }

    /// @dev True iff the hookless poolId of (t0, t1, fee, ts) truncates to
    ///      `pool` — the unforgeable link between a registry pool address and
    ///      a claimed tier.
    function _v4IdMatches(address pool, address t0, address t1, uint24 fee, int24 ts)
        private pure returns (bool)
    {
        return address(uint160(uint256(
            BPC.computeV4PoolId(t0, t1, fee, ts, address(0))
        ))) == pool;
    }

    // ─── V4 pattern-code learning (discovery-hint metadata ONLY) ───────
    //
    //  INV-16 BOUNDARY: everything below writes/reads $.v4CodeOf and nothing
    //  else. The code never feeds psi/fitness/eviction/route-ranking —
    //  routing weight comes exclusively from measured marginal output. A
    //  wrong code (staleness, manipulation) costs at most one wasted probe in
    //  _scanV4, because every candidate is re-proven live before emission and
    //  proven again at quote time. No revert paths: learning must never break
    //  a swap or a claim.

    /// @dev Write the pattern code on the pair's NON-BRIDGE side(s). Bridges
    ///      pair with many tokens at many tiers — a per-bridge code would
    ///      thrash — so the code is the launch-tier fingerprint of the minted
    ///      token only. Last proof wins: self-correcting toward the tier that
    ///      actually trades. Skips the SSTORE when the code is unchanged.
    function _writeV4Code(address t0, address t1, uint24 fee, int24 ts) private {
        HubStore storage $ = _store();
        uint256 c = _v4Code(fee, ts);
        if (!$.isBridge[t0] && $.v4CodeOf[t0] != c) $.v4CodeOf[t0] = c;
        if (!$.isBridge[t1] && $.v4CodeOf[t1] != c) $.v4CodeOf[t1] = c;
    }

    /// @dev recordSwap-side healer for an already-registered V4 pool: recover
    ///      the swapped pool's tickSpacing (steady state: one SLOAD + one
    ///      keccak — the learned code already describes the pool) and refresh
    ///      the non-bridge side(s). Fail-open: unrecoverable means no update.
    function _noteV4Code(address pool, address t0, address t1, uint24 fee) private {
        (int24 ts, bool ok) = _recoverV4Ts(pool, t0, t1, fee);
        if (ok) _writeV4Code(t0, t1, fee, ts);
    }

    /// @dev Recover the tickSpacing of a routed hookless V4 pool from
    ///      (pool, t0, t1, fee) — recordSwap does not carry tickSpacing and
    ///      the Router stays unchanged, so the missing coordinate is
    ///      reconstructed and VERIFIED against the truncated poolId before
    ///      being trusted. The sources mirror exactly what the derive-scan
    ///      can emit, so the loop is closed:
    ///        1. learned per-token codes (one SLOAD + one keccak steady state)
    ///        2. generator inverse (fee = 10_000*j  =>  ts = 100*j)
    ///        3. canonical tiers
    ///        4. MODE_V4_DERIVE rows' paired extras
    ///        5. the registered V4Entry — the backstop that always resolves a
    ///           pool admitted via claimV4/addV4
    ///      A hooked pool never matches (hookless derivation) => (0, false).
    function _recoverV4Ts(address pool, address t0, address t1, uint24 fee)
        private view returns (int24 ts, bool ok)
    {
        HubStore storage $ = _store();
        // 1) learned codes
        uint256 c = $.v4CodeOf[t0];
        if (c != 0 && uint24(c >> 24) == fee) {
            ts = int24(uint24(c));
            if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
        }
        c = $.v4CodeOf[t1];
        if (c != 0 && uint24(c >> 24) == fee) {
            ts = int24(uint24(c));
            if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
        }
        // 2) generator inverse
        if (fee != 0 && fee % 10_000 == 0 && fee / 10_000 <= V4_GRID_MAX) {
            ts = int24(uint24((fee / 10_000) * 100));
            if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
        }
        // 3) canonical tiers
        uint256[] memory tiers = _v4CanonicalTiers();
        for (uint256 i; i < tiers.length; ) {
            if (uint24(tiers[i] >> 24) == fee) {
                ts = int24(uint24(tiers[i]));
                if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
            }
            unchecked { ++i; }
        }
        // 4) V4_DERIVE rows' paired extras
        uint256 fn = $.factories.length;
        for (uint256 fi; fi < fn; ) {
            Factory storage fac = $.factories[fi];
            if (fac.mode == MODE_V4_DERIVE) {
                uint256 en = fac.fees.length < fac.spacings.length
                    ? fac.fees.length
                    : fac.spacings.length;
                for (uint256 i; i < en; ) {
                    if (fac.fees[i] == fee) {
                        ts = fac.spacings[i];
                        if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
                    }
                    unchecked { ++i; }
                }
            }
            unchecked { ++fi; }
        }
        // 5) the registered V4Entry backstop
        uint256 vn = $.v4Entries.length;
        for (uint256 vi; vi < vn; ) {
            V4Entry storage e = $.v4Entries[vi];
            if (
                e.currency0 == t0 && e.currency1 == t1 && e.fee == fee
                    && e.hooks == address(0)
            ) {
                ts = e.tickSpacing;
                if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
            }
            unchecked { ++vi; }
        }
        return (0, false);
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
                if ((pi.kind != BPC.KIND_V4 && pi.kind != BPC.KIND_V4_NATIVE)
                    || pi.hooks == address(0) || isHookLive(pi.hooks)) {
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
        // Restore the orientation contract for V4-NATIVE pools: token0 must be
        // the wrapped-native side, which is what the Solver and the Quoter
        // assume when deriving the key by `zeroForOne`. The index stays sorted
        // by address (lookups depend on it); only the REPORTED ORIENTATION is
        // corrected, and the bit already came in the slot this function receives.
        bool _swap = p.kind == BPC.KIND_V4_NATIVE && _nativeSwapped(s);
        p.token0      = _swap ? t1 : t0;
        p.token1      = _swap ? t0 : t1;
        p.pool        = $.poolOf[key];
        p.hooks       = $.hooksOf[key];
        p.stable      = false;
        // tickSpacing is not packed in the pool slot. V3-style kinds derive
        // pools from the fee (0 is fine), but V4 needs the real tickSpacing —
        // it is part of the poolId the quote recomputes — so recover it from
        // the matching V4Entry.
        p.tickSpacing = 0;
        if (BPC.kindHas(p.kind, BPC.A_CONC_SING)) {
            // V1 / invariant I11: O(1) entry recovery by key (index+1), replacing
            // the linear scan below on the hot per-solve path. Every registered V4
            // pool has an entry recorded under its key at registration (v4EntryOf),
            // so this hits; on a miss it falls through to the scan (fail-closed,
            // unreachable for pools registered after this fix).
            uint256 ep = $.v4EntryOf[key];
            if (ep != 0) {
                V4Entry storage e0 = $.v4Entries[ep - 1];
                p.tickSpacing = e0.tickSpacing;
                if (p.kind == BPC.KIND_V4_NATIVE) {
                    // Native entry: currency0 == address(0), currency1 == the ERC20
                    // counterpart. Orient WETH-canonical (token0 = wrapped-native
                    // side, token1 = counterpart) exactly as the scan did.
                    p.token0 = e0.currency1 == t0 ? t1 : t0;
                    p.token1 = e0.currency1;
                }
                return p;
            }
            uint256 vn = $.v4Entries.length;
            for (uint256 vi; vi < vn; ) {
                V4Entry storage e = $.v4Entries[vi];
                if (p.kind == BPC.KIND_V4) {
                    if (e.currency0 == t0 && e.currency1 == t1 && e.fee == p.fee && e.hooks == p.hooks) {
                        p.tickSpacing = e.tickSpacing;
                        break;
                    }
                } else if (e.currency0 == address(0) && e.fee == p.fee && e.hooks == p.hooks
                    && (e.currency1 == t0 || e.currency1 == t1)) {
                    // Native entry (currency0 = address(0), currency1 = the
                    // ERC20 counterpart). Verify by the unforgeable truncated-
                    // poolId match — a same-fee native entry of another pair
                    // can then never mis-resolve this one — and ORIENT the
                    // WETH-canonical pair: token0 = the wrapped-native side,
                    // token1 = the counterpart. This orientation is the
                    // contract the Solver's zeroForOne / auxId / quote-ctx
                    // construction relies on (token0 == tIn ⇔ input is the
                    // pool's currency0).
                    if (address(uint160(uint256(BPC.computeV4PoolId(
                            address(0), e.currency1, p.fee, e.tickSpacing, p.hooks
                        )))) == p.pool) {
                        p.tickSpacing = e.tickSpacing;
                        p.token0 = e.currency1 == t0 ? t1 : t0;
                        p.token1 = e.currency1;
                        break;
                    }
                }
                unchecked { ++vi; }
            }
        }
    }

    function getPsi(bytes32 key) external view returns (uint256) { return _psi(key); }

    /// @dev THEY WERE NOT TWO IDENTICAL CHAINS — THEY WERE TWO IDENTICAL BODIES. This function
    ///      and `_psiOfSlot` differed only in how they fetched the slot; all the rest was a
    ///      literal copy, including the four-kind chain. Collapsing the chain and leaving the
    ///      two functions cured the symptom and kept the sibling. Now there is ONE body.
    function _psi(bytes32 key) private view returns (uint256) {
        return _psiOfSlot(_store().slot[key]);
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

    /// @dev BIT 6 of the Monoslot (inside the reserved [7:1] span): "the
    ///      wrapped-native side is token1, not token0".
    ///
    ///      WHY IT EXISTS. The Solver and the Quoter derive which side of a
    ///      V4-NATIVE pool is `address(0)` from `zeroForOne`, and their
    ///      comments invoke an "orientation contract: token0 is the
    ///      wrapped-native side". That contract DID NOT EXIST: `_register`
    ///      indexes by `sortTokens`, that is, by ADDRESS. When the other token
    ///      sorts below WETH, `token0` stops being WETH, `zeroForOne` flips,
    ///      and the two derivations (Router by `nativeMapVerified`, Quoter by
    ///      orientation) produce DIFFERENT poolIds — the native pool becomes
    ///      invisible to half the token space. Fail-closed, but silently
    ///      unreachable. See test/V4NativeOrientation.t.sol.
    ///
    ///      The case that passed (USDC on Base, 0x8335... > WETH 0x4200...) was
    ///      the only one tested — which is why the prose looked true.
    ///
    ///      The flag makes the contract REAL at no read cost: the slot is
    ///      already loaded in `_readPoolInfo`, and reading a bit is free.
    function _markNativeSwapped(uint256 slot, bool b) private pure returns (uint256) {
        return b ? (slot | (uint256(1) << 6)) : (slot & ~(uint256(1) << 6));
    }
    function _nativeSwapped(uint256 slot) private pure returns (bool) {
        return ((slot >> 6) & 1) == 1;
    }

    function _markBridged(uint256 slot, bool b) private pure returns (uint256) {
        return b ? (slot | (uint256(1) << 7)) : (slot & ~(uint256(1) << 7));
    }

    function getSlot(bytes32 key) external view returns (uint256) { return _store().slot[key]; }
    function getPool(bytes32 key) external view returns (address) { return _store().poolOf[key]; }
    function v4PoolManager() external view returns (address) { return _store().v4PoolManager; }
    function v4EntryCount() external view returns (uint256) { return _store().v4Entries.length; }
    /// @notice Learned V4 pattern code of a token: packed
    ///         (fee << 24 | uint24(tickSpacing)), 0 = none. Hint metadata
    ///         only — never a routing weight (INV-16).
    function v4CodeOf(address token) external view returns (uint256) { return _store().v4CodeOf[token]; }

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
        // SIBLING CHANNEL. `addFactory` closes the kinds it does not accept; this is the Hub's
        // SECOND registration door and it had no closure at all — this codebase's defect
        // signature ("a fix applied to ONE of two symmetric channels") inside the excision itself.
        //
        // BUT EACH DOOR CLOSES WITH ITS OWN MASK. The first version of this closure reused the
        // factory's `KINDS_ROUTABLE`, and that swapped the question: here we do not ask "which
        // kinds get registered by a factory?" but "which kinds can the Router have just
        // executed?". V4_NATIVE answers no to the first and YES to the second, and was left out
        // — see KINDS_EXECUTABLE.
        //
        // NOT redundant with the `else { revert RouterE(8); }` in the Router's dispatch:
        // `$.router` is swappable (setRoles), so the single producer of these kinds is NOT
        // immutable. A future Router that gains a new arm without the Hub knowing would write a
        // kind into the registry that the rest of the system cannot read. This is the LOCAL
        // defence, the one that does not depend on another address staying what it was at deploy.
        //
        // Skips registration, does NOT revert: the user's swap has already executed and cannot
        // fail over a registry decision — the same discipline as the V4 !okTs case further down.
        if (((KINDS_EXECUTABLE >> kind) & 1) == 0) return;
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        bytes32 key = keyOf(pool, t0, t1);
        HubStore storage $ = _store();
        uint256 s = $.slot[key];
        if (s != 0) {
            // existing pool — tick + stamp wall-clock activity time
            uint256 newSlot = BPC.tickSlot(s, uint32(block.number), depthWad, uint32(block.timestamp));
            $.slot[key] = _stampTs(newSlot);
            // Hookless V4 leg: refresh the tokens' learned pattern code
            // (discovery-hint metadata only — never fitness; see INV-16
            // boundary at the learning section). Hooked pools are excluded:
            // the code describes a hookless derivation.
            if (kind == BPC.KIND_V4 && hooks == address(0)) _noteV4Code(pool, t0, t1, fee);
            emit Volume(key, amtIn, amtOut);
            return;
        }
        // unknown — attempt insert
        if (!_canInsert($.pairKeys[t0][t1], depthWad)) return;
        // Pair-shaped kinds: PROVE the pool really trades (t0, t1) before it
        // enters the registry. Every argument here is caller-controlled
        // calldata carried in the Router's Route — pool, kind AND depth — so
        // without this an attacker registers a contract they wrote under a
        // pair they picked, at a depth they picked, holding neither token.
        // This mirrors the authenticity proof the V4 branch below already has
        // (poolId recomputation); no other kind had one.
        // The mask is the Router's own "the pool field is a pair" taxonomy
        // (_legTokens) — see KINDS_PAIR_PROOF. Outside it: V4(4) and
        // V4_NATIVE(8), whose `pool` is a truncated poolId with no bytecode at
        // all, and which prove themselves in the branch below. kind > 8 shifts
        // the mask to 0 — a future kind stays unverified (today's behaviour)
        // instead of becoming silently unregistrable.
        // Cost: at most two staticcalls (short-circuited to one on the first
        // mismatch), on the COLD first-registration path ONLY — the hot path
        // returned at the tick above and pays nothing.
        // Mismatch => skip registration, NEVER revert: the user's swap has
        // already executed and must not fail over a registry decision — the
        // same fail-without-registering the V4 !okTs case takes.
        if (((KINDS_PAIR_PROOF >> kind) & 1) != 0
            && (BPC.token0Of(pool) != t0 || BPC.token1Of(pool) != t1)) return;
        if (kind == BPC.KIND_V4) {
            // A V4 pool reaching FIRST registration here was found by the
            // derive-scan (a view — it could not persist anything). The
            // registry's V4 reads REQUIRE a matching V4Entry (tickSpacing
            // recovery for quote-time poolId recomputation), and recordSwap
            // does not carry tickSpacing — so recover it and verify against
            // the truncated poolId. The derivation is hookless-only, so a
            // hooked pool never matches. Unrecoverable => skip registration
            // entirely: an entry-less V4 registration would be dead weight
            // that marks the pair "known" and starves rediscovery. The swap
            // itself is unaffected either way (fail closed, fail open).
            (int24 v4Ts, bool okTs) = _recoverV4Ts(pool, t0, t1, fee);
            if (!okTs) return;
            $.v4Entries.push(V4Entry({
                currency0: t0, currency1: t1, fee: fee,
                tickSpacing: v4Ts, hooks: address(0)
            }));
            $.v4EntryOf[key] = $.v4Entries.length; // V1/I11: O(1) key -> V4Entry
            _writeV4Code(t0, t1, fee, v4Ts);
        }
        if (kind == BPC.KIND_V4_NATIVE) {
            // Native V4 pool routed under its WETH-canonical pair (tA/tB are
            // the Router's hop tokens — routes speak WETH). Authenticity: the
            // truncated NATIVE poolId, derived from (address(0), T), must
            // match `pool`. recordSwap does not carry which side is the
            // wrapped-native one, so try both orientations — the 160-bit
            // truncation match is unforgeable, and the orientation that
            // matches identifies the ERC20 counterpart T. Reuses the exact
            // _recoverV4Ts ladder with the native pair (its steps are
            // pair-parametric; passing address(0) as one side derives native
            // poolIds throughout, and the entries backstop matches native
            // entries by currency0 == address(0)). Hookless-only by
            // construction, like V4. Unrecoverable => skip registration,
            // never revert (same doctrine as the V4 branch above). The entry
            // stores the REAL pool currencies; _readPoolInfo re-orients the
            // pair to WETH-canonical form for the Solver from it.
            address ncp = t1;
            (int24 nTs, bool okN) = _recoverV4Ts(pool, address(0), t1, fee);
            if (!okN) { ncp = t0; (nTs, okN) = _recoverV4Ts(pool, address(0), t0, fee); }
            if (!okN) return;
            $.v4Entries.push(V4Entry({
                currency0: address(0), currency1: ncp, fee: fee,
                tickSpacing: nTs, hooks: address(0)
            }));
            $.v4EntryOf[key] = $.v4Entries.length; // V1/I11: O(1) key -> V4Entry
            // Learn the tier on the ERC20 side only (passed twice: the second
            // write self-skips as unchanged) — a v4CodeOf[address(0)] entry
            // would be dead storage no scan ever reads (_scanV4 rejects
            // native-side pairs), costing a 20k SSTORE on a user's swap.
            _writeV4Code(ncp, ncp, fee, nTs);
        }
        // ─── REG-02 + REG-01: THE PROPOSER'S DATA ARE COORDINATES, NOT FACTS ───
        // This line wrote into the registry the `fee` and the `hooks` COMING FROM the
        // Router's CALLDATA, in the same transaction in which depth was MEASURED. CI
        // already carries the guard "Depth producer guard (depth never comes from
        // calldata)" with the reason written down — "if a producer writes a number
        // the caller chose, the caller gets to decide the registry ranking". The
        // `fee` and the `hooks` were that guard's sibling channel, still to be closed.
        //
        // WHAT THIS ALLOWED (measured in test/RegistryFeeFromCalldata.t.sol):
        // watch the mempool, front-run the first swap on an honest pool not yet
        // registered with a dust swap declaring `leg.fee = 9000`, and the pool
        // was quoted at a 90% fee (effV2Fee is in BPS) until eviction.
        // `tickSlot` preserves the fee bits, and `recordSwap` self-guards on
        // `slot != 0`: not even a later honest swap corrected it.
        //
        // THE FEE, by source of truth:
        //   V4 / native V4 -> the calldata one, because it is AUTHENTICATED and not
        //     trusted: it feeds `computeV4PoolId`, and `_recoverV4Ts` above has
        //     already returned without registering if the derived pid missed the pool.
        //   Algebra (`dyn`) -> 0, the sentinel that tells the reader to MEASURE live
        //     (`quoteV3Fee`). That is rule R2 (L511-512), which only existed at the
        //     `addFactory` door — this door never had it.
        //   Static V3 -> `getV3Fee(pool)`, measured.
        //   V2 / Solidly -> `fee()` does not exist, so 0, and `effV2Fee(0) = 30`: the
        //     house's single producer answers, instead of the caller.
        // The `dyn` of `v3StateAndDynFee` discriminates by SHAPE (slot0 fails and
        // globalState answers), not by a list of venues.
        //
        // WHY NOT DISCRIMINATE BY `kind`, which is already here for free: because
        // `kind` ALSO comes from the calldata. This door only checks that it is
        // in KINDS_EXECUTABLE — never that the pool IS of that type. A
        // `kind = KIND_ALGEBRA` declared on a real V3 pool with `fee = 3000`
        // executes cleanly, would write the 0 sentinel, and from then on
        // `quoteV3Fee(pool, 0, 0, dyn=false)` returns 0xFFFFFF fail-closed: the pool became
        // permanently unquotable. Swapping one calldata field for another calldata
        // field closes nothing — only reading the pool's SHAPE trusts
        // nobody. It costs ~190 B of Hub, measured: the price of not having
        // reintroduced the defect while closing it.
        //
        // THE HOOKS: address(0) always, and that is provable, not conservative. Every
        // path reaching here from `recordSwap` has either proven the pool has NO
        // hook (the V4 branches derive the hookless poolId and `return` if they
        // fail — so explicit that `V4Entry` pins `hooks: address(0)` by
        // hand) or belongs to a hookless kind. Writing the calldata `hooks`
        // allowed poisoning `hooksOf[key]`: a non-allow-listed address made
        // the LEGITIMATE pool drop out of the `getActivePools` filter (L1156,
        // `pi.hooks == address(0) || isHookLive(pi.hooks)`).
        uint24 feeReg = fee;
        if (kind != BPC.KIND_V4 && kind != BPC.KIND_V4_NATIVE) {
            (, , bool dynShape) = BPC.v3StateAndDynFee(pool);
            feeReg = dynShape ? 0 : BPC.getV3Fee(pool);
        }
        _register(key, pool, kind, feeReg, address(0), t0, t1, false);
        // initial tick + stamp wall-clock activity time
        $.slot[key] = _stampTs(BPC.tickSlot($.slot[key], uint32(block.number), depthWad, uint32(block.timestamp)));
        emit Volume(key, amtIn, amtOut);
    }

    /// @dev Refresh the slot's lastUpdateTs (bits [95:64]) to the current
    ///      wall-clock time. The field is otherwise write-once at registration and
    ///      is read by nothing on-chain except the Solver's discovery-freshness
    ///      gate — so repurposing it as "last activity time" is behaviour-neutral
    ///      for fitness/eviction. It is NOT `lastBlk` that feeds that judgment, despite this
    ///      line once having asserted it: the Core's `vitality` and `_decayedSwapCount` read
    ///      `decodeLastUpdateTs`, and `decodeLastBlk` has NOT ONE caller in src/ — its only
    ///      readers are three test assertions about the encoding itself. `lastBlk` is written
    ///      on every tick and never read; it is recorded as such in the Monoslot's dead-bit
    ///      census, and the decision to prune it or reserve it for statistical vitality
    ///      belongs to the owner.
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
        // R-C: integer division made the "strict 25% margin" VANISH exactly where
        // it was needed. For worstPsi <= 3, worstPsi/4 is 0 and the test collapses
        // to `newcomerPsi > worstPsi` — no margin at all, in the dust-vitality
        // regime the hysteresis exists to damp. Rounding up keeps a real margin
        // at every psi.
        return newcomerPsi > worstPsi + BPC.mulDivUp(worstPsi, 2_500, BPC.BPS);
    }

    /// @notice Fitness of a slot using its packed bridge bit and kind-derived conc.
    /// @dev The ONLY producer of psi in this contract. The question "is this pool concentrated
    ///      liquidity?" is a MEMBERSHIP test against a state-SHAPE class (in the pool or in the
    ///      singleton, immaterial to the weight) — it collapses into theta without violating the
    ///      acceptance-predicate rule, because psi is a READ weight and does not decide admission.
    function _psiOfSlot(uint256 s) private view returns (uint256) {
        if (s == 0) return 0;
        bool conc = BPC.kindHasAny(BPC.decodeKind(s), BPC.A_CONC_POOL | BPC.A_CONC_SING);
        return BPC.psi(s, uint32(block.timestamp), _isBridged(s), conc);
    }

    function _register(
        bytes32 key, address pool, uint8 kind, uint24 fee, address hooks,
        address t0, address t1, bool trusted
    ) private {
        HubStore storage $ = _store();
        bytes32[] storage ks = $.pairKeys[t0][t1];
        // KEY-EXISTENCE GUARD: re-registering a key already listed for this
        // pair (addV4/seedPool called twice with identical params) must refresh
        // the slot in place, never append a second copy. getActivePools does
        // not dedup, so a duplicate both double-lists the pool to the Solver
        // and inflates the O(n) scan every quote walks. poolOf is the O(1)
        // witness of presence — written only below, cleared only on eviction,
        // which is the same moment the key leaves ks. recordSwap and the
        // permissionless V4 path already self-guard (slot != 0 / poolOf != 0),
        // so this only closes the operator entry-points.
        if ($.poolOf[key] == address(0)) {
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
        }
        // ROUTABLE, not merely an anchor: the flag is worth +25% fitness in `psi`, and fitness
        // decides evictions in a capped registry. Paying the bonus to a pool the router cannot
        // reach meant evicting useful liquidity in favour of unreachable liquidity.
        bool bridged = _isRoutableBridge($, t0) || _isRoutableBridge($, t1);
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
