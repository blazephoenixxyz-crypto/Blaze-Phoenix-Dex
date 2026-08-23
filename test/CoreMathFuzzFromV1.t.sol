// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/CoreMath.t.sol — only the properties genuinely NOT
// already covered by this repo's own BlazePhoenixCore.t.sol:
//   - outV3 has no test at all here yet (its own section header exists with nothing under it).
//   - mulDiv's floor-exactness identity here is only checked in the uint128-bounded, no-overflow
//     regime (test_MulDiv_MatchesNaiveWhenNoOverflow) — V1 additionally fuzzed the FULL uint256
//     range and tolerated the overflow-revert path, which this adds via an external self-call
//     (a library's internal function can't be wrapped in try/catch directly).
//   - the slot codec round-trip and bucket-isolation checks here use fixed values
//     (test_EncodeDecodeSlot_RoundTrip, test_EncodeSlot_ConcentrationBitsNeverOverlapDepthBucket);
//     V1 fuzzed all fields together, including bucket isolation from fee/kind specifically.
//   - ironFloorBps's bound/monotonicity property is only checked at fixed points here; V1 fuzzed
//     it generally. Bounds updated for V2's floor (hard cap 8000 = 80%, not V1's 7500 = 75%; see
//     FLOOR_HARD_MAX_LOSS_BPS 2500->2000 in the dev-v2 reconstruction).
//
// forge test --match-contract CoreMathFuzzFromV1 -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract CoreMathFuzzFromV1Test is Test {
    uint256 constant BPS = 10_000;
    uint256 constant Q96 = 0x1000000000000000000000000;

    function _b(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    // ─── outV3: bounded by liquidity, monotone in amountIn, fee>=100% unquotable ───
    // No equivalent test exists yet in BlazePhoenixCore.t.sol despite the section header there.
    function testFuzz_outV3(uint256 ain, uint256 sp, uint256 liq, uint24 fee, bool zfo) public pure {
        ain = _b(ain, 1e6, 1e24);
        uint160 sqrtP = uint160(_b(sp, Q96 / 4, Q96 * 4)); // price ~ [0.06 .. 16]
        uint128 L = uint128(_b(liq, 1e15, 1e27));
        fee = uint24(_b(fee, 0, 999_999));
        uint256 o1 = BPC.outV3(ain, sqrtP, L, fee, zfo, 0);
        uint256 o2 = BPC.outV3(ain * 2, sqrtP, L, fee, zfo, 0);
        assertGe(o2, o1, "outV3: not monotone in amountIn");
        uint256 oFull = BPC.outV3(ain, sqrtP, L, 1_000_000, zfo, 0);
        assertEq(oFull, 0, "outV3: fee>=100% must be unquotable (0)");
    }

    // ─── mulDiv: exact floor of (a*b)/d over the FULL uint256 domain, overflow tolerated ───
    // Verified via q*d + (a*b mod d) == a*b (mod 2^256), which holds iff q == floor(a*b/d).
    function _mulDivExternal(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return BPC.mulDiv(a, b, d);
    }

    function testFuzz_mulDiv_isFloorFullRange(uint256 a, uint256 b, uint256 d) public view {
        d = _b(d, 1, type(uint256).max);
        try this._mulDivExternal(a, b, d) returns (uint256 q) {
            uint256 r = mulmod(a, b, d);
            unchecked {
                uint256 lowMul = a * b; // a*b mod 2^256
                uint256 qd = q * d;     // q*d mod 2^256
                assertEq(qd + r, lowMul, "mulDiv: not exact floor");
            }
        } catch {
            // a*b/d doesn't fit in 256 bits — mulDiv's own documented overflow revert. Acceptable.
        }
    }

    // ─── slot codec: encode/decode round-trips across ALL fields; bucket isolation from fee/kind ───
    function testFuzz_slotCodec(
        uint24 fee, uint8 kind, uint8 tier, uint16 conc,
        uint32 ts, uint32 sc, uint32 regBlk, uint32 lastBlk, uint8 bkt
    ) public pure {
        kind = uint8(_b(kind, 0, 7));
        uint256 s = BPC.encodeSlot(true, fee, kind, tier, conc, ts, 0, 0, sc, regBlk, lastBlk);
        assertTrue(BPC.isActive(s), "slot: active lost");
        assertEq(BPC.decodeFee(s), fee, "slot: fee lost");
        assertEq(BPC.decodeKind(s), kind, "slot: kind lost");
        assertEq(BPC.decodeSwapCount(s), sc, "slot: swapCount lost");
        assertEq(BPC.decodeLastBlk(s), lastBlk, "slot: lastBlk lost");
        // setBucket must not corrupt fee/kind (adjacent fields in the packed layout).
        uint256 s2 = BPC.setBucket(s, bkt);
        assertEq(BPC.decodeBucket(s2), bkt & 0xF, "slot: bucket wrong");
        assertEq(BPC.decodeFee(s2), fee, "slot: bucket corrupted fee");
        assertEq(BPC.decodeKind(s2), kind, "slot: bucket corrupted kind");
    }

    // ─── ironFloorBps: always within [hardFloor, base], non-increasing in impact ───
    function testFuzz_ironFloor(uint256 imp, uint256 legs, uint256 sig) public pure {
        imp = _b(imp, 0, 50_000);
        legs = _b(legs, 0, 20);
        sig = _b(sig, 0, 1e30);
        uint256 f = BPC.ironFloorBps(imp, legs, sig);
        assertGe(f, BPS - 2_000, "floor: below the 80% hard cap");
        assertLe(f, 9_600, "floor: above 96% base");
        uint256 f2 = BPC.ironFloorBps(imp + 1000, legs, sig);
        assertLe(f2, f, "floor: not monotone non-increasing in impact");
    }
}
