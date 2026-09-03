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
    function bridgeCount() external pure returns (uint8) { return 0; }
    function bridge(uint8) external pure returns (address) { return address(0); }
    function isBridgeToken(address) external pure returns (bool) { return false; }
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

    function unlock(bytes calldata data) external returns (bytes memory) {
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
///      reverts with a crafted payload directly (a real pool produces the
///      payload by calling the Quoter's fallback; MockV3Pool does that in the
///      genuine round-trip test).
contract EchoConcPool {
    uint8 public constant MODE_ECHO         = 0; // 2-word payload, out side = -quoteOut
    uint8 public constant MODE_SHORT_REVERT = 1; // 32-byte revert (see V4M note above)
    uint8 public constant MODE_NON_NEGATIVE = 2; // 2-word payload, out side >= 0
    uint8 public constant MODE_CLEAN_RETURN = 3; // returns instead of reverting

    uint8  public mode;
    int256 public quoteOut;

    function setMode(uint8 m) external { mode = m; }
    function setQuoteOut(int256 q) external { quoteOut = q; }

    function swap(address, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external view returns (int256, int256)
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
        bytes memory p = abi.encode(a0, a1);
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

    function setUp() public {
        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");
        tokC = new MockERC20("C", "C");

        solverMock = new MockSolverQ();
        hubMock    = new MockHubQ();
        mgrMock    = new MockV4ManagerQ();
        hubMock.setV4PoolManager(address(mgrMock));
        mgrMock.setQuoteOut(int256(Q_OUT));

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
        assertEq(pv.bridgeUsed, bridge, "the bridge is hop 0's tokenOut");
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
        pool.setMode(pool.MODE_CLEAN_RETURN());

        uint256 exactOut = _exact(_wrap(_leg(BPC.KIND_V3, address(pool), AMT, DECOY_OUT), AMT), AMT);
        assertEq(exactOut, DECOY_OUT, "a non-reverting pool yields no quote; the fallback must be used");
    }

    /// BRANCH Quoter:381. Taken by: a pool-side revert whose data is not the
    /// Quoter's 2-word payload (here 32 bytes — see the mock's note on why a
    /// short payload and not an Error(string)). Observable: refusal ->
    /// fallback decoy.
    /// FAILS IF DELETED: yes — abi.decode of 32 bytes as (int256,int256)
    /// reverts and the whole previewPlanExact call dies instead of quoting.
    function test_Exact_Conc_PoolSideRevertFallsBack() public {
        EchoConcPool pool = new EchoConcPool();
        pool.setMode(pool.MODE_SHORT_REVERT());

        uint256 exactOut = _exact(_wrap(_leg(BPC.KIND_V3, address(pool), AMT, DECOY_OUT), AMT), AMT);
        assertEq(exactOut, DECOY_OUT, "a pool-side revert is a refusal, answered by the fallback");
    }

    /// BRANCH Quoter:384. Taken by: a 64-byte revert payload whose
    /// receive-side delta is NON-NEGATIVE — a "swap" that claims the Quoter
    /// receives nothing or owes on both sides. Observable: refusal ->
    /// fallback decoy.
    /// FAILS IF DELETED: yes — `out = uint256(-recv)` on recv == +5 is
    /// 2**256 - 5 and exactOut explodes to an astronomical over-quote.
    function test_Exact_Conc_NonNegativeDeltaRefused() public {
        EchoConcPool pool = new EchoConcPool();
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
        uint256 exactOut = _v4Exact(l, AMT);
        assertEq(exactOut, DECOY_OUT,
            "a delta-altering hook is unquotable even when the manager would answer");
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
        uint256 exactOut = _v4Exact(l, AMT);
        assertEq(exactOut, DECOY_OUT, "a leg with no counter token cannot be dry-run");
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
        mgrMock.setExpectedKey(address(0), address(tokB), POOL_FEE, TICK_SP, address(0));

        Leg memory l = _v4Leg(AMT);
        l.kind = BPC.KIND_V4_NATIVE;
        l.zeroForOne = true; // input is currency0 == native
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
        mgrMock.setExpectedKey(address(0), address(tokA), POOL_FEE, TICK_SP, address(0));

        Leg memory l = _v4Leg(AMT);
        l.kind = BPC.KIND_V4_NATIVE;
        l.zeroForOne = false; // input is currency1 == hop.tokenIn; native is the out side
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
        assertEq(exactOut, DECOY_OUT, "a non-reverting unlock yields no quote");
    }

    /// BRANCH Quoter:449. Taken by: a manager-side revert that is not the
    /// 2-word payload (32 bytes, same reasoning as the conc twin).
    /// FAILS IF DELETED: yes — the short decode reverts and the preview dies.
    function test_Exact_V4_ForeignRevertFallsBack() public {
        mgrMock.setMode(mgrMock.MODE_SHORT_REVERT());
        uint256 exactOut = _v4Exact(_v4Leg(AMT), AMT);
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

        Leg memory l = _leg(BPC.KIND_V2, address(pair), AMT, DECOY_OUT);
        l.fee = 0;          // the sentinel: universalQuote applies effV2Fee's 30 bps
        l.zeroForOne = aIs0;
        uint256 exactOut = _exact(_wrap(l, AMT), AMT);

        QuoteCtx memory qc;
        qc.kind       = BPC.KIND_V2;
        qc.pool       = address(pair);
        qc.zeroForOne = aIs0;
        qc.fee        = 0;
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
        uint256 honest = pair.getAmountOut(AMT, address(tokA));
        assertGt(honest, 0, "sanity: the pair prices this order");

        Leg memory l = _leg(BPC.KIND_SOLIDLY, address(pair), AMT, honest);
        uint256 exactOut = _exact(_wrap(l, AMT), AMT);
        assertEq(exactOut, honest, "at scale 1 the Solidly pass-through is the pool's own number");
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
}
