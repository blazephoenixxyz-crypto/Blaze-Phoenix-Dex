// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, Vm, console2} from "forge-std/Test.sol";
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
    MockV2Pair[] public pairs2;             // a second pool per pair, for two-leg hops
    BlazePhoenixHub public hub;
    address public user = address(0xBEEF);
    // Fixed, matching the Router's actual configured treasuries — these must
    // NOT be fuzzer-controlled parameters of swap() (an earlier version of
    // this handler made that mistake: the fuzzer then measured balance
    // deltas of random unrelated addresses instead of the real fee
    // recipients, so the fee-bound check below was checking nothing).
    address public immutable treasury1;
    address public immutable treasury2;

    bytes32 constant FEE_SIG = keccak256("Fee(address,uint256,uint256,uint256)");
    uint256 public callCount;
    uint256 public successCount;
    bool    public ghost_feeBoundViolated;
    bool    public ghost_deliveredBelowMinOut;
    bool    public ghost_feeEscaped;
    bool    public ghost_feeChargedTwice;
    bool    public ghost_feeEventsNotOne;   // a settlement emitted zero or several Fee events
    bool    public ghost_multiHopFeeShapeWrong;   // a 2-hop settlement paid where the rule does not say
    bool    public ghost_deliveredBelowProtocolFloor;   // a settlement delivered under the floor the Router itself emitted
    uint256 public driftCalls;
    uint256 public driftSettled;
    uint256 public driftRefusedByFloor;
    uint256 public driftRefusedOther;
    uint256 public driftSettledBelowAttested;
    uint256 public driftWhaleFailed;
    bytes32 constant PROOF_SIG = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
    address public whale = address(0xB16);
    uint256 public multiCalls;
    uint256 public multiSettles;
    // Non-vacuity counter for the fee guards THEMSELVES: how many runs
    // observed a non-zero fee. Without it, the three ghosts above read false
    // both when the code is correct and when the fee was never measured at
    // all, and those two states are indistinguishable from the green.
    uint256 public feeObservedCount;

    constructor(
        BlazePhoenixRouter _router, MockERC20[] memory _tokens, MockV2Pair[] memory _pairs,
        MockV2Pair[] memory _pairs2, BlazePhoenixHub _hub, address _treasury1, address _treasury2
    ) {
        router = _router;
        hub = _hub;
        for (uint256 i; i < _pairs2.length; ++i) pairs2.push(_pairs2[i]);
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

        vm.recordLogs();
        vm.prank(user);
        try router.swapExactIn(route, amountIn, minOut, user, block.timestamp + 1) returns (uint256 delivered) {
            successCount++;
            {
                Vm.Log[] memory logs = vm.getRecordedLogs();
                uint256 nFee;
                for (uint256 i; i < logs.length; ++i) if (logs[i].topics[0] == FEE_SIG) ++nFee;
                if (nFee != 1) ghost_feeEventsNotOne = true;
            }
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

    // ── TWO HOPS, ONE OR TWO LEGS (2026-09-05). Until here the campaign built direct one-leg
    //    routes only, and the detection study measured it blind to the exhaustion-regime and
    //    commitment mutants. This action walks two adjacent pairs of the chain, splits hop 0
    //    across the pair's two pools when asked, and checks the fee SHAPE the rule prescribes
    //    for the route it built: anchored (a bridge coin is some hop's input) pays once, there,
    //    ceil(28 bps) of that hop's measured input; exhausted pays once per hop on each input.

    function _leg(MockV2Pair p, address tIn, uint256 amt) private view returns (Leg memory) {
        (uint112 r0, uint112 r1, ) = p.getReserves();
        bool zfo = p.token0() == tIn;
        uint256 q = BPC.outV2(amt, zfo ? r0 : r1, zfo ? r1 : r0, 30);
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
                    zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: q, auxId: bytes32(0)});
    }

    // ── THE PROTOCOL FLOOR, UNDER DRIFT (2026-09-05). No campaign asserted the floor: honest
    //    pools always pay the quote, so the floor never bound and a halved floor was invisible
    //    (invariant-mutants.json, FLOOR-half). This action quotes a route at the current
    //    reserves, lets a whale move the pool by 0-8 % in the user's direction, then executes the
    //    stale route. The Router either refuses by the floor (RouterE 5) or settles — and a
    //    settlement must deliver at least the floor the Router itself published in ExecutionProof.
    function swapAfterDrift(uint256 pairSeed, uint256 amountSeed, uint256 driftBps, bool reverseDirection) external {
        driftCalls++;
        if (pairs.length == 0) return;
        MockV2Pair pair = pairs[pairSeed % pairs.length];
        (address tIn, address tOut) = reverseDirection ? (pair.token1(), pair.token0()) : (pair.token0(), pair.token1());
        uint256 amountIn = bound(amountSeed, 1e15, 200e18);
        driftBps = bound(driftBps, 0, 800);
        // the route carries the floor a Solver would attest at quote time (96 % of the quote): the
        // protocol floor the Router enforces is max(userMinOut, attested floor, measured floor)
        Route memory route = _direct(pair, tIn, tOut, amountIn);
        route.singleOutFloor = BPC.mulDiv(route.totalOut, 9_600, BPC.BPS);
        MockERC20(tIn).mint(user, amountIn);
        vm.prank(user); MockERC20(tIn).approve(address(router), amountIn);
        // the world moves against the user
        if (driftBps > 0) {
            (uint112 r0, uint112 r1, ) = pair.getReserves();
            uint256 rIn = pair.token0() == tIn ? r0 : r1;
            uint256 w = rIn * driftBps / 10_000;
            if (w > 0) {
                MockERC20(tIn).mint(whale, w);
                vm.startPrank(whale);
                MockERC20(tIn).approve(address(router), w);
                try router.swapExactIn(_direct(pair, tIn, tOut, w), w, 1, whale, block.timestamp + 1) {} catch { driftWhaleFailed++; }
                vm.stopPrank();
            }
        }
        uint256 outTreasBefore = _treas(tOut);
        vm.recordLogs();
        vm.prank(user);
        try router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1) returns (uint256 delivered) {
            driftSettled++;
            // the floor is enforced on the GROSS output (before the output-side fee on a direct
            // route into the bridge coin); delivered is net, so the gross is rebuilt from the
            // treasuries' delta in tokenOut
            uint256 gross = delivered + (_treas(tOut) - outTreasBefore);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 floorUsed; bool seen;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics[0] == PROOF_SIG) { (, , floorUsed, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256)); seen = true; }
            }
            // two observers of the same floor: the one the Router published, and the one the
            // handler attested at quote time — a settlement must clear both
            if (!seen || floorUsed == 0 || gross < floorUsed) ghost_deliveredBelowProtocolFloor = true;
            if (gross < route.singleOutFloor) { ghost_deliveredBelowProtocolFloor = true; driftSettledBelowAttested++; }
        } catch (bytes memory ret) {
            if (ret.length == 36 && bytes4(ret) == BlazePhoenixRouter.RouterE.selector) {
                uint16 code; assembly { code := mload(add(ret, 36)) }
                if (code == 5) driftRefusedByFloor++; else driftRefusedOther++;
            } else driftRefusedOther++;
        }
    }

    function _direct(MockV2Pair pair, address tIn, address tOut, uint256 amt) private view returns (Route memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(pair, tIn, amt);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: legs[0].expectedOut, legs: legs});
        return Route({hops: hops, totalOut: legs[0].expectedOut, singleOut: legs[0].expectedOut, singleOutFloor: 0,
                      expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    struct Two { address tIn; address m; address tOut; MockV2Pair p0; MockV2Pair p0b; MockV2Pair p1; }

    function _pickTwo(uint256 hopSeed, bool reverse) private view returns (Two memory t) {
        uint256 i = hopSeed % (pairs.length - 1);              // hops through pairs[i] and pairs[i+1]
        address a = address(tokens[i]); address m = address(tokens[i + 1]); address c = address(tokens[i + 2]);
        if (reverse) t = Two(c, m, a, pairs[i + 1], pairs2[i + 1], pairs[i]);
        else t = Two(a, m, c, pairs[i], pairs2[i], pairs[i + 1]);
    }

    function _twoHopRoute(Two memory t, uint256 amountIn, bool twoLegs) private view returns (Route memory) {
        Hop[] memory hops = new Hop[](2);
        Leg[] memory legs0 = new Leg[](twoLegs ? 2 : 1);
        uint256 e0;
        if (twoLegs) { legs0[0] = _leg(t.p0, t.tIn, amountIn / 2); legs0[1] = _leg(t.p0b, t.tIn, amountIn - amountIn / 2); e0 = legs0[0].expectedOut + legs0[1].expectedOut; }
        else { legs0[0] = _leg(t.p0, t.tIn, amountIn); e0 = legs0[0].expectedOut; }
        hops[0] = Hop({tokenIn: t.tIn, tokenOut: t.m, amountIn: amountIn, expectedOut: e0, legs: legs0});
        Leg[] memory legs1 = new Leg[](1);
        legs1[0] = _leg(t.p1, t.m, e0);
        hops[1] = Hop({tokenIn: t.m, tokenOut: t.tOut, amountIn: e0, expectedOut: legs1[0].expectedOut, legs: legs1});
        return Route({hops: hops, totalOut: hops[1].expectedOut, singleOut: hops[1].expectedOut, singleOutFloor: 0,
                      expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _treas(address t) private view returns (uint256) {
        return MockERC20(t).balanceOf(treasury1) + MockERC20(t).balanceOf(treasury2);
    }

    function swap2(uint256 hopSeed, uint256 amountSeed, bool twoLegs, bool reverse) external {
        multiCalls++;
        if (pairs.length < 2) return;
        Two memory t = _pickTwo(hopSeed, reverse);
        uint256 amountIn = bound(amountSeed, 1e15, 300e18);
        MockERC20(t.tIn).mint(user, amountIn);
        vm.prank(user);
        MockERC20(t.tIn).approve(address(router), amountIn);
        Route memory route = _twoHopRoute(t, amountIn, twoLegs);

        // the rule, computed here from the bridge list — never from the Router
        bool anchored = hub.isBridgeToken(t.tIn) || hub.isBridgeToken(t.m);
        bool feeAtZero = hub.isBridgeToken(t.tIn);
        uint256[3] memory before = [_treas(t.tIn), _treas(t.m), _treas(t.tOut)];
        uint256 mPoolBefore = MockERC20(t.m).balanceOf(address(t.p0)) + MockERC20(t.m).balanceOf(address(t.p0b));

        vm.recordLogs();
        vm.prank(user);
        try router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1) returns (uint256 delivered) {
            multiSettles++;
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 nFee;
            for (uint256 k; k < logs.length; ++k) if (logs[k].topics[0] == FEE_SIG) ++nFee;
            uint256 feeTin = _treas(t.tIn) - before[0];
            uint256 feeM   = _treas(t.m) - before[1];
            uint256 feeOut = _treas(t.tOut) - before[2];
            uint256 mReceived = mPoolBefore - (MockERC20(t.m).balanceOf(address(t.p0)) + MockERC20(t.m).balanceOf(address(t.p0b)));
            uint256 wantTin = BPC.mulDivUp(amountIn, 28, BPC.BPS);
            uint256 wantM   = BPC.mulDivUp(mReceived, 28, BPC.BPS);
            bool okShape;
            if (!anchored)      okShape = nFee == 2 && feeTin == wantTin && feeM == wantM && feeOut == 0;
            else if (feeAtZero) okShape = nFee == 1 && feeTin == wantTin && feeM == 0 && feeOut == 0;
            else                okShape = nFee == 1 && feeTin == 0 && feeM == wantM && feeOut == 0;
            if (!okShape || delivered == 0) ghost_multiHopFeeShapeWrong = true;
        } catch {
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
    MockV2Pair[] pairs2;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
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
            // the pair's second pool, half as deep, for the two-leg hops of swap2
            MockV2Pair q = new MockV2Pair(address(a), address(b));
            a.mint(address(q), depthA / 2);
            b.mint(address(q), depthB / 2);
            q.setReserves(
                uint112(t0 == address(a) ? depthA / 2 : depthB / 2),
                uint112(t0 == address(a) ? depthB / 2 : depthA / 2)
            );
            pairs2.push(q);
        }
        // T1 is the bridge coin, so the chain holds every regime the rule names: T0->T1 (output
        // into a bridge), T1->T2 and T1->T2->T3 (anchored at hop 0), T0->T1->T2 (anchored at
        // hop 1), and T2->T3 / T3->T2->T1 shapes down to the exhaustion regime.
        hub.addBridge(address(tokens[1]));

        handler = new RouterHandler(router, tokens, pairs, pairs2, hub, treasury1, treasury2);
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
    /// @notice The ledger's property, observed from outside: one Fee event per settlement — never
    ///         zero, never two. The Router now refuses both at run time (RouterE 15 / 16); this is
    ///         the campaign confirming that the refusal never had to fire on an honest route.
    function invariant_SettledSwapEmitsExactlyOneFee() public view {
        assertFalse(handler.ghost_feeEventsNotOne(), "a settled swap emitted zero or several Fee events");
    }

    /// @notice The protocol floor, observed where the Router publishes it: a settlement under
    ///         drift delivers at least the floor in its own ExecutionProof, or is refused by it.
    function invariant_DeliveredNeverBelowTheProtocolFloor() public view {
        assertFalse(handler.ghost_deliveredBelowProtocolFloor(), "a settlement delivered below the floor the Router itself published");
    }

    /// @notice Two hops, one or two legs, every regime the rule names: the fee lands where the
    ///         rule says, in the amount the pools measured, and nowhere else.
    function invariant_TwoHopFeeShapeFollowsTheRule() public view {
        assertFalse(handler.ghost_multiHopFeeShapeWrong(), "a two-hop settlement paid the fee where or how much the rule does not say");
    }

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
        console2.log("drift calls", handler.driftCalls(), "settled", handler.driftSettled());
        console2.log("refused by floor", handler.driftRefusedByFloor(), "refused other", handler.driftRefusedOther());
        console2.log("settled below attested", handler.driftSettledBelowAttested(), "whale failed", handler.driftWhaleFailed());
        if (handler.driftCalls() >= 20) {
            assertGt(handler.driftSettled(), 0, "vacuous: no drifted route ever settled");
            assertGt(handler.driftRefusedByFloor(), 0, string.concat("vacuous: the floor never bound - no drifted route was ever refused by it | calls=", vm.toString(handler.driftCalls()), " settled=", vm.toString(handler.driftSettled()), " refusedOther=", vm.toString(handler.driftRefusedOther()), " belowAttested=", vm.toString(handler.driftSettledBelowAttested()), " whaleFailed=", vm.toString(handler.driftWhaleFailed())));
        }
        if (handler.multiCalls() >= 10) {
            assertGt(handler.multiSettles(), 0, "vacuous: no two-hop route ever settled");
        }
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
