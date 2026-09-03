// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  C7 / #21 - Hub:1039 `_scanV4`, the `t0 == w` arm of the native-pass gate.
//
//  THE CLAIM
//  `_scanV4` opens its NATIVE ETH pass on this decision (BlazePhoenixHub.sol,
//  line 1039 at main 6438fe4):
//
//      if (w != address(0) && (t0 == w || t1 == w)) {
//
//  The MC/DC campaign of 2026-09-03 neutralised the `t0 == w` sub-condition
//  (forced false) and the whole suite stayed green. The reason is orientation,
//  not logic: EVERY native discovery test in the tree scans a pair in which
//  WETH sorts HIGH (`t1`), so the surviving `t1 == w` arm answers for all of
//  them. The nearest neighbour, `test_L977_NativeDiscovery_WhenWethSortsSecond`
//  in test/ConditionAdequacyHub.t.sol, is explicitly built that way.
//
//  This file builds the missing orientation: a pair whose counterpart sorts
//  ABOVE WETH, so WETH is `t0` and the `t0 == w` arm is the ONLY leaf that can
//  open the native pass. If it is dropped, the deeper native pool (measured
//  292x deeper than its wrapped twin on Robinhood, per the Hub's own comment at
//  1004-1009) becomes invisible for the whole half of the token space that
//  sorts above WETH - silently, with no error and no worse quote to notice.
//
//  EXPECTED AGAINST 6438fe4: GREEN. The production code is correct; what is
//  missing is a test that DEPENDS on the arm. Under the paired mutant
//  (.github/scripts/mutants.py, entry 1: the `t0 == w` arm removed from the gate)
//  test_C7_L1039_NativeDiscovery_WhenWethSortsFirst goes RED, and so does
//  test_C7_L1039_BothOrientationsCoexist, whose `hi.length == 1` rests on the
//  SAME `t0 == w` arm: it is a second watchman, not a control, and it carries
//  no independent signal about rigidity. The two tests that stay GREEN under
//  that mutant - and that are therefore the anti-rigidity controls - are
//  test_C7_L1039_Control_NothingPlanted_DiscoveryIsEmpty and
//  test_C7_L1039_Control_TwinOrientation_WethSortsSecond.
//
//  WHY THE ASSERTS ARE NOT VACUOUS
//   - the pool address asserted is the truncation of the NATIVE poolId
//     (currency0 = address(0)), which is a DIFFERENT address from the wrapped
//     poolId of the same pair, so a hit produced by the wrapped pass cannot
//     satisfy it;
//   - `_ControlEmptyFixture` runs the identical fixture with nothing planted
//     and asserts ZERO hits, so the length-1 assert above is not something the
//     fixture hands out for free;
//   - `_ControlTwinOrientation` keeps the already-covered `t1 == w` direction
//     green, so a "fix" cannot buy this property by moving the gate to the
//     other side.
//
//  NO CHEATCODE ORDERING HAZARD: this file uses no cheatcodes at all. The
//  manager state is planted with plain calls to the mock's `setSlot`, so no
//  pending `vm.prank` / `vm.expectRevert` can be consumed by a builder.
//
//  Fixture reuse (house idiom, as test/ConditionAdequacyHub.t.sol does):
//  MockV4DeriveManager comes from V4LearnedCodeSuppressesGrid - the only local
//  manager mock answering BOTH extsload shapes - and this test contract is
//  itself the Hub's router role AND answers `weth()`, which is what the native
//  pass staticcalls (Hub:1037-1038, IRouterWeth).
//
//  forge test --match-contract HubScanV4NativeWhenWethSortsFirst -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockV4DeriveManager} from "./V4LearnedCodeSuppressesGrid.t.sol";

