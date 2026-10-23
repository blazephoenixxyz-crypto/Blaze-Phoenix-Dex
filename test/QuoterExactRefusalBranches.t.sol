// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  QUOTER REFUSAL BRANCHES — the 21 branches coverage never took, taken.
//
//  Branch coverage on BlazePhoenixQuoter.sol measured 34.29% (2026-08-31), the
//  worst in the repo, and the untaken set is almost entirely REFUSAL paths of
//  the exact pass (`previewPlanExact` / `_simConc` / `_simV4`) plus the
//  constructor guard and `_classify`'s malformed-route arm. The governing law
//  of this codebase names the defect class these branches exist to prevent:
//  "absence = permission" — a preview that silently returns a number when the
//  measurement could not be made is the preview-side twin of a check that
//  waves a swap through because it could not evaluate.
//
//  WHAT EACH REFUSAL MUST OBSERVABLY DO (the contract these tests pin):
//    - a refusal inside _simConc/_simV4 returns 0 to the CALLER of the sim,
//      and previewPlanExact then falls back to the plan-time linear
//      approximation `mulDiv(leg.expectedOut, legIn, base)` (Quoter:497/518).
//      At scale 1 (legIn == base) that fallback is EXACTLY leg.expectedOut, so
//      every test plants a DECOY expectedOut and asserts the output IS the
//      decoy (refusal observed) or IS the venue's number (measurement
//      observed) — never something in between, never a decoded garbage value.
//    - an empty route quotes ZERO (Quoter:471). Delete that branch and
//      previewPlanExact returns carry == amountIn: an empty route previews as
//      a perfect 1:1 conversion — the purest absence-=-permission shape here.
//    - _classify refuses to name a bridge for a route whose first hop has no
//      legs (Quoter:331) instead of reading legs[0] of nothing.
//
//  DELETION HONESTY, per the coverage doctrine: every test below states
//  whether it fails if its branch's body is deleted. Two cannot (Quoter:379
//  and :447, the try-success `return 0` arms): deleting them falls through to
//  the implicit zero and is behaviourally identical — those two tests pin the
//  OBSERVABLE (a pool/manager that returns instead of reverting yields no
//  quote and cannot inflate one) and say so where they stand.
//
//  MOCKS: MockV3Pool / MockV2Pair / MockSolidlyPair are reused from
//  test/mocks/. ISolverQ, IHubQ and IV4Q have no existing mock, so this file
//  inlines one-off shapes (house idiom): a solver that returns a crafted plan
//  (routes stored as an abi.encode blob — memory-to-storage of nested arrays
//  is not a thing), a hub whose v4PoolManager is settable, a V4 manager that
//  runs the REAL unlock -> unlockCallback -> swap -> revert-payload round
//  trip and only answers when the pool key matches EXACTLY what it was told
//  to expect — so a wrong key surfaces as the fallback decoy, which is how
//  the native-currency substitution tests detect deletion.
//
//  ONE TEST IS RED ON PURPOSE (test_RED_...): the Solidly arm of the exact
//  pass rescales `expectedOut` LINEARLY on scale-up (Quoter:528), over-quoting
//  a convex curve — the externally-reported ~907 bps over-quote. It pins the
//  direction "the preview must never promise more than execution delivers"
//  and goes green when that arm asks the pool (solidlyGetAmountOut), the fix
//  the source's own TRAP comment anticipates. Same red-first idiom as
//  ReproQuoterExactClampInflation.t.sol. The linear fallbacks at :497/:518
//  are the same class at scale-up; at scale 1 (asserted here) they are exact.
//
//  forge test --match-contract QuoterExactRefusalBranches -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixQuoter, IV4Q} from "../src/BlazePhoenixQuoter.sol";
import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg, RoutePlan, QuoteCtx
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

