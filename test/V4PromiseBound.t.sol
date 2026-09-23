// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The in-frame PROMISE for a V4 leg is bounded at the current range's edge.
//  Measured before this test (main 8949a9d): `sqrtBoundary` was defined in the
//  Core and called by nothing — Router._v4LegQuote priced every V4 leg with the
//  unclamped single-tick form, so a leg that left its range promised more than
//  the range could deliver and the floor, derived from that promise, followed.
//  `BlazePhoenixCore.v4LegOut` is the wired form: slot0 + liquidity from the
//  singleton, the fee in the swap's direction, and `outV3` truncated at
//  `sqrtBoundary`. This test is red on the unwired code (the function does not
//  exist there) and stays red on the mutant that passes 0 as the limit.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract MockV4ManagerTicked {
    mapping(bytes32 => bytes32) public slot;
    function set(bytes32 s, bytes32 v) external { slot[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slot[s]; }
}

contract V4PromiseBoundTest is Test {
    int24 constant TS = int24(60);
    MockV4ManagerTicked mgr;
    address tokenA = address(0xA11);
    address tokenB = address(0xB22);
    bytes32 pid;

    function setUp() public {
        mgr = new MockV4ManagerTicked();
        (address s0, address s1) = BPC.sortTokens(tokenA, tokenB);
        pid = BPC.computeV4PoolId(s0, s1, 3000, TS, address(0));
    }

    /// @dev slot0 = sqrtPriceX96 | tick<<160 | protocolFee<<184 | lpFee<<208; liquidity at +3.
    function _seed(uint160 sqrtP, int24 tick, uint24 protoFee, uint24 lpFee, uint128 liq) internal {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        bytes32 word0 = bytes32(
            uint256(sqrtP) | (uint256(uint24(tick)) << 160) | (uint256(protoFee) << 184) | (uint256(lpFee) << 208)
        );
        mgr.set(base, word0);
        mgr.set(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    function test_RangeExit_PromiseIsTruncatedAtTheBoundary() public {
        // tick 59 of a 60-spaced pool, price 1, thin liquidity, a swap that would
        // push the price far below the range's lower edge.
        uint160 P = uint160(BPC.Q96);
        _seed(P, int24(59), 0, 3000, uint128(1e18));
        uint256 amt = 1e21;
        uint256 bounded   = BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, true);
        uint256 unclamped = BPC.outV3(amt, P, uint128(1e18), 3000, true, 0);
        uint256 expected  = BPC.outV3(amt, P, uint128(1e18), 3000, true, BPC.sqrtBoundary(P, int24(59), TS, true));
        assertEq(bounded, expected, "promise must be the boundary-truncated single-tick output");
        assertLt(bounded, unclamped, "a leg that leaves its range promises strictly less than the unclamped form");
        assertGt(bounded, 0, "and still a positive promise for what fits inside the range");
    }

    function test_InsideRange_PromiseEqualsSingleTickForm() public {
        // a small swap deep inside the range: the clamp does not bind
        uint160 P = uint160(BPC.Q96);
        _seed(P, int24(30), 0, 3000, uint128(1e24));
        uint256 amt = 1e18;
        assertEq(BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, true), BPC.outV3(amt, P, uint128(1e24), 3000, true, 0));
    }

    function test_StaticKey_ProtocolFee_ReachesThePromise() public {
        // the same pool with a 5-pip zeroForOne protocol fee promises less than without it
        uint160 P = uint160(BPC.Q96);
        _seed(P, int24(30), 0, 3000, uint128(1e24));
        uint256 without = BPC.v4LegOut(address(mgr), pid, 1e18, 3000, TS, true);
        _seed(P, int24(30), 5, 3000, uint128(1e24));
        uint256 withFee = BPC.v4LegOut(address(mgr), pid, 1e18, 3000, TS, true);
        assertLt(withFee, without, "a protocol fee on a static key lowers the promise");
        assertEq(withFee, BPC.outV3(1e18, P, uint128(1e24), 3005, true, 0), "by exactly the composed fee");
    }

    /// V4-4: going DOWN from a tick that is itself a range boundary, the lower edge is
    /// less than one tick away. The promise there must not exceed the promise one tick
    /// inside the range (continuity across the boundary). Measured before the fix: the
    /// boundary tick promised a full spacing of this range's liquidity below the edge.
    function test_BoundaryTick_Down_PromisesNoMoreThanOneTickInside() public {
        uint160 P = uint160(BPC.Q96);
        uint256 amt = 1e21;                                   // large enough to leave the range
        _seed(P, int24(0), 0, 3000, uint128(1e18));
        uint256 atBoundary = BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, true);
        _seed(P, int24(1), 0, 3000, uint128(1e18));
        uint256 oneInside = BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, true);
        _seed(P, int24(59), 0, 3000, uint128(1e18));
        uint256 farInside = BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, true);
        assertLe(atBoundary, oneInside, "the boundary tick promises no more than one tick inside");
        assertLt(oneInside, farInside, "and the promise grows with the distance to the edge");
        assertGt(atBoundary, 0, "while still promising what the last tick holds");
    }

    /// The mirror: going UP from the same boundary tick the range lies ahead, less the
    /// one tick the price may already be inside (the clamp counts from the price, not
    /// from the tick's start - see the next test). Periodic in the spacing.
    function test_BoundaryTick_Up_PromisesTheWholeRange() public {
        uint160 P = uint160(BPC.Q96);
        uint256 amt = 1e21;
        _seed(P, int24(0), 0, 3000, uint128(1e18));
        uint256 up = BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, false);
        assertEq(up, BPC.outV3(amt, P, uint128(1e18), 3000, false, BPC.sqrtBoundary(P, int24(0), TS, false)), "one spacing ahead");
        assertEq(BPC.sqrtBoundary(P, int24(0), TS, false), BPC.sqrtBoundary(P, int24(60), TS, false), "the up clamp is periodic in the spacing");
    }

    /// The up arm with the price INSIDE its tick. The fixtures above sit at the bottom
    /// of their tick (price 1 with tick 0/59), which is the one position where counting
    /// the range from the tick's start is exact. At 0.9 of tick 30 the true top edge
    /// (tick 60) is 29.1 ticks away; the promise may not price liquidity beyond it.
    /// The edge is the exact sqrt price at tick 60, computed outside the Core.
    /// RED at 28118dd: the promise was 1.030x the range's output.
    function test_Up_PriceInsideItsTick_PromiseNeverExceedsTheRangeOutput() public {
        uint160 P = uint160(79350658504438321566761821096);     // sqrt(1.0001^30.9) * 2^96
        uint160 edge = uint160(79466191966197645195421774832);  // sqrt(1.0001^60)   * 2^96
        uint256 amt = 1e21;                                     // leaves the range
        _seed(P, int24(30), 0, 3000, uint128(1e18));
        uint256 promised = BPC.v4LegOut(address(mgr), pid, amt, 3000, TS, false);
        // The range's whole token0 content, from the closed form - not from `outV3`, which is
        // the function under test: a bound it computed would move with any defect in it.
        uint256 rangeOut = _rangeCap(P, edge, uint128(1e18), true);
        emit log_named_uint("promised  ", promised);
        emit log_named_uint("range out ", rangeOut);
        assertLe(promised, rangeOut, "the up clamp priced liquidity beyond the edge of the range");
        assertGt(promised, rangeOut * 95 / 100, "and it stays within one tick of the edge");
    }

    /// Everything a range of liquidity `L` holds between the price `P` and the edge `e`,
    /// before fees: token0 on the way up, `L*Q96*(e-P)/(P*e)`; token1 on the way down,
    /// `L*(P-e)/Q96`. Rounded UP, because it is a ceiling.
    function _rangeCap(uint160 P, uint160 e, uint128 L, bool up) internal pure returns (uint256) {
        return up
            ? BPC.mulDivUp(BPC.mulDivUp(uint256(L), uint256(e) - uint256(P), uint256(e)), BPC.Q96, uint256(P))
            : BPC.mulDivUp(uint256(L), uint256(P) - uint256(e), BPC.Q96);
    }

    // ─── The promise across its dimensions ────────────────────────────────────
    // direction × spacing × tick × where the price sits inside its tick. The
    // fixed tests above each hold one cell; the defect closed above lived in a
    // cell none of them held (up, price inside its tick). The oracle is the
    // tick's sqrt price computed HERE, by squaring sqrt(1.0001) in 1e38 fixed
    // point - never by the Core - rounded so the bound it gives is the stricter.

    uint256 constant ONE38 = 1e38;
    uint256 constant SQRT_1_0001 = 100004999875006249609402341699379869721; // sqrt(1.0001) * 1e38

    function _sqrtAt(int256 t) internal pure returns (uint160) {
        uint256 k = uint256(t < 0 ? -t : t);
        uint256 r = ONE38;
        uint256 b = SQRT_1_0001;
        while (k != 0) {
            if (k & 1 == 1) r = BPC.mulDiv(r, b, ONE38);
            b = BPC.mulDiv(b, b, ONE38);
            k >>= 1;
        }
        return t < 0 ? uint160(BPC.mulDiv(BPC.Q96, ONE38, r)) : uint160(BPC.mulDiv(BPC.Q96, r, ONE38));
    }

    /// The promise never prices liquidity beyond its range's edge, in either direction,
    /// at any spacing, anywhere inside the tick - except by the one tick the clamp keeps
    /// on purpose when the edge is less than one tick away (the V4-4 tolerance).
    function testFuzz_ThePromiseNeverPricesBeyondItsRange(
        int24 tickSeed, uint16 fracSeed, uint8 spacingSel, bool up
    ) public {
        int256 S = spacingSel % 4 == 0 ? int256(1) : spacingSel % 4 == 1 ? int256(10)
                 : spacingSel % 4 == 2 ? int256(60) : int256(200);
        int256 t = int256(tickSeed) % 200_000;
        uint256 frac = 1 + uint256(fracSeed) % 998;               // per mille, never on an edge
        uint160 pT = _sqrtAt(t);
        uint160 P = uint160(pT + (uint256(_sqrtAt(t + 1)) - pT) * frac / 1000);
        int256 r = t % S;
        if (r < 0) r += S;
        int256 edgeTick = up ? t - r + S : t - r;
        bool withinOneTick = up ? r == S - 1 : r == 0;
        if (withinOneTick) edgeTick = up ? edgeTick + 1 : edgeTick - 1;
        uint256 amt = 1e30;                                       // large enough to leave most ranges

        _seed(P, int24(t), 0, 3000, uint128(1e18));
        uint256 promised = BPC.v4LegOut(address(mgr), pid, amt, 3000, int24(S), !up);
        uint256 bound = _rangeCap(P, _sqrtAt(edgeTick), uint128(1e18), up);
        assertLe(promised, bound, "the promise priced liquidity beyond the edge of its range");
        assertGt(promised, 0, "a range holding liquidity promised nothing");
    }

    /// A dynamic-fee key (fee sentinel 0x800000) under a non-zero protocol fee cannot be
    /// priced in the frame: the promise is zero, so the floor is the caller's attestation and
    /// userMinOut (SOK-DYNFEE-PROTOFEE). Pinned so the residual is visible, not assumed.
    function test_DynamicFeeKey_UnderProtocolFee_PromisesZero() public {
        uint160 P = uint160(BPC.Q96);
        (address s0, address s1) = BPC.sortTokens(tokenA, tokenB);
        bytes32 dyn = BPC.computeV4PoolId(s0, s1, 0x800000, TS, address(0));
        bytes32 base = keccak256(abi.encode(dyn, uint256(6)));
        mgr.set(base, bytes32(uint256(P) | (uint256(uint24(int24(30))) << 160) | (uint256(5) << 184) | (uint256(3000) << 208)));
        mgr.set(bytes32(uint256(base) + 3), bytes32(uint256(1e24)));
        assertEq(BPC.v4LegOut(address(mgr), dyn, 1e18, 0x800000, TS, true), 0, "dynamic fee under a protocol fee promises zero");
    }

    function test_EmptyPool_PromisesZero() public view {
        assertEq(BPC.v4LegOut(address(mgr), pid, 1e18, 3000, TS, true), 0);
    }
}
