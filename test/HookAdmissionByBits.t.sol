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
//  step; pools under hooks that run in the swap (bit 7 or 6) still require the
//  allow-list and the codehash pin; delta-returning hooks are refused regardless.
//  Red first: the settle test fails on the tree that gated every hook.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PricedV4Manager} from "./RouteIntegrityV4.t.sol";

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

    /// The antagonist: a beforeSwap hook that is not allow-listed is refused, as before.
    function test_BeforeSwapHook_Unlisted_IsRefused() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        assertTrue(BPC.hookRunsInSwap(h), "premise: runs in the swap");
        _refused9(_pool(h), h);
    }

    /// Its twin: an afterSwap-only hook, not allow-listed, is refused too.
    function test_AfterSwapHook_Unlisted_IsRefused() public {
        address h = forge_.deploy(AFTER_SWAP, BEFORE_SWAP | SWAP_DELTAS);
        _refused9(_pool(h), h);
    }

    /// Allow-listing a swap-running hook admits it: the operator step still works where it matters.
    function test_BeforeSwapHook_Listed_Settles() public {
        address h = forge_.deploy(BEFORE_SWAP, SWAP_DELTAS);
        hub.allowHook(h, true);
        assertGt(_swap(_pool(h), h), 9e17, "settles once admitted");
    }

    /// A delta-returning hook is refused even when allow-listed: the bits win over the list.
    function test_DeltaHook_Listed_IsRefused() public {
        address h = forge_.deploy(1 << 2, 0);
        hub.allowHook(h, true);
        _refused9(_pool(h), h);
    }

    /// The predicate itself, over the 14-bit space: runs-in-swap iff a swap bit is set.
    function testFuzz_HookRunsInSwap_IffASwapBitIsSet(uint16 bits) public pure {
        bits = uint16(bits & 0x3FFF);
        address h = address(uint160(uint256(bits) | (uint256(0xABCD) << 16)));
        assertEq(BPC.hookRunsInSwap(h), (bits & SWAP_BITS) != 0);
    }
}
