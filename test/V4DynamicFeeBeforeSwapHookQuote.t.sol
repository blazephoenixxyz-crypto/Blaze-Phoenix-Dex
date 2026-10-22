// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  H12 (oc-1018 m2, confirmed Low, 2026-10-19): A DYNAMIC-FEE KEY WHOSE HOOK
//  RUNS beforeSwap IS NOT QUOTED FROM slot0.
//
//  v4-core: `Hooks.beforeSwap` enters the hook only with BEFORE_SWAP_FLAG
//  (1 << 7), and on a key whose fee is the dynamic sentinel (0x800000) the
//  uint24 it returns, with OVERRIDE_FEE_FLAG, is the swap's LP fee
//  (`Pool.swap`: `lpFeeOverride.isOverride() ? ... : slot0Start.lpFee()`).
//  There is no separate permission bit for the override: bit 7 on a dynamic
//  key is the whole grant. The quote read slot0's lpFee through extsload with
//  the hook never called, so a hook returning 2 % where slot0 stores 0.3 %
//  had previewPlan publish a netOut ~1.7 % above delivery, inside the floors.
//
//  The fix fails such a key closed in the one V4 quote producer the Solver and
//  the Quoter share (`Core._v4Quote`): out, depth, rank and ceiling are 0,
//  the shape of a dead pool. What stays quotable, pinned below:
//    - a dynamic key whose hook has no beforeSwap bit (its fee moves only by
//      `updateDynamicLPFee` outside its own swap, so slot0 in the quoting
//      state is the fee the swap charges);
//    - a static key with a beforeSwap hook (the manager ignores the
//      override off a dynamic key);
//    - the explicit door: the Router's in-frame promise (`v4LegOut`) is not
//      touched, so a caller-built route through such a pool still settles,
//      bounded as before by the floors and userMinOut.
//
//  The manager below is the m2 PoC's MockV4DynFeeManager with one change: it
//  applies the hook's fee only when the hook carries bit 7, as v4-core does.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, QuoteCtx, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IFeeHook {
    function beforeSwapFee() external view returns (uint24);
}

/// @dev Runtime etched at address(0x80) = BEFORE_SWAP (1<<7) permission only.
contract HookBeforeSwapOnly {
    uint24 public fee;
    function setFee(uint24 f) external { fee = f; }
    function beforeSwapFee() external view returns (uint24) { return fee; }
}

interface IERC20Tick {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev MockV4TickManager, with swap() taking the DYN-key fee from the hook.
contract MockV4DynFeeManager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint256 internal constant SCAN = 4096;