interface IUnlockCbQ {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Solver stand-in: hands the Quoter exactly the route the test built.
///      Stored as an abi.encode blob because copying structs with nested
///      dynamic arrays into storage is unsupported; decode reconstitutes it.
contract MockSolverQ {
    bytes internal blob;

    function setBest(Route memory best) external {
        Route memory none;
        blob = abi.encode(RoutePlan({best: best, fallbackRoute: none, hasFallback: false}));
    }

    function findBestRoutePlan(address, address, uint256)
        external view returns (RoutePlan memory)
    {
        return abi.decode(blob, (RoutePlan));
    }
}

/// @dev Hub stand-in: the exact-pass only asks it one question.
contract MockHubQ {
    address public v4PoolManager;
    function setV4PoolManager(address m) external { v4PoolManager = m; }
    /// The Router's WETH, asked by the Quoter for a native V4 leg (#52 seal: nativeMapVerified).
    address public weth;
    function setWeth(address w) external { weth = w; }
    function bridgeCount() external pure returns (uint8) { return 0; }
    function bridge(uint8) external pure returns (address) { return address(0); }
    /// The one bridge is the routes' OUTPUT token (set in `setUp`): a direct route into a
    /// bridge is the regime where the Router takes the fee off the output, so the exact
    /// scalar is the plain deduction and each branch below is observed through one dry run.
    /// The input-charged regime has its own suite (QuoterExactFloorHoldsWhenTheFeeIsChargedOnTheInput).
    address public outBridge;
    function setOutBridge(address t) external { outBridge = t; }
    function isBridgeToken(address t) external view returns (bool) { return t != address(0) && t == outBridge; }
    /// The pause arm of the hook sieve (`Router._execV4Amt`, RouterE(9)); `_simV4` asks it
    /// for a hook that runs in the swap (H13, 2026-10-19).
    mapping(address => bool) public hookPaused;
    function setHookPaused(address h, bool p) external { hookPaused[h] = p; }
}

/// @dev V4 PoolManager stand-in running the REAL quote round trip:
///      unlock() calls back the Quoter's unlockCallback, which calls swap()
///      here and reverts with the deltas; the revert bubbles back through
///      unlock into the Quoter's catch. swap() answers ONLY when the pool key
///      matches the expectation byte-for-byte — any mismatch reverts with a
///      string (not a 2-word payload), which the Quoter must treat as a
///      refusal. That makes "the Quoter built the wrong key" OBSERVABLE as
///      the fallback decoy instead of the quote.
contract MockV4ManagerQ {
    uint8 public constant MODE_ECHO         = 0; // answer quoteOut on the out side
    uint8 public constant MODE_SHORT_REVERT = 1; // unlock reverts 32 bytes (not our payload)
    uint8 public constant MODE_CLEAN_RETURN = 2; // unlock returns without reverting
    uint8 public constant MODE_BAD_DELTA    = 3; // echo flow, out-side delta <= 0

    uint8   public mode;
    int256  public quoteOut;
    int256  public badOutDelta;

    address public expC0;
    address public expC1;
    uint24  public expFee;
    int24   public expTickSpacing;
    address public expHooks;

    function setMode(uint8 m) external { mode = m; }
    function setQuoteOut(int256 q) external { quoteOut = q; }
    function setBadOutDelta(int256 d) external { badOutDelta = d; }

    function setExpectedKey(address c0, address c1, uint24 fee_, int24 ts, address hooks_) external {
        expC0 = c0; expC1 = c1; expFee = fee_; expTickSpacing = ts; expHooks = hooks_;
    }

    uint256 public unlockCalls;   // persists only when unlock returns (the revert modes roll it back)

    function unlock(bytes calldata data) external returns (bytes memory) {
        ++unlockCalls;
        if (mode == MODE_SHORT_REVERT) {
            // 32 bytes: unambiguously not the Quoter's 2-word delta payload,
            // AND short enough that abi.decode(reason,(int256,int256)) would
            // revert if the length guard were deleted — a 100-byte
            // Error(string) would instead decode into garbage non-negative
            // words and slip through the rv-sign check, hiding the deletion.
            bytes memory p = abi.encode(uint256(0xDEAD));
            assembly { revert(add(p, 32), mload(p)) }
        }
        if (mode == MODE_CLEAN_RETURN) return bytes("");
        // Real flow: the callback runs the swap and reverts with the deltas;
        // the high-level call bubbles that revert out of unlock().
        IUnlockCbQ(msg.sender).unlockCallback(data);
        revert("V4M: callback returned"); // unreachable: the callback always reverts
    }

    function swap(IV4Q.V4PoolKey memory key, IV4Q.SwapParams memory p, bytes calldata)
        external view returns (int256)
    {
        require(key.currency0   == expC0,          "V4M: c0");
        require(key.currency1   == expC1,          "V4M: c1");
        require(key.fee         == expFee,         "V4M: fee");
        require(key.tickSpacing == expTickSpacing, "V4M: ts");
        require(key.hooks       == expHooks,       "V4M: hooks");
        require(p.amountSpecified <= 0,            "V4M: not exact-in");
        require(
            p.sqrtPriceLimitX96 ==
                (p.zeroForOne ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE),
            "V4M: limit"
        );
        int256 outD = mode == MODE_BAD_DELTA ? badOutDelta : quoteOut;
        (int256 d0, int256 d1) = p.zeroForOne
            ? (p.amountSpecified, outD)
            : (outD, p.amountSpecified);
        // Pack exactly as the Quoter unpacks: d0 in the high 128, d1 low.
        uint256 packed = (uint256(uint128(int128(d0))) << 128) | uint256(uint128(int128(d1)));
        return int256(packed);
    }
}

/// @dev Concentrated-pool stand-in for the _simConc refusal variants. It
///      answers a swap the way a real pool does: it calls the Quoter back
///      with crafted deltas and bubbles the payload the Quoter reverts with.
///      The short-revert mode reverts on its own, without calling back.
contract EchoConcPool {
    uint8 public constant MODE_ECHO         = 0; // 2-word payload, out side = -quoteOut
    uint8 public constant MODE_SHORT_REVERT = 1; // 32-byte revert (see V4M note above)
    uint8 public constant MODE_NON_NEGATIVE = 2; // 2-word payload, out side >= 0
    uint8 public constant MODE_CLEAN_RETURN = 3; // returns instead of reverting

    uint8  public mode;
    int256 public quoteOut;

    function setMode(uint8 m) external { mode = m; }
    function setQuoteOut(int256 q) external { quoteOut = q; }

    // The pair the Router reads off the pool (`_legTokens`): a leg must trade its hop's pair.
    address public token0;
    address public token1;
    function setTokens(address t0, address t1) external { token0 = t0; token1 = t1; }

    function swap(address, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external returns (int256, int256)
    {
        if (mode == MODE_SHORT_REVERT) {
            bytes memory s = abi.encode(uint256(0xBAD));
            assembly { revert(add(s, 32), mload(s)) }
        }
        if (mode == MODE_CLEAN_RETURN) return (int256(0), int256(0));
        int256 a0;
        int256 a1;
        if (mode == MODE_NON_NEGATIVE) { a0 = int256(3); a1 = int256(5); }
        else if (zeroForOne)           { a0 = amountSpecified; a1 = -quoteOut; }
        else                           { a0 = -quoteOut; a1 = amountSpecified; }
        (, bytes memory p) = msg.sender.call(
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", a0, a1, bytes("")));
        assembly { revert(add(p, 32), mload(p)) }
    }
}

contract QuoterExactRefusalBranchesTest is Test {
    BlazePhoenixQuoter quoter;
    MockSolverQ  solverMock;
    MockHubQ     hubMock;
    MockV4ManagerQ mgrMock;

    MockERC20 tokA;
    MockERC20 tokB;
    MockERC20 tokC;

    // Pinned from BPC / from the venue mocks — never magic numbers.
    uint160 constant SQRT_P_1  = 79228162514264337593543950336; // price 1.0 (== BPC.Q96)
    uint128 constant LIQ       = 1e24;
    uint24  constant POOL_FEE  = 3000;
    int24   constant TICK_SP   = 60;

    uint256 constant AMT       = 1e18;
    /// The plan-time approximation planted in every leg. A refusal at scale 1
    /// (legIn == base) reproduces it EXACTLY; a measurement never does.
    uint256 constant DECOY_OUT = 4_242e18;
    /// What the mocked venue answers when actually asked.
    uint256 constant Q_OUT     = 777e18;

    // The range refusals, derived from the type bounds the guards name.
    uint256 constant OVER_INT256 = uint256(type(int256).max) + 1;
    uint256 constant OVER_INT128 = uint256(uint128(type(int128).max)) + 1;

    // V4 hook addresses: permissions live in the low 14 address bits; bit 2/3
    // are the RETURNS_DELTA flags hookAltersDeltas() checks.
    address constant HOOK_DELTA = address(uint160(0xBEEF0000 + (1 << 3)));
    address constant HOOK_CLEAN = address(uint160(0x77770000)); // low 14 bits clear
    address constant HOOK_SWAP  = address(uint160(0xBEEF0000 + (1 << 7))); // BEFORE_SWAP only: runs in the swap, alters no delta

    /// @dev Backs a pair's declared reserves with balances. Since bounty #85 a pair that
    ///      declares more than it holds is a dead pool at every door, the Router's included;
    ///      this fixture's pools were quote-only bookkeeping and now hold what they declare.
    function _held(address p) internal {
        (uint112 r0, uint112 r1, ) = MockV2Pair(p).getReserves();
        _topUp85(MockV2Pair(p).token0(), p, r0);
        _topUp85(MockV2Pair(p).token1(), p, r1);
    }

    function _topUp85(address t, address p, uint256 r) internal {
        uint256 b = MockERC20(t).balanceOf(p);
        if (b < r) MockERC20(t).mint(p, r - b);
    }

    function setUp() public {
        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");
        tokC = new MockERC20("C", "C");

        solverMock = new MockSolverQ();
        hubMock    = new MockHubQ();
        mgrMock    = new MockV4ManagerQ();
        hubMock.setV4PoolManager(address(mgrMock));
        mgrMock.setQuoteOut(int256(Q_OUT));
        hubMock.setOutBridge(address(tokB));

        quoter = new BlazePhoenixQuoter(address(hubMock), address(solverMock));
    }

    // ─── route builders ──────────────────────────────────────────────────────

    function _leg(uint8 kind_, address pool_, uint256 amt, uint256 expectedOut_)
        internal pure returns (Leg memory l)
    {
        l = Leg({
            pool: pool_,
            hooks: address(0),
            kind: kind_,
            fee: POOL_FEE,
            tickSpacing: TICK_SP,
            zeroForOne: true,
            stable: false,
            amountIn: amt,
            expectedOut: expectedOut_,
            auxId: bytes32(0)
        });
    }

    function _wrap(Leg memory l, uint256 amt) internal view returns (Route memory r) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({
            tokenIn: address(tokA), tokenOut: address(tokB),
            amountIn: amt, expectedOut: 0, legs: ls
        });
        r = Route({
            hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _exact(Route memory r, uint256 amt) internal returns (uint256 exactOut) {
        solverMock.setBest(r);
        (Route memory back, uint256 net) = quoter.previewPlanExact(address(tokA), address(tokB), amt);
        // Since 2026-09-03 (register escape FEE-02) the scalar is NET of the
        // protocol fee while the route keeps the pool-math attestation. These
        // branch tests read the pool's own number from the route, and pin the
        // scalar's relation to it on EVERY call, so no branch can drift from
        // the deduction.
        exactOut = back.totalOut;
        assertEq(net, exactOut - BPC.mulDivUp(exactOut, BPC.PROTOCOL_FEE_BPS, BPC.BPS),
            "the exact scalar must be the route's attested total less the protocol fee");
    }

    function _v4Leg(uint256 amt) internal view returns (Leg memory l) {
        l = _leg(BPC.KIND_V4, address(0), amt, DECOY_OUT); // singleton: pool is not a pair
        l.auxId = bytes32(uint256(uint160(address(tokB))));
        _repool(l);
    }

    /// @dev A V4 leg must name the pool its key derives to, in the direction of its
    ///      tokens (BPX-2026-009). A leg built with `pool = 0` is refused at that
    ///      identity check - AFTER the early guards but BEFORE the dry run - so a
    ///      refusal test on such a leg passed for that reason instead of its own. The
    ///      mutation guard found it (2026-09-23): the delta-hook guard's mutant
    ///      survived, because the malformed leg was refused one check later anyway.
    ///      Call again after changing the hook or the counter token.
    function _repool(Leg memory l) internal view {
        address other = address(uint160(uint256(l.auxId)));
        (address c0, address c1) = BPC.sortTokens(address(tokA), other);
        l.zeroForOne = address(tokA) == c0;
        l.pool = address(uint160(uint256(BPC.computeV4PoolId(c0, c1, l.fee, l.tickSpacing, l.hooks))));
    }

    // =========================================================================
    //  Constructor guard — Quoter:146
    // =========================================================================

    /// BRANCH Quoter:146. Taken by: a zero hub, and a zero solver. Observable:
    /// revert with QuoterE(3) — the specific selector, not any revert.
    /// FAILS IF DELETED: yes — construction would succeed against address(0)
    /// dependencies and every later hub/solver call would be a call into
    /// nothing.
    function test_Constructor_RefusesZeroHubAndZeroSolver() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixQuoter.QuoterE.selector, 3));
        new BlazePhoenixQuoter(address(0), address(solverMock));

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixQuoter.QuoterE.selector, 3));
        new BlazePhoenixQuoter(address(hubMock), address(0));

        // Control: honest construction stands and pins both immutables.
        BlazePhoenixQuoter q = new BlazePhoenixQuoter(address(hubMock), address(solverMock));
        assertEq(address(q.hub()),    address(hubMock));
        assertEq(address(q.solver()), address(solverMock));
    }

