// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

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

import {Test, console2} from "forge-std/Test.sol";
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
    // WHY THE CODE AND NOT ONLY THE OUTCOME. `reenteredOk` alone made the invariant below
    // UNFALSIFIABLE, and it was measured: with the reentrancy lock deleted the campaign still
    // ran 50 x 50 green. The nested call carried `Route memory empty`, so without the lock
    // control simply reached `Router:579` - `route.hops.length == 0` - and was refused there
    // instead. The flag is unreachable in both worlds, which makes the assertion true for a
    // reason that has nothing to do with the guard it is named after. This repository already
    // catalogued that shape ("a revert with the right code does not prove the right check
    // fired"); here it had reappeared one layer up, inside an invariant.
    uint16  public nestedCode;    // the RouterE code the nested call actually died on
    bool    public nestedTried;   // non-vacuity: did a nested call ever happen at all

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
            // A NON-EMPTY route, so that the empty-route refusal cannot stand in for the lock.
            // One hop, one concentrated-single leg naming its output through auxId: it passes
            // the shape checks and reaches the reentrancy guard, which is the only thing that
            // should refuse it.
            Leg[] memory legs = new Leg[](1);
            legs[0] = Leg({
                pool: address(this), hooks: address(0), kind: 4, fee: 500, tickSpacing: 10,
                zeroForOne: true, stable: false, amountIn: 1, expectedOut: 0,
                auxId: bytes32(uint256(uint160(address(this))))
            });
            Hop[] memory hops = new Hop[](1);
            hops[0] = Hop({tokenIn: address(this), tokenOut: address(this),
                           amountIn: 1, expectedOut: 0, legs: legs});
            Route memory nested;
            nested.hops = hops;
            nestedTried = true;
            try router.swapExactIn(nested, 1, 1, address(this), type(uint256).max)
                returns (uint256) { reenteredOk = true; }
            catch (bytes memory err) {
                uint16 c;
                if (err.length >= 0x24) { assembly { c := mload(add(err, 0x24)) } }
                nestedCode = c;
            }
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

    // Campaign-shape diagnostics (all view-only surface — none of these become fuzz targets).
    // NOTE Foundry semantics: state resets to the post-setUp snapshot for each of the
    // [invariant].runs runs, and afterInvariant sees only the LAST run — so these counters
    // (and `settled` above) describe the final depth-length window, not all runs summed.
    uint256 public calls;
    uint256 public feasibleUpper;   // draws with 1 <= minOut <= amt (necessary for settle)
    uint256 public honestFeasible;  // hookless && !useOv && 1 <= minOut <= amt
    uint256 public otherRevert;     // non-RouterE revert payloads (over-take underflows etc.)
    uint256[16] public eCode;       // RouterE(code) histogram, code < 16

    function _routerECode(bytes memory err) internal pure returns (bool isE, uint256 code) {
        if (err.length != 36) return (false, 0);
        bytes4 sel; assembly { sel := mload(add(err, 32)) }
        if (sel != BlazePhoenixRouter.RouterE.selector) return (false, 0);
        assembly { code := mload(add(err, 36)) }
        return (true, code);
    }

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
        // minOut draw — THE SHAPE OF THIS DISTRIBUTION IS LOAD-BEARING (afterInvariant's
        // anti-vacuity sentinel depends on it). Settling requires 1 <= minOut <= delivered:
        // the Router refuses minOut==0 outright (RouterE 10, BP-04) and delivers ~amt minus
        // the protocol shave — and the OTHER fuzzed axes already gate the settle path down to
        // ~1/6 of calls (ANY non-zero hook dies at RouterE(9) because nothing is isHookLive
        // here: 2/3 of hookSeeds; armed delta overrides mostly die at RouterE(8): ~1/2 of the
        // rest). A single uniform draw over [0,1e30] has no intrinsic mass in [1, amt]; every
        // settle it ever produced came from Foundry's fuzz DICTIONARY (small literals and
        // constants harvested from the WHOLE compiled project) happening to supply small
        // recSeeds. Adding unrelated test files (50f5bc2) shifted that dictionary and the
        // campaign settled 0 of 2500 calls on most seeds (measured 2026-09-02; only the
        // pinned CI seed still passed). Two regimes make settling structural instead:
        //   * 7/8 anchored to [1, amt]: feasible BY CONSTRUCTION for every amt and every
        //     recSeed shape (the modulo maps any draw inside), while draws in the
        //     (net-of-fee, amt] sliver still probe the tight RouterE(5) boundary;
        //   * 1/8 the original wild [0, 1e30]: keeps deep slippage refusals and the
        //     minOut==0 RouterE(10) guard in the campaign.
        // Net effect ~12-15% of calls settle regardless of dictionary composition, ~85%
        // still revert (hooks, delta overrides, over-take, boundary) — both regimes stay
        // exercised. Do NOT "simplify" back to one uniform range (the campaign goes vacuous
        // again) and do NOT pin minOut to 0 or 1 (that kills the refusal-side search).
        uint256 minOut = recSeed % 8 != 7
            ? _bound(recSeed >> 3, 1, amt)
            : _bound(recSeed, 0, 1e30);
        unchecked {
            ++calls;
            if (minOut != 0 && minOut <= amt) {
                ++feasibleUpper;
                if (hook == address(0) && !useOv) ++honestFeasible;
            }
        }
        try router.swapExactIn(r, amt, minOut, address(this), block.timestamp + 1)
            returns (uint256) { unchecked { ++settled; } }
        catch (bytes memory err) {
            (bool isE, uint256 c) = _routerECode(err);
            unchecked { if (isE && c < 16) ++eCode[c]; else ++otherRevert; }
        }
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
        hub = new BlazePhoenixHub(address(this));
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
        // And the DISCRIMINATING half: whenever a nested call was attempted, the thing that
        // refused it must have been the LOCK (RouterE(7)) and not a sibling guard that happens
        // to refuse the same shape. Without this, deleting the lock leaves the campaign green.
        if (mgr.nestedTried()) {
            assertEq(uint256(mgr.nestedCode()), 7,
                "V4-ADV: the nested call was refused, but not by the reentrancy lock");
        }
    }

    /// @dev Non-vacuousness guard: mints happen before each swap attempt, so conservation and
    ///      holds-nothing would hold trivially over a campaign where every swap reverted. Must be
    ///      afterInvariant (runs once at the end), not an invariant_ function (also evaluated at
    ///      step zero, where the counter is trivially 0).
    function afterInvariant() public view {
        // Campaign-shape log (final window only — see the counter note in V4Adversary): makes
        // the settle/refuse ratio visible at -vv so vacuity DRIFT is seen before it goes red.
        console2.log("V4 campaign final window: calls   ", adv.calls());
        console2.log("V4 campaign final window: settled ", adv.settled());
        console2.log("V4 campaign final window: feasible", adv.feasibleUpper());
        console2.log("V4 campaign final window: honest+f", adv.honestFeasible());
        console2.log("V4 campaign final window: otherRev", adv.otherRevert());
        for (uint256 i = 0; i < 16; ++i) {
            uint256 n = adv.eCode(i);
            if (n != 0) { console2.log("V4 campaign final window: RouterE", i, "x", n); }
        }
        assertGt(adv.settled(), 0, "no V4 swap ever settled across the whole campaign - vacuous pass");
    }
}
