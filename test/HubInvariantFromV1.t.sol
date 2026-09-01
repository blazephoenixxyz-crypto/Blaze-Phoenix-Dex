// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/HubInvariant.t.sol — a genuine gap: this repo's only
// existing invariant/stateful-fuzz suite (BlazePhoenixRouter.invariant.t.sol) targets the Router,
// not the Hub. No stateful fuzz here exercises the registry's own core safety property under
// random interleaved registration/ticking/eviction: a pair can never hold more than MAX_SLOTS
// (16) active pools, and every active entry resolves to a real, non-zero pool address, no matter
// how insertion order and eviction margins (EVICTION_IMPROVE_BPS) interact across many calls.
//
// forge test --match-contract HubInvariantFromV1 -vv

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {PoolInfo} from "../src/BlazePhoenixCore.sol";

/// @dev Drives recordSwap with bounded random pools/depths on a fixed pair. Acts as the Hub's
///      router so recordSwap is authorised.
/// @dev Minimal pool stub, and it must answer THREE reads or the campaign is
///      silently empty. `recordSwap` refuses a candidate — skipping
///      registration, never reverting, because the swap has already executed
///      and must not fail over a registry decision — unless the pool itself
///      backs the caller's claims:
///        * token0()/token1() must match the pair (the proposer picks the
///          pool, the pair and the depth; without this proof a caller
///          registers a contract they wrote under a pair they chose);
///        * fee() must answer for concentrated kinds, because the registry
///          MEASURES the fee off the pool instead of trusting calldata.
///      A codeless address answers zero to all three, so a handler that
///      fabricates pool addresses registers nothing at all and every
///      invariant over the registry holds vacuously.
contract PairStub {
    address public token0;
    address public token1;
    uint24  public fee = 3000;
    constructor(address a, address b) { token0 = a; token1 = b; }
}

contract HubInvariantHandler is Test {
    BlazePhoenixHub public hub;
    address public immutable t0;
    address public immutable t1;
    address[] public poolsList;
    uint256 public inserts;
    /// High-water mark of active pools on the pair during the campaign. This
    /// is the non-vacuity measure the suite needs: both invariants below hold
    /// TRIVIALLY over an EMPTY registry — the first because 0 <= 16, the
    /// second because a loop over zero entries runs no assertion at all. With
    /// the catch below swallowing every failure, a recordSwap that always
    /// reverted would leave the suite green while asserting nothing.
    uint256 public maxActive;
    /// Distinct pools this campaign has actually OFFERED to the registry.
    /// `inserts` counts successful calls, and a call landing on an
    /// already-registered pool ticks it instead of inserting — so call count
    /// is not a proxy for variety, and gating the fill assertion on it asks
    /// the registry to hold more pools than the run ever showed it.
    uint256 public distinctOffered;
    mapping(address => bool) private _seen;

    /// @param n How many distinct stubs to stand up. MUST exceed MAX_SLOTS so
    ///           the pair can fill and eviction actually runs; at exactly
    ///           MAX_SLOTS the campaign tops out without ever evicting.
    constructor(BlazePhoenixHub h, address a, address b, uint256 n) {
        hub = h; t0 = a; t1 = b;
        for (uint256 i; i < n; ++i) poolsList.push(address(new PairStub(a, b)));
    }

    function poolCount() external view returns (uint256) { return poolsList.length; }

    function recordSwap(uint256 seed, uint256 depth) external {
        // HASH THE SEED BEFORE INDEXING. forge's fuzz dictionary is heavily
        // weighted toward boundary values (0, 1, type(uint256).max), so a bare
        // `seed % n` lands on the same pool for most of a run: the first call
        // registers it and every later one takes the already-known tick path
        // without inserting. The pair then never grows past a single entry and
        // eviction is never reached. Hashing flattens the distribution.
        address pool = poolsList[uint256(keccak256(abi.encode(seed))) % poolsList.length];
        depth = bound(depth, 0, 1e30);
        // KIND_V2 ONLY, and deliberately. A concentrated kind is not something
        // a stub can honestly impersonate: for those the registry MEASURES the
        // fee off the pool rather than trusting the caller, so a stub that does
        // not answer like a real concentrated pool is refused — silently, and
        // correctly. Half the campaign's calls were landing there and doing
        // nothing, which is how the pair never reached MAX_SLOTS. This suite
        // exists to search registry MECHANICS (slot accounting, insertion
        // ranking, eviction), not kind dispatch, and constant-product is the
        // shape that exercises all of it with an honest stub.
        uint8 kind = 0;
        try hub.recordSwap(pool, kind, 3000, address(0), t0, t1, 1e18, 1e18, depth) {
            inserts++;
            if (!_seen[pool]) { _seen[pool] = true; distinctOffered++; }
            uint256 n = hub.getActivePools(t0, t1).length;
            if (n > maxActive) maxActive = n;
        } catch {}
    }
}

