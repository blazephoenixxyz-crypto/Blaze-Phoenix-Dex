// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The Router's callback surfaces in an EIP-7702-delegated frame (2026-10-20).
//
//  The SELF guard (test/Fix1020SelfGuard.t.sol) closes the four doors: `_execute`
//  reverts RouterE(18) when the code runs at an address that is not the Router.
//  It does not run on the callback surfaces, which a delegated EOA also exposes:
//  unlockCallback (V4), the V3 swap callback and a V2-shaped callback (both land
//  in `fallback`), `receive` and `fallback` with value. Each is called here by a
//  stranger at the delegated EOA, outside any swap, and must fail closed with the
//  EOA's balances (both tokens and ETH) and the stranger's unchanged.
//
//  Every test pins the exact revert code of the guard it watches, so deleting
//  that guard turns it red (mutants in .github/scripts/mutants.py, "cb-1020").
//
//  forge test --match-path test/Fix1020DelegatedCallbacks.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4HookedManager} from "./mocks/MockV4HookedManager.sol";

contract Fix1020DelegatedCallbacksTest is Test {
    uint24 constant FEE = 3000;
    int24  constant TS = 60;
    uint256 constant PRIOR = 50_000e18;   // the EOA's own tokens
    uint256 constant PRIOR_ETH = 10 ether; // and ETH
    uint256 constant AMT = 1_000e18;

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockV4HookedManager mgr;
    MockERC20 tA;
    MockERC20 tB;
    address victim;
    uint256 victimPk;
    address attacker = makeAddr("attacker");

    function setUp() public {
        mgr = new MockV4HookedManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), makeAddr("t1"), makeAddr("t2"));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        (address c0, address c1) = BPC.sortTokens(address(tA), address(tB));
        bytes32 pid = BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(60), 60, FEE);
        mgr.addPosition(pid, 0, 120, TS, 1e25);
        tA.mint(address(mgr), 1e24);
        tB.mint(address(mgr), 1e24);

        (victim, victimPk) = makeAddrAndKey("victim");
        vm.setEvmVersion("prague");
        vm.etch(victim, abi.encodePacked(hex"ef0100", address(router)));
        assertEq(address(BlazePhoenixRouter(payable(victim)).hub()), address(hub),
            "the delegated EOA does not run the Router code");
        tA.mint(victim, PRIOR);
        tB.mint(victim, PRIOR);
        vm.deal(victim, PRIOR_ETH);
        vm.deal(attacker, 1 ether);
    }

    function _e(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// A well-formed unlockCallback payload for the A/B pool (key, zeroForOne, amount, hookData).
    function _validUnlockData() private view returns (bytes memory) {
        (address c0, address c1) = BPC.sortTokens(address(tA), address(tB));
        return abi.encode(c0, c1, FEE, TS, address(0), true, AMT, bytes(""));
    }

    /// Call `victim` as `from` with `value` and `data`; it must revert with exactly `want`
    /// and leave every balance of the EOA and of the caller where it was.
    function _failsClosed(address from, uint256 value, bytes memory data, bytes memory want) private {
        uint256 vA = tA.balanceOf(victim);
        uint256 vB = tB.balanceOf(victim);
        uint256 vE = victim.balance;
        uint256 fA = tA.balanceOf(from);
        uint256 fB = tB.balanceOf(from);
        uint256 fE = from.balance;
        // hypothesis: the EOA holds something, or "unchanged" proves nothing
        assertGt(vA, 0, "hyp: the EOA's tokenA seed is zero");
        assertGt(vB, 0, "hyp: the EOA's tokenB seed is zero");
        assertGt(vE, 0, "hyp: the EOA's ETH seed is zero");
        vm.prank(from);
        (bool ok, bytes memory ret) = victim.call{value: value}(data);
        assertFalse(ok, "the delegated EOA accepted the call");
        assertEq(ret, want, "refused, but not by the guard under test");
        assertEq(tA.balanceOf(victim), vA, "the EOA's tokenA moved");
        assertEq(tB.balanceOf(victim), vB, "the EOA's tokenB moved");
        assertEq(victim.balance, vE, "the EOA's ETH moved");
        assertEq(tA.balanceOf(from), fA, "the caller's tokenA moved");
        assertEq(tB.balanceOf(from), fB, "the caller's tokenB moved");
        assertEq(from.balance, fE, "the caller's ETH moved");
    }

    /// unlockCallback from a stranger: the manager check refuses it before any decode.
    /// Red iff `msg.sender != mgr` is gone (the garbage payload then dies in abi.decode).
    function test_DCB_1020_UnlockCallbackFromAStrangerIsRefusedRouterE6() public {
        _failsClosed(attacker, 0,
            abi.encodeWithSelector(BlazePhoenixRouter.unlockCallback.selector, hex"deadbeef"), _e(6));
    }

    /// unlockCallback from the manager itself, outside a swap the EOA started: no pending
    /// V4 tokens in transient storage, so the second guard refuses it before the EOA pays.
    /// Red iff the `tIn == 0 || tOut == 0` check is gone.
    function test_DCB_1020_UnlockCallbackFromTheManagerOutsideASwapIsRefusedRouterE6() public {
        _failsClosed(address(mgr), 0,
            abi.encodeWithSelector(BlazePhoenixRouter.unlockCallback.selector, _validUnlockData()), _e(6));
    }

    /// The V3 swap callback (lands in fallback) from a stranger: no expected pool in transient
    /// storage. Red iff the pool check in `_v3Callback` is gone.
    function test_DCB_1020_V3CallbackFromAStrangerIsRefusedRouterE6() public {
        _failsClosed(attacker, 0,
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", int256(AMT), -int256(AMT), ""),
            _e(6));
    }

    /// A V2-shaped callback: the Router has no uniswapV2Call, so it lands in fallback and
    /// reaches the same pool check. Red iff that check is gone.
    function test_DCB_1020_V2CallbackShapeIsRefusedRouterE6() public {
        _failsClosed(attacker, 0,
            abi.encodeWithSignature("uniswapV2Call(address,uint256,uint256,bytes)", attacker, AMT, uint256(0), hex"01"),
            _e(6));
    }

    /// fallback with value: refused before anything else. Red iff the msg.value check is gone.
    function test_DCB_1020_FallbackWithValueIsRefusedRouterE3() public {
        _failsClosed(attacker, 1 ether,
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", int256(AMT), -int256(AMT), ""),
            _e(3));
    }

    /// Bare ETH: receive() opens only to the one sender a swap names. Red iff that check is gone.
    function test_DCB_1020_BareEthIsRefusedRouterE3() public {
        _failsClosed(attacker, 1 ether, "", _e(3));
    }
}
