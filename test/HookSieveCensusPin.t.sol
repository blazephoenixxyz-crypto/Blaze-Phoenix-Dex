// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

/// @notice A4 CLOSURE PIN — the assumption this test turns from prose into CI:
///
///           "Every V4 execution path crosses the delta-altering-hook sieve
///            and the canonical-PoolManager check."       (ledger: A4, NO TEST)
///
///         No forge test can PROVE that sentence: a test exercises paths, and
///         exhaustiveness is a claim about the paths that do NOT exist. What
///         CAN be held mechanically is the STRUCTURE the hand-derived
///         enumeration of 2026-09-01 rests on — which functions are able to
///         mutate the PoolManager at all, and that the sieve sits in the same
///         function, upstream of the mutating call. This test is the census of
///         that structure, in the spirit of the shared-quantities register: a
///         pin that NAMES what it pins. (Source text is scanned via
///         vm.readFile — fs_permissions already grants read on "./".)
///
///         WHAT IT HOLDS FIXED:
///           1. `BPC.hookAltersDeltas(` has exactly FOUR call sites — Solver×2
///              (the registry/discovery candidate merge), Quoter×1 (_simV4),
///              Router×1 (_execV4Amt) — and ONE definition (Core). A fifth
///              copy is this codebase's own defect signature ("a fix applied
///              to one of two symmetric channels") and must reopen the
///              derivation, not slip in silently. A deleted copy likewise.
///           2. The mask is v4-core's BEFORE_SWAP_RETURNS_DELTA (1<<3) |
///              AFTER_SWAP_RETURNS_DELTA (1<<2) over the 14 permission bits
///              (0x3FFF). Wrong bits would green all four sieves at once.
///           3. Only TWO functions in src/ can open a PoolManager unlock —
///              Router._execV4Amt and Quoter._simV4 — and each runs the sieve
///              INSIDE ITS OWN BODY, BEFORE its unlock. The function that
///              unlocks is the function that sieves.
///           4. Only the two unlockCallbacks call PoolManager.swap, each
///              behind `msg.sender != mgr` with mgr read from the Hub in the
///              same frame; every settle/sync/take lives inside the Router's
///              callback. Solver, Hub and Core contain NO manager-mutating
///              call at all (their low-level calls are staticcall-only —
///              checked by eye 2026-09-01, not pinnable by grep).
///
///         IF THIS FAILS you did not "break a string": you moved a wall the
///         A4 enumeration leans on. Re-derive the path enumeration (every
///         route from an external entry point to PoolManager.{unlock,swap}),
///         update the ledger entry, THEN re-pin the counts here — that order.
contract HookSieveCensusPinTest is Test {
    uint256 internal constant NF = type(uint256).max;

    string internal constant ROUTER = "src/BlazePhoenixRouter.sol";
    string internal constant QUOTER = "src/BlazePhoenixQuoter.sol";
    string internal constant SOLVER = "src/BlazePhoenixSolver.sol";
    string internal constant HUB    = "src/BlazePhoenixHub.sol";
    string internal constant CORE   = "src/BlazePhoenixCore.sol";

    // ─── 1. the census: four sieve sites, one definition ────────────────────

    function test_A4_sieve_census_four_sites_one_definition() public view {
        assertEq(_count(_src(SOLVER), "BPC.hookAltersDeltas("), 2,
            "A4 pin: Solver sieve sites changed (expected 2, both in the candidate merge)");
        assertEq(_count(_src(QUOTER), "BPC.hookAltersDeltas("), 1,
            "A4 pin: Quoter sieve sites changed (expected 1, in _simV4)");
        assertEq(_count(_src(ROUTER), "BPC.hookAltersDeltas("), 1,
            "A4 pin: Router sieve sites changed (expected 1, in _execV4Amt)");
        assertEq(_count(_src(HUB), "BPC.hookAltersDeltas("), 0,
            "A4 pin: a sieve call appeared in the Hub - admission deliberately does NOT sieve (delta hooks may sit in the registry; they are refused at selection/quote/execution)");
        assertEq(_count(_src(CORE), "BPC.hookAltersDeltas("), 0,
            "A4 pin: a sieve CALL appeared inside Core (only the definition lives there)");
        // One definition, in the library, nowhere else — a shadow definition
        // with a different mask would fork the meaning of "delta-altering".
        assertEq(_count(_src(CORE), "function hookAltersDeltas"), 1,
            "A4 pin: hookAltersDeltas definition count in Core changed");
        assertEq(
            _count(_src(ROUTER), "function hookAltersDeltas")
          + _count(_src(QUOTER), "function hookAltersDeltas")
          + _count(_src(SOLVER), "function hookAltersDeltas")
          + _count(_src(HUB),    "function hookAltersDeltas"), 0,
            "A4 pin: a second hookAltersDeltas definition appeared outside Core");
    }

    // ─── 2. the mask: the right bits of the right width ─────────────────────

    function test_A4_mask_is_v4_swap_returns_delta_bits() public view {
        bytes memory core = _src(CORE);
        assertEq(_count(core, "uint256 bits = uint160(hook) & 0x3FFF;"), 1,
            "A4 pin: the 14-bit permission mask (v4 ALL_HOOK_MASK) changed");
        assertEq(_count(core, "uint256 deltaFlags = (1 << 3) | (1 << 2);"), 1,
            "A4 pin: delta flags changed - must stay BEFORE_SWAP_RETURNS_DELTA (1<<3) | AFTER_SWAP_RETURNS_DELTA (1<<2), the v4-core bit positions");
    }

    // ─── 3. the two unlock chokepoints sieve in their own frame ─────────────

    function test_A4_router_function_that_unlocks_is_the_function_that_sieves() public view {
        bytes memory s = _src(ROUTER);
        // The whole file owns exactly ONE unlock call, and it is the typed one.
        assertEq(_count(s, ").unlock("), 1,
            "A4 pin: a second unlock call appeared in the Router - a V4 execution path outside _execV4Amt");
        (uint256 a, uint256 b) = _fnSlice(s, "function _execV4Amt");
        uint256 mgrRd = _indexOf(s, bytes("address mgr = hub.v4PoolManager();"), a);
        uint256 sieve = _indexOf(s, bytes("BPC.hookAltersDeltas("), 0);
        uint256 live  = _indexOf(s, bytes("hub.isHookLive("), 0);
        uint256 unl   = _indexOf(s, bytes("IV4PoolManager(mgr).unlock("), 0);
        assertTrue(mgrRd != NF && mgrRd < b,
            "A4 pin: _execV4Amt no longer reads the manager from the Hub in-frame");
        assertTrue(sieve != NF && a < sieve && sieve < b,
            "A4 pin: the Router sieve left _execV4Amt");
        assertTrue(live != NF && a < live && live < b,
            "A4 pin: the isHookLive co-check (Layer 3 codehash pin) left _execV4Amt");
        assertTrue(unl != NF && a < unl && unl < b,
            "A4 pin: the Router unlock call left _execV4Amt");
        assertTrue(sieve < unl && live < unl,
            "A4 pin: in _execV4Amt the sieve and the liveness check must PRECEDE the unlock");
    }

    function test_A4_quoter_function_that_unlocks_is_the_function_that_sieves() public view {
        bytes memory s = _src(QUOTER);
        assertEq(_count(s, ").unlock("), 1,
            "A4 pin: a second unlock call appeared in the Quoter - a dry-run path outside _simV4");
        (uint256 a, uint256 b) = _fnSlice(s, "function _simV4");
        uint256 sieve = _indexOf(s, bytes("BPC.hookAltersDeltas("), 0);
        uint256 unl   = _indexOf(s, bytes("IV4Q(mgr).unlock("), 0);
        assertTrue(sieve != NF && a < sieve && sieve < b,
            "A4 pin: the Quoter sieve left _simV4");
        assertTrue(unl != NF && a < unl && unl < b,
            "A4 pin: the Quoter unlock call left _simV4");
        assertTrue(sieve < unl,
            "A4 pin: in _simV4 the sieve must PRECEDE the unlock");
    }

    // ─── 4. the two callbacks: canonical-manager check before swap ──────────

    function test_A4_router_callback_canonical_check_precedes_swap() public view {
        bytes memory s = _src(ROUTER);
        assertEq(_count(s, "IV4PoolManager(mgr).swap("), 1,
            "A4 pin: PoolManager.swap call count in the Router changed");
        assertEq(_count(s, "if (msg.sender != mgr) revert"), 1,
            "A4 pin: canonical-sender guard count in the Router changed");
        (uint256 a, uint256 b) = _fnSlice(s, "function unlockCallback");
        uint256 mgrRd = _indexOf(s, bytes("address mgr = hub.v4PoolManager();"), a);
        uint256 guard = _indexOf(s, bytes("if (msg.sender != mgr) revert"), 0);
        uint256 swp   = _indexOf(s, bytes("IV4PoolManager(mgr).swap("), 0);
        assertTrue(mgrRd != NF && mgrRd < b && a < guard && guard < b && a < swp && swp < b,
            "A4 pin: unlockCallback lost its in-frame hub-read / sender guard / swap trio");
        assertTrue(mgrRd < guard && guard < swp,
            "A4 pin: unlockCallback order must be read-mgr-from-hub, then sender guard, then swap");
        // Settlement verbs exist ONLY inside this callback.
        _allIn(s, "IV4PoolManager(mgr).settle", 2, a, b,
            "A4 pin: a settle call left the Router unlockCallback");
        _allIn(s, "IV4PoolManager(mgr).take(", 2, a, b,
            "A4 pin: a take call left the Router unlockCallback");
        _allIn(s, "IV4PoolManager(mgr).sync(", 1, a, b,
            "A4 pin: a sync call left the Router unlockCallback");
    }

    function test_A4_quoter_callback_canonical_check_precedes_swap() public view {
        bytes memory s = _src(QUOTER);
        assertEq(_count(s, "IV4Q(mgr).swap("), 1,
            "A4 pin: PoolManager.swap call count in the Quoter changed");
        assertEq(_count(s, "if (msg.sender != mgr) revert"), 1,
            "A4 pin: canonical-sender guard count in the Quoter changed");
        (uint256 a, uint256 b) = _fnSlice(s, "function unlockCallback");
        uint256 mgrRd = _indexOf(s, bytes("address mgr = hub.v4PoolManager();"), a);
        uint256 guard = _indexOf(s, bytes("if (msg.sender != mgr) revert"), 0);
        uint256 swp   = _indexOf(s, bytes("IV4Q(mgr).swap("), 0);
        assertTrue(mgrRd != NF && mgrRd < b && a < guard && guard < b && a < swp && swp < b,
            "A4 pin: Quoter unlockCallback lost its in-frame hub-read / sender guard / swap trio");
        assertTrue(mgrRd < guard && guard < swp,
            "A4 pin: Quoter unlockCallback order must be read-mgr-from-hub, then sender guard, then swap");
    }

    // ─── 5. the Solver plans, never executes; both its sieves in the merge ──

    function test_A4_solver_sieves_in_the_merge_and_never_unlocks() public view {
        bytes memory s = _src(SOLVER);
        (uint256 a, uint256 b) = _fnSlice(s, "function _topKPools");
        uint256 first  = _indexOf(s, bytes("BPC.hookAltersDeltas("), 0);
        uint256 second = _indexOf(s, bytes("BPC.hookAltersDeltas("), first + 1);
        assertTrue(first != NF && second != NF && a < first && second < b && first < second,
            "A4 pin: the Solver's two sieve sites left the _topKPools candidate merge (registry loop + discovery loop)");
        assertEq(_count(s, ").unlock("), 0, "A4 pin: the Solver gained an unlock call - the planner must stay view-only");
        assertEq(_count(s, ").swap("), 0, "A4 pin: the Solver gained a swap call - the planner must stay view-only");
    }

    // ─── 6. Hub and Core cannot touch the manager ───────────────────────────

    function test_A4_hub_and_core_have_no_manager_mutating_calls() public view {
        bytes memory h = _src(HUB);
        bytes memory c = _src(CORE);
        assertEq(_count(h, ").unlock(") + _count(c, ").unlock("), 0,
            "A4 pin: an unlock call appeared in Hub or Core");
        assertEq(_count(h, ").swap(") + _count(c, ").swap("), 0,
            "A4 pin: a swap call appeared in Hub or Core");
        assertEq(_count(h, ".settle(") + _count(c, ".settle("), 0,
            "A4 pin: a settle call appeared in Hub or Core");
        assertEq(_count(h, ".take(") + _count(c, ".take("), 0,
            "A4 pin: a take call appeared in Hub or Core");
        assertEq(_count(h, ".sync(") + _count(c, ".sync("), 0,
            "A4 pin: a sync call appeared in Hub or Core");
    }

    // ─── plumbing ───────────────────────────────────────────────────────────

    function _src(string memory path) internal view returns (bytes memory) {
        return bytes(vm.readFile(path));
    }

    /// @dev [a, b) = the body slice of the UNIQUE function whose header starts
    ///      with `header`, ending at the next top-level member (function /
    ///      fallback / receive at 4-space indent) or EOF. Deliberately layout-
    ///      sensitive: moving one of these functions is exactly the kind of
    ///      change that must reopen the A4 derivation.
    function _fnSlice(bytes memory s, string memory header)
        internal pure returns (uint256 a, uint256 b)
    {
        bytes memory h = bytes(header);
        a = _indexOf(s, h, 0);
        require(a != NF, string.concat("A4 pin: function header not found: ", header));
        require(_indexOf(s, h, a + 1) == NF,
            string.concat("A4 pin: function header not unique: ", header));
        uint256 f1 = _indexOf(s, bytes("\n    function "), a + h.length);
        uint256 f2 = _indexOf(s, bytes("\n    fallback("), a + h.length);
        uint256 f3 = _indexOf(s, bytes("\n    receive("), a + h.length);
        b = f1 < f2 ? f1 : f2;
        b = b < f3 ? b : f3;
        if (b == NF) b = s.length;
    }

    /// @dev Assert the needle occurs exactly `want` times in the file AND
    ///      every occurrence lies inside [a, b).
    function _allIn(
        bytes memory s, string memory needle, uint256 want,
        uint256 a, uint256 b, string memory msg_
    ) internal pure {
        bytes memory n = bytes(needle);
        uint256 seen;
        uint256 i = _indexOf(s, n, 0);
        while (i != NF) {
            assertTrue(a < i && i < b, msg_);
            unchecked { ++seen; }
            i = _indexOf(s, n, i + 1);
        }
        assertEq(seen, want, msg_);
    }

    function _count(bytes memory s, string memory needle) internal pure returns (uint256 c) {
        bytes memory n = bytes(needle);
        uint256 i = _indexOf(s, n, 0);
        while (i != NF) { unchecked { ++c; } i = _indexOf(s, n, i + 1); }
    }

    function _indexOf(bytes memory s, bytes memory n, uint256 from)
        internal pure returns (uint256)
    {
        uint256 nl = n.length;
        if (nl == 0 || s.length < nl) return NF;
        bytes1 first = n[0];
        for (uint256 i = from; i + nl <= s.length; ) {
            if (s[i] == first) {
                bool hit = true;
                for (uint256 j = 1; j < nl; ) {
                    if (s[i + j] != n[j]) { hit = false; break; }
                    unchecked { ++j; }
                }
                if (hit) return i;
            }
            unchecked { ++i; }
        }
        return NF;
    }
}
