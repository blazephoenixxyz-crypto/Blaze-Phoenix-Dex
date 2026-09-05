// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  The stable curve must FAIL CLOSED: a quote it cannot compute is 0, never a revert.
//
//  Found by the N-version lane (test/nversion, 2026-09-05): fuzzing the three binaries of
//  outSolidlyStable on its whole domain, the reference itself reverted with `BPC:mulDiv` on a
//  dust pool (rIn = 3,294,232,917, rOut = 100, 15 and 3 decimals). Every other degenerate case
//  in `_solidlyStable` returns 0 by construction; this one escaped through Newton's method —
//  the domain guards cover the SEED, and the iterate is free to leave the domain the seed was
//  checked in — and the fit check's own division (max·WAD/b) overflows once b < WAD, i.e. on a
//  pool holding under one unit of each token. A revert inside a quote is not a refused pool: `universalQuote` is a library
//  DELEGATECALL, so it unwinds the Solver's whole plan, and with it the planned door for the
//  pair. The direction of the defect is the one this codebase names first: fail-open.
//
//  forge test --match-path test/CoreStableCurveFailsClosed.t.sol
// =============================================================================
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract StableProbe {
    function stable(uint256 a, uint256 rIn, uint256 rOut, uint256 fee, uint8 dIn, uint8 dOut) external pure returns (uint256) {
        return BPC.outSolidlyStable(a, rIn, rOut, fee, dIn, dOut);
    }
    function solidly(uint256 a, uint256 rIn, uint256 rOut, uint256 fee) external pure returns (uint256) {
        return BPC.outSolidly(a, rIn, rOut, fee, true);
    }
}

contract CoreStableCurveFailsClosedTest is Test {
    StableProbe p;

    function setUp() public { p = new StableProbe(); }

    /// The counterexample the lane produced, verbatim.
    function test_DustStablePool_QuoteIsZeroNotRevert() public {
        (bool ok, bytes memory ret) = address(p).call(abi.encodeCall(p.stable, (3233, 3294232917, 100, 6, 15, 3)));
        assertTrue(ok, "outSolidlyStable reverted on a dust stable pool: a quote that must fail closed (0) failed open (revert)");
        assertEq(abi.decode(ret, (uint256)), 0, "a curve Newton cannot solve quotes nothing");
    }


    /// The OTHER escape: a whale input reserve against a dust output reserve passes the K check
    /// and overflows the derivative on the very first step. 5.1e33 wei at 14 decimals against
    /// 1 wei at 18 — constructible by anyone who can mint one token.
    function test_WhaleVsDustStablePool_QuoteIsZeroNotRevert() public {
        (bool ok, bytes memory ret) = address(p).call(abi.encodeCall(p.stable, (1e10, 5_100_000_000_000_000_000_000_000_000_000_000, 1, 5, 14, 18)));
        assertTrue(ok, "outSolidlyStable reverted on a whale-vs-dust stable pool (derivative overflow at the seed)");
        assertEq(abi.decode(ret, (uint256)), 0, "a curve whose derivative does not fit quotes nothing");
    }

    /// The whole domain a registered pool can present: uint112 reserves, any decimals up to 18,
    /// any fee below 100%. The only acceptable outcomes are a number or zero.
    function testFuzz_StableQuoteNeverReverts(uint256 a, uint256 rIn, uint256 rOut, uint16 fee, uint8 dIn, uint8 dOut) public {
        rIn = bound(rIn, 0, type(uint112).max);
        rOut = bound(rOut, 0, type(uint112).max);
        a = bound(a, 0, type(uint112).max);
        uint256 f = bound(fee, 0, 9_999);
        dIn = uint8(bound(dIn, 0, 18));
        dOut = uint8(bound(dOut, 0, 18));
        (bool ok, ) = address(p).call(abi.encodeCall(p.stable, (a, rIn, rOut, f, dIn, dOut)));
        assertTrue(ok, "outSolidlyStable reverted inside its domain");
        (ok, ) = address(p).call(abi.encodeCall(p.solidly, (a, rIn, rOut, f)));
        assertTrue(ok, "outSolidly(stable) reverted inside its domain");
    }
}

import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// REACH. The curve is the Core's FALLBACK for a Solidly pool that does not answer
/// `getAmountOut`; on such a pool with dust reserves the revert unwinds `findBestRoutePlan`,
/// i.e. the planned door for the whole pair. With the fix the pool quotes 0 and is skipped:
/// the Solver may still refuse (no route), but with a selector of its own.
contract StableCurveReachesTheSolverTest is Test {
    function test_DustStablePoolWithoutGetAmountOut_DoesNotUnwindThePlan() public {
        MockERC20 A = new MockERC20("A", "A");
        MockERC20 B = new MockERC20("B", "B");
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        (address t0, address t1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));
        MockSolidlyPair p = new MockSolidlyPair(t0, t1, true);
        // a tenth of a token on each side, in 18-decimal wei: the fit check's own division
        // overflows for pools holding under one unit (below one USDC on a 6-decimal pair)
        MockERC20(t0).mint(address(p), 1e17);
        MockERC20(t1).mint(address(p), 1e17);
        p.setReserves(1e17, 1e17);
        p.setHideGetAmountOut(true);
        hub.seedPool(address(p), BPC.KIND_SOLIDLY, 5, address(0), t0, t1);
        try solver.findBestRoutePlan(t0, t1, 1e15) {
            // a plan or an empty plan: fine either way
        } catch Error(string memory reason) {
            fail(string.concat("a library revert unwound the Solver's plan: ", reason));
        } catch (bytes memory) {
            // the Solver's own selector (no route): the pool was refused, not the door
        }
    }
}
