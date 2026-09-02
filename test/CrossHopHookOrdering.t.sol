// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  F1 — LAYER 2 IS ENFORCED PER HOP; THE THREAT IT NAMES IS ROUTE-WIDE.
//
//  Router:1140, inside the `for (uint256 h; h < route.hops.length; )` body:
//
//      bool sawHooked;
//      for (uint256 l; l < legs; ) {
//          if (leg.hooks == address(0)) { if (sawHooked) revert RouterE(3); }
//          else { sawHooked = true; }
//
//  `sawHooked` is re-initialised at EVERY hop. The rule's own justification,
//  four lines above it (Router:1127-1133), is not per-hop:
//
//      "A hook gains EVM control during the swap and can touch ANY contract —
//       including the pool of a leg of this same route that has not executed
//       yet."
//
//  Every leg of hops 1..H-1 is a leg of this same route that has not executed
//  yet. A hooked leg in hop 0 therefore runs third-party code while every
//  downstream hop is still unmeasured — the exact state the ordering rule
//  exists to make unreachable.
//
//  The two layers meant to bound the residual are ALSO per-hop:
//    · the per-leg floor  (Router:1601)  bounds ONE leg at LEG_FLOOR_BPS = 80%
//    · Layer 1            (Router:1229)  bounds ONE hop's aggregate
//  so the composition Layer 1's own docstring says it exists to close —
//  "across H hops the legitimate guarantee degrades to 0.8^H" — is re-opened
//  by a hooked leg placed in an early hop. Nothing sums the hops.
//
//  THE FIX CARRIES NO RIGIDITY. Hops cannot be reordered (they must chain), so
//  the route-wide form of the rule is "a hooked leg may only appear in the LAST
//  hop" — equivalently, hoist `sawHooked` out of the hop loop. Every route the
//  Solver can build stays expressible; it just cannot put the hook first.
//  `test_HookedOnlyInLastHop_Passes` is the control that pins that.
//
//  WHY V2 LEGS WITH A DECORATIVE `hooks` FIELD: this probe tests the ORDERING
//  RULE, which reads `leg.hooks` for every kind (Router:1143). It is the same
//  device test/HookedLastOrdering.t.sol already uses — that file only ever
//  builds ONE hop, which is why this escaped.
//
//  forge test --match-contract CrossHopHookOrdering -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract CrossHopHookOrderingTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA; MockERC20 tokenB; MockERC20 tokenC;
    MockV2Pair poolAB;   // hop 0
    MockV2Pair poolBC;   // hop 1

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    /// Only the low bits classify a hook; 0x...000 keeps the two
    /// RETURNS_DELTA bits (1<<2 | 1<<3) clear so the Router's own hook sieve
    /// (BPC.hookAltersDeltas) does not reject it for a different reason.
    address constant HOOK = address(0x4444444444444444444444444444444444444000);

    uint256 constant AMT      = 100e18;
    uint112 constant RESERVE  = uint112(100_000e18);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");

        poolAB = new MockV2Pair(address(tokenA), address(tokenB));
        poolBC = new MockV2Pair(address(tokenB), address(tokenC));

        tokenA.mint(address(poolAB), uint256(RESERVE));
        tokenB.mint(address(poolAB), uint256(RESERVE));
        poolAB.setReserves(RESERVE, RESERVE);

        tokenB.mint(address(poolBC), uint256(RESERVE));
        tokenC.mint(address(poolBC), uint256(RESERVE));
        poolBC.setReserves(RESERVE, RESERVE);

        hub.seedPool(address(poolAB), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(poolBC), BPC.KIND_V2, 30, address(0), address(tokenB), address(tokenC));

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    // ─── route builders ──────────────────────────────────────────────────────

    function _leg(MockV2Pair p, address tIn, address hooks)
        internal view returns (Leg memory)
    {
        return Leg({
            pool: address(p),
            hooks: hooks,
            kind: BPC.KIND_V2,
            fee: 30,
            tickSpacing: 0,
            zeroForOne: p.token0() == tIn,
            stable: false,
            amountIn: AMT,
            // 0 on purpose: the in-frame coverage gate (Router:1546) then
            // supplies the floor from the MEASURED quote, so the per-leg floor
            // is live and nothing here is a calldata opt-out.
            expectedOut: 0,
            auxId: bytes32(0)
        });
    }

    /// Two hops, A -> B -> C, one leg each. Continuity holds
    /// (hops[1].tokenIn == hops[0].tokenOut), which is what Router:1058 checks.
    function _twoHopRoute(address hook0, address hook1)
        internal view returns (Route memory r)
    {
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(poolAB, address(tokenA), hook0);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(poolBC, address(tokenB), hook1);

        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
                       amountIn: AMT, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(tokenB), tokenOut: address(tokenC),
                       amountIn: AMT, expectedOut: 0, legs: l1});

        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    // ─── THE CLAIM UNDER TEST (RED TODAY) ────────────────────────────────────

    /// A hooked leg in hop 0 runs third-party code while EVERY leg of hop 1 is
    /// still unexecuted and unmeasured. Under the rule as stated, that route
    /// must be refused (RouterE(3)); today it settles.
    function test_HookedLegInHop0_BeforeHookless_Reverts() public {
        // Built BEFORE the cheatcodes: the builder makes external view calls
        // (token0()) that would otherwise consume the prank and the expectRevert.
        Route memory r = _twoHopRoute(HOOK, address(0));
        vm.prank(user);
        vm.expectRevert();
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// The same defect phrased as an observation rather than a refusal, so the
    /// finding stays legible whatever error code the fix picks — and so this
    /// file does not acquire a permanently-broken test the day it is fixed.
    function test_HookedLegInHop0_IsRefusedOrSettles() public {
        Route memory r = _twoHopRoute(HOOK, address(0));
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1)
            returns (uint256 got)
        {
            assertEq(got, 0,
                "a route whose hook runs BEFORE an unmeasured downstream hop SETTLED: Layer 2 is per-hop, the threat it names is route-wide");
        } catch {
            // Refused — this is what the fix must produce.
        }
    }

    // ─── CONTROLS: the fix must not add rigidity ─────────────────────────────

    /// Canonical route-wide order — the hook is in the LAST hop, so nothing it
    /// touches is still pending. Green today, must stay green after the fix.
    function test_HookedOnlyInLastHop_Passes() public {
        Route memory r = _twoHopRoute(address(0), HOOK);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(got, 0, "a hook in the last hop has no pending leg to manipulate and must route");
    }

    /// A route with no hooks at all can never be affected by this rule.
    function test_AllHookless_TwoHops_Unaffected() public {
        Route memory r = _twoHopRoute(address(0), address(0));
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(got, 0, "a hookless route must be untouched");
    }

    /// The intra-hop rule that DOES exist still fires — this file must not be
    /// read as a claim that Layer 2 is absent, only that its scope is wrong.
    function test_IntraHopRuleStillFires() public {
        Leg[] memory l0 = new Leg[](2);
        l0[0] = _leg(poolAB, address(tokenA), HOOK);        // hooked first
        l0[1] = _leg(poolAB, address(tokenA), address(0));  // hookless after
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
                       amountIn: AMT * 2, expectedOut: 0, legs: l0});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false});

        vm.prank(user);
        vm.expectRevert();
        router.swapExactIn(r, AMT * 2, 1, user, block.timestamp + 1);
    }
}
