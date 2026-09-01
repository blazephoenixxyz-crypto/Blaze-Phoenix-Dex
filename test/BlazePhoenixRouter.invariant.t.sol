// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice Handler for stateful (Monte Carlo) invariant fuzzing of the
///         Router. forge's invariant runner calls `swap` repeatedly with
///         random seeds across many random call sequences ("runs" x
///         "depth"), each time picking a random pair, direction and amount.
///         Every call is wrapped in try/catch: a revert (bad slippage, a
///         starved pool, etc.) is a normal, expected outcome and must NOT
///         corrupt state — that is exactly what the invariants below check.
contract RouterHandler is Test {
    BlazePhoenixRouter public router;
    MockERC20[] public tokens;
    MockV2Pair[] public pairs;
    address public user = address(0xBEEF);
    // Fixed, matching the Router's actual configured treasuries — these must
    // NOT be fuzzer-controlled parameters of swap() (an earlier version of
    // this handler made that mistake: the fuzzer then measured balance
    // deltas of random unrelated addresses instead of the real fee
    // recipients, so the fee-bound check below was checking nothing).
    address public immutable treasury1;
    address public immutable treasury2;

    uint256 public callCount;
    uint256 public successCount;
    bool    public ghost_feeBoundViolated;
    bool    public ghost_deliveredBelowMinOut;
    bool    public ghost_feeEscaped;
    bool    public ghost_feeChargedTwice;
    // Non-vacuity counter for the fee guards THEMSELVES: how many runs
    // observed a non-zero fee. Without it, the three ghosts above read false
    // both when the code is correct and when the fee was never measured at
    // all, and those two states are indistinguishable from the green.
    uint256 public feeObservedCount;

    constructor(
        BlazePhoenixRouter _router, MockERC20[] memory _tokens, MockV2Pair[] memory _pairs,
        address _treasury1, address _treasury2
    ) {
        router = _router;
        treasury1 = _treasury1;
        treasury2 = _treasury2;
        for (uint256 i; i < _tokens.length; ++i) tokens.push(_tokens[i]);
        for (uint256 i; i < _pairs.length; ++i) pairs.push(_pairs[i]);
    }

    function tokensLength() external view returns (uint256) { return tokens.length; }
    function tokenAt(uint256 i) external view returns (MockERC20) { return tokens[i]; }

    function swap(uint256 pairSeed, uint256 amountSeed, uint256 minOutSeed, bool reverseDirection) external {
        callCount++;
        if (pairs.length == 0) return;
        MockV2Pair pair = pairs[pairSeed % pairs.length];
        address t0 = pair.token0();
        address t1 = pair.token1();
        (address tIn, address tOut) = reverseDirection ? (t1, t0) : (t0, t1);

        uint256 amountIn = bound(amountSeed, 1e15, 500e18);

        MockERC20(tIn).mint(user, amountIn);
        vm.prank(user);
        MockERC20(tIn).approve(address(router), amountIn);

        (uint112 r0, uint112 r1, ) = pair.getReserves();
        uint256 rIn = tIn == t0 ? r0 : r1;
        uint256 rOut = tIn == t0 ? r1 : r0;
        uint256 quoted = BPC.outV2(amountIn, rIn, rOut, 30);
        if (quoted == 0) return;

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: tIn == t0, stable: false,
            amountIn: amountIn, expectedOut: quoted, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amountIn, expectedOut: quoted, legs: legs});
        Route memory route = Route({
            hops: hops, totalOut: quoted, singleOut: quoted, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        // MEASURE BOTH SIDES. The protocol fee is charged on tokenIn or on
        // tokenOut depending on the route shape, and this handler builds the
        // shape that charges on tokenIn. Reading only one side makes the fee
        // delta identically zero, which silently turns every fee assertion
        // below into a tautology. This is the same failure the comment above
        // records for the treasury ADDRESSES, one axis over: reading the wrong
        // object rather than the wrong account. Reading both sides keeps the
        // guards correct under either charging regime and survives changes to
        // which one a given route takes.
        uint256 inT1Before  = MockERC20(tIn).balanceOf(treasury1);
        uint256 inT2Before  = MockERC20(tIn).balanceOf(treasury2);
        uint256 outT1Before = MockERC20(tOut).balanceOf(treasury1);
        uint256 outT2Before = MockERC20(tOut).balanceOf(treasury2);

        // BP-04: userMinOut == 0 now reverts RouterE(10) at the entry point —
        // fuzz a REAL bound in [1, quoted] instead. Two distinct guards can
        // then fire: (a) the pre-fee check compares the GROSS output against
        // effMin = max(userMinOut, protocolFloorOut, singleOutFloor) — an
        // honest pool pays the quote, so it passes for any minOut <= quoted;
        // (b) the post-fee check reverts when DELIVERED (gross minus the
        // 28 bps protocol fee) lands below userMinOut — draws in the narrow
        // band (quoted - fee, quoted] exercise that user-slippage revert
        // while the rest settle. Non-vacuity is MEASURED by afterInvariant,
        // not assumed here.
        uint256 minOut = bound(minOutSeed, 1, quoted);

        vm.prank(user);
        try router.swapExactIn(route, amountIn, minOut, user, block.timestamp + 1) returns (uint256 delivered) {
            successCount++;
            // Sentinel write for invariant_DeliveredNeverBelowUserMinOut:
            // unreachable today BY CONSTRUCTION (the Router's final check
            // reverts when delivered < userMinOut) — it records a violation
            // only if a refactor ever removes that check.
            if (delivered < minOut) ghost_deliveredBelowMinOut = true;
            uint256 feeIn  = (MockERC20(tIn).balanceOf(treasury1)  - inT1Before)
                           + (MockERC20(tIn).balanceOf(treasury2)  - inT2Before);
            uint256 feeOut = (MockERC20(tOut).balanceOf(treasury1) - outT1Before)
                           + (MockERC20(tOut).balanceOf(treasury2) - outT2Before);

            // (a) CEILING, asserted EXACTLY rather than with a slack term.
            //     The charge rounds UP, so a scaled comparison against
            //     base*28 needs up to BPS-1 of tolerance — a hand-picked
            //     slack is either too tight (false positive) or so wide it
            //     stops bounding anything. Comparing against the same
            //     mulDivUp the Router itself uses removes the guesswork:
            //     `amountIn` bounds the input side, (delivered + feeOut) the
            //     output side, and a real overcharge of even one wei fails.
            if (feeIn  > BPC.mulDivUp(amountIn, 28, BPC.BPS))             ghost_feeBoundViolated = true;
            if (feeOut > BPC.mulDivUp(delivered + feeOut, 28, BPC.BPS))   ghost_feeBoundViolated = true;

            // (b) FLOOR — the missing half, and the reason this exists. A
            //     ceiling alone is satisfied by a fee of ZERO, so it cannot
            //     distinguish "charged correctly" from "charged nothing". A
            //     swap that delivered value must have paid something: with
            //     round-half-up, a base of at least 1 forces a fee of at
            //     least 1. Any future escape surfaces here.
            if (delivered > 0 && feeIn + feeOut == 0) ghost_feeEscaped = true;

            // (c) EXACTLY ONE SIDE. The fee is charged once, on one side —
            //     never on both. A double charge is a silent overcharge that
            //     neither ceiling above catches, because each one passes on
            //     its own.
            if (feeIn > 0 && feeOut > 0) ghost_feeChargedTwice = true;

            if (feeIn + feeOut > 0) feeObservedCount++;
        } catch {
            // Expected: floors, starved pools, or rounding-to-zero legs all
            // revert cleanly. Nothing to record — the invariants below
            // confirm no state was corrupted by the attempt.
        }
    }
}