    // =========================================================================
    //  _classify's malformed-route arm — Quoter:331
    // =========================================================================

    /// BRANCH Quoter:331, `n == 0` side. Taken by: previewRoute on a route
    /// with zero hops. Observable: no panic, topology 0, no bridge named.
    /// FAILS IF DELETED: yes — `route.hops[0]` on an empty array is
    /// Panic(0x32) and the whole preview reverts.
    function test_Classify_EmptyRouteDoesNotPanic() public {
        Route memory r;
        r.hops = new Hop[](0);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(r, 0);
        assertEq(pv.topology, 0, "an empty route has no topology");
        assertEq(pv.bridgeUsed, address(0), "an empty route names no bridge");
    }

    /// BRANCH Quoter:331, `hops[0].legs.length == 0` side. Taken by: a 2-hop
    /// route whose FIRST hop carries no legs. Observable: the classifier
    /// refuses — topology 0 and bridgeUsed zero — instead of naming
    /// hops[0].tokenOut as a bridge on the strength of a hop that does
    /// nothing.
    /// FAILS IF DELETED: yes — n == 2 would classify as (1, tokenOut) and
    /// both assertions below flip.
    function test_Classify_LeglessFirstHopNamesNoBridge() public {
        address bridge = address(0xB21D9E);

        Hop[] memory hs = new Hop[](2);
        hs[0] = Hop({tokenIn: address(tokA), tokenOut: bridge,        amountIn: AMT, expectedOut: 0, legs: new Leg[](0)});
        hs[1] = Hop({tokenIn: bridge,        tokenOut: address(tokB), amountIn: 0,   expectedOut: 0, legs: new Leg[](0)});
        Route memory r;
        r.hops = hs;

        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(r, 0);
        assertEq(pv.topology, 0, "a legless first hop must not classify as a bridge route");
        assertEq(pv.bridgeUsed, address(0), "no bridge may be named off a legless hop");

        // Control: give hop 0 one leg and the classifier is REAL (it was a
        // dead constant before 2026-08-22): 2 hops -> topology 1, bridge named.
        Leg[] memory ls = new Leg[](1);
        ls[0] = _leg(BPC.KIND_V3, address(uint160(0xF001)), AMT, 0);
        r.hops[0].legs = ls;
        pv = quoter.previewRoute(r, 0);
        assertEq(pv.topology, 1, "2 hops with a real first hop is a one-bridge route");
        // This hub registers no bridge, so the executor charges on every hop and anchors on
        // none; the preview names the bridge the fee is taken in, which here is no bridge.
        // The four topologies are pinned in QuoterBridgeUsedIsTheFeeAnchor.t.sol.
        assertEq(pv.bridgeUsed, address(0), "no bridged input: the fee has no single anchor to name");
    }

    // =========================================================================
    //  The empty route in the exact pass — Quoter:471
    // =========================================================================