    mapping(bytes32 => bytes32) public slots;
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }

    function _base(bytes32 pid) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(pid, uint256(6))));
    }
    function _tickSlot(bytes32 pid, int24 t) internal pure returns (bytes32) {
        return keccak256(abi.encode(int256(t), bytes32(_base(pid) + 4)));
    }
    function _wordSlot(bytes32 pid, int16 w) internal pure returns (bytes32) {
        return keccak256(abi.encode(int256(w), bytes32(_base(pid) + 5)));
    }

    function initialize(bytes32 pid, uint160 sqrtP, int24 tick, uint24 lpFee) external {
        slots[bytes32(_base(pid))] =
            bytes32(uint256(sqrtP) | (uint256(uint24(tick)) << 160) | (uint256(lpFee) << 208));
    }

    function slot0(bytes32 pid) public view returns (uint160 sp, int24 tick) {
        uint256 w = uint256(slots[bytes32(_base(pid))]);
        sp = uint160(w);
        tick = int24(uint24(w >> 160));
    }

    function liquidity(bytes32 pid) public view returns (uint128) {
        return uint128(uint256(slots[bytes32(_base(pid) + 3)]));
    }

    function liquidityNet(bytes32 pid, int24 t) public view returns (int128) {
        return int128(int256(uint256(slots[_tickSlot(pid, t)]) >> 128));
    }

    function _bump(bytes32 pid, int24 t, int24 ts, int128 dNet, uint128 dGross) internal {
        uint256 w = uint256(slots[_tickSlot(pid, t)]);
        uint128 gross = uint128(w) + dGross;
        int128 net = int128(int256(w >> 128)) + dNet;
        slots[_tickSlot(pid, t)] = bytes32(uint256(gross) | (uint256(uint128(net)) << 128));
        int24 c = t / ts;
        int16 wp = int16(c >> 8);
        uint256 bp = uint256(uint24(c)) & 0xff;
        slots[_wordSlot(pid, wp)] = bytes32(uint256(slots[_wordSlot(pid, wp)]) | (uint256(1) << bp));
    }

    function addPosition(bytes32 pid, int24 lower, int24 upper, int24 ts, uint128 liq) external {
        require(lower < upper && lower % ts == 0 && upper % ts == 0, "position");
        _bump(pid, lower, ts, int128(liq), liq);
        _bump(pid, upper, ts, -int128(liq), liq);
        (, int24 tick) = slot0(pid);
        if (lower <= tick && tick < upper) {
            slots[bytes32(_base(pid) + 3)] = bytes32(uint256(liquidity(pid)) + liq);
        }
    }

    function _isInit(bytes32 pid, int256 c) internal view returns (bool) {
        int16 wp = int16(int24(c >> 8));
        uint256 bp = uint256(uint24(int24(c))) & 0xff;
        return (uint256(slots[_wordSlot(pid, wp)]) >> bp) & 1 == 1;
    }

    uint256 internal constant ONE38 = 1e38;
    uint256 internal constant SQRT_1_0001 = 100004999875006249609402341699379869721;

    function sqrtAt(int24 t) public pure returns (uint160) {
        if (t <= MIN_TICK) return MIN_SQRT;
        if (t >= MAX_TICK) return MAX_SQRT;
        uint256 k = uint256(int256(t < 0 ? -t : t));
        uint256 r = ONE38;
        uint256 b = SQRT_1_0001;
        while (k != 0) {
            if (k & 1 == 1) r = BPC.mulDiv(r, b, ONE38);
            b = BPC.mulDiv(b, b, ONE38);
            k >>= 1;
        }
        return t < 0 ? uint160(BPC.mulDiv(BPC.Q96, ONE38, r)) : uint160(BPC.mulDiv(BPC.Q96, r, ONE38));
    }

    function specSwap(bytes32 pid, uint256 amt, uint24 fee, int24 ts, bool zfo)
        public view returns (uint256 used, uint256 out, uint160 spEnd, int24 tickEnd, uint128 liqEnd)
    {
        (uint160 sp, int24 tick) = slot0(pid);
        uint128 L = liquidity(pid);
        uint256 rem = amt;
        int256 c = int256(tick) / int256(ts);
        if (tick < 0 && int256(tick) % int256(ts) != 0) c--;
        if (!zfo) c++;
        for (uint256 n; n < SCAN && rem > 0; ++n) {
            bool init;
            while (true) {
                init = _isInit(pid, c);
                if (init) break;
                if (zfo ? c * int256(ts) <= MIN_TICK : c * int256(ts) >= MAX_TICK) break;
                if (++n >= SCAN) break;
                if (zfo) c--; else c++;
            }
            int256 nt = c * int256(ts);
            if (nt < MIN_TICK) nt = MIN_TICK;
            if (nt > MAX_TICK) nt = MAX_TICK;
            uint160 target = sqrtAt(int24(nt));
            uint256 remLessFee = rem * (1_000_000 - fee) / 1_000_000;
            uint256 toTarget = zfo
                ? _up(BPC.mulDivUp(uint256(L) << 96, uint256(sp) - target, sp), target)
                : BPC.mulDivUp(L, uint256(target) - sp, BPC.Q96);
            uint160 np;
            if (remLessFee >= toTarget) {
                np = target;
                used += toTarget + BPC.mulDivUp(toTarget, fee, 1_000_000 - fee);
                rem -= toTarget + BPC.mulDivUp(toTarget, fee, 1_000_000 - fee);
            } else {
                np = zfo
                    ? uint160(BPC.mulDivUp(uint256(L) << 96, sp, (uint256(L) << 96) + remLessFee * sp))
                    : uint160(uint256(sp) + BPC.mulDiv(remLessFee, BPC.Q96, L));
                used += rem;
                rem = 0;
            }
            out += zfo
                ? BPC.mulDiv(L, uint256(sp) - np, BPC.Q96)
                : BPC.mulDiv(uint256(L) << 96, uint256(np) - sp, np) / sp;
            if (np != target) {
                tick = zfo ? _tickAt(np, int24(nt), tick) : _tickAt(np, tick, int24(nt));
                sp = np;
                break;
            }
            sp = np;
            if (init) {
                int256 net = int256(liquidityNet(pid, int24(nt)));
                if (zfo) net = -net;
                L = uint128(uint256(int256(uint256(L)) + net));
            }
            tick = zfo ? int24(nt) - 1 : int24(nt);
            if (nt == MIN_TICK || nt == MAX_TICK) break;
            if (zfo) c--; else c++;
        }
        spEnd = sp;
        tickEnd = tick;
        liqEnd = L;
    }

    function _up(uint256 a, uint256 b) internal pure returns (uint256) { return a / b + (a % b == 0 ? 0 : 1); }

    function _tickAt(uint160 sp, int24 lo, int24 hi) internal pure returns (int24) {
        while (lo < hi) {
            int24 mid = int24((int256(lo) + int256(hi) + 1) / 2);
            if (sqrtAt(mid) <= sp) lo = mid; else hi = mid - 1;
        }
        return lo;
    }

    address public pendingCur;
    uint256 public pendingOwe;
    bool    public syncedFlag;
    address public syncedCur;
    uint256 public syncBal;

    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        if (!ok) { assembly { revert(add(ret, 32), mload(ret)) } }
        return ret;
    }

    /// @dev THE ONLY CHANGE FROM MockV4TickManager: a DYN key takes its swap
    ///      fee from beforeSwap's return, never from the key. The sieve that
    ///      admits this pool reads neither this value nor the hook's code.
    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (int256) {
        bytes32 pid = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        uint24 fee = key.fee;
        // v4-core Hooks.beforeSwap: the hook is entered only with BEFORE_SWAP_FLAG (1<<7), and its
        // returned fee is the swap's lpFee only on a dynamic-fee key.
        if (key.fee == 0x800000 && (uint160(key.hooks) & (1 << 7)) != 0) {
            fee = IFeeHook(key.hooks).beforeSwapFee();
        }
        (uint256 used, uint256 out, uint160 spEnd, int24 tickEnd, uint128 liqEnd) =
            specSwap(pid, uint256(-p.amountSpecified), fee, key.tickSpacing, p.zeroForOne);
        uint256 w = uint256(slots[bytes32(_base(pid))]);
        slots[bytes32(_base(pid))] = bytes32(
            (w & ~((uint256(1) << 184) - 1)) | uint256(spEnd) | (uint256(uint24(tickEnd)) << 160));
        slots[bytes32(_base(pid) + 3)] = bytes32(uint256(liqEnd));
        pendingCur = p.zeroForOne ? key.currency0 : key.currency1;
        pendingOwe = used;
        int128 oweD = -int128(int256(used));
        int128 recvD = int128(int256(out));
        return p.zeroForOne
            ? int256((uint256(uint128(oweD)) << 128) | uint256(uint128(recvD)))
            : int256((uint256(uint128(recvD)) << 128) | uint256(uint128(oweD)));
    }

    receive() external payable {}

    function sync(address currency) external {
        syncedFlag = true;
        syncedCur = currency;
        syncBal = currency == address(0) ? 0 : IERC20Tick(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256) {
        if (pendingCur == address(0)) {
            require(msg.value == pendingOwe, "settle: value != owed");
        } else {
            require(syncedFlag && syncedCur == pendingCur, "settle: not synced");
            require(IERC20Tick(pendingCur).balanceOf(address(this)) - syncBal >= pendingOwe, "settle: unpaid");
        }
        syncedFlag = false;
        uint256 p = pendingOwe;
        pendingOwe = 0;
        return p;
    }

    function take(address currency, address to, uint256 amount) external {
        if (currency == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "take: eth send failed");
        } else {
            require(IERC20Tick(currency).transfer(to, amount), "take: transfer failed");
        }
    }
}

