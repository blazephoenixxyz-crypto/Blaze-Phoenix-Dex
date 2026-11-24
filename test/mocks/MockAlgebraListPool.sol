// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockV3TickPool} from "./MockV3TickPool.sol";

/// @notice An Algebra Integral face on a MockV3TickPool book: no `slot0()`, the price and
///         the tick in `globalState()`, and the initialized ticks as the linked list the
///         pool keeps (`prevTickGlobal()` / `nextTickGlobal()` around the price, then
///         `ticks(t)` answering liquidityDelta in word 1, prevTick in word 2 and nextTick
///         in word 3), closed by the MIN_TICK / MAX_TICK sentinels. The book itself, and
///         the swap that is the oracle (`specSwap`), stay in the MockV3TickPool: one
///         book, two shapes.
contract MockAlgebraListPool {
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;

    MockV3TickPool public immutable book;
    int24[] internal inits;
    /// 0 honest; 1 the boundary getters do not answer (a pool with no list); 2 the boundary
    /// is the one behind the price; 3 `ticks` points past the tick bounds.
    uint8 public lie;

    /// @param sorted the book's initialized ticks, ascending.
    constructor(MockV3TickPool b, int24[] memory sorted) {
        book = b;
        inits = sorted;
    }

    function tellThisLie(uint8 l) external { lie = l; }

    function token0() external view returns (address) { return book.token0(); }
    function token1() external view returns (address) { return book.token1(); }
    function fee() external view returns (uint16) { return uint16(book.fee()); }
    function tickSpacing() external view returns (int24) { return book.tickSpacing(); }
    function liquidity() external view returns (uint128) { return book.liquidity(); }

    function globalState() external view returns (uint160 price, int24 tick, uint16, uint8, uint16, bool) {
        (price, tick, , , , , ) = book.slot0();
        return (price, tick, uint16(book.fee()), 0, 0, true);
    }

    function prevTickGlobal() external view returns (int24) {
        require(lie != 1, "no list");
        (, int24 tick, , , , , ) = book.slot0();
        return lie == 2 ? _after(tick) : _atOrBefore(tick);
    }

    function nextTickGlobal() external view returns (int24) {
        require(lie != 1, "no list");
        (, int24 tick, , , , , ) = book.slot0();
        return lie == 2 ? _atOrBefore(tick) : _after(tick);
    }

    function ticks(int24 t)
        external view
        returns (uint256 total, int128 delta, int24 prevTick, int24 nextTick, uint256, uint256)
    {
        (bool ok, bytes memory r) = address(book).staticcall(abi.encodeWithSignature("ticks(int24)", t));
        require(ok, "book");
        (total, delta) = abi.decode(r, (uint256, int128));
        prevTick = t == MIN_TICK ? MIN_TICK : _atOrBefore(t - 1);
        nextTick = t == MAX_TICK ? MAX_TICK : _after(t);
        if (lie == 3) (prevTick, nextTick) = (MIN_TICK - 1, MAX_TICK + 1);
        return (total, delta, prevTick, nextTick, 0, 0);
    }

    function _atOrBefore(int24 t) internal view returns (int24 p) {
        p = MIN_TICK;
        for (uint256 i; i < inits.length && inits[i] <= t; ++i) p = inits[i];
    }

    function _after(int24 t) internal view returns (int24) {
        for (uint256 i; i < inits.length; ++i) if (inits[i] > t) return inits[i];
        return MAX_TICK;
    }
}
