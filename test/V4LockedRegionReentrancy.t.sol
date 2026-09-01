// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// V4-LOCKED-REGION REENTRANCY — the property RouterAdversarialV4FromV1's
// `invariant_reentrancyBlocked` advertised but could never test.
//
// WHY THAT INVARIANT WAS DEAD. Its sentinel flipped only if a nested
// `router.swapExactIn(EMPTY_ROUTE, 1, 1, ...)` RETURNED. That call can never
// return on any src: with the lock it reverts RouterE(7); without the lock it
// reverts RouterE(3) on the empty-route guard. So the sentinel was pinned to
// its safe value whether or not the lock existed, and — measured on the box —
// the probe never even fired across a 2500-call campaign (a blocked reentry
// forces the outer swap to revert, and that rollback erases the record).
//
// THIS TEST fixes both defects deterministically:
//   * the outer V4 swap SETTLES (so the recorded signal survives),
//   * the nested reentry carries a REAL route and its EXACT revert code is
//     recorded and asserted to be the LOCK, RouterE(7) — not a sibling guard.
// With the lock present it is green (proven). Remove the lock and the nested
// call reverts RouterE(3) (empty route) or settles outright, so the code-7
// assertion turns red — the discrimination the old sentinel never had.
//
// forge test --match-contract V4LockedRegionReentrancy -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

interface IERC20Min {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract MockERC20Adv {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) public returns (bool) {
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address from, address to, uint256 amt) public returns (bool) {
        balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
}

/// @dev Honest-settling hostile V4 manager that, during swap() (inside the
///      Router's locked region), re-enters swapExactIn with a REAL route and
///      RECORDS the exact revert code — the corrected sentinel.
contract RecordingV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    BlazePhoenixRouter public router;
    bytes   public nestedCalldata;
    bool    public armed;

    bool    public probeFired;
    bool    public nestedReverted;
    uint16  public nestedCode;

    function setRouter(BlazePhoenixRouter r) external { router = r; }
    function armReentry(bytes calldata cd) external { nestedCalldata = cd; armed = true; }

    function _pack(int128 d0, int128 d1) internal pure returns (int256) {
        return int256((uint256(uint128(d0)) << 128) | uint256(uint128(d1)));
    }
    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(ok, "unlock: callback reverted");
        return ret;
    }
    function swap(V4PoolKey calldata, SwapParams calldata p, bytes calldata) external returns (int256) {
        if (armed && address(router) != address(0)) {
            armed = false; probeFired = true;
            (bool ok, bytes memory ret) = address(router).call(nestedCalldata);
            nestedReverted = !ok;
            if (!ok && ret.length >= 0x24) { uint16 c; assembly { c := mload(add(ret, 0x24)) } nestedCode = c; }
        }
        uint256 amt = uint256(-p.amountSpecified);
        int128 owe = -int128(int256(amt));
        int128 recv = int128(int256(amt));
        return p.zeroForOne ? _pack(owe, recv) : _pack(recv, owe);
    }
    function sync(address) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(address currency, address to, uint256 amount) external {
        IERC20Min(currency).transfer(to, amount);
    }
}

contract V4LockedRegionReentrancyTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20Adv A;
    MockERC20Adv B;
    RecordingV4Manager mgr;

    address treasury1 = makeAddr("t1");
    address treasury2 = makeAddr("t2");

    function setUp() public {
        mgr = new RecordingV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr)); // V4 manager = the recording one
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);
        A = new MockERC20Adv();
        B = new MockERC20Adv();
        mgr.setRouter(router);
    }

    function _v4Route(uint256 amt) internal view returns (Route memory r) {
        bool zfo = address(A) < address(B);
        Leg memory leg = Leg({
            pool: address(uint160(uint256(keccak256("pid")))),
            hooks: address(0), kind: 4, fee: 500, tickSpacing: 10,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: 0,
            auxId: bytes32(uint256(uint160(address(B))))
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: amt, expectedOut: 0, legs: legs});
        r.hops = hops;
    }

    /// The nested reentry (a REAL V4 route, so it would genuinely settle if the
    /// lock were gone) must be rejected by EXACTLY the reentrancy lock RouterE(7).
    function test_NestedReentryDuringV4Settle_BlockedByExactLockCode() public {
        uint256 amt = 1e18;
        A.mint(address(this), amt);
        B.mint(address(mgr), amt); // honest 1:1 liquidity for the outer fill

        // Arm the reentry the manager will attempt mid-settle: a REAL V4 route,
        // minOut = 1 (a zero minOut would trip RouterE(10) before the lock).
        Route memory nested = _v4Route(amt);
        bytes memory cd = abi.encodeWithSelector(
            router.swapExactIn.selector, nested, amt, uint256(1), address(mgr), type(uint256).max);
        mgr.armReentry(cd);

        uint256 delivered = router.swapExactIn(_v4Route(amt), amt, 1, address(this), block.timestamp + 1);

        assertGt(delivered, 0, "the outer V4 swap must settle so the recorded signal survives");
        assertTrue(mgr.probeFired(), "non-vacuity: the reentry probe must have fired");
        assertTrue(mgr.nestedReverted(), "the nested reentry must have reverted");
        assertEq(uint256(mgr.nestedCode()), 7,
            "the nested reentry must be blocked by the LOCK (RouterE(7)), not a sibling guard");
    }
}