contract V4DynamicFeeBeforeSwapHookQuoteTest is Test {
    uint24  constant DYN  = 0x800000;
    uint24  constant STATIC_FEE = 3000;
    int24   constant TS   = 60;
    uint128 constant LIQ  = 1e25;      // deep: the swap stays inside one stretch
    uint256 constant AMT  = 1e18;
    uint24  constant MEASURED = 3000;  // slot0 lpFee the measurement reads
    uint256 constant DECLARED = 0.9e18; // conservative claim for the hand-built route

    address constant HOOK_BS = address(0x80); // BEFORE_SWAP (1<<7) only
    address constant HOOK_AS = address(0x40); // AFTER_SWAP (1<<6) only

    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockV4DynFeeManager mgr;
    MockERC20 A;
    MockERC20 B;

    address user = address(0xBEEF);
    bytes32 pidDynBs;     // dynamic key, beforeSwap hook (registered)
    bytes32 pidDynAs;     // dynamic key, afterSwap-only hook
    bytes32 pidStaticBs;  // static key, beforeSwap hook

    function setUp() public {
        vm.etch(HOOK_BS, type(HookBeforeSwapOnly).runtimeCode);
        vm.etch(HOOK_AS, type(HookBeforeSwapOnly).runtimeCode);
        HookBeforeSwapOnly(HOOK_BS).setFee(MEASURED);
        HookBeforeSwapOnly(HOOK_AS).setFee(MEASURED);

        mgr = new MockV4DynFeeManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        A = new MockERC20("AAA", "AAA");
        B = new MockERC20("BBB", "BBB");
        (address t0, address t1) = BPC.sortTokens(address(A), address(B));
        pidDynBs    = BPC.computeV4PoolId(t0, t1, DYN, TS, HOOK_BS);
        pidDynAs    = BPC.computeV4PoolId(t0, t1, DYN, TS, HOOK_AS);
        pidStaticBs = BPC.computeV4PoolId(t0, t1, STATIC_FEE, TS, HOOK_BS);
        for (uint256 i; i < 3; ++i) {
            bytes32 pid = i == 0 ? pidDynBs : (i == 1 ? pidDynAs : pidStaticBs);
            mgr.initialize(pid, mgr.sqrtAt(60), 60, MEASURED); // slot0 measures 0.3%
            mgr.addPosition(pid, 0, 120, TS, LIQ);
        }
        hub.addV4(address(A), address(B), DYN, TS, HOOK_BS); // allow-listed + pinned: hookPaused == false

        A.mint(user, AMT);
        A.mint(address(mgr), 1e21);
        B.mint(address(mgr), 1e21);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function _ctx(uint24 fee, address hooks) internal view returns (QuoteCtx memory c) {
        (address t0, ) = BPC.sortTokens(address(A), address(B));
        c.kind        = BPC.KIND_V4;
        c.zeroForOne  = address(A) == t0;
        c.fee         = fee;
        c.tickSpacing = TS;
        c.tokenIn     = address(A);
        c.tokenOther  = address(B);
        c.hooks       = hooks;
        c.v4Manager   = address(mgr);
    }

    /// RED on 57a4bab. The quantity: the V4 quote of a dynamic-fee key whose hook
    /// runs beforeSwap. The hook returns 2 % where slot0 stores 0.3 %; the quote
    /// read 0.3 % and the preview published a netOut the swap does not deliver.
    /// Goes red iff the shared V4 quote producer prices such a key at all.
    function test_H12_DynamicFeeKeyWithBeforeSwapHook_QuoteFailsClosed() public {
        HookBeforeSwapOnly(HOOK_BS).setFee(20_000);
        assertFalse(BPC.hookAltersDeltas(HOOK_BS), "setup: no delta bit, the delta sieve passes it");
        assertFalse(hub.hookPaused(HOOK_BS), "setup: listed and pinned, the pause sieve passes it");

        (uint256 out, uint256 depth) = BPC.universalQuote(_ctx(DYN, HOOK_BS), AMT);
        assertEq(out, 0, "a dynamic-fee key with a beforeSwap hook was priced from slot0's lpFee");
        assertEq(depth, 0, "a fail-closed V4 key must not keep a depth vote");

        // The registered pool is the pair's only venue: with it unquotable the Solver finds
        // no route (bestU == 0) and the preview refuses instead of promising one.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5)));
        quoter.previewPlan(address(A), address(B), AMT);
    }

    /// Control (both eras): a dynamic key whose hook has no beforeSwap bit is
    /// never entered before its own swap, so slot0's lpFee is the swap's fee and
    /// the pool stays quotable. Red under a gate keyed on every swap bit (0xCC).
    function test_H12_DynamicFeeKeyWithAfterSwapOnlyHook_StillQuoted() public {
        assertTrue(BPC.hookRunsInSwap(HOOK_AS), "setup: the hook runs in the swap (afterSwap)");
        (uint256 out, uint256 depth) = BPC.universalQuote(_ctx(DYN, HOOK_AS), AMT);
        assertGt(out, 0, "a dynamic-fee pool with no beforeSwap hook must stay quotable (INV-20)");
        assertGt(depth, 0, "and keep its depth");
    }

    /// Control (both eras): a static key ignores the override, so a beforeSwap
    /// hook on it does not move the fee. Red under a gate that drops the
    /// dynamic-key condition.
    function test_H12_StaticFeeKeyWithBeforeSwapHook_StillQuoted() public {
        (uint256 out, ) = BPC.universalQuote(_ctx(STATIC_FEE, HOOK_BS), AMT);
        assertGt(out, 0, "a static-fee key with a beforeSwap hook must stay quotable");
    }

    /// Control (both eras): the fix is quote-side only. A caller-built route
    /// through the dynamic beforeSwap pool still settles on the explicit door;
    /// its promise (`v4LegOut`) is unchanged.
    function test_H12_ExplicitDoor_DynamicBeforeSwapLeg_StillSettles() public {
        Route memory r = _v4Route(pidDynBs, DYN, HOOK_BS);
        uint256 before = B.balanceOf(user);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(got, DECLARED, "the explicit door still settles the leg");
        assertEq(B.balanceOf(user) - before, got, "delivered to the recipient");
    }

    function _v4Route(bytes32 poolId, uint24 fee, address hooks) internal view returns (Route memory route) {
        (address c0,) = BPC.sortTokens(address(A), address(B));
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool:        address(uint160(uint256(poolId))),
            hooks:       hooks,
            kind:        BPC.KIND_V4,
            fee:         fee,
            tickSpacing: TS,
            zeroForOne:  address(A) == c0,
            stable:      false,
            amountIn:    AMT,
            expectedOut: DECLARED,
            auxId:       bytes32(uint256(uint160(address(B))))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: AMT, expectedOut: DECLARED, legs: legs});
        route = Route({
            hops:              hops,
            totalOut:          DECLARED,
            singleOut:         DECLARED,
            singleOutFloor:    0,
            expectedImpactBps: 0,
            confidenceWad:     0,
            estGas:            0,
            hasSurplus:        true,
            isV4Bundle:        false
        });
    }
}
