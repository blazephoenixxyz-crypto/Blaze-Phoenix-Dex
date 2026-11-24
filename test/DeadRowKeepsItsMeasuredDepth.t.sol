// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A ROW THAT WENT QUIET KEEPS THE DEPTH IT STILL HOLDS.
//
//  Red on 833c3b1. A row nobody traded for about nine days scores psi 0, and on a
//  full pair `_canInsert` admitted any newcomer of depth >= 1 against a worst psi of
//  0: one dust claim, or one dust leg, took the seat of a 3M row that was merely
//  quiet. Psi 0 says the row is not being used; it says nothing about what it holds.
//
//  The admission now measures the row that would leave - the one eviction removes,
//  chosen by the same producer - with the registry's depth producer, and seats the
//  newcomer only on a strictly deeper bucket. A read that fails, answers short or
//  runs past its gas cap is not a measurement: the row measures 0 and leaves, and
//  no door gains a revert.
//
//  forge test --match-path test/DeadRowKeepsItsMeasuredDepth.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockOriginFactory, Origin} from "./mocks/MockOriginFactory.sol";

interface IMint { function mint(address to, uint256 amt) external; }

/// The single-slot `extsload` the V4 state reader performs, and nothing else.
contract QuietV4Manager {
    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
}

/// A token whose `balanceOf` can refuse, answer short, never come back, or come back late.
contract MoodyToken {
    mapping(address => uint256) internal bal;
    uint8 public immutable decimals;
    uint8 public mood; // 0 honest, 1 reverts, 2 answers 31 bytes, 3 spends all the gas it is given
    uint256 public burn; // gas an honest answer spends first
    constructor(uint8 d) { decimals = d; }
    function mint(address to, uint256 amt) external { bal[to] += amt; }
    function setMood(uint8 m) external { mood = m; }
    function setBurn(uint256 g) external { burn = g; }
    function balanceOf(address who) external view returns (uint256) {
        uint8 m = mood;
        if (m == 1) revert("moody");
        while (m == 3 && gasleft() > 0) {}
        uint256 g0 = gasleft();
        while (g0 - gasleft() < burn) {}
        uint256 b = bal[who];
        if (m == 2) assembly { mstore(0x00, b) return(0x00, 31) }
        return b;
    }
}