    /// BRANCH Quoter:471. Taken by: a solver plan whose best route has no
    /// hops. Observable: exactOut == 0 and the returned route still promises
    /// nothing (totalOut 0).
    /// FAILS IF DELETED: yes, and this is the sharpest absence-=-permission
    /// shape in the contract: with the guard gone the loop runs zero times,
    /// carry stays == amountIn, and previewPlanExact returns exactOut ==
    /// amountIn — an empty route previewing as a perfect 1:1 conversion of
    /// the caller's full order.
    function test_Exact_EmptyRouteQuotesZero_NotAmountIn() public {
        Route memory r;
        r.hops = new Hop[](0);
        solverMock.setBest(r);

        (Route memory back, uint256 exactOut) =
            quoter.previewPlanExact(address(tokA), address(tokB), AMT);

        assertEq(exactOut, 0, "an empty route must quote ZERO, not echo amountIn");
        assertEq(back.totalOut, 0, "an empty route must not be rewritten into a promise");
    }

    // =========================================================================
    //  _simConc refusals — Quoter:373, 379, 381, 384 (+ fallback at 497)
    // =========================================================================

    /// BRANCH Quoter:373 (both arms: amtIn == 0, amtIn > int256.max). Taken
    /// by: a zero order, and an order past the int256 range the pool swap
    /// interface can express. Observable: the sim refuses, so the leg falls
    /// back to the plan-time linear approximation — 0 for the zero order,
    /// exactly DECOY_OUT for the over-range one (legIn == base). The echo
    /// pool is primed to answer Q_OUT, so a quote from the pool cannot be
    /// mistaken for the fallback.
    /// FAILS IF DELETED: yes — the echo pool answers regardless of amount, so
    /// removing either arm turns 0/DECOY_OUT into Q_OUT (the over-range value
    /// wraps negative through int256() and the echo still answers).
    function test_Exact_Conc_ZeroAndOverRangeInputRefused() public {
        EchoConcPool pool = new EchoConcPool();
        pool.setTokens(address(tokA), address(tokB));
        pool.setQuoteOut(int256(Q_OUT));

        // amtIn == 0
        uint256 exactOut = _exact(_wrap(_leg(BPC.KIND_V3, address(pool), 0, DECOY_OUT), 0), 0);
        assertEq(exactOut, 0, "a zero-input conc leg quotes zero, not the pool's echo");

        // amtIn > int256.max
        exactOut = _exact(
            _wrap(_leg(BPC.KIND_V3, address(pool), OVER_INT256, DECOY_OUT), OVER_INT256),
            OVER_INT256
        );
        assertEq(exactOut, DECOY_OUT,
            "an over-range conc leg must fall back to the plan approximation, not swap-sim a wrapped negative");
    }

    /// BRANCH Quoter:379 (try-success arm of the pool swap). Taken by: a pool
    /// whose swap() RETURNS instead of reverting — the Quoter never pays, so
    /// a conforming pool cannot get here; a lying one can. Observable: no
    /// quote; fallback to the decoy.
    /// FAILS IF DELETED: NO — stated per the coverage doctrine: deleting
    /// `return 0` falls through to the implicit zero and is behaviourally
    /// identical. What this test pins is the observable: a pool that
    /// "succeeds" without the callback round trip must never be treated as
    /// having quoted, and its returned tuple must never be believed.
    function test_Exact_Conc_CleanReturnIsNoQuote() public {
        EchoConcPool pool = new EchoConcPool();
        pool.setTokens(address(tokA), address(tokB));
        pool.setMode(pool.MODE_CLEAN_RETURN());

        uint256 exactOut = _exact(_wrap(_leg(BPC.KIND_V3, address(pool), AMT, DECOY_OUT), AMT), AMT);
        assertEq(exactOut, DECOY_OUT, "a non-reverting pool yields no quote; the fallback must be used");
    }

    /// BRANCH Quoter:381. Taken by: a pool-side revert whose data is not the
    /// Quoter's tagged delta payload (here 32 bytes — see the mock's note on why a
    /// short payload and not an Error(string)). Observable: refusal ->
    /// fallback decoy.
    /// FAILS IF DELETED: yes — abi.decode of 32 bytes as (int256,int256)
    /// reverts and the whole previewPlanExact call dies instead of quoting.
    function test_Exact_Conc_PoolSideRevertFallsBack() public {
        EchoConcPool pool = new EchoConcPool();
        pool.setTokens(address(tokA), address(tokB));
        pool.setMode(pool.MODE_SHORT_REVERT());

        uint256 exactOut = _exact(_wrap(_leg(BPC.KIND_V3, address(pool), AMT, DECOY_OUT), AMT), AMT);
        assertEq(exactOut, DECOY_OUT, "a pool-side revert is a refusal, answered by the fallback");
    }

    /// BRANCH Quoter:384. Taken by: a delta payload of the Quoter's own whose
    /// receive-side delta is NON-NEGATIVE — a "swap" that claims the Quoter
    /// receives nothing or owes on both sides. Observable: refusal ->
    /// fallback decoy.
    /// FAILS IF DELETED: yes — `out = uint256(-recv)` on recv == +5 is
    /// 2**256 - 5 and exactOut explodes to an astronomical over-quote.
    function test_Exact_Conc_NonNegativeDeltaRefused() public {
        EchoConcPool pool = new EchoConcPool();
        pool.setTokens(address(tokA), address(tokB));
        pool.setMode(pool.MODE_NON_NEGATIVE());

        uint256 exactOut = _exact(_wrap(_leg(BPC.KIND_V3, address(pool), AMT, DECOY_OUT), AMT), AMT);
        assertEq(exactOut, DECOY_OUT, "a non-negative receive delta is not a quote");
    }

    /// BRANCH Quoter:494 (the A_CONC_POOL arm) and the REAL revert-extraction
    /// loop: Quoter:363/365 (the universal fallback answering the V3 callback
    /// with the deltas) plus the catch decode. MockV3Pool runs the genuine
    /// flow — swap -> callback into the Quoter's fallback -> revert(deltas)
    /// -> bubbled -> decoded — so this is the dry run against the pool's own
    /// arithmetic, no mock payload anywhere.
    /// Observable: exactOut equals BPC.outV3 on the pool's exact state — the
    /// number the pool itself computes — and NOT the planted decoy. Direction
    /// pinned: at price 1.0 the fee makes out strictly less than in; the
    /// preview must not promise more than the pool delivers.
    /// FAILS IF DELETED: yes — without the A_CONC_POOL arm the leg falls to
    /// the linear else and answers the decoy.
    function test_Exact_Conc_RealDryRunMatchesPoolMath() public {
        MockV3Pool pool = new MockV3Pool(address(tokA), address(tokB), POOL_FEE);
        pool.setState(SQRT_P_1, LIQ);
        bool zfo = pool.token0() == address(tokA);

        Leg memory l = _leg(BPC.KIND_V3, address(pool), AMT, DECOY_OUT);
        l.zeroForOne = zfo;
        uint256 exactOut = _exact(_wrap(l, AMT), AMT);

        uint256 poolMath = BPC.outV3(AMT, SQRT_P_1, LIQ, POOL_FEE, zfo, 0);
        assertGt(poolMath, 0, "sanity: the pool prices this order");
        assertEq(exactOut, poolMath, "the exact pass must return the pool's own number");
        assertLt(exactOut, AMT, "at price 1.0 the fee bounds out strictly below in");
    }

