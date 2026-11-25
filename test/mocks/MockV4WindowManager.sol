// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IERC20Window {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice A V4 PoolManager for tests that stores a pool the way the singleton does - slot0,
///         the active liquidity, the ticks mapping and the tick bitmap, at their real extsload
///         offsets - and swaps it with the V4 loop written HERE from the specification, its
///         own tick-to-price arithmetic (fixed point at 1e38) rather than the Core's table.
///         Unlike a one-swap mock it keeps what the singleton keeps across one unlock: every
///         swap honours its sqrtPriceLimitX96 (stopping there with input unspent, refusing a
///         limit already passed) and the deltas of several swaps add up to one settlement.
///         It also counts the swaps and the input each pool consumed, so a test can see how
///         many windows a price-limited leg ran and where the hop's input went.
contract MockV4WindowManager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    /// @dev How far the specification's scan looks for the next initialized tick, in
    ///      compressed ticks, before treating the rest of the book as empty.
    uint256 internal constant SCAN = 1_000_000; // steps (bitmap words or initialized ticks)

    mapping(bytes32 => bytes32) public slots;
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }

    // ── the pool, at the singleton's own offsets ─────────────────────────────

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

    /// @notice slot0 with a protocol fee too (bits [184,208): zeroForOne in the low 12).
    function initializeWithProtocolFee(bytes32 pid, uint160 sqrtP, int24 tick, uint24 protoFee, uint24 lpFee) external {
        slots[bytes32(_base(pid))] = bytes32(
            uint256(sqrtP) | (uint256(uint24(tick)) << 160) | (uint256(protoFee) << 184) | (uint256(lpFee) << 208));
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
        int24 c = t / ts;                                   // positions sit on multiples of ts
        int16 wp = int16(c >> 8);
        uint256 bp = uint256(uint24(c)) & 0xff;
        slots[_wordSlot(pid, wp)] = bytes32(uint256(slots[_wordSlot(pid, wp)]) | (uint256(1) << bp));
    }

    /// @notice A liquidity position [lower, upper) of `liq`, both ticks on the spacing.
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

    // ── tick -> price, independently of the Core's table ─────────────────────

    uint256 internal constant ONE38 = 1e38;
    uint256 internal constant SQRT_1_0001 = 100004999875006249609402341699379869721; // sqrt(1.0001) * 1e38

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

    // ── the swap, from the V4 specification ──────────────────────────────────

    /// @dev The walk's running state, held in memory so the step stays within the stack.
    struct Walk { uint160 sp; int24 tick; uint128 L; uint256 rem; uint256 used; uint256 out; int256 c; }

    /// @notice What an exact-input swap of `amt` pays and spends, walking the book to `limit`
    ///         (v4-core Pool.swap): each step aims at the next initialized tick or the bitmap
    ///         word's edge, or at the limit when it comes first; between initialized ticks the
    ///         liquidity is constant; crossing one applies its liquidityNet, negated going down.
    function specSwap(bytes32 pid, uint256 amt, uint24 fee, int24 ts, bool zfo, uint160 limit)
        public view returns (uint256 used, uint256 out, uint160 spEnd, int24 tickEnd, uint128 liqEnd)
    {
        Walk memory w;
        (w.sp, w.tick) = slot0(pid);
        w.L = liquidity(pid);
        w.rem = amt;
        w.c = int256(w.tick) / int256(ts);
        if (w.tick < 0 && int256(w.tick) % int256(ts) != 0) w.c--;
        if (!zfo) w.c++;
        for (uint256 n; n < SCAN && w.rem > 0 && w.sp != limit; ++n) {
            if (_step(w, pid, fee, ts, zfo, limit)) break;
        }
        return (w.used, w.out, w.sp, w.tick, w.L);
    }

    /// @dev One step of the walk; true when the walk ends here.
    function _step(Walk memory w, bytes32 pid, uint24 fee, int24 ts, bool zfo, uint160 limit)
        internal view returns (bool done)
    {
        bool init;
        (w.c, init) = _nextInit(pid, w.c, zfo);
        int256 nt = w.c * int256(ts);
        if (nt < MIN_TICK) nt = MIN_TICK;
        if (nt > MAX_TICK) nt = MAX_TICK;
        uint160 next = sqrtAt(int24(nt));
        // v4-core SwapMath.getSqrtPriceTarget: the limit, when it comes before the tick.
        uint160 target = (zfo ? limit > next : limit < next) ? limit : next;
        uint160 np = _fill(w, fee, zfo, target);
        w.out += zfo
            ? BPC.mulDiv(w.L, uint256(w.sp) - np, BPC.Q96)
            : BPC.mulDiv(uint256(w.L) << 96, uint256(np) - w.sp, np) / w.sp;
        if (np != next) {
            // Stopped inside this stretch (input spent, or the limit): the tick is the
            // largest one whose price is at or below where the price stopped.
            w.tick = zfo ? _tickAt(np, int24(nt), w.tick) : _tickAt(np, w.tick, int24(nt));
            w.sp = np;
            return true;
        }
        w.sp = np;
        if (init) {
            int256 net = int256(liquidityNet(pid, int24(nt)));
            if (zfo) net = -net;
            w.L = uint128(uint256(int256(uint256(w.L)) + net));
        }
        w.tick = zfo ? int24(nt) - 1 : int24(nt);
        if (nt == MIN_TICK || nt == MAX_TICK) return true;
        if (zfo) w.c--; else w.c++;
    }

    /// @dev The price the step reaches toward `target`, charging what it spends to the walk.
    function _fill(Walk memory w, uint24 fee, bool zfo, uint160 target) internal pure returns (uint160 np) {
        uint256 remLessFee = w.rem * (1_000_000 - fee) / 1_000_000;
        uint256 toTarget = zfo
            ? _up(BPC.mulDivUp(uint256(w.L) << 96, uint256(w.sp) - target, w.sp), target)
            : BPC.mulDivUp(w.L, uint256(target) - w.sp, BPC.Q96);
        if (remLessFee >= toTarget) {
            uint256 spent = toTarget + BPC.mulDivUp(toTarget, fee, 1_000_000 - fee);
            w.used += spent;
            w.rem -= spent;
            return target;
        }
        np = zfo
            ? uint160(BPC.mulDivUp(uint256(w.L) << 96, w.sp, (uint256(w.L) << 96) + remLessFee * w.sp))
            : uint160(uint256(w.sp) + BPC.mulDiv(remLessFee, BPC.Q96, w.L));
        w.used += w.rem;
        w.rem = 0;
    }

    function _nextInit(bytes32 pid, int256 c, bool zfo) internal view returns (int256, bool init) {
        int256 wp = c >> 8;
        uint256 bp = uint256(c - (wp << 8));
        uint256 word = uint256(slots[_wordSlot(pid, int16(wp))]);
        if (zfo) {
            uint256 masked = word & ((uint256(1) << bp) - 1 + (uint256(1) << bp));
            init = masked != 0;
            return (init ? c - int256(bp - _msb(masked)) : c - int256(bp), init);
        }
        uint256 m2 = word & ~((uint256(1) << bp) - 1);
        init = m2 != 0;
        return (init ? c + int256(_lsb(m2) - bp) : c + int256(255 - bp), init);
    }
    function _msb(uint256 x) internal pure returns (uint256 r) { while (x > 1) { x >>= 1; ++r; } }
    function _lsb(uint256 x) internal pure returns (uint256 r) { while (x & 1 == 0) { x >>= 1; ++r; } }

    function _up(uint256 a, uint256 b) internal pure returns (uint256) { return a / b + (a % b == 0 ? 0 : 1); }

    function _tickAt(uint160 sp, int24 lo, int24 hi) internal pure returns (int24) {
        while (lo < hi) {
            int24 mid = int24((int256(lo) + int256(hi) + 1) / 2);
            if (sqrtAt(mid) <= sp) lo = mid; else hi = mid - 1;
        }
        return lo;
    }

    // ── settlement, the way the Router's callback drives the singleton ───────
    // ── settlement, the way the Router's callback drives the singleton ───────

    address public pendingCur;
    uint256 public pendingOwe;
    bool    public syncedFlag;
    address public syncedCur;
    uint256 public syncBal;
    uint256 public swapCount;
    mapping(bytes32 => uint256) public spentIn;

    // ── hostile knobs (0 / false = the honest singleton) ─────────────────────
    /// @dev The swap number (counted as `swapCount` counts, from 1) that answers with a delta of
    ///      the wrong sign (+1 owed, +1 received, whatever the direction) and moves nothing: a
    ///      lying pool or hook, in whichever window of a price-limited leg the test picks.
    uint256 public lieAt;
    /// @dev Rewrites word 6 of the unlock payload (the leg's committed input, `amt`) to
    ///      2^256-1 before calling back: the input budget at the one value where the Core's
    ///      refusal sentinel equals it.
    bool public lieAmt;

    function setLie(uint256 at, bool amtMax) external { (lieAt, lieAmt) = (at, amtMax); }

    function unlock(bytes calldata data) external returns (bytes memory) {
        pendingOwe = 0;
        bytes memory d = data;
        if (lieAmt) assembly { mstore(add(d, 224), not(0)) }
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", d));
        if (!ok) { assembly { revert(add(ret, 32), mload(ret)) } }
        require(pendingOwe == 0, "unlock: unsettled");  // v4-core: CurrencyNotSettled
        return abi.decode(ret, (bytes)); // v4-core: the callback's bytes, unchanged
    }

    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (int256) {
        if (lieAt != 0 && swapCount + 1 == lieAt) {
            ++swapCount;
            return int256((uint256(1) << 128) | 1);
        }
        bytes32 pid = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        (uint160 sp0, ) = slot0(pid);
        uint160 lim = p.sqrtPriceLimitX96;
        // v4-core Pool.swap: PriceLimitAlreadyExceeded / PriceLimitOutOfBounds.
        require(p.zeroForOne ? (lim < sp0 && lim > MIN_SQRT) : (lim > sp0 && lim < MAX_SQRT), "swap: limit");
        (uint256 used, uint256 out, uint160 spEnd, int24 tickEnd, uint128 liqEnd) =
            specSwap(pid, uint256(-p.amountSpecified), key.fee, key.tickSpacing, p.zeroForOne, lim);
        uint256 w = uint256(slots[bytes32(_base(pid))]);
        slots[bytes32(_base(pid))] = bytes32(
            (w & ~((uint256(1) << 184) - 1)) | uint256(spEnd) | (uint256(uint24(tickEnd)) << 160));
        slots[bytes32(_base(pid) + 3)] = bytes32(uint256(liqEnd));
        address cur = p.zeroForOne ? key.currency0 : key.currency1;
        require(pendingOwe == 0 || pendingCur == cur, "swap: two currencies owed");
        pendingCur = cur;
        pendingOwe += used;
        ++swapCount;
        spentIn[pid] += used;
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
        syncBal = currency == address(0) ? 0 : IERC20Window(currency).balanceOf(address(this));
    }

    /// Native settlement is exactly the owed value, as the singleton takes it; an ERC-20 is
    /// the balance delta since `sync`.
    function settle() external payable returns (uint256) {
        if (pendingCur == address(0)) {
            require(msg.value == pendingOwe, "settle: value != owed");
        } else {
            require(syncedFlag && syncedCur == pendingCur, "settle: not synced");
            require(IERC20Window(pendingCur).balanceOf(address(this)) - syncBal >= pendingOwe, "settle: unpaid");
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
            require(IERC20Window(currency).transfer(to, amount), "take: transfer failed");
        }
    }
}