contract DeadRowKeepsItsMeasuredDepthTest is Test {
    BlazePhoenixHub   hub;
    QuietV4Manager    mgr;
    MockOriginFactory origin;
    MoodyToken        moody;
    address t0;
    address t1;
    address wethTok;
    address lastWarm;
    uint24  tier;

    address constant STRANGER = address(0xCA11);
    int24   constant TS   = 60;
    uint256 constant DEEP = 3_000_000e18;   // bucket 9
    uint256 constant WARM = 1e18;           // bucket 3

    /// `addV4` asks the router for the wrapped coin; the router here is this contract.
    function weth() external view returns (address) { return wethTok; }

    function setUp() public {
        mgr = new QuietV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.setRoles(address(this), address(this), address(this));
        MockERC20 anchor = new MockERC20("A", "A");
        moody = new MoodyToken(18);
        _usePair(address(anchor), address(moody), address(anchor));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _usePair(address a, address b, address bridge) internal {
        (t0, t1) = a < b ? (a, b) : (b, a);
        hub.addBridge(bridge);
        origin = Origin.tiers(hub, BPC.KIND_V2, 4);
        tier = 0;
    }

    /// The test's own bucket oracle: 0 under 1e15, then one bucket per decade, capped at 15.
    function _bucketRef(uint256 d) internal pure returns (uint256 b) {
        d /= 1e15;
        while (d >= 10 && b < 15) { d /= 10; ++b; }
    }

    function _row(uint256 depth) internal returns (MockV2Pair p) {
        p = new MockV2Pair(t0, t1);
        IMint(t0).mint(address(p), depth);
        IMint(t1).mint(address(p), depth);
        p.setReserves(uint112(depth), uint112(depth));
    }

    /// Operator's door: seats unconditionally, at the depth the producer measures.
    function _seed(uint256 depth) internal returns (address p) {
        p = address(_row(depth));
        hub.seedPool(p, BPC.KIND_V2, 30, address(0), t0, t1);
    }

    function _warmFifteen() internal {
        for (uint256 i; i < 15; ++i) lastWarm = _seed(WARM);
    }

    function _age(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 2);
    }

    function _seated(address p) internal view returns (bool) {
        return hub.getPool(hub.keyOf(p, t0, t1)) == p;
    }

    function _fullWithOneDeadRow(address dead) internal view {
        assertEq(hub.getActivePools(t0, t1).length, 16, "non-vacuity: the pair is full");
        assertEq(hub.getPsi(dead, t0, t1), 0, "non-vacuity: the quiet row is at psi 0");
        assertGt(hub.getPsi(lastWarm, t0, t1), 0, "non-vacuity: the other fifteen are warm");
    }

    /// One row of `depth` that went quiet, then fifteen shallow rows that are still warm:
    /// the quiet row is the pair's worst and the only one an eviction can remove.
    function _quietRowAmongWarm(uint256 depth) internal returns (address quiet) {
        quiet = _seed(depth);
        _age(60 days);
        _warmFifteen();
        _fullWithOneDeadRow(quiet);
    }

    function _v4Base(address c0, address c1, uint24 fee, address hook) internal pure returns (bytes32 pid, bytes32 base) {
        pid = BPC.computeV4PoolId(c0, c1, fee, TS, hook);
        base = keccak256(abi.encode(pid, uint256(6)));
    }

    /// A live hookless V4 pool in the manager, at the layout `BPC.v4SqrtAndLiq` reads.
    function _plant(address c0, address c1, uint24 fee, uint160 sp, uint128 liq) internal returns (address poolAddr) {
        return _plantHooked(c0, c1, fee, address(0), sp, liq);
    }

    function _plantHooked(
        address c0, address c1, uint24 fee, address hook, uint160 sp, uint128 liq
    ) internal returns (address poolAddr) {
        (bytes32 pid, bytes32 base) = _v4Base(c0, c1, fee, hook);
        mgr.setSlot(base, bytes32(uint256(sp)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
        poolAddr = address(uint160(uint256(pid)));
    }

    /// The permissionless door, from a stranger.
    function _claim(uint24 fee) internal returns (bytes32 key) {
        vm.prank(STRANGER);
        key = hub.claimV4(t0, t1, fee, TS);
    }

    /// The swap door: a factory-derived pair the Router reports after a leg, at `depth`.
    function _leg(uint256 depth) internal returns (address p) {
        p = address(_row(depth));
        origin.list(p, t0, t1, ++tier, false);
        hub.recordSwap(p, BPC.KIND_V2, 30, address(0), t0, t1, depth, depth, depth);
    }

    // ── the defect, on both doors ────────────────────────────────────────────

    function test_DustClaim_CannotEvictADeepRowThatWentQuiet() public {
        address deep = _quietRowAmongWarm(DEEP);
        _plant(t0, t1, 500, uint160(BPC.Q96), 1e14);                 // bucket 0
        uint256 g = gasleft();
        bytes32 key = _claim(500);
        emit log_named_uint("claimV4 gas, full pair, worst row dead (V2 read)", g - gasleft());
        assertTrue(_seated(deep), "a dust claim evicted a deep row that had only gone quiet");
        assertEq(hub.getPool(key), address(0), "the dust claim took a seat");
    }

    function test_SwapDoor_DustLeg_CannotEvictADeepQuietRow() public {
        address deep = _quietRowAmongWarm(DEEP);
        address p = address(_row(1e14));
        origin.list(p, t0, t1, ++tier, false);
        uint256 g = gasleft();
        hub.recordSwap(p, BPC.KIND_V2, 30, address(0), t0, t1, 1e14, 1e14, 1e14);
        emit log_named_uint("recordSwap gas, full pair, worst row dead (V2 read)", g - gasleft());
        assertTrue(_seated(deep), "a dust leg evicted a deep row that had only gone quiet");
        assertFalse(_seated(p), "the dust leg took a seat");
    }

    // ── what the row holds NOW decides, not what it was sealed with ──────────

    /// INV-16 control: the squatter that emptied itself measures shallow and leaves, to a
    /// newcomer under the bucket the row was sealed with (9) and above the one it holds (0).
    function test_AnEmptiedDeadRow_StillLeaves() public {
        address deep = _quietRowAmongWarm(DEEP);
        MockV2Pair(deep).setReserves(1e12, 1e12);
        address mid = _leg(1e21);                                    // bucket 6
        assertTrue(_seated(mid), "an emptied dead row kept its seat on the bucket it was sealed with");
        assertFalse(_seated(deep), "the emptied row is the one that leaves");
    }

    function test_ASameBucketNewcomer_DoesNotEvictADeadRow() public {
        address quiet = _quietRowAmongWarm(1e21);                    // bucket 6
        address same = _leg(1e22 - 1);                               // bucket 6, one wei under 7
        assertTrue(_seated(quiet), "an equal bucket evicted the dead row");
        assertFalse(_seated(same), "an equal bucket took the seat");
    }

    function test_ADeeperNewcomer_EvictsADeadRow() public {
        address quiet = _quietRowAmongWarm(1e21);                    // bucket 6
        address deeper = _leg(1e22);                                 // bucket 7, on the edge
        assertTrue(_seated(deeper), "a strictly deeper newcomer was refused");
        assertFalse(_seated(quiet), "the dead row is the one that leaves");
    }

    function test_OneWeiUnderTheEdge_TheDeadRowMeasuresABucketLower() public {
        address quiet = _quietRowAmongWarm(1e21 - 1);                // bucket 5
        address deeper = _leg(1e21);                                 // bucket 6
        assertTrue(_seated(deeper), "the live read is not the row's depth to the wei");
        assertFalse(_seated(quiet), "the dead row is the one that leaves");
    }

    // ── a failed read is not a depth ─────────────────────────────────────────

    function test_AFailedDepthRead_IsNotADepth() public {
        address deep = _quietRowAmongWarm(DEEP);
        address pool = _plant(t0, t1, 500, uint160(BPC.Q96), 1e18);  // bucket 3
        uint256 snap = vm.snapshotState();
        bytes32 key = _claim(500);
        assertEq(hub.getPool(key), address(0), "control: read honestly, the deep row outranks bucket 3");
        for (uint8 m = 1; m <= 3; ++m) {
            vm.revertToState(snap);
            moody.setMood(m);
            key = _claim(500);                                       // must not revert either
            assertEq(hub.getPool(key), pool, "a read that failed was taken for a depth");
            assertFalse(_seated(deep), "the row nobody could measure is the one that leaves");
        }
    }

    /// The producer answers, but under one word: the guard on the read's own answer, apart
    /// from the reads inside the producer. Mocked at the library, for this row's read only.
    function test_AShortAnswer_IsNotADepth() public {
        address deep = _quietRowAmongWarm(DEEP);
        uint256 snap = vm.snapshotState();
        address inc = _leg(1e18);                                    // bucket 3
        assertFalse(_seated(inc), "control: answered in full, the deep row outranks bucket 3");
        vm.revertToState(snap);
        vm.mockCall(
            address(BPC),
            abi.encodeWithSelector(
                BPC.registryDepth18.selector, deep, BPC.KIND_V2, t0, t1, address(mgr), bytes32(0)
            ),
            hex""
        );
        inc = _leg(1e18);
        assertTrue(_seated(inc), "an answer under one word was taken for a depth");
        assertFalse(_seated(deep), "the row whose read answered short is the one that leaves");
    }

    /// The read's ceiling is 5 x GAS_CAP for the whole producer: a quiet row whose read spends
    /// 150k (over one GAS_CAP, under five) is measured and stays; one whose read would spend
    /// 600k (over five) measures 0 and leaves.
    function test_TheReadCeiling_IsFiveGasCapsForTheWholeProducer() public {
        address deep = _quietRowAmongWarm(DEEP);
        address pool = _plant(t0, t1, 500, uint160(BPC.Q96), 1e18);  // bucket 3
        uint256 snap = vm.snapshotState();
        moody.setBurn(150_000);
        bytes32 key = _claim(500);
        assertEq(hub.getPool(key), address(0), "a read over one GAS_CAP and under five was cut short");
        assertTrue(_seated(deep), "the deep row measured within the ceiling left");
        vm.revertToState(snap);
        moody.setBurn(600_000);
        key = _claim(500);
        assertEq(hub.getPool(key), pool, "a read past five GAS_CAPs was let run");
        assertFalse(_seated(deep), "the row whose read ran past the ceiling is the one that leaves");
    }

    /// The caller picks the gas. A frame too short to pay for the read cannot seat anything
    /// either: whatever the read left behind does not pay for one registry write.
    function test_AFrameTooShortForTheRead_SeatsNothing() public {
        address deep = _quietRowAmongWarm(DEEP);
        _plant(t0, t1, 500, uint160(BPC.Q96), 1e18);                 // bucket 3: seats on a read of 0
        bytes memory cd = abi.encodeCall(hub.claimV4, (t0, t1, 500, TS));
        bool ok;
        for (uint256 g = 20_000; g <= 400_000; g += 500) {
            vm.prank(STRANGER);
            (ok, ) = address(hub).call{gas: g}(cd);
            assertTrue(_seated(deep), "a short frame turned a starved read into an eviction");
        }
        assertTrue(ok, "non-vacuity: the sweep ends on a frame that ran to the end");
    }

    // ── the row admission measures is the row eviction removes ──────────────

    /// Sixteen dead rows, the deepest first: a newcomer between the shallowest and the rest is
    /// measured against the shallowest, the row the eviction takes, not against the first:
    /// `_worstRow` names it once for both.
    function test_TheRowAdmissionMeasures_IsTheRowEvictionRemoves() public {
        address deep = _seed(DEEP);                                  // index 0, bucket 9
        for (uint256 i; i < 14; ++i) _seed(1e21);                    // bucket 6
        address shallow = _seed(1e19);                               // index 15, bucket 4
        _age(60 days);
        assertEq(hub.getPsi(deep, t0, t1), 0, "non-vacuity: every row is at psi 0");
        assertEq(hub.getPsi(shallow, t0, t1), 0, "non-vacuity: every row is at psi 0");
        address inc = _leg(1e20);                                    // bucket 5
        assertTrue(_seated(inc), "admission measured a row other than the one eviction removes");
        assertFalse(_seated(shallow), "the shallowest dead row is the one that leaves");
        assertTrue(_seated(deep), "the deepest row left");
    }

    // ── a V4 row is measured under its own pool id, in its own currency order ─

    function test_ADeadSingletonRow_IsMeasuredUnderItsOwnPoolId() public {
        address v4 = _plant(t0, t1, 3000, uint160(BPC.Q96), 1e24);   // bucket 9
        _claim(3000);
        assertTrue(_seated(v4), "non-vacuity: the claim seated the V4 row");
        _age(60 days);
        _warmFifteen();
        _fullWithOneDeadRow(v4);
        address inc = _leg(1e20);                                    // bucket 5
        assertTrue(_seated(v4), "a deep dead V4 row was not measured under its pool id");
        assertFalse(_seated(inc), "bucket 5 took the seat of a bucket 9 row");
        _plant(t0, t1, 3000, uint160(BPC.Q96), 1e15);                // drained: bucket 0
        inc = _leg(1e20);
        assertTrue(_seated(inc), "a drained dead V4 row kept its seat");
        assertFalse(_seated(v4), "the drained row is the one that leaves");
    }

    /// A native pool's currency0 is the coin, which WETH stands for, and the registry key is
    /// WETH-sorted: with a 6-decimal token sorting below WETH the two orders differ. Read in
    /// the key's order this row measures 2e12 (bucket 0) instead of 2e24 (bucket 9).
    function test_ADeadNativeRow_IsMeasuredInItsOwnCurrencyOrder() public {
        MockERC20 w = new MockERC20("W", "W");
        MoodyToken six = new MoodyToken(6);
        while (address(six) > address(w)) six = new MoodyToken(6);
        wethTok = address(w);
        _usePair(address(six), address(w), address(w));
        // sqrtPrice 1e-6: L = 2e18 holds 2e24 wei of the coin and 2e12 units (2e24 at 18 decimals) of `six`.
        address pool = _plant(address(0), address(six), 3000, uint160(BPC.Q96 / 1e6), 2e18);
        bytes32 key = hub.addV4(address(0), address(six), 3000, TS, address(0));
        assertEq(hub.getPool(key), pool, "non-vacuity: the native row is seated");
        assertEq(BPC.decodeBucket(hub.getSlot(key)), 9, "non-vacuity: sealed at bucket 9");
        _age(60 days);
        _warmFifteen();
        _fullWithOneDeadRow(pool);
        address inc = _leg(1e20);                                    // bucket 5
        assertEq(hub.getPool(key), pool, "a deep dead native row was measured with its decimals swapped");
        assertFalse(_seated(inc), "bucket 5 took the seat of a bucket 9 native row");
    }

    /// A concentrated row is read as one: liquidity at its price, capped by what it holds.
    function test_ADeadConcentratedRow_IsMeasuredAsConcentrated() public {
        MockV3Pool v3 = new MockV3Pool(t0, t1, 3000);
        v3.setState(uint160(BPC.Q96), 1e24);                         // bucket 9
        IMint(t0).mint(address(v3), 1e24);
        IMint(t1).mint(address(v3), 1e24);
        hub.seedPool(address(v3), BPC.KIND_V3, 3000, address(0), t0, t1);
        address p = address(v3);
        assertEq(BPC.decodeBucket(hub.getSlot(hub.keyOf(p, t0, t1))), 9, "non-vacuity: sealed at bucket 9");
        _age(60 days);
        _warmFifteen();
        _fullWithOneDeadRow(p);
        address inc = _leg(1e20);                                    // bucket 5
        assertTrue(_seated(p), "a deep dead V3 row was not measured as concentrated");
        assertFalse(_seated(inc), "bucket 5 took the seat of a bucket 9 V3 row");
        v3.setState(uint160(BPC.Q96), 1e12);                         // drained: bucket 0
        inc = _leg(1e20);
        assertTrue(_seated(inc), "a drained dead V3 row kept its seat");
        assertFalse(_seated(p), "the drained row is the one that leaves");
    }

    /// A hooked V4 row's pool id carries its hook: measured under the hookless id it reads an
    /// empty slot and measures 0.
    function test_ADeadHookedRow_IsMeasuredUnderItsHookedPoolId() public {
        address hook = address(0x40CC);
        address v4 = _plantHooked(t0, t1, 3000, hook, uint160(BPC.Q96), 1e24); // bucket 9
        bytes32 key = hub.addV4(t0, t1, 3000, TS, hook);
        assertEq(hub.getPool(key), v4, "non-vacuity: addV4 seated the hooked row");
        assertEq(BPC.decodeBucket(hub.getSlot(key)), 9, "non-vacuity: sealed at bucket 9");
        _age(60 days);
        _warmFifteen();
        _fullWithOneDeadRow(v4);
        address inc = _leg(1e20);                                    // bucket 5
        assertTrue(_seated(v4), "a deep dead hooked row was not measured under its own pool id");
        assertFalse(_seated(inc), "bucket 5 took the seat of a bucket 9 hooked row");
    }

    // ── every depth, every quiet spell ───────────────────────────────────────

    function testFuzz_DeadRowEviction_NewcomerBucketMustExceedTheLiveBucket(
        uint256 deadDepth, uint256 newDepth, uint32 quiet
    ) public {
        deadDepth = bound(deadDepth, 1, 1e31);
        newDepth  = bound(newDepth, 1, 1e31);
        address dead = _seed(deadDepth);
        _age(bound(quiet, 12 days, 30 days));
        _warmFifteen();
        _fullWithOneDeadRow(dead);
        address inc = _leg(newDepth);
        bool wins = _bucketRef(newDepth) > _bucketRef(deadDepth);
        assertEq(_seated(inc), wins, "the newcomer seats exactly when its bucket exceeds the live one");
        assertEq(_seated(dead), !wins, "exactly one of the two holds the seat");
    }
}
