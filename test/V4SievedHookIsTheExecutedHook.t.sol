// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

/// @dev Minimal ERC20, matching the shape the other V4 fixtures use. Kept local for the same
///      reason they keep theirs local: the Router only needs balanceOf/transfer/transferFrom.
contract MockERC20Simple {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) public returns (bool) {
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address from, address to, uint256 amt) public returns (bool) {
        balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
}

interface IERC20Min { function transfer(address, uint256) external returns (bool); }

/// @dev The manager the suite was missing. Every existing V4 mock declares
///      `swap(V4PoolKey calldata, SwapParams calldata p, bytes calldata)` with the key
///      parameter UNNAMED, and therefore throws it away. That is why no test in this
///      repository has ever observed which hook the Router actually swaps against.
contract KeyRecordingV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    address  public lastHooks;
    address  public lastCurrency0;
    address  public lastCurrency1;
    uint24   public lastFee;
    int24    public lastTickSpacing;
    uint256  public unlockCount;
    uint256  public swapCount;

    function _pack(int128 d0, int128 d1) internal pure returns (int256) {
        return int256((uint256(uint128(d0)) << 128) | uint256(uint128(d1)));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockCount++;
        (bool ok, bytes memory ret) =
            msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(ok, "unlock: callback reverted");
        return ret;
    }

    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata)
        external returns (int256)
    {
        swapCount++;
        lastHooks       = key.hooks;
        lastCurrency0   = key.currency0;
        lastCurrency1   = key.currency1;
        lastFee         = key.fee;
        lastTickSpacing = key.tickSpacing;
        uint256 amt = uint256(-p.amountSpecified);
        int128 owe  = -int128(int256(amt));
        int128 recv =  int128(int256(amt));
        return p.zeroForOne ? _pack(owe, recv) : _pack(recv, owe);
    }

    function sync(address) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(address currency, address to, uint256 amount) external {
        IERC20Min(currency).transfer(to, amount);
    }
}

