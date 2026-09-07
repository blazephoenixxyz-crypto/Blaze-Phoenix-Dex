// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  HOOK ADMISSION BY ADDRESS BITS.
//
//  A Uniswap V4 hook's permissions live in the lowest 14 bits of its address and
//  the manager dispatches on them. Only four of those bits concern a swap:
//  BEFORE_SWAP (7), AFTER_SWAP (6) and the two swap-delta flags (3, 2). A hook
//  with none of them set is never entered during a swap, so a pool under such a
//  hook behaves, for a swap, exactly like a hookless pool: quote equals execution
//  by construction, and no judgement about the hook's code can change that.
//
//  Guarantee: pools under swap-invisible hooks are routable without an operator
//  step; a hook that runs in the swap (bit 7 or 6) is refused only while PAUSED
//  (revoked, or listed and its code moved); one nobody listed is the caller's
//  signed choice on the explicit door, bounded like every venue, and never
//  proposed by the automatic door; delta-returning hooks are refused regardless.
//  Red first: the settle test fails on the tree that gated every hook.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PricedV4Manager, FixedPlanSolver} from "./RouteIntegrityV4.t.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {PoolInfo} from "../src/BlazePhoenixCore.sol";

contract AnyHook { constructor(uint256) {} }

/// @dev Deploys a hook at an address whose low 14 bits satisfy (bits & mustSet) == mustSet
///      and (bits & mustClear) == 0, by CREATE2 salt search.
contract HookForge {
    function deploy(uint256 mustSet, uint256 mustClear) external returns (address hook) {
        bytes memory initCode = abi.encodePacked(type(AnyHook).creationCode, abi.encode(uint256(0)));
        bytes32 ch = keccak256(initCode);
        for (uint256 salt; salt < 1_000_000; ++salt) {
            uint256 bits = uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), ch)))) & 0x3FFF;
            if ((bits & mustSet) == mustSet && (bits & mustClear) == 0) {
                assembly { hook := create2(0, add(initCode, 32), mload(initCode), salt) }
                require(hook != address(0), "create2");
                return hook;
            }
        }
        revert("no salt");
    }
}

