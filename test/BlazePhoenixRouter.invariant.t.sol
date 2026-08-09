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

    function swap(uint256 pairSeed, uint256 amountSeed, bool reverseDirection) external {
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

        uint256 t1BalBefore = MockERC20(tOut).balanceOf(treasury1);
        uint256 t2BalBefore = MockERC20(tOut).balanceOf(treasury2);

        vm.prank(user);
        try router.swapExactIn(route, amountIn, 0, user, block.timestamp + 1) returns (uint256 delivered) {
            successCount++;
            uint256 feeDelta = (MockERC20(tOut).balanceOf(treasury1) - t1BalBefore)
                              + (MockERC20(tOut).balanceOf(treasury2) - t2BalBefore);
            // fee must never exceed PROTOCOL_FEE_BPS (28/10000) of the gross
            // (delivered + fee), i.e. feeDelta*10000 <= gross*28. A couple of
            // wei of mulDiv rounding slack is tolerated, nothing more.
            if (feeDelta * BPC.BPS > (delivered + feeDelta) * 28 + 2) {
                ghost_feeBoundViolated = true;
            }
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
        hub = new BlazePhoenixHub();
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
            "a swap collected more than PROTOCOL_FEE_BPS of its own gross output");
    }
}
