// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  CONDITION ADEQUACY — BlazePhoenixHub, the MC/DC-inert sub-conditions.
//
//  MC/DC triage (2026-08-31) found 56 sub-conditions in this contract that no
//  test in the tree depends on: neutralising them (replacing the condition with
//  the identity element of its connective) leaves the whole suite green. Each
//  test here constructs the ONE state where its sub-condition is the deciding
//  leaf, so that exactly that neutralisation makes it FAIL.
//
//  Three sub-conditions are NOT covered here, because their neutralisation is
//  observationally equivalent for any black-box test:
//    - Hub:1156 / Hub:1157 `$.v4CodeOf[t] != c` — skip-if-unchanged SSTOREs;
//      forcing them rewrites the identical value. Only storage-access
//      instrumentation pinned to the ERC-7201 struct offset could see it.
//    - Hub:1006 `cB != cA` — the duplicated _admitV4 replays a deterministic
//      view computation and the pool-address dedup swallows it; gas only.
//
//  Fixture reuse (house idiom, cf. ConditionAdequacyQuoter importing from
//  QuoterExactRefusalBranches): MockV4DeriveManager comes from
//  V4LearnedCodeSuppressesGrid (the only local manager mock answering BOTH
//  extsload shapes), pair/factory mocks from test/mocks. The test contract
//  itself is the Hub's router role AND answers weth() — recordSwap needs the
//  caller to BE the router, and the native/V4-scan paths need router.weth()
//  to answer; one constant serves both, mirroring RouterWethStub2.
//
//  forge test --match-contract ConditionAdequacyHub -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {MockV4DeriveManager} from "./V4LearnedCodeSuppressesGrid.t.sol";

/// @dev Solidly factory-call mock: mode 2's canonical selector
///      getPool(address,address,bool) (Core:508). No such factory mock existed
///      (MockV2Factory answers only getPair(address,address)); modelled on it.
contract MockSolidlyGetPoolFactory {
    mapping(bytes32 => address) internal pools;

    function setPool(address a, address b, bool stable, address pool) external {
        pools[keccak256(abi.encodePacked(a, b, stable))] = pool;
    }

    function getPool(address a, address b, bool stable) external view returns (address) {
        return pools[keccak256(abi.encodePacked(a, b, stable))];
    }
}

