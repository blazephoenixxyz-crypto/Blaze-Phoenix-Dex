// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

/// @dev The fee hook's view, keyed by the caller of the manager's swap (the `sender` v4-core hands
///      beforeSwap). A hook that answers the Quoter one fee and the Router another is the
///      "charges differently by caller" venue of test/DirtyWorld.invariant.t.sol.
interface IDWFeeHook {
    function beforeSwapFee(address sender) external view returns (uint24);
}

/// @dev An ADMITTED static-fee hook holding BEFORE_SWAP only (no delta bits): before each swap
///      it moves the pool in the swap's direction by `frontRun(amountIn)`, an amount read from
///      its own STORAGE. Its admin turns that knob after admission: the runtime code, so the
///      codehash the Hub pinned, never changes, and the Layer-3 auto-pause never fires.
interface IDWMoverHook {
    function frontRun(uint256 amountIn) external view returns (uint256);
}

interface IERC20DW {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice MockV4DynFeeManager (test/Fix1019DynFeeOverrideExplicitDoor.t.sol, oc-1018/m2) with one
///         change: the dynamic-fee override is asked of the hook WITH the caller, and only when the
///         hook holds BEFORE_SWAP. Storage layout, extsload offsets, spec swap and flash accounting
///         are byte-for-byte the original's.
contract MockV4HookedManager {
    // (second change, 2026-10-20: the admitted mover hook of IDWMoverHook, static keys only)
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
        return abi.decode(ret, (bytes)); // v4-core: the callback's bytes, unchanged
    }

    /// @dev THE ONLY CHANGE FROM MockV4TickManager: a DYN key takes its swap
    ///      fee from beforeSwap's return, never from the key. The sieve that
    ///      admits this pool reads neither this value nor the hook's code.
    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (int256) {
        bytes32 pid = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        uint24 fee = key.fee;
        // A dynamic key whose hook holds BEFORE_SWAP (1 << 7) takes its fee from what the hook
        // returns for THIS caller (v4-core passes the locker as `sender` to beforeSwap). Static
        // keys ignore the hook, as in v4-core: the override flag is only honoured on 0x800000.
        if (key.fee == 0x800000 && uint160(key.hooks) & 0x80 != 0) {
            fee = IDWFeeHook(key.hooks).beforeSwapFee(msg.sender);
        }
        // A STATIC key whose hook holds BEFORE_SWAP may still act before the swap (here: its
        // own swap on the same pool, in the same direction, paid by the hook). The quote of
        // the pool's slot0 cannot see it; a dry-run through the manager does.
        if (key.fee != 0x800000 && uint160(key.hooks) & 0x80 != 0) {
            uint256 front = IDWMoverHook(key.hooks).frontRun(uint256(-p.amountSpecified));
            if (front != 0) {
                (,, uint160 fsp, int24 ftick, uint128 fliq) =
                    specSwap(pid, front, fee, key.tickSpacing, p.zeroForOne);
                uint256 fw = uint256(slots[bytes32(_base(pid))]);
                slots[bytes32(_base(pid))] = bytes32(
                    (fw & ~((uint256(1) << 184) - 1)) | uint256(fsp) | (uint256(uint24(ftick)) << 160));
                slots[bytes32(_base(pid) + 3)] = bytes32(uint256(fliq));
            }
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
        syncBal = currency == address(0) ? 0 : IERC20DW(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256) {
        if (pendingCur == address(0)) {
            require(msg.value == pendingOwe, "settle: value != owed");
        } else {
            require(syncedFlag && syncedCur == pendingCur, "settle: not synced");
            require(IERC20DW(pendingCur).balanceOf(address(this)) - syncBal >= pendingOwe, "settle: unpaid");
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
            require(IERC20DW(currency).transfer(to, amount), "take: transfer failed");
        }
    }
}
