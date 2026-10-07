// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  EVERY REGISTRY DOOR WRITES THE DEPTH ITS OWN PRODUCER MEASURES.
//
//  The Hub has four doors that create a row: the swap door (`recordSwap`), the
//  permissionless V4 claim (`claimV4`), and the operator's two (`seedPool`,
//  `addV4`). Commit 2912b40 wired `Core.registryDepth18` into three of them and
//  said "so no door can fall behind a fix again"; the fourth, `addV4`, kept
//  writing bucket 0. Since `encodeSlot` never touches the bucket bits, every
//  `addV4` row was born at weight 1 and psi 1, the funnel cut a deep pool below
//  warm dust before anything was quoted, `claimV4` could not heal it (it returns
//  early on a row that exists), and for the native family - which `seedPool`
//  refuses - there was no door that measured at all.
//
//  Reported by Seavia Resources through the bug bounty programme, with the
//  proof of concept the first two sections are built from. The fix goes one step
//  past the report: `_register` takes the measured depth as an argument and
//  writes the bucket itself, so a door that forgets the depth does not compile.
//  Section 3 walks the whole family rather than the door that was missed.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev The single-slot extsload state `BPC.v4SqrtAndLiq` reads, as in
///      test/HardeningA4_ClaimV4Margin.t.sol.
contract RegistryDoorsV4State {
    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
}

/// @dev A six-decimal token, so a native pool's two sides are not symmetric.
contract RegistryDoorsDec6 {
    string public name = "D6"; string public symbol = "D6";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
}

