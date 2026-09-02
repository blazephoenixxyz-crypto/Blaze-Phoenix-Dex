// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  CONDITION ADEQUACY — BlazePhoenixCore, the MC/DC-inert sub-conditions.
//
//  MC/DC triage (2026-08-31) found 30 sub-conditions in this library that no
//  test in the tree depends on: neutralising each (replacing it with the
//  identity of its connective — true in `&&`, false in `||`) leaves the whole
//  suite green. Each test below exists to make exactly one neutralisation FAIL.
//
//  The common shape: a zero-guard whose small-value cases are already pinned
//  (BlazePhoenixCore.t.sol:285) but whose DISTINGUISHING corner — the input
//  where skipping the guard panics or mis-quotes instead of also returning 0 —
//  was never driven. Skipping such a guard is invisible until the corner
//  arrives on the hot quote path as a checked-arithmetic revert: the quote-DoS
//  this library's own comments name as its defect signature. The remaining
//  tests cover two absence-as-permission reads (a refusal decoded as a value
//  in solidlyGetAmountOut / readDynamicFee) and two dispatch gates
//  (deriveAddress's Algebra detection, _factoryLookup's mode-2 dialect).
//
//  No vm.expectRevert anywhere: every kill is an assertEq on a value, where
//  the neutralised world either panics (test reverts -> red) or produces a
//  different value (assert fails -> red). Nothing here can pass on a
//  different guard that shares a selector.
//
//  Fixture reuse: CoreHarness (mocks/), MockSolidlyPair (mocks/), and
//  AlgebraDeployerFactory / DialectFactory / RevertingProbe imported from
//  CoreReadsBranches.t.sol (house idiom, cf. ConditionAdequacyQuoter importing
//  from QuoterExactRefusalBranches). The only new one-off shapes are the three
//  factory()/getFee behaviours no existing mock has — which is precisely why
//  their arms triaged INERT.
//
//  forge test --match-contract ConditionAdequacyCore -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {CoreHarness} from "./mocks/CoreHarness.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {
    AlgebraDeployerFactory,
    DialectFactory,
    RevertingProbe
} from "./CoreReadsBranches.t.sol";

// ─── one-off shapes (house idiom: inline what mocks/ does not have) ──────────

/// @dev A Solidly-shaped pair whose factory() ANSWERS — the missing link that
///      lets a test reach readDynamicFee's getFee branch at all (no local mock
///      exposed factory()+getFee before; that branch never ran in the suite).
contract SolidlyPairWithFactory {
    address internal immutable fac;
    constructor(address f) { fac = f; }
    function factory() external view returns (address) { return fac; }
}

/// @dev getFee REFUSES with a clean 32-byte word (5). A refusal whose payload
///      is a plausible small fee: the one shape that separates "ok was checked"
///      from "ok was assumed" — an Error(string) refusal would be caught by the
///      intact `f < BPS` arm by accident (selector word >= 2^224).
contract RevertWordFeeFactory {
    function getFee(address, bool) external view returns (uint256) {
        assembly { mstore(0x00, 5) revert(0x00, 0x20) }
    }
}

/// @dev getFee answers whatever it was told — 0 and >= BPS are the two answers
///      the f-range gate at Core:1372 exists to refuse.
contract SettableFeeFactory {
    uint256 internal answer;
    function set(uint256 f) external { answer = f; }
    function getFee(address, bool) external view returns (uint256) { return answer; }
}

// ═════════════════════════════════════════════════════════════════════════════

