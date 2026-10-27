// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A Solidly pair without a stable() getter (Aerodrome 2026 V2, 2026-10-26).
//  Red at 1d9c610, three ways:
//    - SHAPE. The probe read only stable(). The 2026 Aerodrome V2 factories
//      fix the curve per factory (one Volatile, one Stable) and their pairs
//      have no stable() getter, so every such pair read as a Uniswap-V2 pair:
//      the swap door registered it as KIND_V2 and it was priced with V2 math
//      at 30 bps instead of asked.
//    - FAIL CLOSED. A Solidly leg whose pair answered neither quote ask was
//      priced on the replicated curve the calldata's `stable` flag picked.
//      For a pair that does not answer stable() that flag is nobody's word:
//      the volatile curve on a stable pool is not conservative (it under-asks
//      a balanced pool and over-asks a skewed one, which then reverts in K).
//    - GAS. A probe run on less than GAS_CAP of gas could fail for want of
//      gas, and the shape read the failure as an answer. The new pairs' fee
//      read checks gasleft() before its fee module and reverts EARLY, handing
//      the gas back, so the caller of the swap door chose the gas that made
//      the probe fail and the pair stayed registered as V2.
//
//  Now: a pair is Solidly-shaped when it answers stable() with an ABI bool, or
//  when it answers the total-fee ask getAmountOutWithTotalFee(0, address(0))
//  with 0 - the output of nothing is nothing, so a catch-all fallback's
//  nonzero word is not an answer. A pair that does not answer stable() has no
//  curve the Core can replicate, so the replicated-curve fallback quotes 0
//  for it. Every one-word ask needs headroom for the whole GAS_CAP (EIP-150
//  keeps 1/64; a cold access costs 2 600) or the read reverts empty, the
//  house's out-of-gas signature: a pool's answer is never read on less.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @dev The 2026 Aerodrome V2 pair as the Core reads it (metadex-public 8b506b4, read as data):
///      no stable() - its factory fixes the curve - and the total-fee ask, whose fee read checks
///      gasleft() before the fee module (`if (gasleft() <= 60_000) revert`). The check is modelled
///      in the pair: a starved ask reverts early and hands its gas back. `mute` makes it answer
///      nothing at all.
contract NoStableGetterPair {
    address public token0;
    address public token1;
    uint256 public reserve0;
    uint256 public reserve1;
    bool public mute;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setReserves(uint256 r0, uint256 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    function setMute(bool m) external {
        mute = m;
    }

    function getReserves() external view returns (uint256, uint256, uint256) {
        return (reserve0, reserve1, block.timestamp);
    }

    function getAmountOutWithTotalFee(uint256 amountIn, address tokenIn) external view returns (uint256) {
        if (gasleft() <= 60_000 || mute) revert();
        if (amountIn == 0) return 0;
        (uint256 rIn, uint256 rOut) = tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 a = amountIn - (amountIn * 30) / 10_000;
        return (a * rOut) / (rIn + a);
    }
}

/// @dev An old-shape Solidly pair whose stable() answer costs nearly the whole GAS_CAP: it is
///      read right only when the probe runs on the cap. Cold, the call's account access alone
///      costs 2 600 gas, so a floor without that term still starves it.
contract CapHungryStablePair {
    function stable() external view returns (bool) {
        if (gasleft() < 99_000) revert();
        return false;
    }
}

/// @dev The same appetite on a stable pair: its registration's stable bit is read right only
///      on the cap.
contract CapHungryTrueStablePair {
    function stable() external view returns (bool) {
        if (gasleft() < 99_000) revert();
        return true;
    }
}

/// @dev A pair that answers stable() with a word that is not an ABI bool, holds reserves, and
///      answers no quote ask: it has no curve the Core can replicate.
contract NonBoolStablePair {
    address public token0;
    address public token1;
    uint112 internal r0;
    uint112 internal r1;

    constructor(address a, address b, uint112 x, uint112 y) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        (r0, r1) = (x, y);
    }

    function stable() external pure returns (uint256) {
        return 7;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, uint32(block.timestamp));
    }
}

/// @dev No stable(), and a total-fee ask that pays something for nothing.
contract SomethingForNothingPair {
    function getAmountOutWithTotalFee(uint256 amountIn, address) external pure returns (uint256) {
        return amountIn + 1;
    }
}

