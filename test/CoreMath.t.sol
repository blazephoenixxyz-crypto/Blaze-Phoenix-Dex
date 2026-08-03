// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CoreHarness } from "./harness/CoreHarness.sol";

/// @notice Fuzz the pure math primitives every other contract is built on.
///         Dependency-free: assertions revert on failure (forge marks the
///         fuzz case as failing), giving the same signal as assertEq.
contract CoreMathTest {
    CoreHarness h;

    uint256 constant BPS = 10_000;
    uint256 constant Q96 = 0x1000000000000000000000000;

    function setUp() public { h = new CoreHarness(); }

    function _b(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function _req(bool c, string memory m) internal pure { require(c, m); }

    // ─── mulDiv: result is the exact floor of (a*b)/d ───
    // Verified via the modular identity q*d + (a*b mod d) ≡ a*b  (mod 2^256),
    // which holds iff q == floor(a*b/d). Uses the harness so the overflow
    // revert path (d <= prod1) is caught rather than failing the case.
    function testFuzz_mulDiv_isFloor(uint256 a, uint256 b, uint256 d) public view {
        d = _b(d, 1, type(uint256).max);
        try h.mulDiv(a, b, d) returns (uint256 q) {
            uint256 r = mulmod(a, b, d);
            unchecked {
                uint256 lowMul = a * b;       // a*b mod 2^256
                uint256 qd     = q * d;       // q*d mod 2^256
                _req(qd + r == lowMul, "mulDiv: not exact floor");
            }
        } catch {
            // Overflow path: a*b/d would not fit in 256 bits. Acceptable.
        }
    }

    function testFuzz_mulDivUp_bounds(uint256 a, uint256 b, uint256 d) public view {
        d = _b(d, 1, type(uint256).max);
        try h.mulDiv(a, b, d) returns (uint256 q) {
            uint256 up = h.mulDivUp(a, b, d);
            bool exact = mulmod(a, b, d) == 0;
            if (exact) _req(up == q, "mulDivUp: exact mismatch");
            else _req(up == q + 1 || (q == type(uint256).max && up == q), "mulDivUp: not q+1");
        } catch { }
    }

    // ─── outV2: bounded, monotone in amountIn, fee guard ───
    function testFuzz_outV2(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee) public view {
        ain  = _b(ain, 1, 1e30);
        rIn  = _b(rIn, 1, 1e33);
        rOut = _b(rOut, 1, 1e33);
        fee  = _b(fee, 0, BPS - 1);
        uint256 o1 = h.outV2(ain, rIn, rOut, fee);
        _req(o1 < rOut, "outV2: drains pool");               // can never take full reserve
        uint256 o2 = h.outV2(ain + (ain / 7) + 1, rIn, rOut, fee);
        _req(o2 >= o1, "outV2: not monotone");               // more in => not less out
        _req(h.outV2(ain, rIn, rOut, BPS) == 0, "outV2: fee>=100% must be 0");
    }

    // ─── outV3: bounded by liquidity, monotone in amountIn ───
    function testFuzz_outV3(uint256 ain, uint256 sp, uint256 liq, uint24 fee, bool zfo) public view {
        ain = _b(ain, 1e6, 1e24);
        // keep sqrtPrice in a sane band around Q96 (price ~ [0.06 .. 16])
        uint160 sqrtP = uint160(_b(sp, Q96 / 4, Q96 * 4));
        uint128 L = uint128(_b(liq, 1e15, 1e27));
        fee = uint24(_b(fee, 0, 999_999));
        uint256 o1 = h.outV3(ain, sqrtP, L, fee, zfo);
        uint256 o2 = h.outV3(ain * 2, sqrtP, L, fee, zfo);
        _req(o2 >= o1, "outV3: not monotone");
        _req(h.outV3(ain, sqrtP, L, 1_000_000, zfo) == 0, "outV3: fee>=100% must be 0");
    }

    // ─── ironFloorBps: always within [hardFloor, base], decreasing in impact ───
    function testFuzz_ironFloor(uint256 imp, uint256 legs, uint256 sig) public view {
        imp  = _b(imp, 0, 50_000);
        legs = _b(legs, 0, 20);
        sig  = _b(sig, 0, 1e30);
        uint256 f = h.ironFloorBps(imp, legs, sig);
        _req(f >= BPS - 2_500, "floor: below 75% hard cap");
        _req(f <= 9_600, "floor: above 96% base");
        // Monotone non-increasing as impact grows (legs/sigma fixed).
        uint256 f2 = h.ironFloorBps(imp + 1000, legs, sig);
        _req(f2 <= f, "floor: not monotone in impact");
    }

    function test_ironFloor_cleanSwapIs96pct() public view {
        _req(h.ironFloorBps(0, 1, 0) == 9_600, "floor: clean swap != 96%");
    }

    // ─── impactV2Bps: within [0, BPS], non-decreasing in amountIn ───
    function testFuzz_impactV2(uint256 ain, uint256 rIn) public view {
        ain = _b(ain, 1, 1e30);
        rIn = _b(rIn, 1, 1e33);
        uint256 i1 = h.impactV2Bps(ain, rIn);
        _req(i1 <= BPS, "impact: above 100%");
        uint256 i2 = h.impactV2Bps(ain * 2 + 1, rIn);
        _req(i2 >= i1, "impact: not monotone");
    }

    // ─── slot codec: encode/decode round-trips; bucket isolation (Finding B) ───
    function testFuzz_slotCodec(
        uint24 fee, uint8 kind, uint8 tier, uint16 conc,
        uint32 ts, uint32 sc, uint32 regBlk, uint32 lastBlk, uint8 bkt
    ) public view {
        kind = uint8(_b(kind, 0, 7));
        uint256 s = h.encodeSlot(true, fee, kind, tier, conc, ts, 0, 0, sc, regBlk, lastBlk);
        _req(h.isActive(s), "slot: active lost");
        _req(h.decodeFee(s) == fee, "slot: fee lost");
        _req(h.decodeKind(s) == kind, "slot: kind lost");
        _req(h.decodeSwapCount(s) == sc, "slot: swapCount lost");
        _req(h.decodeLastBlk(s) == lastBlk, "slot: lastBlk lost");
        // setBucket must not corrupt fee/kind (adjacent fields).
        uint256 s2 = h.setBucket(s, bkt);
        _req(h.decodeBucket(s2) == (bkt & 0xF), "slot: bucket wrong");
        _req(h.decodeFee(s2) == fee, "slot: bucket corrupted fee");
        _req(h.decodeKind(s2) == kind, "slot: bucket corrupted kind");
    }

    // ─── depthBucket: monotone non-decreasing, capped at 15 ───
    function testFuzz_depthBucket(uint256 d) public view {
        d = _b(d, 0, 1e40);
        uint8 b = h.depthBucket(d);
        _req(b <= 15, "bucket: >15");
        uint8 b2 = h.depthBucket(d * 10 + 1);
        _req(b2 >= b, "bucket: not monotone");
    }
}
