// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  A quote is a promise about the future. This measures how it ages.
//
//  Through the public ABI — `previewAndEncode` returns the preview AND the calldata — a quote is
//  taken, the world moves (0..3 trades by someone else through the same pools, each up to 3 % of
//  the shallow reserve, in the user's direction so every one of them hurts), 0..10 seconds pass,
//  and the calldata is executed unchanged. Every outcome is classified: settled (then delivered
//  must be at least the floor the preview attested), refused by the floor (RouterE 5), refused
//  by the deadline (RouterE 4), or a third way (which fails the test). The statistics — settle
//  rate and delivered/predicted per drift bucket — are printed; the GUARANTEES are asserted:
//    * time alone never breaks a quote inside its deadline (drift 0 → 100 % settle, any delay);
//    * a settlement never delivers below the attested floor;
//    * nothing settles after the deadline;
//    * there is no third way.
//
//  forge test --match-path test/QuoteDelayStatistics.t.sol -vv
// =============================================================================
import {console2} from "forge-std/Test.sol";
import {QuoteWorld, BlazePhoenixQuoter, BlazePhoenixRouter, MockERC20, MockV2Pair} from "./QuoteWorld.sol";

contract QuoteDelayStatisticsTest is QuoteWorld {
    uint256 constant N = 240;

    function setUp() public { _world(true); }

    struct Stat { uint256 n; uint256 settled; uint256 ratioSum; uint256 ratioMin; uint256 ratioMax; uint256 refused5; }

    function test_QuoteThenExecuteUpTo10sLater_Statistics() public {
        Stat[3] memory byDrift;      // 0: no drift, 1: up to 1 %, 2: 1..3 %
        Stat[3] memory byDelay;      // 0: 0 s, 1: 1..5 s, 2: 6..10 s
        for (uint256 b; b < 3; ++b) { byDrift[b].ratioMin = type(uint256).max; byDelay[b].ratioMin = type(uint256).max; }
        uint256 noQuote; uint256 thirdWay;
        for (uint256 i; i < N; ++i) {
            uint256 rng = uint256(keccak256(abi.encode("quote-delay", i)));
            (MockERC20 tIn, MockERC20 tOut, MockV2Pair first, MockERC20 firstOut) = _pick(rng % 3);
            uint256 amountIn = 1e15 + (rng >> 8) % 3e18;
            uint256 d = (rng >> 80) % 11;
            uint256 k = (rng >> 96) % 4;
            uint256 bps = (rng >> 112) % 301;              // drift size in bps of the shallow reserve
            uint256 deadline = block.timestamp + 20;
            (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
                quoter.previewAndEncode(address(tIn), address(tOut), amountIn, user, deadline);
            if (!pv.canExecute) { ++noQuote; continue; }
            tIn.mint(user, amountIn);
            vm.prank(user); tIn.approve(address(router), amountIn);
            uint256 driftBps;
            for (uint256 j; j < k; ++j) {
                (uint112 r0, uint112 r1, ) = first.getReserves();
                uint256 rIn = first.token0() == address(tIn) ? r0 : r1;
                uint256 amt = rIn * bps / 10_000;
                if (amt == 0) continue;
                _drift(first, tIn, firstOut, amt);
                driftBps += bps;
            }
            vm.warp(block.timestamp + d);
            vm.roll(block.number + (d + 1) / 2);
            vm.prank(user);
            (bool ok, bytes memory ret) = address(router).call(call);
            uint256 dIdx = driftBps == 0 ? 0 : (driftBps <= 100 ? 1 : 2);
            uint256 tIdx = d == 0 ? 0 : (d <= 5 ? 1 : 2);
            byDrift[dIdx].n++; byDelay[tIdx].n++;
            if (ok) {
                uint256 delivered = abi.decode(ret, (uint256));
                assertGe(delivered, pv.effectiveMinOut, "a settlement delivered below the floor the preview attested");
                uint256 ratio = delivered * 10_000 / pv.netOut;
                _tally(byDrift[dIdx], ratio); _tally(byDelay[tIdx], ratio);
                if (driftBps == 0) assertGe(ratio, 10_000, "no drift: delivery below the preview's own net prediction");
            } else {
                (uint16 code, bool isR) = _routerCode(ret);
                if (isR && code == 5) { byDrift[dIdx].refused5++; byDelay[tIdx].refused5++; }
                else ++thirdWay;
                assertTrue(driftBps != 0, "time alone broke a quote inside its deadline");
            }
        }
        assertEq(thirdWay, 0, "an outcome that is neither a settlement nor a refusal of ours");
        assertLt(noQuote, N / 10, "the Solver found no route on more than a tenth of the samples");
        console2.log("samples", N, "no quote", noQuote);
        _print("drift  0        ", byDrift[0]); _print("drift  1-100 bps", byDrift[1]); _print("drift  1-3 %    ", byDrift[2]);
        _print("delay  0 s      ", byDelay[0]); _print("delay  1-5 s    ", byDelay[1]); _print("delay  6-10 s   ", byDelay[2]);
        assertEq(byDrift[0].settled, byDrift[0].n, "drift-free quotes must all settle, at any delay inside the deadline");
    }

    /// The deadline is the one thing time is allowed to break — and it breaks it with its own code.
    function test_QuoteExecutedAfterItsDeadline_IsRefusedWithCode4() public {
        uint256 refused4;
        for (uint256 i; i < 20; ++i) {
            uint256 amountIn = 1e17 + i * 1e16;
            uint256 deadline = block.timestamp + 5;
            (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
                quoter.previewAndEncode(address(A), address(C), amountIn, user, deadline);
            assertTrue(pv.canExecute, "precondition: the quote exists");
            A.mint(user, amountIn); vm.prank(user); A.approve(address(router), amountIn);
            vm.warp(block.timestamp + 10);
            vm.prank(user);
            (bool ok, bytes memory ret) = address(router).call(call);
            assertFalse(ok, "a quote executed after its deadline settled");
            (uint16 code, bool isR) = _routerCode(ret);
            assertTrue(isR && code == 4, "refused, but not by the deadline");
            ++refused4;
        }
        assertEq(refused4, 20);
    }

    function _pick(uint256 c) private view returns (MockERC20 tIn, MockERC20 tOut, MockV2Pair first, MockERC20 firstOut) {
        if (c == 0) return (A, C, AB1, B);        // two hops through the bridge
        if (c == 1) return (A, B, AB1, B);        // direct into the bridge
        return (C, A, BC1, B);                    // two hops the other way
    }

    function _tally(Stat memory s, uint256 ratio) private pure {
        s.settled++; s.ratioSum += ratio;
        if (ratio < s.ratioMin) s.ratioMin = ratio;
        if (ratio > s.ratioMax) s.ratioMax = ratio;
    }

    function _print(string memory tag, Stat memory s) private pure {
        if (s.n == 0) { console2.log(tag, "n=0"); return; }
        console2.log(tag, "n", s.n);
        console2.log("   settled", s.settled, "refused(5)", s.refused5);
        if (s.settled > 0) {
            console2.log("   delivered/predicted bps: mean", s.ratioSum / s.settled);
            console2.log("   min", s.ratioMin, "max", s.ratioMax);
        }
    }
}
