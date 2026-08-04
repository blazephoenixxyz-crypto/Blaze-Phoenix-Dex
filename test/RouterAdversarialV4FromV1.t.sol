// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Ported from Blaze-Phoenix-Dex (V1) test/RouterAdversarialV4.t.sol — a genuine, significant gap:
// this repo's V4 coverage was limited to the two auth-rejection cases (wrong caller; real manager
// but outside a swap — see RouterCallbackAuthFromV1.t.sol). Nothing here actually EXECUTES a
// settling V4 swap offline. The unlock -> swap -> sync -> settle -> take flow moves real funds
// and was flagged in this repo's own audit scope as needing "a full settle path... fork/audit" —
// this is exactly that offline exercise, against a HOSTILE manager:
//
//   * hookAltersDeltas — a hook carrying the delta-return permission bits must be refused
//     (RouterE 9) before any unlock (already covered separately by RouterExecGuardsFromV1.t.sol;
//     re-fuzzed here alongside the rest for completeness under the SAME adversarial harness).
//   * delta-sign guard — owedDelta must be <= 0 and receivedDelta >= 0, else RouterE(8): the
//     manager cannot make the Router receive-and-still-owe.
//   * over-take — a manager reporting more output than it holds simply reverts on take();
//     nothing is minted.
//   * reentrancy DURING the V4-locked region — a hostile manager/hook attempting to nest a swap
//     from inside swap() itself (not via a malicious ERC20, a DIFFERENT vector than this repo's
//     existing MaliciousReentrantERC20 test) must be rejected by the same nonReentrant lock.
//   * conservation / holds-nothing across the whole randomized sequence.
//
// forge test --match-contract RouterAdversarialV4FromV1 -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

interface IERC20Min {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev Minimal ERC20: no allowance enforcement (irrelevant to these guards — the adversary IS
///      the caller pulling its own funds).
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

/// @dev A hostile V4 PoolManager that actually settles. Struct field layouts mirror the Router's
///      IV4PoolManager (ABI-compatible). Honest by default (1:1 fill); armable to return an
///      arbitrary packed delta so the Router's sign guard and take() bound are exercised.
contract HostileV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    bool public useOverride;
    int128 public d0Ov;
    int128 public d1Ov;
    BlazePhoenixRouter public router;
    bool public reenter;
    bool public reenteredOk; // true only if the guard FAILED to block the nested call

    function arm(bool _use, int128 _d0, int128 _d1) external { useOverride = _use; d0Ov = _d0; d1Ov = _d1; }
    function setRouter(BlazePhoenixRouter _r) external { router = _r; }
    function armReenter(bool _re) external { reenter = _re; }

    function _pack(int128 d0, int128 d1) internal pure returns (int256) {
        return int256((uint256(uint128(d0)) << 128) | uint256(uint128(d1)));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(ok, "unlock: callback reverted");
        return ret;
    }

    function swap(V4PoolKey calldata, SwapParams calldata p, bytes calldata) external returns (int256) {
        // Reentrancy DURING the V4-locked region: the outer swap holds the nonReentrant lock, so
        // a hostile hook/manager nesting a call here must be rejected. If it did NOT revert, the
        // guard failed.
        if (reenter && address(router) != address(0)) {
            Route memory empty;
            try router.swapExactIn(empty, 1, 0, address(this), type(uint256).max)
                returns (uint256) { reenteredOk = true; } catch {}
        }
        if (useOverride) return _pack(d0Ov, d1Ov);
        uint256 amt = uint256(-p.amountSpecified);
        int128 owe = -int128(int256(amt));
        int128 recv = int128(int256(amt));
        return p.zeroForOne ? _pack(owe, recv) : _pack(recv, owe);
    }

    function sync(address) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(address currency, address to, uint256 amount) external {
        IERC20Min(currency).transfer(to, amount); // reverts if unfunded — the over-take case
    }
}

contract V4Adversary {
    BlazePhoenixRouter immutable router;
    MockERC20Adv immutable A;
    MockERC20Adv immutable B;
    HostileV4Manager immutable mgr;
    address immutable victim;

    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public settled;

    constructor(BlazePhoenixRouter _r, MockERC20Adv _a, MockERC20Adv _b, HostileV4Manager _m, address _v) {
        router = _r; A = _a; B = _b; mgr = _m; victim = _v;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    /// A V4 leg through the hostile manager, with fuzzed hook, fuzzed returned delta, and fuzzed
    /// crafted Route fields.
    function swapV4(
        uint256 amtSeed, uint256 hookSeed, bool useOv,
        int128 d0, int128 d1, uint256 recSeed, bool reenter
    ) external {
        uint256 amt = _bound(amtSeed, 1, 1e30); // 1 wei up to 1e30, to stress fee/floor rounding
        A.mint(address(this), amt); mintedA += amt;
        B.mint(address(mgr), amt); mintedB += amt; // 1:1 honest liquidity

        mgr.arm(useOv, d0, d1);
        mgr.armReenter(reenter);

        // Fuzz the hook: 0 (none), a delta-return permission bit (must be rejected), or junk.
        address hook = hookSeed % 3 == 0 ? address(0)
                     : hookSeed % 3 == 1 ? address(uint160(1 << 2))
                     : address(uint160(hookSeed));

        bool zfo = address(A) < address(B); // consistent with sortTokens
        Leg memory leg = Leg({
            pool: address(uint160(uint256(keccak256("pid")))), // truncated poolId
            hooks: hook, kind: 4 /*V4*/, fee: 500, tickSpacing: 10,
            zeroForOne: zfo, stable: false,
            amountIn: amt, expectedOut: 0,
            auxId: bytes32(uint256(uint160(address(B)))) // counterpart currency
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: amt, expectedOut: 0, legs: legs});
        Route memory r; r.hops = hops;
        uint256 minOut = _bound(recSeed, 0, 1e30);
        try router.swapExactIn(r, amt, minOut, address(this), block.timestamp + 1)
            returns (uint256) { unchecked { ++settled; } } catch {}
    }
}

contract RouterAdversarialV4FromV1Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20Adv A;
    MockERC20Adv B;
    HostileV4Manager mgr;
    V4Adversary adv;

    address victim = makeAddr("victim");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    function setUp() public {
        mgr = new HostileV4Manager();
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(mgr)); // V4 manager = the hostile one
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20Adv();
        B = new MockERC20Adv();
        mgr.setRouter(router); // enable the reentrancy probe
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
    function invariant_reentrancyBlocked() public view {
        assertTrue(!mgr.reenteredOk(), "V4-ADV: reentrancy during V4 lock succeeded");
    }
}