contract ConditionAdequacyHubTest is Test {
    BlazePhoenixHub hub;
    MockV4DeriveManager mgr;

    // Sorted bare-address tokens, base-test style. bridgeLo sorts BELOW every
    // token (the t0-side states the suite never built), bridgeHi ABOVE.
    address constant tokenLow = address(0x1000);
    address constant bridgeLo = address(0x1111);
    address constant tokenA   = address(0x2222);
    address constant tokenB   = address(0x3333);
    address constant tokenC   = address(0x4444);
    address constant tokenD   = address(0x5555);
    address constant bridgeHi = address(0xDDDD);
    // The canonical wrapped-native answer of this file's router (= this test).
    address constant WETH     = address(0xEEE0);
    address constant aboveWeth = address(0xFFF0);
    // Codeless hook, low 14 bits zero (same hygiene as GuardsNeverFired.HOOK).
    address constant HOOK = address(uint160(0xCAFE) << 14);

    // Hub-internal mode constants, pinned (as V4LearnedCodeSuppressesGrid does).
    uint8 constant MODE_SOLIDLY_CALL = 2;
    uint8 constant MODE_CREATE2_V2   = 4;
    uint8 constant MODE_CREATE2_CLONE = 6;
    uint8 constant MODE_V4_DERIVE    = 9;

    uint24[] internal noFees;
    int24[]  internal noSpacings;

    /// @dev The Hub's router role is this contract; the native/V4 scan paths
    ///      staticcall router.weth() (IRouterWeth), so answer it here.
    function weth() external pure returns (address) { return WETH; }

    function setUp() public {
        mgr = new MockV4DeriveManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.setRoles(address(this), address(this), address(this));
    }

    // ─── helpers ───────────────────────────────────────────────────────────

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    function _code(uint24 fee, int24 ts) private pure returns (uint256) {
        return (uint256(fee) << 24) | uint256(uint24(ts));
    }

    function _trunc(bytes32 pid) private pure returns (address) {
        return address(uint160(uint256(pid)));
    }

    /// Plant a live hookless V4 pool (StateLibrary layout, mirrors
    /// HardeningA4/V4LearnedCodeSuppressesGrid): slot0 = Q96, liquidity at +3.
    function _plantAt(bytes32 pid, uint128 liq) private {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    /// Liquidity word only, slot0 left zero — the sp==0 && liq!=0 state the
    /// suite never mocked.
    function _plantLiqOnlyAt(bytes32 pid, uint128 liq) private {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
    }

    function _wrappedPid(address a, address b, uint24 fee, int24 ts) private pure returns (bytes32) {
        (address s0, address s1) = BPC.sortTokens(a, b);
        return BPC.computeV4PoolId(s0, s1, fee, ts, address(0));
    }

    function _nativePid(address counterpart, uint24 fee, int24 ts) private pure returns (bytes32) {
        return BPC.computeV4PoolId(address(0), counterpart, fee, ts, address(0));
    }

    function _recordV4(address pool, uint24 fee, address a, address b) private {
        hub.recordSwap(pool, BPC.KIND_V4, fee, address(0), a, b, 1e18, 1e18, 1e18);
    }

    function _addDeriveRow(uint24[] memory fees, int24[] memory sps) private {
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), fees, sps);
    }

    function _find(PoolInfo[] memory hits, address pool)
        private pure returns (bool found, PoolInfo memory pi)
    {
        for (uint256 i; i < hits.length; ++i) {
            if (hits[i].pool == pool) return (true, hits[i]);
        }
    }

    function _bit(uint256 s, uint256 i) private pure returns (uint256) { return (s >> i) & 1; }

    // =========================================================================
    //  Hub:432 — onlyOperator: `msg.sender == admin`
    //  The admin fallback is only decisive when the admin is NOT in the
    //  operator mapping; initialize always sets operator[admin], so that state
    //  never existed. setOperator can revoke the admin's own bit.
    // =========================================================================

    /// Neutralised (fallback forced false), the revoked-operator admin is
    /// refused with HubE(1) and the seedPool below reverts — the assert reads a
    /// registration that can then never have happened.
    function test_L432_AdminWhoIsNotOperator_StillPassesOperatorDoor() public {
        hub.setOperator(address(this), false);
        bytes32 key = hub.seedPool(address(0xA001), BPC.KIND_V2, 30, address(0), tokenA, tokenB);
        assertEq(hub.getPool(key), address(0xA001),
            "admin must pass the operator door through the admin leg alone");
        // Control: the door is not simply open — a roleless stranger is refused.
        vm.prank(address(0xBAD));
        vm.expectRevert(_err(1));
        hub.seedPool(address(0xA002), BPC.KIND_V2, 30, address(0), tokenA, tokenB);
    }

    // =========================================================================
    //  Hub:502 — isHookLive: `$.hookAllowed[h]`
    //  For a CODED hook, revocation deletes the pin and the codehash conjunct
    //  masks the allow-bit. A CODELESS hook has codehash 0 == deleted pin 0,
    //  so the allow-bit is the ONLY thing keeping it dead.
    // =========================================================================

    /// Neutralised (hookAllowed forced true), the revoked codeless hook reads
    /// live (0 == 0 on the pin conjunct) and the assertFalse fails. The
    /// control first proves liveness is reachable, so false is a reading.
    function test_L502_RevokedCodelessHook_IsNotLive() public {
        hub.allowHook(HOOK, true);
        assertTrue(hub.isHookLive(HOOK), "control: allowed codeless hook is live (pin 0 == codehash 0)");
        hub.allowHook(HOOK, false);
        assertFalse(hub.isHookLive(HOOK),
            "a revoked codeless hook must be dead on the allow-bit alone");
    }

    // =========================================================================
    //  Hub:629 — addFactory: `kind != BPC.KIND_SOLIDLY` (mode-6 coherence)
    //  The suite refuses mode 6 with a WRONG kind but never admits it with the
    //  right one — zero successful mode-6 admissions anywhere.
    // =========================================================================

    /// Neutralised (forced true), EVERY mode-6 row reverts HubE(5), including
    /// this legitimate SOLIDLY clone row — the count assert cannot run.
    function test_L629_CloneModeWithSolidlyKind_IsAdmitted() public {
        uint8 idx = hub.addFactory(
            address(0xFAC6), BPC.KIND_SOLIDLY, MODE_CREATE2_CLONE,
            bytes32(uint256(1)), noFees, noSpacings
        );
        assertEq(idx, 0, "the clone row must be admitted");
        assertEq(hub.factoryCount(), 1, "mode-6 + KIND_SOLIDLY is the coherent pair");
    }

    // =========================================================================
    //  Hub:690 — addV4 (native): `c1 == w`
    //  No test ever called addV4(address(0), WETH). Neutralised (forced
    //  false), the WETH/WETH junk entry registers and the exact HubE(3) below
    //  never fires.
    // =========================================================================

    function test_L690_NativeAddV4_RefusesWethAsCounterpart() public {
        vm.expectRevert(_err(3));
        hub.addV4(address(0), WETH, 500, 10, address(0));
    }

    // =========================================================================
    //  Hub:715 — addV4: `nat && r0 != w` (Monoslot bit 6)
    //  The read side is shadowed by the V4Entry override, but the BIT itself
    //  is raw state behind getSlot. Pin it on both false-sides.
    // =========================================================================

    /// Neutralised `nat` (forced true): a NON-native addV4 evaluates r0 != w
    /// with w unset (0), true for any real token, and stamps bit 6 on a plain
    /// V4 slot. The assert reads that exact bit.
    function test_L715_NonNativeAddV4_LeavesNativeSwappedBitClear() public {
        bytes32 key = hub.addV4(tokenA, tokenB, 500, 60, address(0));
        assertEq(_bit(hub.getSlot(key), 6), 0,
            "a non-native registration must not carry the native-swapped bit");
    }

    /// Neutralised `r0 != w` (forced true): every native registration stamps
    /// bit 6, including this one where WETH already sorts first (r0 == w).
    /// The below-WETH control proves the bit machinery is live, so the zero
    /// read is a reading and not a dead flag.
    function test_L715_NativeAddV4_WethSortingFirst_LeavesBitClear() public {
        bytes32 keyClean = hub.addV4(address(0), aboveWeth, 500, 60, address(0));
        assertEq(_bit(hub.getSlot(keyClean), 6), 0,
            "counterpart above WETH: orientation already canonical, bit must stay clear");
        bytes32 keySwapped = hub.addV4(address(0), tokenB, 500, 60, address(0));
        assertEq(_bit(hub.getSlot(keySwapped), 6), 1,
            "control: counterpart below WETH does set the bit");
    }

    // =========================================================================
    //  Hub:756 — claimV4: `!_isRoutableBridge($, c1)`
    //  Every successful claim in the suite passes the bridge as c0.
    // =========================================================================

    /// Neutralised (forced true), the anchor gate sees only c0 (non-bridge)
    /// and reverts HubE(9); the registration this asserts cannot exist.
    function test_L756_ClaimWithBridgeAsSecondArgument_Succeeds() public {
        hub.addBridge(bridgeLo);
        bytes32 pid = _wrappedPid(bridgeLo, tokenA, 500, 10);
        _plantAt(pid, 1e18);
        vm.prank(address(0xCA11));
        bytes32 key = hub.claimV4(tokenA, bridgeLo, 500, 10);
        assertEq(hub.getPool(key), _trunc(pid),
            "the c1 arm of the permissionless anchor gate must admit a bridge-as-second-argument claim");
    }

    // =========================================================================
    //  Hub:763 — claimV4: `sp == 0`
    //  sp==0 with liq!=0 was never mocked; liq==0 always masked the sibling.
    // =========================================================================

    /// Neutralised (forced false), the liq!=0 arm passes the guard, the static
    /// fee passes INV-20, depthFromL18(sp=0) yields 0 and the empty pair
    /// admits it — the claim SUCCEEDS, so the exact HubE(9) never fires.
    function test_L763_PlantedLiquidityWithoutPrice_RefusedWithNine() public {
        hub.addBridge(bridgeLo);
        _plantLiqOnlyAt(_wrappedPid(bridgeLo, tokenA, 500, 10), 1e18);
        vm.prank(address(0xCA11));
        vm.expectRevert(_err(9));
        hub.claimV4(bridgeLo, tokenA, 500, 10);
    }

    // =========================================================================
    //  Hub:824 + Hub:878 — the mode-2 (Solidly factory-call) arms
    //  No local mode-2 factory ever existed. Both pools of one (fee, spacing)
    //  combo live => the hits allocation NEEDS mul=2 and the scan NEEDS the
    //  stable probe.
    // =========================================================================

    function _setupMode2BothVariants() private returns (address volPool, address staPool) {
        MockSolidlyGetPoolFactory fac = new MockSolidlyGetPoolFactory();
        hub.addFactory(address(fac), BPC.KIND_SOLIDLY, MODE_SOLIDLY_CALL, bytes32(0), noFees, noSpacings);
        volPool = address(0xA1A1);
        staPool = address(0xB2B2);
        vm.etch(volPool, hex"fe");
        vm.etch(staPool, hex"fe");
        (address t0, address t1) = BPC.sortTokens(tokenA, tokenB);
        fac.setPool(t0, t1, false, volPool);
        fac.setPool(t0, t1, true, staPool);
    }

    /// Neutralised (`fac.mode == 2` in the ternary forced false), maxOut is 1
    /// while the scan still probes both variants: the second _probe writes
    /// hits[1] out of bounds and discoverFor dies with Panic(0x32) before any
    /// assert — the length-2 read is unreachable.
    function test_L824_Mode2Row_AllocatesBothVariantSlots() public {
        (address volPool, address staPool) = _setupMode2BothVariants();
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 2, "one Solidly combo yields TWO candidates: volatile and stable");
        (bool fv,) = _find(hits, volPool);
        (bool fs,) = _find(hits, staPool);
        assertTrue(fv && fs, "both variants must be present");
    }

    /// Neutralised (`fac.mode == 2` in the solidly flag forced false), only
    /// the volatile probe runs and the stable hit vanishes.
    function test_L878_Mode2Row_ProbesStableVariant() public {
        (, address staPool) = _setupMode2BothVariants();
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        (bool fs, PoolInfo memory pi) = _find(hits, staPool);
        assertTrue(fs, "the stable-variant probe must reach the stable pool");
        assertTrue(pi.stable, "and report it as stable");
    }

    // =========================================================================
    //  Hub:824 + Hub:878 — the mode-6 (CREATE2 clone) arms
    //  Zero mode-6 rows existed anywhere. The clone salt includes `stable`, so
    //  the two variants derive two distinct addresses; etch code at both.
    // =========================================================================

    function _setupMode6BothVariants() private returns (address volPool, address staPool) {
        address fac6 = address(0xFAC006);
        bytes32 ih = keccak256("clone-init");
        hub.addFactory(fac6, BPC.KIND_SOLIDLY, MODE_CREATE2_CLONE, ih, noFees, noSpacings);
        volPool = BPC.deriveAddress(fac6, tokenA, tokenB, 0, false, 0, MODE_CREATE2_CLONE, ih);
        staPool = BPC.deriveAddress(fac6, tokenA, tokenB, 0, true, 0, MODE_CREATE2_CLONE, ih);
        vm.etch(volPool, hex"fe");
        vm.etch(staPool, hex"fe");
    }

    /// Same shape as the mode-2 kill: neutralised, maxOut halves and the
    /// second in-bounds write panics 0x32 inside discoverFor.
    function test_L824_Mode6Row_AllocatesBothVariantSlots() public {
        (address volPool, address staPool) = _setupMode6BothVariants();
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 2, "one clone combo yields TWO candidates: volatile and stable");
        (bool fv,) = _find(hits, volPool);
        (bool fs,) = _find(hits, staPool);
        assertTrue(fv && fs, "both derived clone addresses must be present");
    }

    /// Neutralised (`fac.mode == 6` in the solidly flag forced false), the
    /// stable clone address is never derived and this hit vanishes.
    function test_L878_Mode6Row_ProbesStableVariant() public {
        (, address staPool) = _setupMode6BothVariants();
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        (bool fs, PoolInfo memory pi) = _find(hits, staPool);
        assertTrue(fs, "the stable clone variant must be derived and emitted");
        assertTrue(pi.stable, "and reported as stable");
    }

    // =========================================================================
    //  Hub:872 — _scanFactory: `fac.mode < 4` (codehash pin scope)
    //  Every CREATE2 factory in the suite kept its admission codehash. Mutate
    //  one: the pin must NOT gate derive modes — a derivation is a theorem the
    //  factory cannot influence.
    // =========================================================================

    /// Neutralised (forced true), the pin extends to this mutated CREATE2 row
    /// (stored pin 0 != post-etch codehash) and discovery yields nothing.
    function test_L872_MutatedCreate2Factory_StillDerives() public {
        address fac4 = address(0xFAC0004);          // codeless at admission: pin = 0
        bytes32 ih = keccak256("v2-init");
        hub.addFactory(fac4, BPC.KIND_V2, MODE_CREATE2_V2, ih, noFees, noSpacings);
        vm.etch(fac4, hex"fe");                     // the factory's code changes AFTER admission
        address pool = BPC.deriveAddress(fac4, tokenA, tokenB, 0, false, 0, MODE_CREATE2_V2, ih);
        vm.etch(pool, hex"fe");

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "a mutated CREATE2 factory must keep deriving (the pin is for asking modes)");
        assertEq(hits[0].pool, pool, "the derived pool is the hit");
    }

    // =========================================================================
    //  Hub:977 — _scanV4: `t1 == w`
    //  All WETH pairs the suite scans have WETH as t0. Here the counterpart
    //  sorts BELOW WETH, so only the t1 arm opens the native pass.
    // =========================================================================

    /// Neutralised (forced false), the native pass is skipped for this
    /// orientation and native discovery silently vanishes: zero hits.
    function test_L977_NativeDiscovery_WhenWethSortsSecond() public {
        _addDeriveRow(noFees, noSpacings);
        _plantAt(_nativePid(tokenB, 500, 10), 1e21);

        PoolInfo[] memory hits = hub.discoverFor(tokenB, WETH); // tokenB < WETH => t1 == w
        assertEq(hits.length, 1, "the native pool must be discovered when WETH sorts as t1");
        assertEq(hits[0].kind, BPC.KIND_V4_NATIVE, "emitted as native");
        assertEq(hits[0].token0, WETH, "orientation contract: token0 is the wrapped-native side");
        assertEq(hits[0].token1, tokenB, "counterpart is token1");
    }

    // =========================================================================
    //  Hub:1006 — _scanV4: `cB != 0`
    //  Deciding state: cA != 0, cB == 0 (so the sibling `cB != cA` is true),
    //  with a live pool planted at the phantom (fee 0, ts 0) tier that a
    //  forced-through code-0 admit would probe.
    // =========================================================================

    /// Neutralised (forced true), _admitV4 runs with code 0, finds the planted
    /// (0,0) pool live, and emits a second hit; the length-1 assert fails.
    function test_L1006_EmptyCounterpartCode_DoesNotProbeZeroTier() public {
        hub.addBridge(bridgeLo);
        _addDeriveRow(noFees, noSpacings);
        // Learn a code for tokenA only (claim on the bridge pair writes the
        // non-bridge side): cA = code(500,10), cB = 0.
        _plantAt(_wrappedPid(bridgeLo, tokenA, 500, 10), 1e18);
        vm.prank(address(0xCA11));
        hub.claimV4(bridgeLo, tokenA, 500, 10);
        // The scanned pair: one legitimate pool at the learned tier, plus a
        // live pool parked exactly at the phantom (0,0) tier.
        _plantAt(_wrappedPid(tokenA, tokenC, 500, 10), 1e18);
        _plantAt(_wrappedPid(tokenA, tokenC, 0, 0), 1e18);

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenC);
        assertEq(hits.length, 1, "an empty learned code must not be probed as tier (0,0)");
        assertEq(hits[0].fee, uint24(500), "the single hit is the legitimate tier");
    }

    // =========================================================================
    //  Hub:1036 — _probeV4Batch: `kf >> 128 >= V4_CAP`
    //  Once the native pass fills the cap, the outer guard is what keeps the
    //  scan from consulting the manager again (the inner break re-guards
    //  admissions, so the CALL is the only observable). vm.expectCall with
    //  count 0 pins the call-pattern: the wrapped canonical batch must never
    //  reach the manager.
    // =========================================================================

    /// Neutralised (forced false), the wrapped canonical batch builds its pids
    /// and performs the batched extsload — the count-0 expectation trips.
    function test_L1036_CapReached_ManagerNotConsultedAgain() public {
        uint24[] memory fees4 = new uint24[](4);
        int24[]  memory sps4  = new int24[](4);
        fees4[0] = 400;    sps4[0] = 8;
        fees4[1] = 2500;   sps4[1] = 50;
        fees4[2] = 7000;   sps4[2] = 140;
        fees4[3] = 20000;  sps4[3] = 400;
        _addDeriveRow(fees4, sps4);
        // 4 canonical + 4 extra native pools: the native pass fills V4_CAP = 8.
        _plantAt(_nativePid(tokenB, 500, 10), 1e18);
        _plantAt(_nativePid(tokenB, 3000, 60), 1e18);
        _plantAt(_nativePid(tokenB, 10_000, 200), 1e18);
        _plantAt(_nativePid(tokenB, 100, 1), 1e18);
        for (uint256 i; i < 4; ++i) {
            _plantAt(_nativePid(tokenB, fees4[i], sps4[i]), 1e18);
        }

        // The wrapped-pair canonical batch calldata, byte-identical to what
        // BPC.v4Slot0Batch would send: selector 0xdbd035ff ++ bytes32[] of
        // slot0 base slots for the four canonical tiers of (tokenB, WETH).
        bytes32[] memory slots4 = new bytes32[](4);
        slots4[0] = keccak256(abi.encode(_wrappedPid(tokenB, WETH, 500, 10), uint256(6)));
        slots4[1] = keccak256(abi.encode(_wrappedPid(tokenB, WETH, 3000, 60), uint256(6)));
        slots4[2] = keccak256(abi.encode(_wrappedPid(tokenB, WETH, 10_000, 200), uint256(6)));
        slots4[3] = keccak256(abi.encode(_wrappedPid(tokenB, WETH, 100, 1), uint256(6)));
        vm.expectCall(address(mgr), abi.encodeWithSelector(bytes4(0xdbd035ff), slots4), uint64(0));

        PoolInfo[] memory hits = hub.discoverFor(WETH, tokenB);
        assertEq(hits.length, 8, "the native pass alone fills the cap");
        for (uint256 i; i < hits.length; ++i) {
            assertEq(hits[i].kind, BPC.KIND_V4_NATIVE, "every emitted hit is native");
        }
    }

    // =========================================================================
    //  Hub:1067 — _admitV4: `kf >> 128 >= V4_CAP` (direct learned-code call)
    //  Deciding state: cap already full when stage (a) runs, with hits.length
    //  ABOVE V4_CAP (an extra factory row inflates maxOut), so the sibling
    //  `k >= hits.length` cannot catch it.
    // =========================================================================

    /// Neutralised (forced false), the direct stage-(a) admit proceeds (k=8 <
    /// hits.length=9), finds the planted dust tier live and emits a 9th hit.
    function test_L1067_CapReached_LearnedCodeAdmitStops() public {
        hub.addBridge(bridgeLo);
        uint24[] memory fees4 = new uint24[](4);
        int24[]  memory sps4  = new int24[](4);
        fees4[0] = 400;    sps4[0] = 8;
        fees4[1] = 2500;   sps4[1] = 50;
        fees4[2] = 7000;   sps4[2] = 140;
        fees4[3] = 20000;  sps4[3] = 400;
        _addDeriveRow(fees4, sps4);
        // A second row only to make hits.length = V4_CAP + 1 (it finds nothing).
        hub.addFactory(address(new MockV2Factory()), BPC.KIND_V2, 0, bytes32(0), noFees, noSpacings);
        // Fill the cap with 8 native pools, as in the L1036 test.
        _plantAt(_nativePid(tokenB, 500, 10), 1e18);
        _plantAt(_nativePid(tokenB, 3000, 60), 1e18);
        _plantAt(_nativePid(tokenB, 10_000, 200), 1e18);
        _plantAt(_nativePid(tokenB, 100, 1), 1e18);
        for (uint256 i; i < 4; ++i) {
            _plantAt(_nativePid(tokenB, fees4[i], sps4[i]), 1e18);
        }
        // Learn a dust code for tokenB and park a live pool at that tier on
        // the scanned wrapped pair, reachable ONLY through stage (a).
        _plantAt(_wrappedPid(bridgeLo, tokenB, 777, 5), 1e18);
        vm.prank(address(0xCA11));
        hub.claimV4(bridgeLo, tokenB, 777, 5);
        _plantAt(_wrappedPid(tokenB, WETH, 777, 5), 1e18);

        PoolInfo[] memory hits = hub.discoverFor(WETH, tokenB);
        assertEq(hits.length, 8,
            "with the cap full, the learned-code direct admit must stop at the cap guard");
    }

    // =========================================================================
    //  Hub:1072 — _admitV4: `sp == 0`
    //  The batch path pre-filters sp!=0, so only the DIRECT learned-code call
    //  can carry sp==0 with liq!=0 into this guard.
    // =========================================================================

    /// Neutralised (forced false), the liq!=0 sibling passes, the static fee
    /// passes INV-20, and the price-less tier is emitted: length 0 fails.
    function test_L1072_LearnedTierWithLiquidityButNoPrice_NotEmitted() public {
        hub.addBridge(bridgeLo);
        _addDeriveRow(noFees, noSpacings);
        // Learn code (3000,60) for tokenA through a fully live claim pair.
        _plantAt(_wrappedPid(bridgeLo, tokenA, 3000, 60), 1e18);
        vm.prank(address(0xCA11));
        hub.claimV4(bridgeLo, tokenA, 3000, 60);
        // The scanned pair's tier has liquidity but slot0 == 0.
        _plantLiqOnlyAt(_wrappedPid(tokenA, tokenC, 3000, 60), 1e18);

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenC);
        assertEq(hits.length, 0, "a pool with liquidity but no price is not live and must not be emitted");
    }

    // =========================================================================
    //  Hub:1157 — _writeV4Code: `!$.isBridge[t1]`
    //  Every asserted flow had the bridge sorting as t0. Here it sorts as t1.
    // =========================================================================

    /// Neutralised (forced true), the claim writes a launch-tier code onto the
    /// BRIDGE itself; v4CodeOf(bridgeHi) == 0 fails.
    function test_L1157_BridgeSortingAsToken1_LearnsNoCode() public {
        hub.addBridge(bridgeHi);
        _plantAt(_wrappedPid(tokenA, bridgeHi, 500, 10), 1e18);
        vm.prank(address(0xCA11));
        hub.claimV4(tokenA, bridgeHi, 500, 10);
        assertEq(hub.v4CodeOf(bridgeHi), 0,
            "a bridge must never learn a pattern code (per-bridge codes thrash)");
        assertEq(hub.v4CodeOf(tokenA), _code(500, 10),
            "control: the non-bridge side does learn - the writer ran");
    }

    // =========================================================================
    //  Hub:1188 / Hub:1193 — _recoverV4Ts learned-code guards
    //  Recovery FAILURE is the only observable that separates them: recordSwap
    //  must SKIP first registration when the ladder finds nothing. Each mutant
    //  widens the ladder into succeeding, so the pool registers and the
    //  emptiness asserts fail.
    // =========================================================================

    /// L1188 `c != 0` neutralised: with v4CodeOf[t0] == 0 the widened guess is
    /// tier (0, 0) under fee 0, whose pid THIS pool address was chosen to
    /// match — recovery succeeds and the pool registers.
    function test_L1188_ZeroFeeSwap_NoRecoveryFromEmptyT0Code() public {
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 0, 0));
        _recordV4(pool, 0, tokenA, tokenB);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenB)), address(0),
            "an unrecoverable V4 first registration must be skipped");
        assertEq(hub.v4EntryCount(), 0, "and push no V4Entry");
    }

    /// L1193 `c != 0` neutralised: same construction through the t1 code read.
    function test_L1193_ZeroFeeSwap_NoRecoveryFromEmptyT1Code() public {
        address pool = _trunc(_wrappedPid(tokenC, tokenD, 0, 0));
        _recordV4(pool, 0, tokenC, tokenD);
        assertEq(hub.getPool(hub.keyOf(pool, tokenC, tokenD)), address(0),
            "an unrecoverable V4 first registration must be skipped");
        assertEq(hub.v4EntryCount(), 0, "and push no V4Entry");
    }

    /// L1188 `uint24(c >> 24) == fee` neutralised: tokenA's learned code holds
    /// ts 777 under fee 3000; the mutant tries that ts under the caller's fee
    /// 500, and this pool address IS the (500, 777) truncation — recovery
    /// succeeds where every honest ladder step fails (777 is not canonical,
    /// not generator, no matching row or entry).
    function test_L1188_FeeMismatchedT0Code_DoesNotDriveRecovery() public {
        hub.addBridge(bridgeLo);
        _plantAt(_wrappedPid(bridgeLo, tokenA, 3000, 777), 1e18);
        vm.prank(address(0xCA11));
        hub.claimV4(bridgeLo, tokenA, 3000, 777); // v4CodeOf[tokenA] = (3000, 777)
        uint256 entriesBefore = hub.v4EntryCount();

        address pool = _trunc(_wrappedPid(tokenA, tokenC, 500, 777));
        _recordV4(pool, 500, tokenA, tokenC);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenC)), address(0),
            "a code learned under another fee must not resolve this fee");
        assertEq(hub.v4EntryCount(), entriesBefore, "no V4Entry pushed");
    }

    /// L1193 `uint24(c >> 24) == fee` neutralised: symmetric, code on t1.
    function test_L1193_FeeMismatchedT1Code_DoesNotDriveRecovery() public {
        hub.addBridge(bridgeLo);
        _plantAt(_wrappedPid(bridgeLo, tokenC, 3000, 777), 1e18);
        vm.prank(address(0xCA11));
        hub.claimV4(bridgeLo, tokenC, 3000, 777); // v4CodeOf[tokenC] = (3000, 777)
        uint256 entriesBefore = hub.v4EntryCount();

        address pool = _trunc(_wrappedPid(tokenA, tokenC, 500, 777)); // t1 = tokenC
        _recordV4(pool, 500, tokenA, tokenC);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenC)), address(0),
            "a t1 code learned under another fee must not resolve this fee");
        assertEq(hub.v4EntryCount(), entriesBefore, "no V4Entry pushed");
    }

    // =========================================================================
    //  Hub:1198 — _recoverV4Ts generator-inverse guards
    //  Same failure-observable: each mutant widens the generator inverse into
    //  producing the ts this pool address was built from.
    // =========================================================================

    /// `fee != 0` neutralised: fee 0 enters the generator (0 % 10k == 0,
    /// 0 <= max), guesses ts 0, and the (0,0) truncation matches.
    function test_L1198_ZeroFee_DoesNotEnterGenerator() public {
        address pool = _trunc(_wrappedPid(tokenB, tokenD, 0, 0));
        _recordV4(pool, 0, tokenB, tokenD);
        assertEq(hub.getPool(hub.keyOf(pool, tokenB, tokenD)), address(0),
            "fee 0 must not be treated as a generator tier");
        assertEq(hub.v4EntryCount(), 0, "no V4Entry pushed");
    }

    /// `fee % 10_000 == 0` neutralised: fee 25_000 floor-divides to a ts-200
    /// guess, and this pool address is exactly the (25_000, 200) truncation.
    function test_L1198_NonMultipleFee_DoesNotEnterGenerator() public {
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 25_000, 200));
        _recordV4(pool, 25_000, tokenA, tokenB);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenB)), address(0),
            "an off-grid fee must not produce a generator guess");
        assertEq(hub.v4EntryCount(), 0, "no V4Entry pushed");
    }

    /// `fee / 10_000 <= V4_GRID_MAX` neutralised: fee 1_000_000 (j = 100 > 99)
    /// guesses ts 10_000, and this pool address is that truncation. recordSwap
    /// has no INV-20 gate, so only this bound keeps the tier out.
    function test_L1198_FeeAboveGridMax_DoesNotEnterGenerator() public {
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 1_000_000, 10_000));
        _recordV4(pool, 1_000_000, tokenA, tokenB);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenB)), address(0),
            "a fee beyond the grid ceiling must not produce a generator guess");
        assertEq(hub.v4EntryCount(), 0, "no V4Entry pushed");
    }

    // =========================================================================
    //  Hub:1234 — _recoverV4Ts entries-backstop conjuncts
    //  Each test plants ONE entry that is wrong in exactly the tested
    //  coordinate but whose ts (777) is CORRECT for the swapped pool, so the
    //  widened scan recovers and registers where the honest one refuses.
    // =========================================================================

    /// `e.currency0 == t0` neutralised: a (tokenLow, tokenB) entry — right
    /// currency1/fee/hooks, wrong currency0 — supplies ts 777.
    function test_L1234_WrongCurrency0Entry_DoesNotDriveRecovery() public {
        hub.addV4(tokenLow, tokenB, 500, 777, address(0));
        uint256 entriesBefore = hub.v4EntryCount();
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 500, 777));
        _recordV4(pool, 500, tokenA, tokenB);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenB)), address(0),
            "an entry of another pair must not resolve this pool");
        assertEq(hub.v4EntryCount(), entriesBefore, "no V4Entry pushed");
    }

    /// `e.currency1 == t1` neutralised: a (tokenA, tokenC) entry supplies ts.
    function test_L1234_WrongCurrency1Entry_DoesNotDriveRecovery() public {
        hub.addV4(tokenA, tokenC, 500, 777, address(0));
        uint256 entriesBefore = hub.v4EntryCount();
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 500, 777));
        _recordV4(pool, 500, tokenA, tokenB);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenB)), address(0),
            "an entry of another pair must not resolve this pool");
        assertEq(hub.v4EntryCount(), entriesBefore, "no V4Entry pushed");
    }

    /// `e.fee == fee` neutralised: a same-pair entry at fee 3000 supplies the
    /// ts for a fee-500 swap.
    function test_L1234_WrongFeeEntry_DoesNotDriveRecovery() public {
        hub.addV4(tokenA, tokenB, 3000, 777, address(0));
        uint256 entriesBefore = hub.v4EntryCount();
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 500, 777));
        _recordV4(pool, 500, tokenA, tokenB);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenB)), address(0),
            "an entry at another fee must not resolve this fee's pool");
        assertEq(hub.v4EntryCount(), entriesBefore, "no V4Entry pushed");
    }

    /// `e.hooks == address(0)` neutralised: a HOOKED same-pair entry supplies
    /// the ts; the guess is verified against the HOOKLESS pid, which this
    /// pool address matches — the hooked entry is the only barrier.
    function test_L1234_HookedEntry_DoesNotDriveRecovery() public {
        hub.allowHook(HOOK, true);
        hub.addV4(tokenA, tokenB, 500, 777, HOOK);
        uint256 entriesBefore = hub.v4EntryCount();
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 500, 777)); // hookless pid
        _recordV4(pool, 500, tokenA, tokenB);
        assertEq(hub.getPool(hub.keyOf(pool, tokenA, tokenB)), address(0),
            "a hooked entry must not lend its tickSpacing to a hookless recovery");
        assertEq(hub.v4EntryCount(), entriesBefore, "no V4Entry pushed");
    }

    // =========================================================================
    //  Hub:1261 — getActivePools hook auto-pause: the two kind leaves
    //  No test ever revoked a hook and then READ the registry.
    // =========================================================================

    /// `pi.kind != KIND_V4` neutralised (forced true): the dead-hook V4 pool
    /// passes the first disjunct and stays in the read channel — length 0
    /// fails. The pre-revocation control proves the pool was listed.
    function test_L1261_RevokedHook_V4PoolLeavesReadChannel() public {
        hub.allowHook(HOOK, true);
        hub.addV4(tokenA, tokenB, 500, 60, HOOK);
        assertEq(hub.getActivePools(tokenA, tokenB).length, 1, "control: live hook, pool listed");
        hub.allowHook(HOOK, false);
        assertEq(hub.getActivePools(tokenA, tokenB).length, 0,
            "a V4 pool whose hook died must leave the read channel");
    }

    /// `pi.kind != KIND_V4_NATIVE` neutralised: same auto-pause for a hooked
    /// NATIVE pool — a state no test ever built.
    function test_L1261_RevokedHook_NativePoolLeavesReadChannel() public {
        hub.allowHook(HOOK, true);
        hub.addV4(address(0), tokenB, 500, 60, HOOK);
        assertEq(hub.getActivePools(tokenB, WETH).length, 1, "control: live hook, native pool listed");
        hub.allowHook(HOOK, false);
        assertEq(hub.getActivePools(tokenB, WETH).length, 0,
            "a native pool whose hook died must leave the read channel");
    }

    // =========================================================================
    //  Hub:1285 — _readPoolInfo: `_nativeSwapped(s)`
    //  Every registered native pool has a V4Entry that overrides orientation.
    //  seedPool with KIND_V4_NATIVE builds the entry-less pool where the bit
    //  is the ONLY orientation producer.
    // =========================================================================

    /// Neutralised (forced true), _swap flips for this entry-less native pool
    /// and the reported orientation inverts.
    function test_L1285_EntrylessNativeSeed_ReportsSortedOrientation() public {
        hub.seedPool(address(0xFA11), BPC.KIND_V4_NATIVE, 500, address(0), tokenA, tokenB);
        PoolInfo[] memory ps = hub.getActivePools(tokenA, tokenB);
        assertEq(ps.length, 1, "seeded native pool is listed (hookless)");
        assertEq(ps[0].token0, tokenA, "bit 6 clear: token0 stays the sorted t0");
        assertEq(ps[0].token1, tokenB, "and token1 the sorted t1");
    }

    // =========================================================================
    //  Hub:1319 — _readPoolInfo wrapped-entry fallback conjuncts
    //  Reachable ONLY for a V4 pool with no v4EntryOf: seedPool(KIND_V4).
    //  Each test plants one entry wrong in exactly the tested coordinate with
    //  ts 777; this arm has NO pid re-check, so a widened match lands directly
    //  in the reported tickSpacing.
    // =========================================================================

    function _seedWrappedV4() private returns (address pool) {
        pool = address(0xFA11);
        hub.seedPool(pool, BPC.KIND_V4, 500, address(0), tokenA, tokenB);
    }

    function _seededInfo(address pool) private view returns (PoolInfo memory pi) {
        (bool found, PoolInfo memory p) = _find(hub.getActivePools(tokenA, tokenB), pool);
        assertTrue(found, "the seeded pool must be listed");
        pi = p;
    }

    /// `e.currency0 == t0` neutralised: the (tokenLow, tokenB) entry matches
    /// and its ts 777 replaces the honest 0.
    function test_L1319_WrappedFallback_RequiresCurrency0() public {
        hub.addV4(tokenLow, tokenB, 500, 777, address(0));
        address pool = _seedWrappedV4();
        assertEq(_seededInfo(pool).tickSpacing, int24(0),
            "no entry of THIS pair exists: tickSpacing must stay unresolved");
    }

    /// `e.currency1 == t1` neutralised: the (tokenA, tokenC) entry matches.
    function test_L1319_WrappedFallback_RequiresCurrency1() public {
        hub.addV4(tokenA, tokenC, 500, 777, address(0));
        address pool = _seedWrappedV4();
        assertEq(_seededInfo(pool).tickSpacing, int24(0),
            "no entry of THIS pair exists: tickSpacing must stay unresolved");
    }

    /// `e.fee == p.fee` neutralised: the same-pair fee-3000 entry matches a
    /// fee-500 pool.
    function test_L1319_WrappedFallback_RequiresFee() public {
        hub.addV4(tokenA, tokenB, 3000, 777, address(0));
        address pool = _seedWrappedV4();
        assertEq(_seededInfo(pool).tickSpacing, int24(0),
            "an entry at another fee must not resolve this pool's tickSpacing");
    }

    /// `e.hooks == p.hooks` neutralised: the hooked same-pair entry matches a
    /// hookless pool.
    function test_L1319_WrappedFallback_RequiresHooks() public {
        hub.allowHook(HOOK, true);
        hub.addV4(tokenA, tokenB, 500, 777, HOOK);
        address pool = _seedWrappedV4();
        assertEq(_seededInfo(pool).tickSpacing, int24(0),
            "a hooked entry must not resolve a hookless pool's tickSpacing");
    }

    // =========================================================================
    //  Hub:1323 — _readPoolInfo native-entry fallback conjuncts
    //  Same unreachable-until-now arm, native flavour: seedPool(KIND_V4_NATIVE)
    //  at an address chosen as the native-pid truncation, so the arm's pid
    //  re-check (L1334) passes whenever a widened entry match is tried.
    // =========================================================================

    function _seedNativeAt(address counterpart) private returns (address pool) {
        pool = _trunc(_nativePid(counterpart, 500, 777));
        hub.seedPool(pool, BPC.KIND_V4_NATIVE, 500, address(0), tokenA, tokenB);
    }

    /// `e.currency0 == address(0)` neutralised: a WRAPPED (tokenLow, tokenB)
    /// entry is tried, its (currency1=tokenB, ts=777) passes the pid check
    /// against this pool, and ts 777 replaces the honest 0.
    function test_L1323_NativeFallback_RequiresNativeCurrency0() public {
        hub.addV4(tokenLow, tokenB, 500, 777, address(0));
        address pool = _seedNativeAt(tokenB);
        (bool found, PoolInfo memory pi) = _find(hub.getActivePools(tokenA, tokenB), pool);
        assertTrue(found, "seeded native pool listed");
        assertEq(pi.tickSpacing, int24(0),
            "a wrapped entry must not resolve an entry-less NATIVE pool");
    }

    /// `e.fee == p.fee` neutralised: a native entry at fee 3000 is tried under
    /// the pool's fee 500 and passes the pid check (the check uses p.fee).
    function test_L1323_NativeFallback_RequiresFee() public {
        hub.addV4(address(0), tokenB, 3000, 777, address(0));
        address pool = _seedNativeAt(tokenB);
        (bool found, PoolInfo memory pi) = _find(hub.getActivePools(tokenA, tokenB), pool);
        assertTrue(found, "seeded native pool listed");
        assertEq(pi.tickSpacing, int24(0),
            "a native entry at another fee must not resolve this pool");
    }

    /// `e.hooks == p.hooks` neutralised: a HOOKED native entry is tried; the
    /// pid check runs with p.hooks (0) and passes.
    function test_L1323_NativeFallback_RequiresHooks() public {
        hub.allowHook(HOOK, true);
        hub.addV4(address(0), tokenB, 500, 777, HOOK);
        address pool = _seedNativeAt(tokenB);
        (bool found, PoolInfo memory pi) = _find(hub.getActivePools(tokenA, tokenB), pool);
        assertTrue(found, "seeded native pool listed");
        assertEq(pi.tickSpacing, int24(0),
            "a hooked native entry must not resolve a hookless pool");
    }

    /// `e.currency1 == t0` neutralised (forced false): the honest match via
    /// the t0 arm — counterpart == sorted t0 — stops matching and the
    /// recovered ts 777 collapses to 0. This is the positive kill.
    function test_L1323_NativeFallback_MatchesCounterpartAsToken0() public {
        hub.addV4(address(0), tokenA, 500, 777, address(0));
        address pool = _seedNativeAt(tokenA);
        (bool found, PoolInfo memory pi) = _find(hub.getActivePools(tokenA, tokenB), pool);
        assertTrue(found, "seeded native pool listed");
        assertEq(pi.tickSpacing, int24(777),
            "the t0-side counterpart entry must resolve the tickSpacing");
        assertEq(pi.token1, tokenA, "orientation: counterpart reported as token1");
    }

    /// `e.currency1 == t1` neutralised (forced false): symmetric positive kill
    /// through the t1 arm.
    function test_L1323_NativeFallback_MatchesCounterpartAsToken1() public {
        hub.addV4(address(0), tokenB, 500, 777, address(0));
        address pool = _seedNativeAt(tokenB);
        (bool found, PoolInfo memory pi) = _find(hub.getActivePools(tokenA, tokenB), pool);
        assertTrue(found, "seeded native pool listed");
        assertEq(pi.tickSpacing, int24(777),
            "the t1-side counterpart entry must resolve the tickSpacing");
    }

    // =========================================================================
    //  Hub:1367 — psisOf: `tBs.length != n`
    //  The one existing mismatch test shortens tAs; a tBs-ONLY mismatch keeps
    //  the sibling false, so only this leg produces the revert.
    // =========================================================================

    /// Neutralised (forced false), the guard passes; with tBs LONGER than n
    /// the loop reads in bounds and psisOf RETURNS — the exact HubE(4) below
    /// never fires (no panic to hide behind).
    function test_L1367_LongTokenBArray_RefusedWithFour() public {
        address[] memory pools = new address[](1);
        address[] memory tAs = new address[](1);
        address[] memory tBs = new address[](2);
        pools[0] = address(0xA001);
        tAs[0] = tokenA;
        tBs[0] = tokenA; tBs[1] = tokenB;
        vm.expectRevert(_err(4));
        hub.psisOf(pools, tAs, tBs);
    }

    // =========================================================================
    //  Hub:1437 — recordSwap: `pool == address(0)` and `amtIn == 0`
    // =========================================================================

    /// `pool == 0` neutralised: with the route pair (0, 0), the pair proof
    /// passes vacuously (token0Of(0) fail-reads 0 == t0, same for t1), the V2
    /// shape refuter passes (sp 0 == not concentrated), and address(0)
    /// REGISTERS under the (0,0) pair — slot and active list both move. Every
    /// other kind's authenticity net catches pool 0; this pair is the one
    /// state where only the guard stands.
    function test_L1437_ZeroPool_NeverReachesRegistration() public {
        hub.recordSwap(address(0), BPC.KIND_V2, 30, address(0), address(0), address(0), 1e18, 1e18, 1e18);
        assertEq(hub.getSlot(hub.keyOf(address(0), address(0), address(0))), 0,
            "the zero pool must be dropped before any slot write");
        assertEq(hub.getActivePools(address(0), address(0)).length, 0,
            "and the (0,0) pair must stay empty");
    }

    /// `amtIn == 0` neutralised: a zero-amount call at a REGISTERED real pool
    /// ticks vitality — swapCount moves from 1 to 2 and the equality fails.
    function test_L1437_ZeroAmountIn_DoesNotTickVitality() public {
        address pool = address(new MockV2Pair(tokenA, tokenB));
        hub.recordSwap(pool, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        bytes32 key = hub.keyOf(pool, tokenA, tokenB);
        assertEq(BPC.decodeSwapCount(hub.getSlot(key)), 1, "state pin: registered with one tick");

        hub.recordSwap(pool, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 0, 1e18, 1e18);
        assertEq(BPC.decodeSwapCount(hub.getSlot(key)), 1,
            "a zero-amount swap must not tick vitality at a registered pool");
    }

    // =========================================================================
    //  Hub:1469 — recordSwap tick-path learning gate
    //  The pid-verification net only protects REAL pool addresses. Seed the
    //  registry at the pid-truncation address itself: the ladder then matches,
    //  and the calldata-kind/hooks conjuncts are the only barrier.
    // =========================================================================

    /// `kind == KIND_V4` neutralised (forced true): the V2 tick at this
    /// truncation address runs _noteV4Code, canonical step recovers (500,10),
    /// and both tokens learn codes — the zero reads fail.
    function test_L1469_NonV4Tick_DoesNotLearnPatternCode() public {
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 500, 10));
        hub.seedPool(pool, BPC.KIND_V2, 30, address(0), tokenA, tokenB);
        hub.recordSwap(pool, BPC.KIND_V2, 500, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        assertEq(hub.v4CodeOf(tokenA), 0, "a non-V4 leg must not learn a V4 pattern code");
        assertEq(hub.v4CodeOf(tokenB), 0, "on either side");
    }

    /// `hooks == address(0)` neutralised (forced true): the HOOKED V4 tick at
    /// the hookless truncation address runs the learner and writes codes.
    function test_L1469_HookedV4Tick_DoesNotLearnPatternCode() public {
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 500, 10));
        hub.seedPool(pool, BPC.KIND_V4, 500, address(0), tokenA, tokenB);
        hub.recordSwap(pool, BPC.KIND_V4, 500, address(0xD00D), tokenA, tokenB, 1e18, 1e18, 1e18);
        assertEq(hub.v4CodeOf(tokenA), 0, "a hooked leg must not refresh the hookless pattern code");
        assertEq(hub.v4CodeOf(tokenB), 0, "on either side");
    }

    // =========================================================================
    //  Hub:1494 — the pair proof's two token arms
    //  Every dishonest pool in the suite was codeless: BOTH reads failed
    //  together. A pool lying about exactly ONE token isolates each arm.
    // =========================================================================

    /// `token0Of(pool) != t0` neutralised (forced false): this pool answers
    /// the RIGHT token1 and a WRONG token0, so the token1 arm is false and
    /// the whole proof collapses — the liar registers and the slot moves.
    function test_L1494_PoolLyingAboutToken0_IsRefused() public {
        address liar = address(new MockV2Pair(tokenLow, tokenB)); // token0 = tokenLow != tokenA
        hub.recordSwap(liar, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        assertEq(hub.getSlot(hub.keyOf(liar, tokenA, tokenB)), 0,
            "a pool lying about token0 alone must be refused");
        assertEq(hub.getActivePools(tokenA, tokenB).length, 0, "nothing registered");
    }

    /// `token1Of(pool) != t1` neutralised (forced false): right token0, wrong
    /// token1 — symmetric single-arm liar.
    function test_L1494_PoolLyingAboutToken1_IsRefused() public {
        address liar = address(new MockV2Pair(tokenA, tokenC)); // token1 = tokenC != tokenB
        hub.recordSwap(liar, BPC.KIND_V2, 30, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        assertEq(hub.getSlot(hub.keyOf(liar, tokenA, tokenB)), 0,
            "a pool lying about token1 alone must be refused");
        assertEq(hub.getActivePools(tokenA, tokenB).length, 0, "nothing registered");
    }

    // =========================================================================
    //  Hub:1608 — the shape-refuter exemption for the V4 family
    //  The pid-authenticated calldata fee must SURVIVE registration. The fork
    //  test registers a V4 pool this way but never asserts the fee.
    // =========================================================================

    /// `kind != KIND_V4` neutralised (forced true): the V4 registration runs
    /// the refuter, getV3Fee(codeless truncation) reads 0, and the registered
    /// fee collapses from 500 to 0 — the fee assert fails.
    function test_L1608_V4Registration_KeepsAuthenticatedFee() public {
        address pool = _trunc(_wrappedPid(tokenA, tokenB, 500, 10));
        _recordV4(pool, 500, tokenA, tokenB);
        PoolInfo[] memory ps = hub.getActivePools(tokenA, tokenB);
        assertEq(ps.length, 1, "the recoverable V4 pool registers");
        assertEq(ps[0].kind, BPC.KIND_V4, "as V4");
        assertEq(ps[0].fee, uint24(500), "the pid-authenticated calldata fee must be persisted");
        assertEq(ps[0].tickSpacing, int24(10), "with the recovered tickSpacing");
    }

    /// `kind != KIND_V4_NATIVE` neutralised: the first-ever native recordSwap
    /// registration in the tree — same fee-poisoning kill through the native
    /// branch (the whole Hub:1516 arm was unexercised).
    function test_L1608_NativeRegistration_KeepsAuthenticatedFee() public {
        address pool = _trunc(_nativePid(tokenB, 500, 10));
        hub.recordSwap(pool, BPC.KIND_V4_NATIVE, 500, address(0), WETH, tokenB, 1e18, 1e18, 1e18);
        PoolInfo[] memory ps = hub.getActivePools(WETH, tokenB);
        assertEq(ps.length, 1, "the native pool registers through recordSwap");
        assertEq(ps[0].kind, BPC.KIND_V4_NATIVE, "as native");
        assertEq(ps[0].fee, uint24(500), "the pid-authenticated calldata fee must be persisted");
        assertEq(ps[0].token0, WETH, "orientation contract holds");
    }

    // =========================================================================
    //  Hub:1610 — `declaredConc = kind == KIND_V3 || kind == KIND_ALGEBRA`
    //  No test ever REGISTERED an Algebra pool through this door (the Algebra
    //  suite seeds its pools).
    // =========================================================================

    /// `kind == KIND_ALGEBRA` neutralised (forced false): the honest Algebra
    /// registration reads declaredConc=false against isConc=true and is
    /// refused as a shape contradiction — the length-1 assert fails.
    function test_L1610_HonestAlgebraRegistration_IsAdmitted() public {
        MockAlgebraPool pool = new MockAlgebraPool(tokenA, tokenB, 3000);
        pool.setState(uint160(BPC.Q96), 1e24);
        // Calldata fee 777 on purpose: the registered fee must be the measured
        // dynamic sentinel 0, never the caller's number.
        hub.recordSwap(address(pool), BPC.KIND_ALGEBRA, 777, address(0), tokenA, tokenB, 1e18, 1e18, 1e18);
        PoolInfo[] memory ps = hub.getActivePools(tokenA, tokenB);
        assertEq(ps.length, 1, "an honest Algebra pool must register through recordSwap");
        assertEq(ps[0].kind, BPC.KIND_ALGEBRA, "shape-derived kind");
        assertEq(ps[0].fee, uint24(0), "dynamic-fee sentinel, not calldata");
    }

    // =========================================================================
    //  Hub:1746 — _register: `_isRoutableBridge($, t0)`
    //  Every raw bit-7 assert in the tree has the bridge sorting as t1.
    // =========================================================================

    /// Neutralised (forced false), a pool whose bridge sorts as t0 loses the
    /// +25%-fitness bridged bit; the bit-7 read fails. The non-bridge control
    /// guards against a stuck-high bit.
    function test_L1746_BridgeSortingAsToken0_GetsBridgedBit() public {
        hub.addBridge(bridgeLo); // bridgeLo < tokenB: sorts as t0
        bytes32 k = hub.seedPool(address(0xA001), BPC.KIND_V2, 30, address(0), bridgeLo, tokenB);
        assertEq(_bit(hub.getSlot(k), 7), 1,
            "a pair whose bridge sorts as token0 must carry the bridged bit");
        bytes32 kNone = hub.seedPool(address(0xA002), BPC.KIND_V2, 30, address(0), tokenA, tokenB);
        assertEq(_bit(hub.getSlot(kNone), 7), 0, "control: no bridge, no bit");
    }
}