/// @dev No function at all.
contract NoAnswerPool {}

/// @dev A catch-all fallback that refuses stable() and answers every other call with `size`
///      bytes whose first word is `word`.
contract RawAnswerPool {
    uint256 public immutable size;
    uint256 public immutable word;

    constructor(uint256 s, uint256 w) {
        size = s;
        word = w;
    }

    fallback(bytes calldata input) external returns (bytes memory out) {
        if (input.length >= 4 && bytes4(input[:4]) == bytes4(0x22be3de1)) revert();
        out = new bytes(size);
        uint256 w = word;
        if (size >= 32) {
            assembly ("memory-safe") { mstore(add(out, 32), w) }
        }
    }
}

contract SolidlyPairWithoutStableGetterTest is Test {
    MockERC20 tA;
    MockERC20 tB;

    function setUp() public {
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
    }

    function shaped(address p) external view returns (bool) {
        return BPC.isSolidlyShaped(p);
    }

    function stableOf(address p) external view returns (bool) {
        return BPC.solidlyStable(p);
    }

    function legQuote(Leg calldata leg, address tIn, address tOut, uint256 amt)
        external view returns (uint256 q, uint256 imp, bool held)
    {
        return BPC.legQuoteImpact(leg, tIn, tOut, amt);
    }

    function _pair(uint256 r0, uint256 r1) internal returns (NoStableGetterPair p) {
        p = new NoStableGetterPair(address(tA), address(tB));
        p.setReserves(r0, r1);
        MockERC20(p.token0()).mint(address(p), r0);
        MockERC20(p.token1()).mint(address(p), r1);
    }

    /// An old-shape pair (answers stable()) that answers no quote ask: the fallback's control.
    function _oldSilentPair(uint112 r0, uint112 r1) internal returns (MockSolidlyPair p) {
        p = new MockSolidlyPair(address(tA), address(tB), false);
        p.setReserves(r0, r1);
        p.setHideGetAmountOut(true);
        MockERC20(p.token0()).mint(address(p), r0);
        MockERC20(p.token1()).mint(address(p), r1);
    }

    function _leg(address pool) internal pure returns (Leg memory l) {
        l.pool = pool;
        l.kind = BPC.KIND_SOLIDLY;
        l.zeroForOne = true;
        l.amountIn = 1e18;
    }

    // ─── Shape ────────────────────────────────────────────────────────────

    function test_Shape_PairWithoutStableGetter_IsSolidly() public {
        NoStableGetterPair p = _pair(1_000e18, 2_000e18);
        assertTrue(this.shaped(address(p)), "a pair that answers the total-fee ask for nothing with 0 is Solidly-shaped");
        (bool ok, uint8 k) = BPC.provenShape(address(p), BPC.KIND_V2);
        assertTrue(ok, "a pair-shaped declaration on a pair is not refused");
        assertEq(k, BPC.KIND_SOLIDLY, "the shape decides: declared V2, the pair is Solidly");
        assertTrue(this.shaped(address(new MockSolidlyPair(address(tA), address(tB), true))), "control: stable() is still a shape answer");
    }

    function test_Shape_AnswerToNothingMustBeNothing() public {
        assertFalse(this.shaped(address(new SomethingForNothingPair())), "a pair that pays something for nothing is not a shape answer");
        assertFalse(this.shaped(address(new RawAnswerPool(32, 7))), "a catch-all fallback's nonzero word is not a shape answer");
        assertTrue(this.shaped(address(new RawAnswerPool(32, 0))), "control: the word 0 for nothing is");
    }

    function test_Shape_NoOrShortAnswer_IsNotSolidly() public {
        assertFalse(this.shaped(address(new NoAnswerPool())), "a pool with no function is not Solidly-shaped");
        assertFalse(this.shaped(address(0xDEAD)), "an account with no code answers nothing");
        assertFalse(this.shaped(address(new RawAnswerPool(16, 0))), "half a word is not an answer");
        NoStableGetterPair p = _pair(1_000e18, 2_000e18);
        p.setMute(true);
        assertFalse(this.shaped(address(p)), "a pair that answers neither probe reads as V2");
    }

    function test_Shape_HugeAnswer_CostsTheCallerOneWord() public {
        address big = address(new RawAnswerPool(64 * 1024, 0));
        address bomb = address(new RawAnswerPool(1024 * 1024, 0));
        uint256 g0 = gasleft();
        bool y = this.shaped(big);
        uint256 used = g0 - gasleft();
        assertTrue(y, "64 KiB whose first word is 0 answers 0");
        assertLt(used, 2 * BPC.GAS_CAP + 10_000, "the caller copies one word, never the whole answer");
        g0 = gasleft();
        y = this.shaped(bomb);
        used = g0 - gasleft();
        assertFalse(y, "an answer the pool cannot pay for within the cap is no answer");
        assertLt(used, 2 * BPC.GAS_CAP + 10_000, "a returndata bomb costs at most the cap per ask");
    }

    // ─── Fail closed: no stable(), no answer, no curve ────────────────────

    function test_SolidlyAsk_UnknownCurve_AsksNothing() public {
        NoStableGetterPair p = _pair(1_000e18, 2_000e18);
        address t0 = p.token0();
        uint256 asked = p.getAmountOutWithTotalFee(1e18, t0);
        assertEq(BPC.solidlyAskOut(address(p), 1e18, t0, true, false, 0), asked - 1, "control: an answering pair is asked");
        p.setMute(true);
        assertEq(BPC.solidlyAskOut(address(p), 1e18, t0, true, false, 0), 0, "no stable() and no answer: the curve is unknown, the ask is 0");
        MockSolidlyPair old = _oldSilentPair(1_000e18, 2_000e18);
        assertGt(BPC.solidlyAskOut(address(old), 1e18, old.token0(), true, false, 0), 0, "control: a pair that answers stable() keeps the replicated curve");
    }

    /// The curve's gate is the ABI-bool answer, not any answer to stable(): a word above 1 says
    /// nothing about the curve, so the ask is 0 there too.
    function test_SolidlyAsk_StableWordNotABool_AsksNothing() public {
        NonBoolStablePair p = new NonBoolStablePair(address(tA), address(tB), 1_000e18, 2_000e18);
        MockERC20(p.token0()).mint(address(p), 1_000e18);
        MockERC20(p.token1()).mint(address(p), 2_000e18);
        assertEq(BPC.solidlyAskOut(address(p), 1e18, p.token0(), true, false, 0), 0, "a stable() word that is not a bool is no curve");
    }

    function test_LegQuote_UnknownCurve_QuotesNothing() public {
        NoStableGetterPair p = _pair(1_000e18, 2_000e18);
        (address t0, address t1) = (p.token0(), p.token1());
        (uint256 q, , bool held) = this.legQuote(_leg(address(p)), t0, t1, 1e18);
        assertTrue(held, "the pair holds its reserves");
        assertEq(q, p.getAmountOutWithTotalFee(1e18, t0), "control: an answering pair is asked");
        p.setMute(true);
        (q, , held) = this.legQuote(_leg(address(p)), t0, t1, 1e18);
        assertTrue(held, "silence is not a dead leg");
        assertEq(q, 0, "no stable() and no answer: the in-frame quote is 0, not a guessed curve");
        MockSolidlyPair old = _oldSilentPair(1_000e18, 2_000e18);
        (q, , ) = this.legQuote(_leg(address(old)), old.token0(), old.token1(), 1e18);
        assertGt(q, 0, "control: a pair that answers stable() keeps the replicated curve");
    }

    // ─── Gas: a pool's answer is never read on less than the cap ──────────

    /// Every gas limit from starvation to plenty, the pool cold each time: a probe either
    /// refuses (empty revert, the out-of-gas signature) or reads the pair's shape.
    function _sweep(address pool) internal returns (uint256 oks, uint256 refusals) {
        for (uint256 g = 60_000; g <= 260_000; g += 251) {
            vm.cool(pool);
            try this.shaped{gas: g}(pool) returns (bool y) {
                assertTrue(y, string.concat("the shape was read from a starved probe at gas ", vm.toString(g)));
                ++oks;
            } catch (bytes memory err) {
                assertEq(err.length, 0, "a refusal is the out-of-gas signature");
                ++refusals;
            }
        }
    }

    function test_ShapeUnderEveryGas_PairWithoutStableGetter_NeverReadsV2() public {
        NoStableGetterPair p = _pair(1_000e18, 2_000e18);
        (uint256 oks, uint256 refusals) = _sweep(address(p));
        assertGt(oks, 0, "the sweep reaches the gas that reads the pair");
        assertGt(refusals, 0, "the sweep starts below the gas a probe needs");
    }

    // RED-STRIP-BEGIN: answersStable does not exist before the fix.
    function answers(address p) external view returns (bool) {
        return BPC.answersStable(p);
    }

    /// The same sweep on the stable() ask alone: a cold pair that answers stable() is either
    /// answered or refused, never read as a pair that does not answer.
    function _askSweep(address pool) internal returns (uint256 oks, uint256 refusals) {
        for (uint256 g = 60_000; g <= 260_000; g += 251) {
            vm.cool(pool);
            try this.answers{gas: g}(pool) returns (bool y) {
                assertTrue(y, string.concat("the cold stable() ask was starved at gas ", vm.toString(g)));
                ++oks;
            } catch (bytes memory err) {
                assertEq(err.length, 0, "a refusal is the out-of-gas signature");
                ++refusals;
            }
        }
    }
    // RED-STRIP-END

    /// The shape alone cannot see the floor's cold-access term. A starved first ask (stable(),
    /// cold) hands the shape to the second ask (the total-fee ask), which holds the same floor
    /// after the cold access is paid: whenever that floor lets it run, the first ask had the whole
    /// cap, so a floor without the 2_600 refuses there instead of reading wrong (mutant [759]
    /// lived on the shape sweep, 2026-10-27). So the stable() ask is swept alone too: it is the
    /// shape's first ask and the gate of the replicated-curve fallback.
    function test_ShapeUnderEveryGas_ColdStableAnswer_GetsTheWholeCap() public {
        address p = address(new CapHungryStablePair());
        (uint256 oks, uint256 refusals) = _sweep(p);
        assertGt(oks, 0, "the sweep reaches the gas that reads the pair");
        assertGt(refusals, 0, "the sweep starts below the gas a probe needs");
        // RED-STRIP-BEGIN: answersStable does not exist before the fix.
        (oks, refusals) = _askSweep(p);
        assertGt(oks, 0, "the sweep reaches the gas that answers the stable() ask");
        assertGt(refusals, 0, "the sweep starts below the gas the stable() ask needs");
        // RED-STRIP-END
    }

    /// The registration's stable bit (`solidlyStable`, bit 5 of the row) is the same ask: a stable
    /// pair is never written volatile because its probe ran starved.
    function test_StableBitUnderEveryGas_NeverReadsVolatile() public {
        address p = address(new CapHungryTrueStablePair());
        uint256 oks;
        uint256 refusals;
        for (uint256 g = 60_000; g <= 260_000; g += 251) {
            vm.cool(p);
            try this.stableOf{gas: g}(p) returns (bool y) {
                assertTrue(y, string.concat("the stable bit was read from a starved probe at gas ", vm.toString(g)));
                ++oks;
            } catch (bytes memory err) {
                assertEq(err.length, 0, "a refusal is the out-of-gas signature");
                ++refusals;
            }
        }
        assertGt(oks, 0, "the sweep reaches the gas that reads the pair");
        assertGt(refusals, 0, "the sweep starts below the gas a probe needs");
    }

    // RED-STRIP-BEGIN: the floor does not exist before the fix.
    /// ASK_GAS_FLOOR is derived, and tight at its EIP-150 term: at A = GAS_CAP * 64 / 63 left at
    /// the call the callee gets the whole cap, one less and it does not. The 3_000 above A is the
    /// cold account access (2_600) and the opcodes up to the call; the cap-hungry sweeps above are
    /// its measurement (a floor without the 2_600 starves them).
    function test_TheAskFloorIsDerived() public pure {
        uint256 a = BPC.GAS_CAP * 64 / 63;
        assertGe(a - a / 64, BPC.GAS_CAP, "at A the callee gets the whole cap");
        assertLt((a - 1) - (a - 1) / 64, BPC.GAS_CAP, "and A is the least that does");
        assertEq(BPC.ASK_GAS_FLOOR, a + 3_000, "the floor is A plus the cold access and the opcodes");
    }
    // RED-STRIP-END
}