/// @notice Stateful (Monte Carlo) invariant coverage for the Router — the
///         gap TESTING.md flagged as entirely missing: "Router pass-through
///         / zero-residual-balance, per-token conservation across arbitrary
///         route shapes." Run with a high --fuzz-runs / invariant-depth for
///         a meaningful search (see forge test -vvv --match-contract
///         RouterInvariant in TESTING.md).
contract BlazePhoenixRouterInvariantTest is StdInvariant, Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    RouterHandler handler;
    MockERC20[] tokens;
    MockV2Pair[] pairs;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), treasury1, treasury2);

        tokens.push(new MockERC20("T0", "T0"));
        tokens.push(new MockERC20("T1", "T1"));
        tokens.push(new MockERC20("T2", "T2"));
        tokens.push(new MockERC20("T3", "T3"));

        for (uint256 i; i < 3; ++i) {
            MockERC20 a = tokens[i];
            MockERC20 b = tokens[i + 1];
            MockV2Pair p = new MockV2Pair(address(a), address(b));
            uint256 depthA = 100_000e18 * (i + 1);
            uint256 depthB = (depthA * 8) / 5;
            a.mint(address(p), depthA);
            b.mint(address(p), depthB);
            (address t0, ) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
            p.setReserves(
                uint112(t0 == address(a) ? depthA : depthB),
                uint112(t0 == address(a) ? depthB : depthA)
            );
            pairs.push(p);
        }

        handler = new RouterHandler(router, tokens, pairs, treasury1, treasury2);
        targetContract(address(handler));
    }

    /// @notice The Router must NEVER retain a balance of any token in the
    ///         test universe after any sequence of successful/failed swaps
    ///         — the core holds-nothing invariant every leg's residual-sweep
    ///         logic exists to guarantee.
    function invariant_RouterHoldsNothing() public view {
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].balanceOf(address(router)), 0,
                "Router must never retain a residual token balance");
        }
    }

    /// @notice Every successful swap's collected fee must stay within the
    ///         protocol's 0.28% bound of its own gross output — checked live
    ///         inside the handler; this just surfaces any violation ever
    ///         recorded across the whole random call sequence.
    function invariant_FeeNeverExceedsProtocolMax() public view {
        assertFalse(handler.ghost_feeBoundViolated(),
            "a swap collected more than PROTOCOL_FEE_BPS of the base it was charged on");
    }

    /// @notice THE MISSING HALF. The ceiling above is satisfied by a fee of
    ///         zero, so on its own it cannot tell a correct charge from no
    ///         charge at all. Round-half-up makes a zero fee unreachable for
    ///         any non-zero base; this asserts that property over randomised
    ///         routes rather than a single hand-pinned case.
    function invariant_FeeNeverEscapes() public view {
        assertFalse(handler.ghost_feeEscaped(),
            "a swap delivered value and paid zero protocol fee on both sides");
    }

    /// @notice One fee, one side. Charging on input AND output would be an
    ///         overcharge that neither ceiling catches in isolation, because
    ///         each one passes on its own.
    function invariant_FeeIsChargedOnExactlyOneSide() public view {
        assertFalse(handler.ghost_feeChargedTwice(),
            "a single swap paid a protocol fee on BOTH tokenIn and tokenOut");
    }

    /// @notice REGRESSION SENTINEL, not coverage: the Router's final check
    ///         (delivered >= userMinOut on every successful return) makes the
    ///         handler's ghost unreachable BY CONSTRUCTION today. This turns
    ///         red only if a refactor ever removes that post-fee check —
    ///         which would let a fee-on-transfer tokenOut slip a user below
    ///         the bound they set (the BP-04 mandate).
    function invariant_DeliveredNeverBelowUserMinOut() public view {
        assertFalse(handler.ghost_deliveredBelowMinOut(),
            "a successful swap delivered less than the caller's userMinOut");
    }

    /// @notice ANTI-VACUITY — the real lesson of 2026-08-09: a new entry
    ///         guard (BP-04, RouterE(10)) silently turned every handler swap
    ///         into a revert and the invariants above went green over an
    ///         empty universe ("no adversarial route ever settled"). Runs
    ///         once at the end of each invariant run: if the handler was
    ///         exercised, swaps MUST have settled. The gate of 10 stays
    ///         engaged under the configured depth (50) and never trips on a
    ///         short custom run.
    function afterInvariant() public view {
        if (handler.callCount() >= 10) {
            assertGt(handler.successCount(), 0,
                "vacuous invariant run: zero swaps settled (entry-guard regression?)");
            // NON-VACUITY FOR THE FEE GUARDS. A settled swap must leave a
            // trace in the treasuries. If this counter is zero, the guards
            // above are reading the wrong object and nothing can be concluded
            // from their green — the same class of defect this suite already
            // records once, for the treasury addresses.
            assertGt(handler.feeObservedCount(), 0,
                "vacuous fee guards: swaps settled but no protocol fee was ever observed");
        }
    }
}