contract HookAdmissionByBitsTest is Test {
    uint256 constant BEFORE_SWAP = 1 << 7; uint256 constant AFTER_SWAP = 1 << 6;
    uint256 constant SWAP_DELTAS = (1 << 3) | (1 << 2); uint256 constant BEFORE_ADD_LIQ = 1 << 11;
    uint256 constant SWAP_BITS = BEFORE_SWAP | AFTER_SWAP | SWAP_DELTAS;

    BlazePhoenixHub hub; BlazePhoenixRouter router; PricedV4Manager mgr; HookForge forge_;
    MockERC20 tokA; MockERC20 tokB; address c0; address c1;
    address user = address(0xBEEF);
    uint24 constant FEE = 3000; int24 constant TS = 60; uint128 constant LIQ = 1e30;

    function setUp() public {
        mgr = new PricedV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        tokA = new MockERC20("A", "A"); tokB = new MockERC20("B", "B");
        (c0, c1) = address(tokA) < address(tokB) ? (address(tokA), address(tokB)) : (address(tokB), address(tokA));
        forge_ = new HookForge();
        MockERC20(c0).mint(user, 100e18); MockERC20(c1).mint(address(mgr), 1_000e18);
        vm.prank(user); MockERC20(c0).approve(address(router), type(uint256).max);
    }

    function _pool(address hooks) internal returns (bytes32 pid) {
        pid = BPC.computeV4PoolId(c0, c1, FEE, TS, hooks);
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
        mgr.setRate(pid, 1000);
    }

    function _route(bytes32 pid, address hooks, uint256 amt) internal view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({ pool: address(uint160(uint256(pid))), hooks: hooks, kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS,
                        zeroForOne: true, stable: false, amountIn: amt, expectedOut: amt, auxId: bytes32(uint256(uint160(c1))) });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: c0, tokenOut: c1, amountIn: amt, expectedOut: amt, legs: legs });
        route = Route({ hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
                        estGas: 0, hasSurplus: false, isV4Bundle: false });
    }

    function _swap(bytes32 pid, address hooks) internal returns (uint256) {
        uint256 amt = 1e18;
        vm.prank(user);
        return router.swapExactIn(_route(pid, hooks, amt), amt, 1, user, block.timestamp + 1);
    }

    function _refused9(bytes32 pid, address hooks) internal {
        uint256 amt = 1e18;
        Route memory r = _route(pid, hooks, amt);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(9)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    /// A liquidity-only hook (BEFORE_ADD_LIQUIDITY set, no swap bit): not allow-listed,
    /// never admitted by anyone, and its pool settles. Red on the tree that gated every hook.
    function test_SwapInvisibleHook_Unlisted_Settles() public {
        address h = forge_.deploy(BEFORE_ADD_LIQ, SWAP_BITS);
        assertFalse(hub.isHookLive(h), "premise: not allow-listed");
        assertFalse(BPC.hookRunsInSwap(h), "premise: no swap bit");
        uint256 got = _swap(_pool(h), h);
        assertGt(got, 9e17, "settles at the pool's price");
    }

    /// The same class with EVERY non-swap permission set (initialize, liquidity, donate):
    /// still invisible to a swap, still admitted by the bits.
    function test_SwapInvisibleHook_AllOtherBits_Unlisted_Settles() public {
        address h = forge_.deploy((1 << 13) | (1 << 12) | (1 << 11) | (1 << 10) | (1 << 5), SWAP_BITS);
        assertGt(_swap(_pool(h), h), 9e17, "settles");
    }

    /// A beforeSwap hook nobody listed: on the explicit door it is the caller's signed
    /// choice and settles, bounded like every venue. (It never reaches the automatic door:
    /// registry reads filter by isHookLive.)
    function test_BeforeSwapHook_Unlisted_ExplicitDoor_Settles() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        assertTrue(BPC.hookRunsInSwap(h), "premise: runs in the swap");
        assertFalse(hub.isHookLive(h), "premise: not listed");
        assertGt(_swap(_pool(h), h), 9e17, "settles on the explicit door");
    }

    /// Its twin: an afterSwap-only hook, not listed, settles on the explicit door too.
    function test_AfterSwapHook_Unlisted_ExplicitDoor_Settles() public {
        address h = forge_.deploy(AFTER_SWAP, BEFORE_SWAP | SWAP_DELTAS);
        assertGt(_swap(_pool(h), h), 9e17, "settles");
    }

    /// The curator's explicit "no": a revoked hook is refused on the explicit door too.
    function test_RevokedHook_ExplicitDoor_IsRefused() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        hub.allowHook(h, true); hub.allowHook(h, false);
        assertTrue(hub.hookPaused(h), "premise: revoked");
        _refused9(_pool(h), h);
    }

    /// The auto-pause: a listed hook whose runtime code moved is refused on every door.
    function test_ListedHook_CodeMoved_IsPaused() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        hub.allowHook(h, true);
        vm.etch(h, hex"6000");
        assertTrue(hub.hookPaused(h), "premise: pin no longer matches");
        _refused9(_pool(h), h);
    }

    /// Registration is admission: addV4 with an unlisted swap-running hook lists and pins it
    /// (one operator step where there were two); a revoked hook is not re-admitted that way.
    function test_AddV4_AdmitsAndPinsTheHookItRegisters() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        assertFalse(hub.isHookLive(h), "premise: not listed");
        hub.setRoles(address(router), address(0xBEEF), address(this));
        hub.addV4(c0, c1, FEE, TS, h);
        assertTrue(hub.isHookLive(h), "listed and pinned by the registration");
        address r = forge_.deploy(AFTER_SWAP, BEFORE_SWAP | SWAP_DELTAS);
        hub.allowHook(r, true); hub.allowHook(r, false);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint8(8)));
        hub.addV4(c0, c1, 500, 10, r);
    }

    /// The bound the explicit door gives a caller who routes through a hook nobody vetted.
    /// The singleton fills at a fraction of a 1:1 price (what a hostile hook could do to the
    /// fill); the caller attests the in-frame promise and sets a minimum. Then:
    ///   - a settlement never delivers below the caller's minimum, nor below the gate's
    ///     share (80 %) of the in-frame promise;
    ///   - a refusal happens only where the fill sits below the caller's minimum or below the
    ///     Iron-Law floor's base share (96 %) of what the caller attested. The floor's
    ///     constant is restated here from the paper, not read from the code.
    /// 256 runs locally; the campaign figure comes from the CI box.
    function testFuzz_UnlistedHook_HostileFill_BoundedByGateAndMinOut(uint16 rateBps, uint96 minSeed) public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        bytes32 pid = _pool(h);
        uint256 rate = bound(uint256(rateBps), 0, 1200);          // 0 .. 120 % of a 1:1 fill
        mgr.setRate(pid, rate);
        uint256 amt = 1e18;
        uint256 promised = BPC.v4LegOut(address(mgr), pid, amt, FEE, TS, true);
        uint256 minOut = bound(uint256(minSeed), 1, amt);
        Route memory r = _route(pid, h, amt);
        r.hops[0].expectedOut = promised; r.hops[0].legs[0].expectedOut = promised; r.totalOut = promised; r.singleOut = promised;
        // what the singleton will hand over: the input net of the protocol fee, at the rate
        uint256 fill = (amt - amt * 28 / 10_000) * rate / 1000;
        vm.prank(user);
        try router.swapExactIn(r, amt, minOut, user, block.timestamp + 1) returns (uint256 got) {
            assertGe(got, minOut, "a settlement never delivers below the caller's minimum");
            assertGe(got + 1, promised * 8 / 10, "nor below the gate's share of the in-frame promise");
        } catch {
            assertTrue(fill < minOut || fill < promised * 96 / 100 + 1,
                "a refusal only where the minimum or the floor's base share of the attestation would have been missed");
        }
    }

    // ── Relations around the rule ──────────────────────────────────────────

    /// The whole decision table, fuzzed over the 14 permission bits and the four states a
    /// hook can be in. The verdict restated here, from the rule and not from the code:
    ///   delta bit set              -> refused, whatever the state;
    ///   no swap bit                -> settles, whatever the state;
    ///   swap bit, never listed     -> settles (the caller's choice on the explicit door);
    ///   swap bit, listed           -> settles;
    ///   swap bit, revoked          -> refused;
    ///   swap bit, listed, moved    -> refused.
    function testFuzz_Verdict_DecisionTable(uint16 bitsSeed, uint8 stateSeed) public {
        uint256 bits = uint256(bitsSeed) & 0x3FFF;
        uint8 state = stateSeed % 4;                         // 0 unknown, 1 listed, 2 revoked, 3 listed then moved
        address h = address(uint160((uint256(0xD00D) << 20) | bits));
        vm.etch(h, hex"6001");                               // a hook with code, so a pin means something
        if (state == 1 || state == 3) hub.allowHook(h, true);
        if (state == 2) { hub.allowHook(h, true); hub.allowHook(h, false); }
        if (state == 3) vm.etch(h, hex"6002");
        bool deltaBit = (bits & SWAP_DELTAS) != 0;
        bool runs = (bits & SWAP_BITS) != 0;
        bool expectRefusal = deltaBit || (runs && (state == 2 || state == 3));
        bytes32 pid = _pool(h);
        uint256 amt = 1e18;
        Route memory r = _route(pid, h, amt);
        vm.prank(user);
        if (expectRefusal) {
            vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(9)));
            router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        } else {
            assertGt(router.swapExactIn(r, amt, 1, user, block.timestamp + 1), 9e17, "settles");
        }
    }

    /// Metamorphic: two pools that differ only in the hook, one listed and one nobody listed,
    /// deliver the same amount for the same fill. The list changes routability, never price.
    function test_Metamorphic_ListedAndUnlistedHooksDeliverAlike() public {
        address hl = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS); hub.allowHook(hl, true);
        address hu = forge_.deploy(AFTER_SWAP, SWAP_DELTAS);
        uint256 a = _swap(_pool(hl), hl); uint256 b = _swap(_pool(hu), hu);
        assertEq(a, b, "same fill, same delivery, list or no list");
    }

    /// The automatic door never proposes a hook that is not live: a row registered under a
    /// hook (admitted by the registration) leaves every registry read once the hook is
    /// revoked, while the explicit door refuses the same hook.
    function test_AutomaticDoor_ExcludesTheRevokedHooksRow() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        hub.setRoles(address(router), address(0xBEEF), address(this));
        hub.addV4(c0, c1, FEE, TS, h);
        assertTrue(_rowVisible(h), "the row is read while the hook is live");
        hub.allowHook(h, false);
        assertFalse(_rowVisible(h), "the row leaves every registry read once revoked");
        _refused9(_pool(h), h);
    }

    function _rowVisible(address h) internal view returns (bool) {
        PoolInfo[] memory rows = hub.getActivePools(c0, c1);
        for (uint256 i; i < rows.length; ++i) if (rows[i].hooks == h) return true;
        return false;
    }

    /// After renunciation: registering still admits (admission survives), revocation dies,
    /// and a hook revoked before renunciation stays refused for ever, at both doors.
    function test_AfterRenounce_RegistrationAdmits_RevocationDies_RevokedStays() public {
        address gone = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        hub.allowHook(gone, true); hub.allowHook(gone, false);
        hub.setRoles(address(router), address(0xBEEF), address(this));
        hub.renounceControl();
        address fresh = forge_.deploy(AFTER_SWAP, BEFORE_SWAP | SWAP_DELTAS);
        hub.addV4(c0, c1, FEE, TS, fresh);
        assertTrue(hub.isHookLive(fresh), "registration still admits after renunciation");
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint8(1)));
        hub.allowHook(fresh, false);
        assertTrue(hub.hookPaused(gone), "revoked before renunciation: still refused");
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint8(8)));
        hub.addV4(c0, c1, 500, 10, gone);
        _refused9(_pool(gone), gone);
    }

    /// The route-shape rule is untouched by admission: a hookless leg after a hooked one is
    /// refused (RouterE(3)) whether the hook is listed or not, and the canonical order settles.
    function test_Ordering_AppliesToUnlistedHooksToo() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        bytes32 pidH = _pool(h); bytes32 pidP = _pool(address(0));
        uint256 amt = 1e18;
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({ pool: address(uint160(uint256(pidH))), hooks: h, kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS, zeroForOne: true, stable: false, amountIn: amt / 2, expectedOut: 0, auxId: bytes32(uint256(uint160(c1))) });
        legs[1] = Leg({ pool: address(uint160(uint256(pidP))), hooks: address(0), kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS, zeroForOne: true, stable: false, amountIn: amt / 2, expectedOut: 0, auxId: bytes32(uint256(uint160(c1))) });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: c0, tokenOut: c1, amountIn: amt, expectedOut: 0, legs: legs });
        Route memory bad = Route({ hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false });
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(bad, amt, 1, user, block.timestamp + 1);
        (legs[0], legs[1]) = (legs[1], legs[0]);
        vm.prank(user);
        assertGt(router.swapExactIn(bad, amt, 1, user, block.timestamp + 1), 9e17, "hookless first, hooked last: settles");
    }

    /// Preview and delivery agree on a pool under a hook nobody listed: the Quoter never
    /// read the list, and the exact preview equals what the Router delivers.
    function test_Quoter_PricesAnUnlistedHookPool_AndMatchesDelivery() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        bytes32 pid = _pool(h);
        uint256 amt = 1e18;
        FixedPlanSolver solver = new FixedPlanSolver();
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        solver.setPlan(_route(pid, h, amt));
        (, uint256 exactOut) = quoter.previewPlanExact(c0, c1, amt);
        assertGt(exactOut, 9e17, "priced");
        assertEq(_swap(pid, h), exactOut, "the exact preview is the delivery");
    }
}
