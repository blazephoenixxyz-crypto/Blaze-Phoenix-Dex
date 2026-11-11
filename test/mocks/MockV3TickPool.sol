// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IERC20V3Tick {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IV3SwapCallbackTick {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice A Uniswap-V3-shaped pool that CROSSES its initialized ticks when it swaps: the V3
///         twin of MockV4TickManager (DEX-01). It answers the getters a V3 book is read through
///         (slot0 with its tick, liquidity, fee, tickSpacing, tickBitmap(int16), ticks(int24)
///         with liquidityNet in word 1) and swaps with UniswapV3Pool.swap's loop written HERE
///         from the specification. Its tick-to-price arithmetic is its own (fixed point at
///         1e38, squaring sqrt(1.0001)), not the TickMath table the Core uses, and it scans
///         initialized ticks one compressed tick at a time rather than a bitmap word at a time:
///         a quote the Core computes is measured against a second implementation, not against
///         itself. Exact input only; the output is paid before the callback, as the pool pays.
contract MockV3TickPool {
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    /// @dev How far the specification's scan looks for the next initialized tick, in
    ///      compressed ticks, before treating the rest of the book as empty.
    uint256 internal constant SCAN = 4096;

    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint128 public liquidity;
    uint160 internal sqrtP;
    int24 internal tick;
    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => int128) internal net;
    mapping(int24 => uint128) internal gross;
    /// @notice Gas each slot0() and ticks() read burns; zero (the default) burns none and checks
    ///         nothing. Non-zero, those two getters model a pool whose code reads gasleft(): one
    ///         handed less than the 98,000 a GAS_CAP read leaves it after dispatch refuses (so a
    ///         caller that swallows the failure reads zero), and an answered read costs `burn`.
    uint256 public burn;

    constructor(address a, address b, uint24 f, int24 ts) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
        tickSpacing = ts;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        _hungry();
        return (sqrtP, tick, 0, 0, 0, 0, true);
    }

    function ticks(int24 t)
        external view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        _hungry();
        return (gross[t], net[t], 0, 0, 0, 0, 0, gross[t] != 0);
    }

    function burnOnRead(uint256 b) external {
        burn = b;
    }

    /// @dev The gas is read before `burn` is loaded, so the check sees what the caller handed.
    function _hungry() internal view {
        uint256 g = gasleft();
        uint256 b = burn;
        if (b == 0) return;
        if (g < 98_000) revert();
        uint256 stop = gasleft() - b;
        while (gasleft() > stop) {}
    }

    /// @notice The price at tick `t`, by this mock's own arithmetic, with `t` as slot0's tick.
    function initialize(int24 t) external {
        tick = t;
        sqrtP = sqrtAt(t);
    }

    /// @notice A hostile book: slot0 reports `t` and keeps its price. The positions already in
    ///         the book stay where they are.
    function lieAboutTheTick(int24 t) external {
        tick = t;
    }

    /// @notice A hostile book: tickSpacing() answers `ts`. Nothing else moves, and neither
    ///         addPosition nor specSwap is called on the book after it (both divide by it).
    function lieAboutTheSpacing(int24 ts) external {
        tickSpacing = ts;
    }

    /// @notice A hostile book: tick `t`'s liquidityNet answers `n`. The bitmap and the
    ///         liquidity already in the book stay where they are.
    function lieAboutTheNet(int24 t, int128 n) external {
        net[t] = n;
    }

    /// @notice A liquidity position [lower, upper) of `liq`, both ticks on the spacing.
    function addPosition(int24 lower, int24 upper, uint128 liq) external {
        _bump(lower, int128(liq), liq);
        _bump(upper, -int128(liq), liq);
        if (lower <= tick && tick < upper) liquidity += liq;
    }

    function _bump(int24 t, int128 dNet, uint128 dGross) internal {
        require(t % tickSpacing == 0, "spacing");
        int24 c = t / tickSpacing;
        tickBitmap[int16(c >> 8)] |= uint256(1) << (uint256(uint24(c)) & 0xff);
        gross[t] += dGross;
        net[t] += dNet;
    }

    function _isInit(int256 c) internal view returns (bool) {
        int16 wp = int16(int24(c >> 8));
        uint256 bp = uint256(uint24(int24(c))) & 0xff;
        return (tickBitmap[wp] >> bp) & 1 == 1;
    }

    // -- tick -> price, independently of the Core's table --------------------------------

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

    // -- the swap, from the V3 specification ---------------------------------------------

    /// @notice What an exact-input swap of `amt` pays, and what it spends, walking the book one
    ///         compressed tick at a time down to (or up to) the price `limit`: between
    ///         initialized ticks the liquidity is constant; crossing one applies its
    ///         liquidityNet, negated going down.
    function specSwap(uint256 amt, bool zfo, uint160 limit)
        public view returns (uint256 used, uint256 out, uint160 spEnd, int24 tickEnd, uint128 liqEnd)
    {
        uint160 sp = sqrtP;
        int24 tk = tick;
        uint128 L = liquidity;
        int256 ts = int256(tickSpacing);
        uint256 rem = amt;
        int256 c = int256(tk) / ts;
        if (tk < 0 && int256(tk) % ts != 0) c--;
        if (!zfo) c++;
        for (uint256 n; n < SCAN && rem > 0; ++n) {
            // the next initialized tick in the swap's direction, one compressed tick at a time
            bool init;
            while (true) {
                init = _isInit(c);
                if (init) break;
                if (zfo ? c * ts <= MIN_TICK : c * ts >= MAX_TICK) break;
                if (++n >= SCAN) break;
                if (zfo) c--; else c++;
            }
            int256 nt = c * ts;
            if (nt < MIN_TICK) nt = MIN_TICK;
            if (nt > MAX_TICK) nt = MAX_TICK;
            uint160 target = sqrtAt(int24(nt));
            bool limited = zfo ? target < limit : target > limit;
            if (limited) target = limit;
            uint256 remLessFee = rem * (1_000_000 - fee) / 1_000_000;
            // input to reach the target, rounded up; output, rounded down
            uint256 toTarget = zfo
                ? _up(BPC.mulDivUp(uint256(L) << 96, uint256(sp) - target, sp), target)
                : BPC.mulDivUp(L, uint256(target) - sp, BPC.Q96);
            uint160 np;
            if (remLessFee >= toTarget) {
                np = target;
                uint256 spent = toTarget + BPC.mulDivUp(toTarget, fee, 1_000_000 - fee);
                used += spent;
                rem -= spent;
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
            if (np != target || limited) {
                // Spent inside this stretch, or stopped at the limit: the tick is the largest one
                // whose price is at or below where the price stopped.
                tk = zfo ? _tickAt(np, int24(nt), tk) : _tickAt(np, tk, int24(nt));
                sp = np;
                break;
            }
            sp = np;
            if (init) {
                int256 d = int256(net[int24(nt)]);
                if (zfo) d = -d;
                L = uint128(uint256(int256(uint256(L)) + d));
            }
            tk = zfo ? int24(nt) - 1 : int24(nt);
            if (nt == MIN_TICK || nt == MAX_TICK) break;
            if (zfo) c--; else c++;
        }
        spEnd = sp;
        tickEnd = tk;
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

    /// @notice UniswapV3Pool.swap, exact input: the price limit checked as the pool checks it
    ///         ('SPL'), the state moved, the output paid, then the callback asked for the input.
    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 sqrtPriceLimitX96, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified > 0, "MockV3TickPool: exact-out unsupported");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtP && sqrtPriceLimitX96 > MIN_SQRT
                : sqrtPriceLimitX96 > sqrtP && sqrtPriceLimitX96 < MAX_SQRT,
            "SPL"
        );
        (uint256 used, uint256 out, uint160 spEnd, int24 tickEnd, uint128 liqEnd) =
            specSwap(uint256(amountSpecified), zeroForOne, sqrtPriceLimitX96);
        (sqrtP, tick, liquidity) = (spEnd, tickEnd, liqEnd);
        (address tIn, address tOut) = zeroForOne ? (token0, token1) : (token1, token0);
        amount0 = zeroForOne ? int256(used) : -int256(out);
        amount1 = zeroForOne ? -int256(out) : int256(used);
        if (out != 0) IERC20V3Tick(tOut).transfer(recipient, out);
        uint256 balBefore = IERC20V3Tick(tIn).balanceOf(address(this));
        IV3SwapCallbackTick(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20V3Tick(tIn).balanceOf(address(this)) >= balBefore + used, "IIA");
    }
}
