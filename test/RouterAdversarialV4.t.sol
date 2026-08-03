// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER ADVERSARIAL INVARIANTS — hostile V4 PoolManager, offline.
//
//  The V4 settle/take flow moves real funds through unlockCallback and is the
//  least-covered execution path offline (no other offline suite stands up a
//  SETTLING V4 manager). Here a hostile manager returns an attacker-fuzzed
//  BalanceDelta, and the caller fuzzes the leg's hook address and counterpart
//  currency. The Router's own defences must hold regardless:
//
//    * hookAltersDeltas — a hook whose address carries the delta-return
//      permission bits must be refused (RouterE 9) before any unlock.
//    * delta-sign guard — owedDelta must be <= 0 and receivedDelta >= 0, else
//      RouterE 8: the manager cannot make the Router receive-and-still-owe.
//    * over-take — a manager that reports more output than it holds simply
//      reverts on take(); nothing is minted.
//    * holds-nothing / conservation across the whole random sequence.
//
//    forge test --match-contract RouterAdversarialV4 -vv
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";
import { Route, Hop, Leg } from "../src/BlazePhoenixCore.sol";
import { MockERC20Exec } from "./RouterExecGuards.t.sol";

interface IERC20Min {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev A hostile V4 PoolManager that actually settles. Structs mirror the
///      Router's IV4PoolManager by field layout (ABI-compatible). Honest by
///      default (1:1 fill); armable to return an arbitrary packed delta so the
///      Router's sign guard and take() bound are exercised.
contract HostileV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    bool    public useOverride;
    int128  public d0Ov;
    int128  public d1Ov;
    BlazePhoenixRouter public router;
    bool    public reenter;      // attempt to re-enter swapExactIn mid-swap
    bool    public reenteredOk;  // set true only if the guard FAILED to block it

    function arm(bool _use, int128 _d0, int128 _d1) external {
        useOverride = _use; d0Ov = _d0; d1Ov = _d1;
    }
    function setRouter(BlazePhoenixRouter _r) external { router = _r; }
    function armReenter(bool _re) external { reenter = _re; }

    function _pack(int128 d0, int128 d1) internal pure returns (int256) {
        return int256((uint256(uint128(d0)) << 128) | uint256(uint128(d1)));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        // Re-enter the Router's unlockCallback exactly as the real manager does.
        (bool ok, bytes memory ret) = msg.sender.call(
            abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(ok, "unlock: callback reverted");
        return ret;
    }

    function swap(V4PoolKey calldata, SwapParams calldata p, bytes calldata)
        external returns (int256)
    {
        // Reentrancy DURING the V4-locked region (the outer swap holds the
        // nrEntrant lock): a hostile hook / manager attempting to nest a swap
        // must be rejected. This stands in for a non-delta hook's worst side
        // effect. If the nested call did NOT revert, the guard failed.
        if (reenter && address(router) != address(0)) {
            Route memory empty;
            try router.swapExactIn(empty, 1, 0, address(this), type(uint256).max)
                returns (uint256) { reenteredOk = true; } catch {}
        }
        if (useOverride) return _pack(d0Ov, d1Ov);
        uint256 amt = uint256(-p.amountSpecified);
        int128 owe = -int128(int256(amt));       // owe the input side
        int128 recv = int128(int256(amt));        // 1:1 output
        // zeroForOne: currency0 is input (owed=d0), currency1 output (recv=d1).
        return p.zeroForOne ? _pack(owe, recv) : _pack(recv, owe);
    }

    function sync(address) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(address currency, address to, uint256 amount) external {
        IERC20Min(currency).transfer(to, amount);   // reverts if unfunded
    }
}

contract V4Adversary {
    BlazePhoenixRouter immutable router;
    MockERC20Exec      immutable A;
    MockERC20Exec      immutable B;
    HostileV4Manager   immutable mgr;
    address            immutable victim;

    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public settled;

    constructor(
        BlazePhoenixRouter _r, MockERC20Exec _a, MockERC20Exec _b,
        HostileV4Manager _m, address _v
    ) { router = _r; A = _a; B = _b; mgr = _m; victim = _v; }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    /// A V4 leg through the hostile manager, with fuzzed hook, fuzzed returned
    /// delta, and fuzzed crafted Route fields.
    function swapV4(
        uint256 amtSeed, uint256 hookSeed, bool useOv,
        int128 d0, int128 d1, uint256 recSeed, bool reenter
    ) external {
        // Full extreme range: 1 wei up to 1e30, to stress fee/floor rounding.
        uint256 amt = _bound(amtSeed, 1, 1e30);
        A.mint(address(this), amt);        mintedA += amt;
        B.mint(address(mgr), amt);         mintedB += amt;    // 1:1 honest liquidity

        mgr.arm(useOv, d0, d1);
        mgr.armReenter(reenter);

        // Fuzz the hook: 0 (none), 0x04 (delta bit → must be rejected), or junk.
        address hook = hookSeed % 3 == 0 ? address(0)
                     : hookSeed % 3 == 1 ? address(0x04)
                     : address(uint160(hookSeed));

        bool zfo = address(A) < address(B);   // consistent with sortTokens
        Leg memory leg = Leg({
            pool: address(uint160(uint256(keccak256("pid")))),  // truncated poolId
            hooks: hook, kind: 4 /*V4*/, fee: 500, tickSpacing: 10,
            zeroForOne: zfo, stable: false,
            amountIn: amt, expectedOut: 0,
            auxId: bytes32(uint256(uint160(address(B))))         // counterpart currency
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(A), tokenOut: address(B),
            amountIn: amt, expectedOut: 0, legs: legs });
        Route memory r; r.hops = hops;
        uint256 minOut = _bound(recSeed, 0, 1e30);
        try router.swapExactIn(r, amt, minOut, address(this), block.timestamp + 1)
            returns (uint256) { unchecked { ++settled; } } catch {}
    }
}

contract RouterAdversarialV4 is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20Exec      A;
    MockERC20Exec      B;
    HostileV4Manager   mgr;
    V4Adversary        adv;

    address victim    = makeAddr("victim");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    function setUp() public {
        mgr = new HostileV4Manager();
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(mgr));   // V4 manager = the hostile one
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20Exec();
        B = new MockERC20Exec();
        mgr.setRouter(router);                 // enable the reentrancy probe
        adv = new V4Adversary(router, A, B, mgr, victim);
        targetContract(address(adv));
    }

    function _sumA() internal view returns (uint256) {
        return A.balanceOf(address(adv)) + A.balanceOf(address(mgr))
             + A.balanceOf(address(router)) + A.balanceOf(victim)
             + A.balanceOf(treasury1) + A.balanceOf(treasury2);
    }
    function _sumB() internal view returns (uint256) {
        return B.balanceOf(address(adv)) + B.balanceOf(address(mgr))
             + B.balanceOf(address(router)) + B.balanceOf(victim)
             + B.balanceOf(treasury1) + B.balanceOf(treasury2);
    }

    function invariant_conservationA() public view {
        assertEq(_sumA(), adv.mintedA(), "V4-ADV: token A value created/destroyed");
    }
    function invariant_conservationB() public view {
        assertEq(_sumB(), adv.mintedB(), "V4-ADV: token B value created/destroyed");
    }
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "V4-ADV: A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "V4-ADV: B stuck in Router");
    }
    /// The reentrancy attempt during the V4-locked region must NEVER succeed.
    function invariant_reentrancyBlocked() public view {
        assertTrue(!mgr.reenteredOk(), "V4-ADV: reentrancy during V4 lock succeeded");
    }
}