    // =========================================================================
    //  _simV4 refusals — Quoter:420, 422, 423, 425, 447, 449, 452
    //  (+ fallback at 518, + the unlockCallback round trip 397-409)
    // =========================================================================

    function _v4Exact(Leg memory l, uint256 amt) internal returns (uint256 exactOut) {
        Route memory r = _wrap(l, amt);
        exactOut = _exact(r, amt);
    }

    /// @dev A leg the Router refuses: the scalar is zero since W3-F2, so the dry run's own
    ///      answer is read from the route's attestation, which still shows whether `_simV4`
    ///      refused the leg (the plan's DECOY_OUT) or priced it (the manager's Q_OUT).
    function _v4Refused(Leg memory l) internal returns (uint256 attested) {
        solverMock.setBest(_wrap(l, AMT));
        (Route memory back, uint256 net) = quoter.previewPlanExact(address(tokA), address(tokB), AMT);
        assertEq(net, 0, "a leg the Router refuses must quote a zero exact scalar (W3-F2)");
        attested = back.totalOut;
    }

    /// BRANCH Quoter:420 (both arms). Taken by: a zero order and an order
    /// past int128 — the range V4's amountSpecified can express. Observable:
    /// refusal -> 0 / fallback decoy, with the manager primed to answer.
    /// FAILS IF DELETED: yes — the manager answers Q_OUT for the matching
    /// key at any amount, so 0 becomes Q_OUT and DECOY_OUT becomes Q_OUT.
    function test_Exact_V4_ZeroAndOverRangeInputRefused() public {
        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokB));
        mgrMock.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, address(0));

        uint256 exactOut = _v4Exact(_v4Leg(0), 0);
        assertEq(exactOut, 0, "a zero-input V4 leg quotes zero, not the manager's echo");

        exactOut = _v4Exact(_v4Leg(OVER_INT128), OVER_INT128);
        assertEq(exactOut, DECOY_OUT,
            "an over-int128 V4 leg must fall back, not truncate through the singleton");
    }

    /// BRANCH Quoter:422. Taken by: hub.v4PoolManager() == 0 — no singleton
    /// wired on this chain. Observable: refusal -> fallback decoy.
    /// FAILS IF DELETED: yes — the try would call unlock() on address(0);
    /// the empty-returndata decode reverts in the CALLER (not caught by
    /// try/catch) and the whole preview dies.
    function test_Exact_V4_NoManagerFallsBack() public {
        hubMock.setV4PoolManager(address(0));
        uint256 exactOut = _v4Exact(_v4Leg(AMT), AMT);
        assertEq(exactOut, DECOY_OUT, "no manager: the V4 sim must refuse, not call into nothing");
    }

    /// BRANCH Quoter:423 — guarantee Q3: a delta-altering hook makes the leg
    /// unquotable by the exact pass. Taken by: a hook address with a
    /// RETURNS_DELTA permission bit. The manager is primed to answer for
    /// EXACTLY this key, hook included — so the refusal is provably the
    /// Quoter's own, not a downstream failure.
    /// FAILS IF DELETED: yes — key matches, manager answers Q_OUT, and the
    /// decoy assertion flips.
    function test_Exact_V4_DeltaHookUnquotable() public {
        assertTrue(BPC.hookAltersDeltas(HOOK_DELTA), "pinned: bit 3 is a RETURNS_DELTA flag");
        assertFalse(BPC.hookAltersDeltas(HOOK_CLEAN), "pinned: clean low bits alter nothing");

        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokB));
        mgrMock.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, HOOK_DELTA);

        Leg memory l = _v4Leg(AMT);
        l.hooks = HOOK_DELTA;
        _repool(l);   // well-formed for THIS key, so only the delta-hook guard can refuse
        uint256 exactOut = _v4Refused(l);
        assertEq(exactOut, DECOY_OUT,
            "a delta-altering hook is unquotable even when the manager would answer");
    }

    /// BRANCH Quoter `_simV4` pause arm (H13, oc-1018 m2, 2026-10-19). Taken by: a hook that
    /// runs in the swap and that the Hub holds PAUSED - the second arm of the Router's sieve
    /// (`_execV4Amt`: `hookRunsInSwap && hub.hookPaused` -> RouterE(9)). Observable: the
    /// fallback decoy, as for the delta arm above, with the manager primed to answer the key.
    /// FAILS IF DELETED: yes - the key matches, the manager answers Q_OUT for a leg the Router
    /// refuses, and Q_OUT replaces the decoy.
    function test_Exact_V4_PausedSwapHookUnquotable() public {
        assertTrue(BPC.hookRunsInSwap(HOOK_SWAP), "pinned: bit 7 runs in the swap");
        assertFalse(BPC.hookAltersDeltas(HOOK_SWAP), "pinned: and alters no delta, so only the pause arm can refuse");
        Leg memory l = _swapHookLeg();
        hubMock.setHookPaused(HOOK_SWAP, true);
        uint256 exactOut = _v4Refused(l);
        assertEq(exactOut, DECOY_OUT,
            "the exact pass priced a leg whose hook is paused, which the Router refuses with RouterE(9)");
    }

    /// Control for the arm above: the same hook, NOT paused, is priced by the pool. Red under
    /// a pause arm that refuses every swap-running hook without asking the Hub.
    function test_Exact_V4_LiveSwapHookIsPricedByThePool() public {
        Leg memory l = _swapHookLeg();
        uint256 exactOut = _v4Exact(l, AMT);
        assertEq(exactOut, Q_OUT, "a live swap-running hook must be dry-run on the pool");
    }

    /// W3-F2 (bounty uid 3115, Luis_MZ): guarantee Q3 for the exact scalar. A route whose V4 leg
    /// names a hook the Router refuses (RouterE(9): paused while it runs in the swap, or altering
    /// deltas) is unquotable at BOTH exact doors, as `_pack` withholds `canExecute` for it: the
    /// answer is zero, not the plan's own claim. The manager is primed to answer each key and the
    /// plan carries DECOY_OUT, so a nonzero answer is either the dry run or the fallback.
    /// FAILS IF DELETED: yes - without the `_hookRefusedIn` question at the head of the exact
    /// pass, the leg falls back to the plan's claim and the scalar is DECOY_OUT less the fee.
    function test_ExactScalar_RouterRefusedHook_IsZero() public {
        Leg memory l = _swapHookLeg();
        hubMock.setHookPaused(HOOK_SWAP, true);
        Route memory r = _wrap(l, AMT);
        solverMock.setBest(r);
        (, uint256 net) = quoter.previewPlanExact(address(tokA), address(tokB), AMT);
        assertEq(net, 0, "previewPlanExact quoted a paused swap hook the Router refuses with RouterE(9)");
        (, net) = quoter.previewRouteExact(r, AMT);
        assertEq(net, 0, "previewRouteExact quoted a paused swap hook the Router refuses with RouterE(9)");

        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokB));
        mgrMock.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, HOOK_DELTA);
        l = _v4Leg(AMT);
        l.hooks = HOOK_DELTA;
        _repool(l);
        solverMock.setBest(_wrap(l, AMT));
        (, net) = quoter.previewPlanExact(address(tokA), address(tokB), AMT);
        assertEq(net, 0, "previewPlanExact quoted a delta-altering hook the Router refuses with RouterE(9)");
    }

    function _swapHookLeg() internal returns (Leg memory l) {
        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokB));
        mgrMock.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, HOOK_SWAP);
        l = _v4Leg(AMT);
        l.hooks = HOOK_SWAP;
        _repool(l);   // well-formed for THIS key, so only the hook arms can refuse
    }

    /// BRANCH Quoter:425. Taken by: auxId == 0 — the leg names no counter
    /// token. The manager is primed to answer the MALFORMED key
    /// (sortTokens(tokenIn, 0)) on purpose: the guard must refuse BEFORE
    /// asking.
    /// FAILS IF DELETED: yes — the malformed key matches the primed
    /// expectation and Q_OUT replaces the decoy.
    function test_Exact_V4_ZeroAuxTokenRefused() public {
        (address c0, address c1) = BPC.sortTokens(address(tokA), address(0));
        mgrMock.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, address(0));

        Leg memory l = _v4Leg(AMT);
        l.auxId = bytes32(0);
        _repool(l);   // the malformed key's own pool, so only the zero-token guard can refuse
        solverMock.setBest(_wrap(l, AMT));
        (Route memory back, uint256 net) = quoter.previewPlanExact(address(tokA), address(tokB), AMT);
        assertEq(back.totalOut, DECOY_OUT, "a leg with no counter token cannot be dry-run");
        // And the scalar is zero: the leg's output (token 0) is not its hop's, which the Router
        // refuses with RouterE(3) (revisao-total 2026-10-23).
        assertEq(net, 0, "a leg with no counter token is not executable");
    }

    /// BRANCHES Quoter:515/516 (the A_CONC_SING arm) and the full V4 round
    /// trip: unlock -> unlockCallback (Quoter:397-409: auth, decode,
    /// exact-input params, packed-delta split) -> swap -> revert payload ->
    /// catch decode (448-453). The manager answers ONLY the exact key
    /// sortTokens(hop.tokenIn, auxId token) with the leg's fee/tickSpacing/
    /// hooks — so this pins the whole key construction, including a nonzero
    /// clean hook riding into the key.
    /// FAILS IF DELETED: yes — without the arm the leg answers the decoy;
    /// with a wrong key the manager refuses and the decoy shows.
    function test_Exact_V4_DryRunRoundTrip_KeyPinned() public {
        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokB));
        mgrMock.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, HOOK_CLEAN);

        Leg memory l = _v4Leg(AMT);
        l.hooks = HOOK_CLEAN;
        l.zeroForOne = address(tokA) == c0;
        l.pool = address(uint160(uint256(BPC.computeV4PoolId(c0, c1, POOL_FEE, TICK_SP, HOOK_CLEAN))));
        uint256 exactOut = _v4Exact(l, AMT);
        assertEq(exactOut, Q_OUT, "the V4 dry run must return the manager's own number");
    }

    /// BRANCH Quoter:426 + 436 (KIND_V4_NATIVE, zeroForOne): the input side
    /// is substituted with the native currency, so the key MUST be
    /// (address(0), auxId token) — address(0) sorts first by construction.
    /// The manager answers only that key.
    /// FAILS IF DELETED: yes — the un-substituted key sortTokens(tokA, tokB)
    /// mismatches, the manager refuses, and the decoy shows instead of Q_OUT.
    function test_Exact_V4Native_ZeroForOneSubstitutesCurrency0() public {
        hubMock.setWeth(address(tokA)); // the input side is the Router's WETH
        mgrMock.setExpectedKey(address(0), address(tokB), POOL_FEE, TICK_SP, address(0));

        Leg memory l = _v4Leg(AMT);
        l.kind = BPC.KIND_V4_NATIVE;
        l.zeroForOne = true; // input is currency0 == native
        l.pool = address(uint160(uint256(BPC.computeV4PoolId(address(0), address(tokB), POOL_FEE, TICK_SP, address(0)))));
        uint256 exactOut = _v4Exact(l, AMT);
        assertEq(exactOut, Q_OUT, "native zfo leg must key on (0, counterToken)");
    }

    /// BRANCH Quoter:437 (KIND_V4_NATIVE, !zeroForOne): the COUNTER side is
    /// native, so the key must be (address(0), hop.tokenIn) — the auxId
    /// placeholder is discarded, and the currency1 seat distinguishes this
    /// sub-branch from its zfo sibling.
    /// FAILS IF DELETED: yes — tokenOther stays the auxId token, the key
    /// mismatches, and the decoy shows.
    function test_Exact_V4Native_NotZeroForOneSubstitutesCounterSide() public {
        hubMock.setWeth(address(tokB)); // the counter side is the Router's WETH
        mgrMock.setExpectedKey(address(0), address(tokA), POOL_FEE, TICK_SP, address(0));

        Leg memory l = _v4Leg(AMT);
        l.kind = BPC.KIND_V4_NATIVE;
        l.zeroForOne = false; // input is currency1 == hop.tokenIn; native is the out side
        l.pool = address(uint160(uint256(BPC.computeV4PoolId(address(0), address(tokA), POOL_FEE, TICK_SP, address(0)))));
        uint256 exactOut = _v4Exact(l, AMT);
        assertEq(exactOut, Q_OUT, "native !zfo leg must key on (0, hop.tokenIn)");
    }

    /// BRANCH Quoter:447 (try-success arm of unlock). Taken by: a manager
    /// that returns instead of letting the callback's revert bubble.
    /// FAILS IF DELETED: NO — same fall-through equivalence as Quoter:379,
    /// stated here as there. The pinned observable: a manager that "succeeds"
    /// never produced deltas and must yield no quote.
    function test_Exact_V4_CleanReturnIsNoQuote() public {
        mgrMock.setMode(mgrMock.MODE_CLEAN_RETURN());
        uint256 exactOut = _v4Exact(_v4Leg(AMT), AMT);
        assertEq(mgrMock.unlockCalls(), 1, "setup: the dry run must reach unlock, or this branch is never asked");
        assertEq(exactOut, DECOY_OUT, "a non-reverting unlock yields no quote");
    }

    /// BRANCH Quoter:449. Taken by: a manager-side revert that is not the
    /// 2-word payload (32 bytes, same reasoning as the conc twin).
    /// FAILS IF DELETED: yes — the short decode reverts and the preview dies.
    function test_Exact_V4_ForeignRevertFallsBack() public {
        // WITNESS FIRST. The revert modes roll the unlock counter back, so the refusal
        // below cannot show it reached the manager. The same leg, in a mode that returns,
        // shows it: every check before unlock passes, and only the manager can refuse it.
        Leg memory l = _v4Leg(AMT);
        mgrMock.setMode(mgrMock.MODE_CLEAN_RETURN());
        _v4Exact(l, AMT);
        assertEq(mgrMock.unlockCalls(), 1, "setup: this leg must reach unlock, or the refusal is not from the manager");
        mgrMock.setMode(mgrMock.MODE_SHORT_REVERT());
        uint256 exactOut = _v4Exact(l, AMT);
        assertEq(exactOut, DECOY_OUT, "a manager-side revert is a refusal, answered by the fallback");
    }

    /// BRANCH Quoter:452. Taken by: a well-formed payload whose receive-side
    /// delta is <= 0 — the pool "answers" that the swapper gets nothing back.
    /// FAILS IF DELETED: yes — `out = uint256(rv)` on rv == -7 is 2**256 - 7:
    /// the refusal becomes an astronomical over-quote.
    function test_Exact_V4_NonPositiveDeltaRefused() public {
        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokB));
        mgrMock.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, address(0));
        mgrMock.setMode(mgrMock.MODE_BAD_DELTA());
        mgrMock.setBadOutDelta(-7);

        Leg memory l = _v4Leg(AMT);
        l.zeroForOne = address(tokA) == c0;
        // WITNESS FIRST: the same leg with an honest delta is priced, so the key checks
        // pass and the refusal below can only be the sign check.
        mgrMock.setMode(mgrMock.MODE_ECHO());
        assertEq(_v4Exact(l, AMT), Q_OUT, "setup: the same leg with a positive delta must be priced");
        mgrMock.setMode(mgrMock.MODE_BAD_DELTA());
        uint256 exactOut = _v4Exact(l, AMT);
        assertEq(exactOut, DECOY_OUT, "a non-positive receive delta is not a quote");
    }

    // =========================================================================
    //  The V2 arm — Quoter:498
    // =========================================================================

    /// BRANCH Quoter:498. Taken by: a KIND_V2 leg. Observable: the leg is
    /// priced by the ONE Core dispatcher (universalQuote) against the pair's
    /// real reserves — asserted by asking the same producer with the same
    /// coordinates, never by re-deriving the formula here. Direction pinned:
    /// out strictly below the no-fee spot conversion.
    /// FAILS IF DELETED: yes — the leg falls to the linear else and answers
    /// the decoy instead of the reserves-derived number.
    function test_Exact_V2LegPricedByUniversalQuote() public {
        MockV2Pair pair = new MockV2Pair(address(tokA), address(tokB));
        bool aIs0 = pair.token0() == address(tokA);
        if (aIs0) pair.setReserves(1_000e18, 500e18);
        else      pair.setReserves(500e18, 1_000e18);
        _held(address(pair));

        Leg memory l = _leg(BPC.KIND_V2, address(pair), AMT, DECOY_OUT);
        l.fee = 0;          // the sentinel: universalQuote applies effV2Fee's 30 bps
        l.zeroForOne = aIs0;
        uint256 exactOut = _exact(_wrap(l, AMT), AMT);

        QuoteCtx memory qc;
        qc.kind       = BPC.KIND_V2;
        qc.pool       = address(pair);
        qc.zeroForOne = aIs0;
        qc.fee        = 0;
        // Bounty #85: the dispatcher checks the pair holds its reserves, by token.
        qc.tokenIn    = address(tokA);
        qc.tokenOther = address(tokB);
        (uint256 producerOut, ) = BPC.universalQuote(qc, AMT);

        assertGt(producerOut, 0, "sanity: the pair prices this order");
        assertEq(exactOut, producerOut, "the V2 leg must be priced by the one Core dispatcher");
        assertLt(exactOut, BPC.mulDiv(AMT, 500e18, 1_000e18),
            "fee + impact bound the V2 quote strictly below spot");
    }

    // =========================================================================
    //  The Solidly else — Quoter:528 (executed, and its defect pinned)
    // =========================================================================

    /// BRANCH Quoter:528 (the final else — Solidly is the only live kind
    /// landing there). At scale 1 (legIn == base) the linear pass-through is
    /// exact: the plan value IS the pool's own getAmountOut, taken at plan
    /// time, and the exact pass must reproduce it.
    /// FAILS IF DELETED: yes — an emptied else leaves legOut == 0 and the
    /// exact pass quotes zero where the plan had a real number.
    function test_Exact_SolidlyLegExactAtScaleOne() public {
        MockSolidlyPair pair = new MockSolidlyPair(address(tokA), address(tokB), false);
        pair.setReserves(1_000e18, 1_000e18);
        _held(address(pair));
        uint256 honest = pair.getAmountOut(AMT, address(tokA));
        assertGt(honest, 0, "sanity: the pair prices this order");

        Leg memory l = _leg(BPC.KIND_SOLIDLY, address(pair), AMT, honest);
        l.zeroForOne = pair.token0() == address(tokA); // the pair sorts: trade A -> B as the Router reads it
        uint256 exactOut = _exact(_wrap(l, AMT), AMT);
        // The pool's own number less the wei the executor leaves it for its K check: the
        // exact pass promises what the executor asks for (Core.solidlyAskOut, dex-13).
        assertEq(exactOut, honest - 1, "at scale 1 the Solidly pass-through is the executor's ask");
    }

    /// RED-UNTIL-FIXED — the direction law on the branch's other flank.
    /// Quoter:528 rescales expectedOut LINEARLY when hop 1's real input
    /// exceeds the planned one (carry from a hop-0 dry run that out-delivered
    /// the plan). A constant-product curve is convex: getAmountOut(2x) is
    /// strictly less than 2*getAmountOut(x), so the linear rescale OVER-quotes
    /// — the externally reported ~907 bps over-quote on a thin pool, and an
    /// exact measurement (solidlyGetAmountOut) exists precisely where the
    /// approximation is used. The preview must never promise more than
    /// execution delivers; this asserts that direction against the pool's own
    /// answer at the scaled size and FAILS TODAY by design (same red-first
    /// idiom as ReproQuoterExactClampInflation.t.sol). It goes green when the
    /// else arm asks the pool — minding the source's own TRAP note about the
    /// KIND_V2-pinned ctx.
    function test_RED_SolidlyScaleUpMustNotOverQuote() public {
        // Hop 0: a real V3 dry run A -> B whose true output R exceeds the
        // plan's committed hop-1 input (P1 = R/2), forcing a 2x scale-up.
        MockV3Pool v3 = new MockV3Pool(address(tokA), address(tokB), POOL_FEE);
        v3.setState(SQRT_P_1, LIQ);
        bool zfo3 = v3.token0() == address(tokA);
        uint256 amtRed = 100e18;
        uint256 R  = BPC.outV3(amtRed, SQRT_P_1, LIQ, POOL_FEE, zfo3, 0);
        uint256 P1 = R / 2;

        MockSolidlyPair pair = new MockSolidlyPair(address(tokB), address(tokC), false);
        pair.setReserves(1_000e18, 1_000e18);
        _held(address(pair));
        uint256 honestBase = pair.getAmountOut(P1, address(tokB));

        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(BPC.KIND_V3, address(v3), amtRed, R);
        l0[0].zeroForOne = zfo3;
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(BPC.KIND_SOLIDLY, address(pair), P1, honestBase);
        l1[0].zeroForOne = pair.token0() == address(tokB);

        Hop[] memory hs = new Hop[](2);
        hs[0] = Hop({tokenIn: address(tokA), tokenOut: address(tokB), amountIn: amtRed, expectedOut: R,          legs: l0});
        hs[1] = Hop({tokenIn: address(tokB), tokenOut: address(tokC), amountIn: P1,     expectedOut: honestBase, legs: l1});
        Route memory r;
        r.hops = hs;
        solverMock.setBest(r);

        (, uint256 exactOut) = quoter.previewPlanExact(address(tokA), address(tokC), amtRed);

        // The pool's own answer at the ACTUAL scaled input (legIn == R).
        uint256 honestAtScale = pair.getAmountOut(R, address(tokB));
        assertGt(honestAtScale, 0, "sanity: the pair prices the scaled order");
        assertLe(exactOut, honestAtScale,
            "RED-UNTIL-FIXED: linear rescale of a convex curve promises more than the pool delivers");
    }


    // =========================================================================
    //  The Router's RouterE(3) shape, asked at the exact doors (revisao-total 2026-10-23)
    // =========================================================================
    //
    //  `Router._execute` refuses a route whose SHAPE does not hold before it moves a token:
    //  a leg that does not trade its hop's pair (Router:1311, the pair read from the pool as
    //  `_legTokens` reads it; a V4 leg's counter token is its auxId), a hookless leg after a
    //  hooked one (:1272), a hop that does not start where the previous one ended (:1130).
    //  `_hookRefusedIn` asked only the V4 refusals (9, 11, 8), so a hand-built route of any of
    //  these shapes previewed a positive exact scalar for a swap the Router reverts: the
    //  V3 twin of the flipped V4 direction (BPX-2026-009). Each test below has a control of the
    //  same route in the shape the Router accepts, priced by the same pool.

    function _echoAB() internal returns (EchoConcPool pool) {
        pool = new EchoConcPool();
        pool.setQuoteOut(int256(Q_OUT));
        pool.setTokens(address(tokA), address(tokB));
    }

    /// FAILS IF DELETED: yes - without the pair question the flipped leg is dry-run on the
    /// pool (the echo answers in either direction) and the scalar is Q_OUT less the fee.
    function test_Shape_LegTradingTheOtherDirection_IsNotQuoted() public {
        Leg memory l = _leg(BPC.KIND_V3, address(_echoAB()), AMT, DECOY_OUT);
        (, uint256 net) = quoter.previewRouteExact(_wrap(l, AMT), AMT);
        assertGt(net, 0, "control: a leg that trades its hop's pair is quoted");

        l.zeroForOne = false; // the pool now trades B -> A inside an A -> B hop
        (, net) = quoter.previewRouteExact(_wrap(l, AMT), AMT);
        assertEq(net, 0, "previewRouteExact quoted a leg the Router refuses with RouterE(3) (direction)");
    }

    /// FAILS IF DELETED: yes - the leg on the C/B pool is dry-run and quoted.
    function test_Shape_LegOnAnotherPair_IsNotQuoted() public {
        EchoConcPool pool = _echoAB();
        pool.setTokens(address(tokC), address(tokB)); // legIn = C in an A -> B hop
        Leg memory l = _leg(BPC.KIND_V3, address(pool), AMT, DECOY_OUT);
        (, uint256 net) = quoter.previewRouteExact(_wrap(l, AMT), AMT);
        assertEq(net, 0, "previewRouteExact quoted a leg on another pair, which the Router refuses with RouterE(3)");
    }

    /// FAILS IF DELETED: yes - the key (A, C) holds together, so the V4 sieve passes it and the
    /// manager, primed for that key, answers Q_OUT.
    function test_Shape_V4LegNamingAnotherCounterToken_IsNotQuoted() public {
        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokC));
        mgrMock.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, address(0));
        Leg memory l = _v4Leg(AMT);
        l.auxId = bytes32(uint256(uint160(address(tokC))));
        _repool(l); // well-formed for (A, C): only the hop's pair can refuse it
        (, uint256 net) = quoter.previewRouteExact(_wrap(l, AMT), AMT);
        assertEq(net, 0, "previewRouteExact quoted a V4 leg whose counter token is not the hop's output");
    }

    /// FAILS IF DELETED: yes - both legs are priced and the scalar is their sum less the fee.
    function test_Shape_HooklessLegAfterAHookedOne_IsNotQuoted() public {
        Leg memory hooked = _swapHookLeg();  // live swap hook, priced by the pool
        hooked.amountIn = AMT / 2;
        Leg memory plain = _leg(BPC.KIND_V3, address(_echoAB()), AMT / 2, DECOY_OUT);
        Route memory r = _wrap(plain, AMT);
        Leg[] memory ls = new Leg[](2);
        ls[0] = plain; ls[1] = hooked;
        r.hops[0].legs = ls;
        (, uint256 net) = quoter.previewRouteExact(r, AMT);
        assertGt(net, 0, "control: hookless legs before hooked ones are quoted");

        ls[0] = hooked; ls[1] = plain;
        (, net) = quoter.previewRouteExact(r, AMT);
        assertEq(net, 0, "previewRouteExact quoted a hookless leg after a hooked one (RouterE(3))");
    }

    /// FAILS IF DELETED: yes - the second hop's legs are priced on the carry of the first.
    function test_Shape_HopsThatDoNotChain_AreNotQuoted() public {
        EchoConcPool bc = new EchoConcPool();
        bc.setQuoteOut(int256(Q_OUT));
        bc.setTokens(address(tokB), address(tokC));
        Route memory r = _wrap(_leg(BPC.KIND_V3, address(_echoAB()), AMT, DECOY_OUT), AMT);
        Hop[] memory hs = new Hop[](2);
        hs[0] = r.hops[0];
        Leg[] memory ls = new Leg[](1);
        ls[0] = _leg(BPC.KIND_V3, address(bc), Q_OUT, DECOY_OUT);
        hs[1] = Hop({tokenIn: address(tokB), tokenOut: address(tokC), amountIn: Q_OUT, expectedOut: 0, legs: ls});
        r.hops = hs;
        (, uint256 net) = quoter.previewRouteExact(r, AMT);
        assertGt(net, 0, "control: hops that chain are quoted");

        ls[0].zeroForOne = false; // the C -> B pool ...
        hs[1].tokenIn = address(tokC); // ... in a hop that starts at C, not where hop 0 ended
        hs[1].tokenOut = address(tokB);
        (, net) = quoter.previewRouteExact(r, AMT);
        assertEq(net, 0, "previewRouteExact quoted hops that do not chain (RouterE(3))");
    }
}
