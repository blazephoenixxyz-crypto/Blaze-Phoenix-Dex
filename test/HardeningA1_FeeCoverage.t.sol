// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A1 / C1b regression — a forged near-zero quote must NOT evade the fee.
//
//  _execute charges the protocol fee on the in-frame on-chain quote
//  (onchainQuoteAcc) so a crafted route.totalOut cannot shrink the fee base.
//  But the V3/Algebra quote prices with the CALLER's leg.fee while execution
//  charges the pool's own fee: leg.fee near 1e6 drives outV3 toward 0, so the
//  pre-fix feeBase = min(quote, delivered) collapsed and the bulk of the
//  delivered output became fee-exempt "surplus" (~0 protocol fee on a real
//  delivery).
//
//  The fix (MIN_QUOTE_COVERAGE_BPS = 5_000): the quote is trusted as the fee
//  base only while it covers >= 50% of the MEASURED delivery; below that it is
//  implausible and the fee is charged on the delivered amount instead.
//
//  MockV3Pool executes with its own constructor fee (3000) via the SAME
//  BPC.outV3 formula the Router quotes with, and never mutates its state, so:
//    • honest leg  (leg.fee = 3000)    → quote == delivered, coverage 100%
//    • forged leg  (leg.fee = 999_999) → quote ~ delivered/1e6, coverage ~0
//  and BOTH must pay exactly mulDiv(delivered_gross, 28, 10_000) — the two
//  treasury deltas are compared for exact equality.
//
//  forge test --match-contract HardeningA1FeeCoverage -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract HardeningA1FeeCoverageTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool;

    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);

    // Router constants, pinned (blind-constant law: the test must break if
    // either silently changes).
    uint256 constant PROTOCOL_FEE_BPS = 28;      // 0.28% of the fee base
    uint256 constant TREASURY1_SHARE  = 3_000;   // 30/70 split
    uint256 constant MIN_QUOTE_COVERAGE_BPS = 5_000;

    // sqrtPriceX96 for price 1.0 (2**96), deep single-tick liquidity: the
    // quote and the mock's execution use the same outV3 on the same static
    // state, so quote == delivered by construction for an honest leg.
    uint160 constant SQRT_P_1  = 79228162514264337593543950336;
    uint128 constant LIQ       = 1_000_000e18;
    uint24  constant POOL_FEE  = 3000;      // the fee the pool ACTUALLY charges
    uint24  constant FORGED_FEE = 999_999;  // quote-only: outV3 keeps ~1e-6 of the input
    uint256 constant AMOUNT_IN = 10_000e18;

    bool zfo; // tokenA -> tokenB direction on the sorted pair

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pool = new MockV3Pool(address(tokenA), address(tokenB), POOL_FEE);
        pool.setState(SQRT_P_1, LIQ);
        // Enough real output-side inventory for every swap in this file —
        // execution must never be capacity-limited, only the FEE is under test.
        tokenB.mint(address(pool), 1_000_000e18);
        // Registry sees the pool's REAL fee tier; the forged figure exists only
        // in the crafted calldata leg, which is exactly the attack surface.
        hub.seedPool(address(pool), BPC.KIND_V3, POOL_FEE, address(0), address(tokenA), address(tokenB));

        zfo = pool.token0() == address(tokenA);

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    /// @dev One-hop, one-leg tokenA -> tokenB route. `legFee` is the only knob:
    ///      3000 mirrors the pool (honest), 999_999 forges the quote toward 0.
    ///      expectedOut = 0 keeps the per-leg floor fail-open — a caller
    ///      weakening its own crafted route, precisely the attacker's shape.
    function _route(uint24 legFee) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pool),
            hooks: address(0),
            kind: BPC.KIND_V3,
            fee: legFee,
            tickSpacing: 0,
            zeroForOne: zfo,
            stable: false,
            amountIn: AMOUNT_IN,
            expectedOut: 0,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: AMOUNT_IN,
            expectedOut: 0,
            legs: legs
        });
        r = Route({
            hops: hops,
            totalOut: 0,
            singleOut: 0,
            singleOutFloor: 0,
            expectedImpactBps: 0,
            confidenceWad: 0,
            estGas: 0,
            hasSurplus: false,
            isV4Bundle: false
        });
    }

    /// @dev What the pool will actually deliver (gross, before the protocol
    ///      fee): the mock executes outV3 with ITS OWN fee on static state.
    function _grossOut() internal view returns (uint256) {
        return BPC.outV3(AMOUNT_IN, SQRT_P_1, LIQ, POOL_FEE, zfo);
    }

    function _treasuries() internal view returns (uint256) {
        return tokenB.balanceOf(T1) + tokenB.balanceOf(T2);
    }

    // ─── (a) honest swap: a normal 0.28% fee on the delivered amount ─────────

    function test_Fee_HonestSwap_Collects28BpsOfDelivered() public {
        uint256 userBefore = tokenB.balanceOf(user);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _route(POOL_FEE), AMOUNT_IN, 1, user, block.timestamp + 1);

        uint256 gross = _grossOut();
        uint256 fee   = BPC.mulDiv(gross, PROTOCOL_FEE_BPS, BPC.BPS);
        assertGt(fee, 0, "setup: the honest fee must be a real, non-zero amount");

        // Honest leg quotes exactly what the pool delivers (coverage 100%), so
        // feeBase == delivered and the treasuries take exactly 28 bps of it.
        assertEq(_treasuries(), fee, "treasuries must take exactly 0.28% of the gross delivery");
        assertEq(tokenB.balanceOf(T1), BPC.mulDiv(fee, TREASURY1_SHARE, BPC.BPS), "30/70 split");
        assertEq(delivered, gross - fee, "user receives gross minus the protocol fee");
        assertEq(tokenB.balanceOf(user) - userBefore, delivered, "reported == received");
    }

    // ─── (b) forged leg.fee = 999_999: the near-zero quote must not evade it ─

    function test_Fee_ForgedV3LegFee_CannotZeroTheFeeBase() public {
        uint256 gross       = _grossOut();
        uint256 forgedQuote = BPC.outV3(AMOUNT_IN, SQRT_P_1, LIQ, FORGED_FEE, zfo);

        // Attack preconditions, asserted so the test can never pass vacuously:
        // the forged quote is real but implausibly small — far below the 50%
        // coverage bar the fix demands of a trustworthy fee base.
        assertGt(forgedQuote, 0, "setup: forged quote must be non-zero (sum stays 'plausible' pre-fix)");
        assertLt(forgedQuote, BPC.mulDiv(gross, MIN_QUOTE_COVERAGE_BPS, BPC.BPS),
            "setup: forged quote must fail the coverage bar");

        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _route(FORGED_FEE), AMOUNT_IN, 1, user, block.timestamp + 1);

        uint256 fees = _treasuries();
        uint256 fee  = BPC.mulDiv(gross, PROTOCOL_FEE_BPS, BPC.BPS);

        // The regression pin: coverage failed, so the fee is charged on the
        // DELIVERED amount. Pre-fix, feeBase was the forged quote itself and
        // the treasuries took ~0.28% of ~nothing — here the collected fee must
        // exceed the ENTIRE forged quote, which no pre-fix outcome can reach.
        assertEq(fees, fee, "fee must be 0.28% of the delivered amount, not of the forged quote");
        assertGt(fees, forgedQuote, "collected fee must dwarf the forged quote (pre-fix: ~0)");
        assertEq(delivered, gross - fee, "user still receives gross minus the real fee");
    }

    // ─── forged vs honest: identical delivery => identical treasury delta ────

    function test_Fee_ForgedVsHonest_TreasuryDeltasEqual() public {
        // The mock never mutates sqrtPrice/liquidity, so both swaps deliver the
        // SAME gross amount — the only difference is the calldata leg.fee. The
        // fix makes the fee a function of what was delivered, so the two
        // treasury deltas must match to the wei.
        uint256 before0 = _treasuries();
        vm.prank(user);
        router.swapExactIn(_route(POOL_FEE), AMOUNT_IN, 1, user, block.timestamp + 1);
        uint256 honestDelta = _treasuries() - before0;

        uint256 before1 = _treasuries();
        vm.prank(user);
        router.swapExactIn(_route(FORGED_FEE), AMOUNT_IN, 1, user, block.timestamp + 1);
        uint256 forgedDelta = _treasuries() - before1;

        assertGt(honestDelta, 0, "setup: the honest swap must collect a real fee");
        assertEq(forgedDelta, honestDelta,
            "forging leg.fee must not change the protocol fee by a single wei");
    }
}