contract RegistryDoorsMeasureWhatTheyWriteTest is Test {
    BlazePhoenixHub        hub;
    BlazePhoenixSolver     solver;
    RegistryDoorsV4State   mgr;
    MockERC20 A;
    MockERC20 B;
    MockERC20 W;

    uint24  constant FEE      = 3000;
    int24   constant TS       = 60;
    uint128 constant DEEP_LIQ = 1e24;   // depthBucket 9, bucketWeight 512
    uint256 constant RIVAL_R  = 1e17;   // depthBucket 2, bucketWeight 4
    uint256 constant THIN_R   = 1e16;   // depthBucket 1, bucketWeight 2
    uint256 constant ORDER    = 1e18;

    function setUp() public {
        mgr = new RegistryDoorsV4State();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        // This contract stands in for the Router: on recordSwap, and as the
        // `weth()` the native V4 door asks the Router for.
        hub.setRoles(address(this), address(solver), address(this));
        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        W = new MockERC20("W", "W");
    }

    function weth() external view returns (address) { return address(W); }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Plant a live hookless V4 pool on (c0, c1) at the layout v4SqrtAndLiq reads.
    function _plantOn(address c0, address c1, uint160 sp, uint128 liq)
        internal returns (address poolAddr, bytes32 pid)
    {
        pid = BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(sp)));                         // sqrtPriceX96
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));  // liquidity
        poolAddr = address(uint160(uint256(pid)));
    }

    function _plant(uint128 liq) internal returns (address poolAddr, bytes32 pid) {
        (address s0, address s1) = BPC.sortTokens(address(A), address(B));
        return _plantOn(s0, s1, uint160(BPC.Q96), liq);
    }

    function _key(address pool) internal view returns (bytes32) {
        return hub.keyOf(pool, address(A), address(B));
    }

    function _bucketOf(address pool, address tA, address tB) internal view returns (uint8) {
        return BPC.decodeBucket(hub.getSlot(hub.keyOf(pool, tA, tB)));
    }

    function _v2(uint256 r) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(A), address(B));
        A.mint(address(p), r);
        B.mint(address(p), r);
        p.setReserves(uint112(r), uint112(r));
    }

    /// @dev Warm a row to `n` recorded swaps at its own measured depth.
    function _warm(address pool, uint256 depthWad, uint32 n) internal {
        while (BPC.decodeSwapCount(hub.getSlot(_key(pool))) < n) {
            hub.recordSwap(pool, BPC.KIND_V2, 30, address(0),
                           address(A), address(B), 1, 1, depthWad);
        }
    }

    /// @dev Eight rivals at `r` a side, each warmed to 3 swaps.
    function _fillFunnelWithWarmDust(uint256 r) internal {
        for (uint256 i; i < 8; ++i) {
            MockV2Pair d = _v2(r);
            hub.seedPool(address(d), BPC.KIND_V2, 30, address(0), address(A), address(B));
            _warm(address(d), r, 3);
        }
    }

    function _routedAndOut(address pool) internal returns (bool routed, uint256 out, bool planned) {
        try solver.findBestRoutePlan(address(A), address(B), ORDER) returns (RoutePlan memory plan) {
            planned = true;
            out = plan.best.totalOut;
            for (uint256 i; i < plan.best.hops[0].legs.length; ++i) {
                if (plan.best.hops[0].legs[i].pool == pool) routed = true;
            }
        } catch {}
    }

    // =========================================================================
    //  (1) THE OPERATOR'S V4 DOOR, READ STRAIGHT OFF THE REGISTRY
    // =========================================================================

    function test_AddV4_SealsTheDepthItMeasures() public {
        (address pool, ) = _plant(DEEP_LIQ);
        hub.addV4(address(A), address(B), FEE, TS, address(0));
        uint256 sAdd = hub.getSlot(_key(pool));
        assertEq(hub.getPool(_key(pool)), pool, "setup: addV4 must have registered the row");
        uint8 measured = BPC.depthBucket(uint256(DEEP_LIQ));
        assertGt(measured, 0, "setup: the planted pool is genuinely deep");
        // The operator's other door, on the very same pool, as the control.
        hub.seedPool(pool, BPC.KIND_V4, FEE, address(0), address(A), address(B));
        assertEq(BPC.decodeBucket(hub.getSlot(_key(pool))), measured,
            "control: the operator's other door seals the measured bucket");
        assertEq(BPC.decodeBucket(sAdd), measured,
            "addV4 wrote a row at a bucket its own liquidity does not support");
    }

    /// psi is the ranking quantity: a row born at bucket 0 scores 1.
    function test_AddV4_RowScoresTheMeasuredWeight() public {
        (address pool, ) = _plant(DEEP_LIQ);
        hub.addV4(address(A), address(B), FEE, TS, address(0));
        uint256 psiAdd = hub.getPsi(pool, address(A), address(B));
        uint256 wMeasured = BPC.bucketWeight(BPC.depthBucket(uint256(DEEP_LIQ)));
        assertGe(psiAdd, wMeasured,
            "the row carries none of the weight its own liquidity supports");
    }

    /// The permissionless door returns early on a row that exists (Hub:991), so
    /// the operator's door has to be right the first time. It now is, and a
    /// later claim leaves the measured bucket where it is.
    function test_AddV4_ThenClaimV4_TheMeasuredBucketStands() public {
        (address pool, ) = _plant(DEEP_LIQ);
        hub.addBridge(address(A));                 // claimV4's anchor gate
        hub.addV4(address(A), address(B), FEE, TS, address(0));
        uint8 measured = BPC.depthBucket(uint256(DEEP_LIQ));
        assertEq(BPC.decodeBucket(hub.getSlot(_key(pool))), measured, "born measured");
        vm.prank(address(0xCA11));                 // a roleless stranger
        hub.claimV4(address(A), address(B), FEE, TS);
        assertEq(BPC.decodeBucket(hub.getSlot(_key(pool))), measured,
            "the claim door left the operator's measured row as it found it");
    }

    /// No other door serves the native family: `seedPool` refuses every
    /// single-tick kind that is not KIND_V4, and `claimV4` refuses the native
    /// currency. `addV4` is the only door, so it is the one that must measure.
    function test_SeedPoolRefusesTheNativeKind_SoAddV4IsTheOnlyDoor() public {
        (address pool, ) = _plant(DEEP_LIQ);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(4)));
        hub.seedPool(pool, BPC.KIND_V4_NATIVE, FEE, address(0), address(A), address(B));
    }

    // =========================================================================
    //  (2) THE ROUTE: A MEASURED ROW SURVIVES THE FUNNEL
    // =========================================================================

    function test_control_SealedDoor_TheDeepPoolIsRouted() public {
        (address pool, ) = _plant(DEEP_LIQ);
        hub.seedPool(pool, BPC.KIND_V4, FEE, address(0), address(A), address(B));
        _fillFunnelWithWarmDust(RIVAL_R);
        (bool routed, , bool planned) = _routedAndOut(pool);
        assertTrue(planned, "control: the sealed row gives the pair a route");
        assertTrue(routed, "control: a measured deep row survives the funnel");
    }

    function test_AddV4_DeepPoolSurvivesTheFunnelOfWarmDust() public {
        (address pool, ) = _plant(DEEP_LIQ);
        hub.addV4(address(A), address(B), FEE, TS, address(0));
        _fillFunnelWithWarmDust(RIVAL_R);
        assertEq(hub.getActivePools(address(A), address(B)).length, 9,
            "setup: nine rows on the pair, the funnel keeps eight");
        (bool routed, , ) = _routedAndOut(pool);
        assertTrue(routed, "the deep V4 row was cut from the funnel by warm shallow rows");
    }

    /// Same pool, same rivals, same order: the operator's two doors fill alike.
    function test_AddV4_FillsLikeTheDoorThatMeasures() public {
        uint256 snap = vm.snapshotState();
        (address pool, ) = _plant(DEEP_LIQ);
        hub.seedPool(pool, BPC.KIND_V4, FEE, address(0), address(A), address(B));
        _fillFunnelWithWarmDust(RIVAL_R);
        (, uint256 sealedOut, ) = _routedAndOut(pool);
        vm.revertToState(snap);
        (address pool2, ) = _plant(DEEP_LIQ);
        hub.addV4(address(A), address(B), FEE, TS, address(0));
        _fillFunnelWithWarmDust(RIVAL_R);
        (, uint256 addOut, ) = _routedAndOut(pool2);
        assertEq(pool, pool2, "setup: the two runs name the same pool");
        assertGt(sealedOut, 0, "setup: the measured door produces a fill");
        assertGe(addOut, sealedOut * 99 / 100,
            "the order was filled below the venue the operator registered");
    }

    /// Rivals too shallow to carry the order: the deep venue is the pair's only route.
    function test_AddV4_WithShallowRivals_ThePairKeepsItsRoute() public {
        (address pool, ) = _plant(DEEP_LIQ);
        hub.addV4(address(A), address(B), FEE, TS, address(0));
        _fillFunnelWithWarmDust(THIN_R);
        (bool routed, , bool planned) = _routedAndOut(pool);
        assertTrue(planned, "the pair lost its only route: the deep venue was cut");
        assertTrue(routed, "and the route it has is the deep venue");
    }

    // =========================================================================
    //  (3) THE FAMILY: EVERY DOOR, NOT ONLY THE ONE THAT WAS MISSED
    // =========================================================================

    /// Each door registers a FRESH pool, and the bucket it writes is compared
    /// with a figure computed here, not with the producer the door calls.
    function test_EveryDoorSealsTheDepthOfItsOwnProducer() public {
        uint8 deep = BPC.depthBucket(uint256(DEEP_LIQ));
        assertGt(deep, BPC.depthBucket(RIVAL_R), "setup: the two depths sit in different buckets");

        // operator's V4 door
        (address pAdd, ) = _plant(DEEP_LIQ);
        hub.addV4(address(A), address(B), FEE, TS, address(0));
        assertEq(_bucketOf(pAdd, address(A), address(B)), deep, "addV4");

        // operator's seed door, concentrated (a second V4 key: another tick spacing)
        (address s0, address s1) = BPC.sortTokens(address(A), address(B));
        bytes32 pidSeed = BPC.computeV4PoolId(s0, s1, 500, 10, address(0));
        bytes32 base = keccak256(abi.encode(pidSeed, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(DEEP_LIQ)));
        address pSeedV4 = address(uint160(uint256(pidSeed)));
        hub.addV4(address(A), address(B), 500, 10, address(0));   // the seed door needs the V4 entry
        assertEq(_bucketOf(pSeedV4, address(A), address(B)), deep, "addV4, second key");
        // The book thins; the seed door must write what it measures NOW, not keep the old row.
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(RIVAL_R));
        hub.seedPool(pSeedV4, BPC.KIND_V4, 500, address(0), address(A), address(B));
        assertEq(_bucketOf(pSeedV4, address(A), address(B)), BPC.depthBucket(RIVAL_R), "seedPool, V4");

        // operator's seed door, reserves
        MockV2Pair pSeedV2 = _v2(RIVAL_R);
        hub.seedPool(address(pSeedV2), BPC.KIND_V2, 30, address(0), address(A), address(B));
        assertEq(_bucketOf(address(pSeedV2), address(A), address(B)), BPC.depthBucket(RIVAL_R),
            "seedPool, V2");

        // the swap door: a row it creates carries the depth the Router measured
        MockV2Pair pSwap = _v2(RIVAL_R);
        hub.recordSwap(address(pSwap), BPC.KIND_V2, 30, address(0),
                       address(A), address(B), 1, 1, uint256(DEEP_LIQ));
        assertEq(_bucketOf(address(pSwap), address(A), address(B)), deep, "recordSwap, new row");

        // the permissionless V4 claim, on a pair of its own
        MockERC20 C = new MockERC20("C", "C");
        hub.addBridge(address(C));
        (address c0, address c1) = BPC.sortTokens(address(C), address(B));
        (address pClaim, ) = _plantOn(c0, c1, uint160(BPC.Q96), DEEP_LIQ);
        vm.prank(address(0xCA11));
        hub.claimV4(address(C), address(B), FEE, TS);
        assertEq(_bucketOf(pClaim, address(C), address(B)), deep, "claimV4");
    }

    /// A native pool's currency0 is the chain's coin, which WETH stands for. The
    /// registry key sorts WETH among the tokens, so when the other token sorts
    /// BELOW WETH the key's order is the reverse of the pool's. The depth has to
    /// be measured in the POOL's order - the order the swap door measures it in
    /// (`Router._recordHits` takes t0/t1 from the leg's direction).
    function test_AddV4Native_MeasuresInThePoolsOwnCurrencyOrder() public {
        // A six-decimal token that sorts below WETH, so the two orders disagree.
        RegistryDoorsDec6 d6 = RegistryDoorsDec6(address(0x1000));
        vm.etch(address(d6), address(new RegistryDoorsDec6()).code);
        assertLt(uint160(address(d6)), uint160(address(W)), "setup: the token sorts below WETH");

        // An asymmetric price, so swapping the decimals moves the bucket.
        uint160 sp = uint160(BPC.Q96 * 1e3);
        (address pool, bytes32 pid) = _plantOn(address(0), address(d6), sp, DEEP_LIQ);
        uint8 poolOrder = BPC.depthBucket(BPC.registryDepth18(
            pool, BPC.KIND_V4_NATIVE, address(W), address(d6), address(mgr), pid));
        uint8 keyOrder = BPC.depthBucket(BPC.registryDepth18(
            pool, BPC.KIND_V4_NATIVE, address(d6), address(W), address(mgr), pid));
        assertTrue(poolOrder != keyOrder, "setup: the two orders measure different depths");

        hub.addV4(address(0), address(d6), FEE, TS, address(0));
        assertEq(_bucketOf(pool, address(W), address(d6)), poolOrder,
            "the native door measured with the registry key's order, not the pool's");
    }
}