contract HubInvariantFromV1Test is StdInvariant, Test {
    BlazePhoenixHub hub;
    HubInvariantHandler handler;
    address constant T0 = address(0x1111);
    address constant T1 = address(0x2222);
    uint256 constant MAX_SLOTS = 16;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        // 24 > MAX_SLOTS (16): enough distinct pools for the pair to fill and
        // for eviction to be exercised, which is this suite's stated purpose.
        handler = new HubInvariantHandler(hub, T0, T1, 24);
        hub.setRoles(address(handler), address(0x5), address(0x6)); // router = handler
        targetContract(address(handler));
        // SPEND THE CALL BUDGET ON THE HUB, NOT ON forge-std. The handler
        // inherits Test, which inherits StdInvariant, which carries a dozen
        // public functions of its own (targetContracts, excludeSenders,
        // targetArtifacts, ...). Without a selector filter the fuzzer spreads
        // each run's `depth` calls across all of them, so only a fraction ever
        // reach recordSwap and the registry never gets near MAX_SLOTS —
        // eviction, the property this suite exists for, is then unreachable no
        // matter how many runs are configured.
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = HubInvariantHandler.recordSwap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_neverExceedsMaxSlots() public view {
        assertLe(hub.getActivePools(T0, T1).length, MAX_SLOTS);
    }

    function invariant_activePoolsResolve() public view {
        PoolInfo[] memory ps = hub.getActivePools(T0, T1);
        for (uint256 i; i < ps.length; ++i) {
            assertTrue(ps[i].pool != address(0), "active pool must resolve");
        }
    }

    /// @notice NON-VACUITY. The handler has always carried an `inserts`
    ///         counter that nothing read, so the two invariants above could be
    ///         green over an empty registry. Three rungs, weakest to
    ///         strongest, so the failure message says WHICH one gave way:
    ///           1. the call path works — recordSwap does not revert into the
    ///              handler's catch on every single call;
    ///           2. the registry actually moved — a call can settle without
    ///              registering, because the Hub fails soft by design;
    ///           3. the pair FILLED. This is the only rung that proves
    ///              eviction ran, and eviction is the suite's stated purpose
    ///              (see the header: insertion order and eviction margins
    ///              interacting across many calls). Without it MAX_SLOTS is
    ///              never touched and the central property goes untested.
    function afterInvariant() public view {
        assertGt(handler.inserts(), 0,
            "vacuous run: every recordSwap reverted into the handler's catch");
        assertGt(handler.maxActive(), 0,
            "vacuous run: calls settled but the registry never gained a pool");
        // Rung 3 is CONDITIONAL ON THE RUN HAVING OFFERED ENOUGH VARIETY. Under the
        // modest local invariant settings (see [invariant] in foundry.toml,
        // kept small because this repo's dev hardware runs under proot) a run
        // lands only a handful of successful registrations, which is not
        // enough distinct pools to fill the pair — asserting the fill
        // unconditionally would be a permanent false red on the dev machine
        // and would train people to ignore it. Gating on `inserts` keeps the
        // assertion honest in both places: it stays quiet when the search was
        // too shallow to have reached eviction, and it bites on a deep run
        // (`forge test --match-contract Invariant --invariant-runs 256
        // --invariant-depth 500`) where filling MUST happen. The gate counts
        // DISTINCT pools offered, not calls made: a call that lands on an
        // already-registered pool ticks it rather than inserting, so call
        // count is not a proxy for variety and gating on it demands a fill the
        // run never made possible. If this fires, MAX_SLOTS distinct valid
        // pools were offered and the pair still did not fill — that is
        // insertion or eviction breaking, the property this suite exists for
        // and the one nothing else covers.
        if (handler.distinctOffered() >= MAX_SLOTS) {
            assertGe(handler.maxActive(), MAX_SLOTS,
                "the registry refused to fill after MAX_SLOTS distinct valid pools were offered");
        }
    }
}
