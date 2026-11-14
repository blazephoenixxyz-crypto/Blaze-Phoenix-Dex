// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  EVERY PREDICATE OF THE SEAT DOOR REFUSES ALONE.
//
//  `claimV4` is permissionless: anyone may name a V4 pool and ask for a seat.
//  It admits the pool only if all of these hold:
//    (1) one side is a routable bridge                    Hub.claimV4, anchor gate
//    (2) the pool id is the hookless one (hooks == 0)     Hub.claimV4, pool id
//    (3) the pool has a price and liquidity               Hub.claimV4, `sp == 0 || liq == 0`
//    (4) its fee resolves to a quotable value             Hub.claimV4, INV-20
//  On a full pair, `_canInsert` also requires
//    (5) a measured depth                                 Hub._canInsert, `newDepth == 0`
//    (6) the quarter margin over the worst incumbent      Hub._canInsert, `ks.length < MAX_SLOTS`
//  The swap door (`recordSwap`) shares (5) and (6).
//
//  If no test depends on a predicate, deleting it turns nothing red. Each
//  world below differs from an admitted control in one coordinate, so the
//  refusal belongs to that predicate and to no other.
//
//  Matrix: the predicate, its world and control, and the mutant it kills.
//  Each mutant is registered in .github/scripts/mutants.py and run alone.
//    (1) world: no bridge on either side; control: the bridge added.
//        Mutant: the line deleted.                                    [MT6-4]
//    (2) world: only a hooked pool is live (all 14 permission bits
//        set), claimed by its own hook; control: the hookless pool
//        live. Mutant: hooks = msg.sender.                            [MT6-5]
//    (3) liq world: a price with zero liquidity; control: liquidity
//        1e18. Mutant: the `liq == 0` arm dropped.                    [MT6-6]
//    (3) sp world: ConditionAdequacyHub.test_L763.
//        Mutant: the `sp == 0` arm dropped.                           [MT6-7]
//    (4) world: HubRefusalsObserved.test_ClaimV4_UnresolvableDynamicFeeIsRefused.
//        Mutant: the line deleted.                                    [MT6-8]
//    (6) world: HardeningA4.test_ClaimV4_FullPair_ThinClaimBelowMarginDoesNotEvict.
//        Mutant: `<` -> `<=`.                                         [MT6-9]
//    (5) world: a full pair of dead rows, newcomer at depth 0;
//        control: depth 1 wei. Mutant: the line deleted.              [MT6-10]
//
//  Oracle: no Hub arithmetic is reproduced. Each world's verdict is the
//  door's own refusal (HubE(9) by selector and code, or no seat), and the
//  control shows the same world admitted.
//
//  Green at cb1d7d9.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {MockV4DeriveManager} from "./V4LearnedCodeSuppressesGrid.t.sol";