contract HubScanV4NativeWhenWethSortsFirstTest is Test {
    BlazePhoenixHub hub;
    MockV4DeriveManager mgr;

    // Same constants and the same sort relations as ConditionAdequacyHub.t.sol,
    // so the two files describe one fixture:
    //   belowWeth < WETH < aboveWeth
    // The pair (WETH, aboveWeth) sorts as (t0, t1) = (WETH, aboveWeth), which
    // is the orientation no native test in the tree ever built.
    address constant WETH      = address(0xEEE0);
    address constant aboveWeth = address(0xFFF0);
    address constant belowWeth = address(0x3333);

    // Hub-internal mode constant (Hub:244), pinned here as the other V4 test
    // files pin it.
    uint8 constant MODE_V4_DERIVE = 9;

    // Canonical Uniswap tier - `_v4CanonicalTiers()` entry 0 (Hub:1151), so it
    // is reached by the native pass's own canonical batch and needs no extras
    // row on the factory.
    uint24 constant FEE = 500;
    int24  constant TS  = 10;

    uint24[] internal noFees;
    int24[]  internal noSpacings;

    /// @dev The Hub's router role is this contract; the native pass resolves
    ///      the wrapped-native address with a staticcall to router.weth().
    function weth() external pure returns (address) { return WETH; }

    function setUp() public {
        mgr = new MockV4DeriveManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.setRoles(address(this), address(this), address(this));
    }

    // --- helpers -----------------------------------------------------------

    function _trunc(bytes32 pid) private pure returns (address) {
        return address(uint160(uint256(pid)));
    }

    /// The NATIVE key of (ETH, counterpart): currency0 = address(0), which
    /// already sorts first, exactly as `_scanV4` passes it (Hub:1047-1048).
    function _nativePid(address counterpart, uint24 fee, int24 ts)
        private pure returns (bytes32)
    {
        return BPC.computeV4PoolId(address(0), counterpart, fee, ts, address(0));
    }

    /// The WRAPPED key of the same economic pair - a DISTINCT poolId, and the
    /// address the asserts below must never accept in place of the native one.
    function _wrappedPid(address a, address b, uint24 fee, int24 ts)
        private pure returns (bytes32)
    {
        (address s0, address s1) = BPC.sortTokens(a, b);
        return BPC.computeV4PoolId(s0, s1, fee, ts, address(0));
    }

    /// Plant a live hookless V4 pool in the mock manager, StateLibrary layout:
    /// slot0 at keccak(abi.encode(pid, 6)), liquidity at +3 (BPC.v4SqrtAndLiq,
    /// Core:1718-1735). slot0 = Q96 means sqrtPriceX96 = 2^96, lpFee = 0,
    /// protocolFee = 0, so the static fee passes the INV-20 gate.
    function _plantAt(bytes32 pid, uint128 liq) private {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    function _addDeriveRow() private {
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), noFees, noSpacings);
    }

    // =========================================================================
    //  THE DECIDING TEST - Hub:1039 `t0 == w`
    // =========================================================================

    /// Neutralised (`t0 == w` forced false), the disjunction is decided by
    /// `t1 == w`, which is FALSE for this pair: the native pass never runs, the
    /// scan falls straight through to the wrapped probes, and discovery of the
    /// deeper native pool vanishes. The length-1 assert is the first to die.
    function test_C7_L1039_NativeDiscovery_WhenWethSortsFirst() public {
        _addDeriveRow();
        // Premise, stated as an assertion so a future change to the constants
        // cannot quietly turn this test back into the already-covered twin.
        // (uint160 casts: forge-std has no address overload of assertLt.)
        assertLt(uint160(WETH), uint160(aboveWeth),
            "premise: WETH must sort as t0 for this pair");

        bytes32 nativePid = _nativePid(aboveWeth, FEE, TS);
        _plantAt(nativePid, 1e21);

        PoolInfo[] memory hits = hub.discoverFor(WETH, aboveWeth);

        assertEq(hits.length, 1,
            "the native pool must be discovered when WETH sorts as t0");
        assertEq(hits[0].pool, _trunc(nativePid),
            "the hit is the NATIVE poolId truncation, not the wrapped one");
        assertTrue(hits[0].pool != _trunc(_wrappedPid(WETH, aboveWeth, FEE, TS)),
            "a wrapped-pass hit must not be able to satisfy the assert above");
        assertEq(hits[0].kind, BPC.KIND_V4_NATIVE, "emitted as native");
        assertEq(hits[0].token0, WETH,
            "orientation contract: token0 is the wrapped-native side");
        assertEq(hits[0].token1, aboveWeth, "counterpart is token1");
        assertEq(hits[0].fee, FEE, "the canonical tier that was planted");
        assertEq(hits[0].tickSpacing, TS, "with its tickSpacing");
        assertEq(hits[0].hooks, address(0), "hookless: a hooked key has no hookless id");
        assertTrue(hits[0].active, "and it is emitted active");

        // Argument order must not decide the answer: discoverFor sorts, so the
        // reversed call is the same scan and must produce the same single hit.
        PoolInfo[] memory rev = hub.discoverFor(aboveWeth, WETH);
        assertEq(rev.length, 1, "discovery is symmetric in its argument order");
        assertEq(rev[0].pool, _trunc(nativePid), "and finds the same native pool");
    }

    // =========================================================================
    //  CONTROLS - green today, and they must stay green after any fix
    // =========================================================================

    /// Anti-vacuity control. The identical fixture with NOTHING planted must
    /// discover nothing. Without this, "length == 1" above could be an artefact
    /// of the fixture rather than a reading of the planted pool.
    function test_C7_L1039_Control_NothingPlanted_DiscoveryIsEmpty() public {
        _addDeriveRow();
        PoolInfo[] memory hits = hub.discoverFor(WETH, aboveWeth);
        assertEq(hits.length, 0,
            "control: with no live pool the same scan yields nothing");
    }

    /// Twin-orientation control. The already-covered direction (counterpart
    /// BELOW WETH, so WETH is t1) must keep working. A fix that bought the t0
    /// orientation by moving the gate to one side would break this.
    function test_C7_L1039_Control_TwinOrientation_WethSortsSecond() public {
        _addDeriveRow();
        assertLt(uint160(belowWeth), uint160(WETH),
            "premise: WETH must sort as t1 for this pair");

        bytes32 nativePid = _nativePid(belowWeth, FEE, TS);
        _plantAt(nativePid, 1e21);

        PoolInfo[] memory hits = hub.discoverFor(belowWeth, WETH);
        assertEq(hits.length, 1,
            "control: the t1 orientation keeps discovering its native pool");
        assertEq(hits[0].pool, _trunc(nativePid), "the native poolId truncation");
        assertEq(hits[0].kind, BPC.KIND_V4_NATIVE, "emitted as native");
        assertEq(hits[0].token0, WETH, "orientation contract holds on this side too");
        assertEq(hits[0].token1, belowWeth, "counterpart is token1");
    }

    // =========================================================================
    //  NOT A CONTROL - a SECOND WATCHMAN on the same arm
    // =========================================================================

    /// Both orientations at once, on one registry. Neither arm may starve the
    /// other: this is the state in which a one-armed gate is visibly a HALF
    /// registry rather than a broken one.
    ///
    /// It is deliberately NOT named `_Control_`: its `hi.length == 1` depends on
    /// the same `t0 == w` arm as the deciding test, so it dies alongside it under
    /// mutant entry 1. It states the property more legibly; it does not make a
    /// fix falsifiable. The two controls are the two tests above.
    function test_C7_L1039_BothOrientationsCoexist() public {
        _addDeriveRow();
        bytes32 pidHigh = _nativePid(aboveWeth, FEE, TS);
        bytes32 pidLow  = _nativePid(belowWeth, FEE, TS);
        _plantAt(pidHigh, 1e21);
        _plantAt(pidLow, 1e21);

        PoolInfo[] memory hi = hub.discoverFor(WETH, aboveWeth);
        PoolInfo[] memory lo = hub.discoverFor(WETH, belowWeth);
        assertEq(hi.length, 1, "the above-WETH pair is discovered");
        assertEq(lo.length, 1, "and so is the below-WETH pair");
        assertEq(hi[0].pool, _trunc(pidHigh), "each side keeps its own pool");
        assertEq(lo[0].pool, _trunc(pidLow), "and they are not the same pool");
    }
}