/// @notice The keystone the hook argument stands on, and which nothing was asserting.
///
///         This project's defence against a malicious Uniswap-V4 hook does NOT rest on the
///         codehash pin - that pin commits to a proxy's dispatcher while the logic lives in the
///         implementation, which is the defect external researchers have reported twice. It
///         rests on the permission bits, which live in the hook's ADDRESS and are immutable:
///         `Core.hookAltersDeltas` masks `uint160(hook) & 0x3FFF` against
///         `BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA`, and the Router refuses at
///         `_execV4Amt` before any manager contact.
///
///         That argument has one joint, and the joint had no evidence. The sieve reads
///         `leg.hooks`; the swap executes `key.hooks`. Between them sits one assignment. If it
///         ever named a different value, every refusal upstream would still fire, every existing
///         test would still pass, and the contract would swap against a hook nobody sieved -
///         which is, exactly, the proxy defect one level up: verify one object, execute another.
///
///         Nothing observed that joint before this file. The census pin
///         (`HookSieveCensusPin.t.sol`) is lexical: it counts substrings and byte offsets, so
///         `if (false && BPC.hookAltersDeltas(leg.hooks))` keeps its count, its ordering and its
///         green. And every V4 mock in the suite discards the pool key. The mutant this file
///         exists for is `src/BlazePhoenixRouter.sol`, `hooks: leg.hooks` -> `hooks: address(0)`,
///         and before this test it survived the entire suite.
contract V4SievedHookIsTheExecutedHookTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    KeyRecordingV4Manager mgr;
    MockERC20Simple A;
    MockERC20Simple B;

    /// @dev Bits 2 and 3 clear, so `hookAltersDeltas` is false and the sieve admits it. Any
    ///      value with those bits set would be refused before the key is ever built, which is
    ///      the OTHER test - this one needs a hook that gets all the way through.
    address constant HOOK_CLEAN = address(uint160(0x1000));

    address treasury1 = makeAddr("t1");
    address treasury2 = makeAddr("t2");

    function setUp() public {
        mgr = new KeyRecordingV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.setRoles(address(this), address(this), address(this));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);
        A = new MockERC20Simple();
        B = new MockERC20Simple();
        // A codeless hook: its live codehash is zero and the pin records zero, so `isHookLive`
        // is satisfied without deploying anything. The sieve under test is the address-bit one.
        hub.allowHook(HOOK_CLEAN, true);
    }

    function _v4Route(uint256 amt, address hooks) internal view returns (Route memory r) {
        Leg memory leg = Leg({
            pool: address(uint160(uint256(keccak256("pid")))),
            hooks: hooks, kind: 4, fee: 500, tickSpacing: 10,
            zeroForOne: address(A) < address(B), stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(uint256(uint160(address(B))))
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B),
                       amountIn: amt, expectedOut: 0, legs: legs});
        r.hops = hops;
    }

    /// @notice The hook the sieve admitted is the hook the pool key carries into the swap.
    function test_TheSievedHookIsTheOneTheSwapExecutesAgainst() public {
        uint256 amt = 1e18;
        A.mint(address(this), amt);
        B.mint(address(mgr), amt);

        uint256 delivered =
            router.swapExactIn(_v4Route(amt, HOOK_CLEAN), amt, 1, address(this), block.timestamp + 1);

        // Non-vacuity first: a swap that never happened would satisfy every assertion below
        // by leaving the recorder at its zero values, and the zero value of `lastHooks` is
        // exactly the mutant's answer.
        assertGt(delivered, 0, "the V4 swap must actually settle, or this test asserts nothing");
        assertEq(mgr.unlockCount(), 1, "exactly one unlock");
        assertEq(mgr.swapCount(), 1, "exactly one swap");

        assertEq(mgr.lastHooks(), HOOK_CLEAN,
            "the pool key must carry the hook the sieve inspected, not some other value");

        // The rest of the key, pinned in the same breath: a wrong currency ordering or a
        // dropped fee tier selects a DIFFERENT pool, which is the same defect wearing a
        // different field.
        (address c0, address c1) = BPC.sortTokens(address(A), address(B));
        assertEq(mgr.lastCurrency0(), c0, "currency0 must be the sorted low token");
        assertEq(mgr.lastCurrency1(), c1, "currency1 must be the sorted high token");
        assertEq(uint256(mgr.lastFee()), 500, "the key must carry the leg's fee tier");
        assertEq(int256(mgr.lastTickSpacing()), int256(10), "the key must carry the leg's spacing");
    }

    /// @notice And the negative arm, so the positive one cannot pass by accident: a hook WITH
    ///         a delta bit is refused, and refused BEFORE the manager is ever contacted. The
    ///         counter is what turns "refused" into "refused before unlocking" - without it,
    ///         that clause is inference.
    function test_ADeltaHookIsRefusedBeforeTheManagerIsEverContacted() public {
        uint256 amt = 1e18;
        A.mint(address(this), amt);
        address hookDelta = address(uint160(1 << 2));   // BEFORE_SWAP_RETURNS_DELTA
        hub.allowHook(hookDelta, true);

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(9)));
        router.swapExactIn(_v4Route(amt, hookDelta), amt, 1, address(this), block.timestamp + 1);

        assertEq(mgr.unlockCount(), 0, "the refusal must land before the manager is unlocked");
        assertEq(mgr.swapCount(), 0, "and certainly before any swap");
    }

    /// @notice The second delta bit, which the mask names and only a unit test has ever driven
    ///         through this door.
    function test_TheOtherDeltaBitIsRefusedToo() public {
        uint256 amt = 1e18;
        A.mint(address(this), amt);
        address hookDelta = address(uint160(1 << 3));   // AFTER_SWAP_RETURNS_DELTA
        hub.allowHook(hookDelta, true);

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(9)));
        router.swapExactIn(_v4Route(amt, hookDelta), amt, 1, address(this), block.timestamp + 1);

        assertEq(mgr.unlockCount(), 0, "refused before the manager is unlocked");
    }
}