contract ConditionAdequacyCoreTest is Test {
    CoreHarness harness;

    address constant TA = address(0xAAA1);
    address constant TB = address(0xBBB1); // TA < TB, so t0 = TA
    bytes32 constant INIT_HASH = keccak256("condition-adequacy:init-code-hash");
    address constant DEP       = address(0xDE9107E4); // poolDeployer answer
    address constant CODELESS  = address(0xC0DE1E55); // provably no code in tests

    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0 (== BPC.Q96)

    /// cfgFee for every readDynamicFee test: inside the ceiling band (<= 100),
    /// nonzero, and distinct from every value a neutralised path would produce
    /// (5, 0, 20000) — so "the default survived" is a reading, not a collision.
    uint256 constant CFG_FEE = 77;

    function setUp() public {
        harness = new CoreHarness();
    }

    function _create2(address origin, bytes32 salt, bytes32 initHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", origin, salt, initHash)))));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:448  `isAlgebra = (sub == 1 && fee == 0)` — sub-condition `sub == 1`
    // ─────────────────────────────────────────────────────────────────────────

    /// Neutralised (isAlgebra = fee == 0), EVERY CREATE2 sub-mode with a zero
    /// fee consults poolDeployer(). A mode-4 factory that answers the probe
    /// then derives from the WRONG CREATE2 origin. The expectation is the
    /// spec formula pinned to the factory address — it cannot follow the
    /// origin swap. The mode-5 control proves the probe is live in this very
    /// fixture (dep really answers), so the mode-4 pin cannot pass vacuously
    /// off a dead deployer.
    function test_DeriveAddress_Mode4ZeroFeeNeverConsultsPoolDeployer() public {
        AlgebraDeployerFactory fac = new AlgebraDeployerFactory(DEP);

        // Control: the true Algebra slot (sub == 1, fee == 0) does swap origin.
        assertEq(
            BPC.deriveAddress(address(fac), TA, TB, 0, false, 0, 5, INIT_HASH),
            _create2(DEP, keccak256(abi.encode(TA, TB)), INIT_HASH),
            "control: mode 5 fee 0 must originate from poolDeployer()"
        );

        // The kill: same factory, same zero fee, sub == 0. Origin must stay
        // the factory even though poolDeployer() would answer.
        assertEq(
            BPC.deriveAddress(address(fac), TA, TB, 0, false, 0, 4, INIT_HASH),
            _create2(address(fac), keccak256(abi.encodePacked(TA, TB)), INIT_HASH),
            "mode 4 with fee 0 must NOT have its origin swapped to the deployer"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:525  `pool == address(0) && mode == 2` — sub-condition `mode == 2`
    // ─────────────────────────────────────────────────────────────────────────

    /// The Velodrome-V1 dialect is a MODE-2 fallback, not a universal one.
    /// DialectFactory answers ONLY getPair(a,b,bool); asked as mode 0 its
    /// canonical V2 getPair reverts (no such selector, no fallback), so the
    /// lookup must end at address(0). Neutralised (`pool == 0 && true`), the
    /// silent mode-0 lookup falls into the Solidly dialect and comes back with
    /// a pool the V2 family never declared. The mode-2 control proves the
    /// dialect selector is wired (rules out a two-zeros vacuous pass).
    function test_FactoryLookup_VeloDialectDoesNotAnswerForeignModes() public {
        DialectFactory fac = new DialectFactory();
        address P1 = address(0xF00D11);
        fac.setVelo(P1); // only the dialect selector has an answer

        // Control: as mode 2 the dialect must win (canonical silent).
        assertEq(
            BPC.deriveAddress(address(fac), TA, TB, 0, true, 0, 2, bytes32(0)),
            P1,
            "control: the V1 dialect answers the mode-2 lookup"
        );

        // The kill: the same factory asked as mode 0 has NO answer anywhere
        // in the V2 family — the dialect must not be consulted.
        assertEq(
            BPC.deriveAddress(address(fac), TA, TB, 0, true, 0, 0, bytes32(0)),
            address(0),
            "a mode-0 lookup must never fall through to the Solidly dialect"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:825  to18: `v == 0 || dec == 18` — sub-condition `v == 0`
    // ─────────────────────────────────────────────────────────────────────────

    /// The distinguishing corner is (v = 0, dec >= 96): the guard returns 0,
    /// the fall-through computes 10**(dec-18) FIRST, which leaves uint256 and
    /// panics before the harmless 0/x division. DecimalsGuardOverflow pins
    /// dec=200 with v=1e18 (the dec-sanitiser story); nothing pinned the
    /// zero-value fast path against the same absurd dec.
    function test_To18_ZeroValueAtAbsurdDecimalsIsZeroNotPanic() public pure {
        assertEq(BPC.to18(0, 200), 0,
            "to18(0, 200) must short-circuit on v == 0, not compute 10**182");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1053  outV2: `ain == 0 || rIn == 0 || rOut == 0`
    // ─────────────────────────────────────────────────────────────────────────

    /// `ain == 0` arm. Small-value pins exist (outV2(0,100,100,30) == 0) but
    /// pass either way: the fall-through also computes 0. Only rIn >= ~1.16e73
    /// distinguishes — there the denominator rIn*BPS leaves uint256, so the
    /// neutralised world panics where the guard returns 0.
    function test_OutV2_ZeroInputAgainstHugeReserveIsZeroNotPanic() public pure {
        assertEq(BPC.outV2(0, 1.2e73, 1, 30), 0,
            "ain == 0 must refuse before rIn * BPS is ever formed");
    }

    /// `rOut == 0` arm, mirrored corner: with rOut = 0 the fall-through's
    /// numerator ain*(BPS-fee) is the first thing to overflow once
    /// ain >= ~1.16e73. Guard present: 0. Guard neutralised: Panic(0x11).
    function test_OutV2_ZeroOutReserveAgainstHugeInputIsZeroNotPanic() public pure {
        assertEq(BPC.outV2(1.2e73, 1, 0, 30), 0,
            "rOut == 0 must refuse before ain * (BPS - fee) is ever formed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1084  outV3: `ain == 0 || liq == 0 || sqrtP == 0`
    // ─────────────────────────────────────────────────────────────────────────

    /// `liq == 0` arm, !zeroForOne: the very first fall-through step is
    /// mulDiv(amtAfterFee, Q96, L) — division by ZERO liquidity. A pool with a
    /// readable price but bricked liquidity() must quote 0, not take the whole
    /// Solver scan down with a panic. Every existing caller bounds L >= 1e15
    /// or guards upstream, so this arm had no witness.
    function test_OutV3_ZeroLiquidityQuotesZeroNotDivisionPanic() public pure {
        assertEq(BPC.outV3(1e18, SQRT_P_1, 0, 3000, false, 0), 0,
            "liq == 0 must refuse before mulDiv divides by L");
    }

    /// `sqrtP == 0` arm, !zeroForOne: with a readable liquidity but no price,
    /// the fall-through survives until the final mulDiv(a, Q96, P) and panics
    /// on P = 0. Dead mocks in the tree are dead for BOTH reads, so the mixed
    /// state (liq > 0, sqrtP == 0) never occurred.
    function test_OutV3_ZeroPriceQuotesZeroNotDivisionPanic() public pure {
        assertEq(BPC.outV3(1e18, 0, 1e18, 3000, false, 0), 0,
            "sqrtP == 0 must refuse before mulDiv divides by P");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1097  outV3 zeroForOne: `sqrtNew >= P || sqrtNew == 0`
    // ─────────────────────────────────────────────────────────────────────────

    /// `sqrtNew >= P` arm. mulDiv floors, so sqrtNew <= P always; the arm only
    /// decides at product == 0 (dust input), where sqrtNew == P exactly. The
    /// distinguishing call carries a sqrtLimit ABOVE P: neutralised, the dust
    /// swap falls into the clamp, sqrtNew is lifted past P, and P - sqrtNew
    /// underflows. Intact, the dust swap is refused with 0 before the clamp.
    /// No caller in src passes a limit at all, so nothing ever watched this.
    function test_OutV3_DustInputWithHighLimitIsZeroNotUnderflow() public pure {
        assertEq(
            BPC.outV3(1, uint160(BPC.Q96 / 2), 1e18, 0, true, uint160(BPC.Q96 / 2 + 1000)),
            0,
            "a swap too small to move the price must be refused before clamping"
        );
    }

    /// `sqrtNew == 0` arm. sqrtNew rounds to zero when L*P < L + product —
    /// an enormous input against dust L*P. Neutralised, the fall-through
    /// computes mulDiv(L, P - 0, Q96): the ENTIRE virtual reserve (1000 here),
    /// promised by a pool that was actually exhausted. Fuzz bounds
    /// (L >= 1e15, P >= Q96/4) keep every existing test out of this regime.
    function test_OutV3_PriceCollapseToZeroQuotesZeroNotWholeReserve() public pure {
        // L = 1, P = 1000*Q96, ain = 2*Q96 -> product = 2000*Q96 >> L*P/…
        // -> sqrtNew = floor(1000*Q96 / (2000*Q96 + 1)) = 0.
        assertEq(BPC.outV3(2 * BPC.Q96, uint160(1000 * BPC.Q96), 1, 0, true, 0), 0,
            "a swap that collapses the price must quote 0, never L*P/Q96");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1113  outV3 !zeroForOne: `sqrtLimit != 0 && sqrtNew > sqrtLimit`
    //             — sub-condition `sqrtNew > sqrtLimit`
    // ─────────────────────────────────────────────────────────────────────────

    /// The up-direction clamp was never exercised WITH a limit (TickBoundary-
    /// Clamp only tests zeroForOne). A permissive limit above the natural
    /// landing price must not bend the quote: at price 1, L = 1e18, ain = 1e18,
    /// fee 0, the swap lands at 2*Q96 and pays out exactly 5e17. Neutralised
    /// (clamp fires whenever a limit exists), sqrtNew is dragged UP to the
    /// 10*Q96 limit and the quote inflates to 9e17 — an over-quote in the one
    /// direction the exact-or-below promise forbids. Both readings pinned:
    /// the hand-derived constant and equality with the unlimited twin (which
    /// is immune to this neutralisation because its first conjunct is false).
    function test_OutV3_NonBindingUpperLimitDoesNotBendTheQuote() public pure {
        uint256 unlimited = BPC.outV3(1e18, SQRT_P_1, 1e18, 0, false, 0);
        uint256 limited   = BPC.outV3(1e18, SQRT_P_1, 1e18, 0, false, uint160(10 * BPC.Q96));
        assertEq(unlimited, 5e17, "state pin: price 1 -> 2*Q96 pays out exactly half L");
        assertEq(limited, unlimited,
            "a limit the swap never reaches must not change the quote");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1143  sqrtBoundary: `spacing <= 0 || sqrtP == 0` — `sqrtP == 0` arm
    // ─────────────────────────────────────────────────────────────────────────

    /// "No price" must mean "no limit" (0), never "limit at price 1 wei".
    /// Neutralised, the zeroForOne fall-through computes dn = 0, trips
    /// dn >= P (0 >= 0) and answers uint160(1) — a fabricated boundary out of
    /// an absent measurement. The control pins that a real price still yields
    /// a real boundary, so the zero reading is a reading, not a dead function.
    function test_SqrtBoundary_NoPriceMeansNoLimitNotBoundaryOne() public pure {
        assertEq(BPC.sqrtBoundary(0, 0, 60, true), 0,
            "sqrtP == 0 must answer 'no limit', never a synthetic boundary");
        assertGt(BPC.sqrtBoundary(SQRT_P_1, 0, 60, true), 0,
            "control: a real price yields a real boundary");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1188  solidlyGetAmountOut: `ok && ret.length >= 32`
    // ─────────────────────────────────────────────────────────────────────────

    /// `ok` arm. A pair whose getAmountOut REVERTS WITH A MESSAGE (the shape
    /// no Solidly mock ever had: MockSolidlyPair answers, HeadlessSolidlyPair
    /// reverts empty). Neutralised, the Error(string) payload is abi-decoded
    /// as the output — first word 0x08c379a0<<224, an astronomical over-quote
    /// that feeds expectedOut/floors. A refusal read as a value: the repo's
    /// named defect family. Intact, the refusal is 0 and the caller falls
    /// back to the replicated curve. The healthy control proves the decode
    /// path is live, so the zero pin cannot pass off a broken probe.
    function test_SolidlyGetAmountOut_MessageRevertIsZeroNotDecodedJunk() public {
        RevertingProbe pair = new RevertingProbe();
        assertEq(BPC.solidlyGetAmountOut(address(pair), 1e18, TA), 0,
            "a revert payload must never be decoded as an amountOut");

        MockSolidlyPair healthy = new MockSolidlyPair(TA, TB, false);
        healthy.setReserves(uint112(1e24), uint112(1e24));
        assertGt(BPC.solidlyGetAmountOut(address(healthy), 1e18, TA), 0,
            "control: a well-formed answer does flow through the decode");
    }

    /// `ret.length >= 32` arm. A codeless address SUCCEEDS with empty return
    /// data — the EVM's own absence-is-permission. Neutralised, abi.decode
    /// runs on 0 bytes and reverts, turning "pool does not exist" into a
    /// quote-path revert instead of the 0 that routes to the curve fallback.
    function test_SolidlyGetAmountOut_EmptySuccessIsZeroNotDecodeRevert() public view {
        assertEq(BPC.solidlyGetAmountOut(CODELESS, 1e18, TA), 0,
            "an empty success answer is not a quote; it must read as 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1194  outSolidly: `ain == 0 || rIn == 0 || rOut == 0`
    // ─────────────────────────────────────────────────────────────────────────

    /// `ain == 0` arm, stable path. The distinguishing corner: rIn at the
    /// 3.4e38 sentinel (admitted — the guard is strictly greater) against a
    /// 1-wei rOut. Neutralised, Newton's first derivative fp = x*(x^2/WAD)/WAD
    /// ~ 3.9e79 cannot be represented and mulDiv reverts "BPC:mulDiv" on the
    /// hot quote path. Intact, the zero input is refused for free.
    function test_OutSolidly_ZeroInputAtSentinelReservesIsZeroNotMulDivRevert() public view {
        assertEq(BPC.outSolidly(0, 3.4e38, 1, 30, true), 0,
            "ain == 0 must refuse before Newton's derivative is formed");
    }

    /// `rIn == 0` arm, stable path: with the guard gone, A = ain*(BPS-fee) is
    /// computed first and panics at ain >= ~1.16e73. Guard present: 0.
    function test_OutSolidly_ZeroInReserveAgainstHugeInputIsZeroNotPanic() public view {
        assertEq(BPC.outSolidly(1e75, 0, 1, 30, true), 0,
            "rIn == 0 must refuse before the fee product is ever formed");
    }

    /// `rOut == 0` arm, same huge-ain corner on the other reserve.
    function test_OutSolidly_ZeroOutReserveAgainstHugeInputIsZeroNotPanic() public view {
        assertEq(BPC.outSolidly(1e75, 1, 0, 30, true), 0,
            "rOut == 0 must refuse before the fee product is ever formed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1284  outSolidlyStable: `ain == 0 || rIn == 0 || rOut == 0`
    // ─────────────────────────────────────────────────────────────────────────

    /// `ain == 0` arm. Unlike outSolidly, the scaled path multiplies reserves
    /// by 10**(18-d) BEFORE any use: with dIn = 1 the fall-through forms
    /// X = rIn * 1e17 and panics at rIn >= ~1.16e60. The guard must answer
    /// first. (Harness call: the library fn is internal and its panics inline.)
    function test_OutSolidlyStable_ZeroInputBeforeReserveScalingPanic() public view {
        assertEq(harness.outSolidlyStable(0, 2e60, 1e18, 30, 1, 18), 0,
            "ain == 0 must refuse before rIn * sIn is ever formed");
    }

    /// `rIn == 0` arm: the OTHER reserve's scaling is what panics once the
    /// guard is gone (Y = rOut * 1e17 at rOut = 2e60).
    function test_OutSolidlyStable_ZeroInReserveBeforeOutScalingPanic() public view {
        assertEq(harness.outSolidlyStable(1e18, 0, 2e60, 30, 18, 1), 0,
            "rIn == 0 must refuse before rOut * sOut is ever formed");
    }

    /// `rOut == 0` arm: reserves scale small, but the input does not —
    /// A = ain * sIn panics at ain = 2e60 with dIn = 1.
    function test_OutSolidlyStable_ZeroOutReserveBeforeInputScalingPanic() public view {
        assertEq(harness.outSolidlyStable(2e60, 1, 0, 30, 1, 18), 0,
            "rOut == 0 must refuse before ain * sIn is ever formed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1298  _solidlyStable: `dIn > 18 || dOut > 18`
    // ─────────────────────────────────────────────────────────────────────────

    /// `dIn > 18` arm. The guard's own comment names the failure it prevents:
    /// 10**(18-d) underflows and bricks the route. _decimalsOf admits up to
    /// 77, so a legit 24-decimals token in a stable pair reaches this line.
    /// Every stable test in the tree uses 18/18 or 18/6 — the fail-closed arm
    /// itself had no witness. Neutralised: Panic(0x11) on the hot quote path.
    function test_SolidlyStable_TokenAbove18DecimalsInIsRefusedNotPanic() public view {
        assertEq(harness.outSolidlyStable(1e18, 1e18, 1e18, 30, 24, 18), 0,
            "dIn > 18 must fail closed, never underflow 10**(18-dIn)");
    }

    /// `dOut > 18` arm, symmetric via sOut.
    function test_SolidlyStable_TokenAbove18DecimalsOutIsRefusedNotPanic() public view {
        assertEq(harness.outSolidlyStable(1e18, 1e18, 1e18, 30, 18, 24), 0,
            "dOut > 18 must fail closed, never underflow 10**(18-dOut)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1329  _solidlyStable: `X > 3.4e38 || Y > 3.4e38`
    // ─────────────────────────────────────────────────────────────────────────

    /// `X > 3.4e38` arm, isolated (Y = 1e18 keeps the other arm false — the
    /// existing sentinel test sets BOTH to 4e38, so either arm answers for
    /// it). The razor corner: X at uintmax makes the NEXT line's X + A the
    /// first thing to overflow. Guard present: refused with 0. Guard
    /// neutralised: Panic(0x11) — the revert-on-admitted-pool this sentinel
    /// series exists to prevent.
    function test_SolidlySentinel_XArmAloneRefusesBeforeXPlusAOverflows() public view {
        assertEq(harness.outSolidlyStable(1e18, type(uint256).max, 1e18, 30, 18, 18), 0,
            "X above the sentinel must be refused before X + A is formed");
    }

    /// `Y > 3.4e38` arm, isolated (X = 50 keeps the X arm false). Dust-X
    /// inputs PASS _solKFits, Newton converges below the seed, and the
    /// neutralised world quotes ~2e39 out of a pool the sentinel refuses —
    /// a positive over-promise, not even a revert. fee = 0 makes A = 50
    /// exactly, matching the traced corner (X=50, A=50, Y=1e40 -> ~2.06e39).
    function test_SolidlySentinel_YArmAloneRefusesDustXHugeYWithZero() public view {
        assertEq(harness.outSolidlyStable(50, 50, 1e40, 0, 18, 18), 0,
            "Y above the sentinel must be refused, never quoted off dust X");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1364  readDynamicFee: `!ok || ret.length < 32`
    // ─────────────────────────────────────────────────────────────────────────

    /// `!ok` arm. Every local pair lacking factory() reverts EMPTY (missing
    /// selector), which the intact length arm also catches — so this arm had
    /// no witness. The distinguishing shape is a factory() that reverts WITH
    /// a message: neutralised, the Error(string) payload flows into
    /// abi.decode(ret,(address)), whose dirty-upper-bits check reverts the
    /// quote instead of keeping the declared fee.
    function test_ReadDynamicFee_MessageRevertingFactoryKeepsDeclaredFee() public {
        RevertingProbe pair = new RevertingProbe();
        assertEq(BPC.readDynamicFee(address(pair), true, CFG_FEE), CFG_FEE,
            "a refused factory() probe must leave the declared fee standing");
    }

    /// `ret.length < 32` arm. A codeless pool: staticcall SUCCEEDS with zero
    /// bytes. Neutralised, abi.decode runs on empty data and reverts — the
    /// absent pool must instead keep the declared fee.
    function test_ReadDynamicFee_CodelessPoolKeepsDeclaredFee() public view {
        assertEq(BPC.readDynamicFee(CODELESS, true, CFG_FEE), CFG_FEE,
            "an empty factory() answer must leave the declared fee standing");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1370  readDynamicFee: `ok && ret.length >= 32` (the getFee read)
    // ─────────────────────────────────────────────────────────────────────────

    /// `ok` arm. This branch NEVER ran locally (no mock had factory()+getFee),
    /// so first a control proves the chain is live: a well-formed getFee
    /// answer (44) must override the declared fee. Then the kill: a getFee
    /// that REFUSES with a raw 32-byte word carrying a plausible fee (5).
    /// Intact, the refusal keeps 77. Neutralised, the refusal payload passes
    /// the length and range gates and 5 becomes the live fee — a refusal read
    /// as a measurement.
    function test_ReadDynamicFee_GetFeeRevertPayloadIsNotAFee() public {
        SettableFeeFactory good = new SettableFeeFactory();
        good.set(44);
        SolidlyPairWithFactory livePair = new SolidlyPairWithFactory(address(good));
        assertEq(BPC.readDynamicFee(address(livePair), true, CFG_FEE), 44,
            "control: a measured in-range fee must override the declared one");

        RevertWordFeeFactory bad = new RevertWordFeeFactory();
        SolidlyPairWithFactory pair = new SolidlyPairWithFactory(address(bad));
        assertEq(BPC.readDynamicFee(address(pair), true, CFG_FEE), CFG_FEE,
            "a getFee refusal must keep the declared fee, whatever its payload");
    }

    /// `ret.length >= 32` arm. factory() answers an address with NO code:
    /// the getFee staticcall succeeds empty. Neutralised, abi.decode reverts
    /// on 0 bytes and the quote path dies; intact, the declared fee stands.
    function test_ReadDynamicFee_CodelessFactoryTargetKeepsDeclaredFee() public {
        SolidlyPairWithFactory pair = new SolidlyPairWithFactory(CODELESS);
        assertEq(BPC.readDynamicFee(address(pair), true, CFG_FEE), CFG_FEE,
            "an empty getFee answer must leave the declared fee standing");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1372  readDynamicFee: `f > 0 && f < BPS`
    // ─────────────────────────────────────────────────────────────────────────

    /// `f > 0` arm. getFee answering 0 is a mapping default for an unknown
    /// pool on live forks — an ABSENT entry, not a measured free pool.
    /// Neutralised, fee becomes 0 and the curve quotes fee-free.
    function test_ReadDynamicFee_ZeroMeasuredFeeIsAbsenceNotFree() public {
        SettableFeeFactory fac = new SettableFeeFactory(); // answers 0 by default
        SolidlyPairWithFactory pair = new SolidlyPairWithFactory(address(fac));
        assertEq(BPC.readDynamicFee(address(pair), true, CFG_FEE), CFG_FEE,
            "getFee == 0 is a missing entry and must not zero the fee");
    }

    /// `f < BPS` arm. A factory answering >= 100% is unpriceable, not a fee.
    /// Neutralised, fee = 20000 flows out and outSolidly's own fee guard
    /// silently zeroes every quote for the pair.
    function test_ReadDynamicFee_AbsurdMeasuredFeeIsRefusedNotAdopted() public {
        SettableFeeFactory fac = new SettableFeeFactory();
        fac.set(20_000);
        SolidlyPairWithFactory pair = new SolidlyPairWithFactory(address(fac));
        assertEq(BPC.readDynamicFee(address(pair), true, CFG_FEE), CFG_FEE,
            "a fee >= 100% must be refused, not adopted");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Core:1419  _solY: `x == 0 || K == 0` — sub-condition `K == 0`
    // ─────────────────────────────────────────────────────────────────────────

    /// _solK rounds to ZERO for wei-scale stable reserves (rIn = 1 wei:
    /// x*y*(x²+y²)/1e54 floors to 0 with rOut up to ~1e17). K == 0 means "no
    /// invariant measured" and must map to out = 0 via the seed return.
    /// Neutralised, Newton runs against K = 0, converges to y ≈ 0, and the
    /// quote becomes almost the ENTIRE output reserve (~1e17) — an
    /// over-promise on a pool that cannot deliver, from a 1-wei deposit.
    /// Every stable-quote test in the tree uses 1e18-scale reserves where K
    /// is huge; the dust regime had no witness.
    function test_SolY_UnmeasurableInvariantQuotesZeroNotTheReserve() public view {
        assertEq(harness.outSolidlyStable(1e18, 1, 1e17, 30, 18, 18), 0,
            "K == 0 must read as 'no invariant', never as 'take the reserve'");
    }
}