contract SeatDoorPredicatesRefuseAloneTest is Test {
    BlazePhoenixHub hub;
    MockV4DeriveManager mgr;

    // Sorted bare-address tokens, the style of HardeningA4 and ConditionAdequacyHub.
    address constant BRIDGE = address(0x1111);
    address constant TOKEN  = address(0x2222);
    address constant CLAIMER = address(0xCA11);
    // A hook address with all 14 permission bits set: the hook that could do the most to a
    // swap through its pool.
    address constant HOOK = address((uint160(0xBAD) << 14) | 0x3FFF);
    uint24 constant FEE = 3000;
    int24 constant TS = 60;

    /// The Hub's router role is this contract; answer `weth()` as the other V4 suites do.
    function weth() external pure returns (address) { return address(0xEEE0); }

    function setUp() public {
        mgr = new MockV4DeriveManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.setRoles(address(this), address(this), address(this));
    }

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    function _pid(address hooks) private pure returns (bytes32) {
        (address s0, address s1) = BPC.sortTokens(BRIDGE, TOKEN);
        return BPC.computeV4PoolId(s0, s1, FEE, TS, hooks);
    }

    /// The pool manager's state for `pid`: slot0 (sqrtPriceX96 only, so lpFee = protocolFee = 0)
    /// at the pool's base slot, liquidity at base + 3 (StateLibrary layout).
    function _plant(bytes32 pid, uint160 sp, uint128 liq) private {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(sp)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    function _seatOf(bytes32 pid) private view returns (address) {
        return hub.getPool(hub.keyOf(address(uint160(uint256(pid))), BRIDGE, TOKEN));
    }

    // ─── claimV4: the control and one world per predicate ────────────────────

    /// The control: bridged, hookless, priced, liquid, static fee. Admitted.
    function test_SeatDoor_Control_ALiveHooklessBridgedPoolIsSeated() public {
        hub.addBridge(BRIDGE);
        _plant(_pid(address(0)), uint160(BPC.Q96), 1e18);
        vm.prank(CLAIMER);
        hub.claimV4(BRIDGE, TOKEN, FEE, TS);
        assertEq(_seatOf(_pid(address(0))), address(uint160(uint256(_pid(address(0))))), "control: not seated");
    }

    /// (1) The control's pool, with no bridge on either side.
    function test_SeatDoor_NoRoutableBridge_RefusedWithNine() public {
        _plant(_pid(address(0)), uint160(BPC.Q96), 1e18);
        vm.prank(CLAIMER);
        vm.expectRevert(_err(9));
        hub.claimV4(BRIDGE, TOKEN, FEE, TS);
    }

    /// (2) The same pool behind a hook with every permission, claimed by that hook. The hookless
    /// id has no pool, and the door reads only that id.
    function test_SeatDoor_OnlyAHookedPoolIsLive_RefusedWithNine() public {
        hub.addBridge(BRIDGE);
        _plant(_pid(HOOK), uint160(BPC.Q96), 1e18);
        vm.prank(HOOK);
        vm.expectRevert(_err(9));
        hub.claimV4(BRIDGE, TOKEN, FEE, TS);
    }

    /// (3) The control's pool with a price and no liquidity.
    function test_SeatDoor_PriceWithoutLiquidity_RefusedWithNine() public {
        hub.addBridge(BRIDGE);
        _plant(_pid(address(0)), uint160(BPC.Q96), 0);
        vm.prank(CLAIMER);
        vm.expectRevert(_err(9));
        hub.claimV4(BRIDGE, TOKEN, FEE, TS);
    }

    // ─── _canInsert: depth 0 on a full pair (swap door) ─────────────────────

    MockERC20 A;
    MockERC20 C;

    function _v2(uint256 r) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(A), address(C));
        A.mint(address(p), r);
        C.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
    }

    /// 16 seeded rows on (A, C), unbridged, then 32 decay steps of silence: every row is dead
    /// (score 0), so any newcomer with a measured depth clears the margin over them.
    function _fullPairOfDeadRows() private {
        A = new MockERC20("A", "A");
        C = new MockERC20("C", "C");
        address[] memory inc = new address[](16);
        for (uint256 i; i < 16; ++i) {
            inc[i] = address(_v2(1e18));
            hub.seedPool(inc[i], BPC.KIND_V2, 30, address(0), address(A), address(C));
        }
        vm.warp(block.timestamp + 32 * 24_576);
        for (uint256 i; i < 16; ++i) {
            assertEq(hub.getPsi(inc[i], address(A), address(C)), 0, "isolation: the row is dead");
        }
    }

    /// A derived newcomer offered to the full pair by one swap, at the router's depth.
    function _offer(uint256 depthWad) private returns (address seat, address pool) {
        pool = address(_v2(1e18));
        Origin.wire(hub, pool, address(A), address(C), BPC.KIND_V2, 30);
        hub.recordSwap(pool, BPC.KIND_V2, 30, address(0), address(A), address(C), 1, 1, depthWad);
        seat = hub.getPool(hub.keyOf(pool, address(A), address(C)));
    }

    /// (5) Depth 0 is no measurement. It is not the smallest one, so it takes no seat, even
    /// over rows that score 0.
    function test_SeatDoor_ZeroDepthNewcomerOnAFullPair_NotSeated() public {
        _fullPairOfDeadRows();
        (address seat, ) = _offer(0);
        assertEq(seat, address(0), "a newcomer with no measured depth was seated");
    }

    /// (5) The control: the same world, depth 1 wei (bucket 0, score 1 > 0 + 0). Seated.
    function test_SeatDoor_Control_OneWeiNewcomerOnAFullPair_Seated() public {
        _fullPairOfDeadRows();
        (address seat, address pool) = _offer(1);
        assertEq(seat, pool, "control: a measured newcomer over dead rows was refused");
    }
}
