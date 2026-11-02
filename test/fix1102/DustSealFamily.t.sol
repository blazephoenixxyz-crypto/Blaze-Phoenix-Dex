// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// FAMILY A of fix-1102, THE DUST SEAL, red first. A row's clock (lastUpdateTs, swapCount, tau) and
// the V4 tier a token teaches move only on a tick that carries anchored mass and closes a real
// interval, and the first interval is weighed from the unmeasured step, never read whole.
// One motor per family of report, one test per report:
//   twins      dust on one of two equal rows leaves both reading the same clock
//              (3545-C1, 3652, 3645, 3552-LA, 3555)
//   admission  dust on 16 shallow seats does not keep a deep newcomer out (3663)
//   first      the first anchored interval moves tau 1/8 of the way from 24576/4 = 6144
//              (3545-C2, 3575)
//   pure       Core.tickSlot alone: no EMA dead zone, no interval closed inside the stamped
//              second (3545-C3a, 3545-C3b)
//   v4         the learned V4 code survives a refused, an idempotent and a dust claim, and an
//              unanchored tick on a registered V4 row (3537 x3 + sibling)
// RED at b46b183: every test here fails on that tree; GREEN once the seal lands. No fork: the real
// Hub and Core with the repo's mocks. The clock of item 7 (3536/3554) is not family A.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV4ScanManager} from "../mocks/MockV4ScanManager.sol";
import {MockOriginFactory, Origin} from "../mocks/MockOriginFactory.sol";

/// A V3-shaped venue the cold door can prove (token0/token1, fee, slot0), as DiscoveryRefreshMonoslot's.
contract SealV3Pool {
    address public token0;
    address public token1;
    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function fee() external pure returns (uint24) { return 500; }
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (79228162514264337593543950336, int24(0), 0, 0, 0, 0, true);
    }
}

contract DustSealFamilyTest is Test {
    BlazePhoenixHub hub;
    MockOriginFactory origin;
    uint24 tier;

    address constant TA = address(0xAAA1);
    address constant TB = address(0xBBB2);
    uint256 constant ORIGIN = 1_000_000;  // base timestamp, every row is seated here
    uint256 constant DEEP = 1e24;         // bucket weight 512 (measured at b46b183)
    uint256 constant SHALLOW = 1e14;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        hub.setRoles(address(this), address(this), address(this)); // the test is the Router
        // One factory with a fee tier per pool: 17 pools of one pair (MAX_FACTORIES is 16).
        origin = Origin.tiers(hub, BPC.KIND_V3, 17);
        vm.warp(ORIGIN);
    }

    // ─── harness ───────────────────────────────────────────────────────────────────────────

    function _tick(address p, uint256 depthWord) internal {
        hub.recordSwap(p, BPC.KIND_V3, 500, address(0), TA, TB, 1e18, 1e18, depthWord);
    }

    function _anchor(address p, uint256 depth) internal { _tick(p, depth | BPC.TICK_ANCHORED); }

    function _slot(address p) internal view returns (uint256) { return hub.getSlot(hub.keyOf(p, TA, TB)); }

    /// A new TA/TB pool, listed by the origin factory, offered to the cold door by an anchored swap.
    function _offer(uint256 depth) internal returns (address p) {
        p = address(new SealV3Pool(TA, TB));
        origin.list(p, TA, TB, ++tier, false);
        _anchor(p, depth);
    }

    function _seat(uint256 depth) internal returns (address p) {
        p = _offer(depth);
        assertGt(_slot(p), 0, "precondition: row seated");
    }

    function _at(uint256 t) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = t;
    }

    /// Hours `from`, `from + 1`, ... (`n` of them) after ORIGIN, each `lead` seconds early.
    function _hourly(uint256 from, uint256 n, uint256 lead) internal pure returns (uint256[] memory r) {
        r = new uint256[](n);
        for (uint256 i; i < n; ++i) r[i] = (from + i) * 1 hours - lead;
    }

    // ─── motor 1: twins (A1) ───────────────────────────────────────────────────────────────

    /// Two equal rows seated at ORIGIN. Every anchor (offset from ORIGIN) lands on both rows, every
    /// dust event (`dustEach` unanchored ticks) on the first only. Time order; an anchor runs
    /// before the dust of its own second. The seal holds iff the twins read the same clock.
    function _twins(string memory id, uint256[] memory anchorsAt, uint256[] memory dustAt, uint256 dustEach)
        internal
    {
        address dusty = _seat(DEEP);
        address clean = _seat(DEEP);
        uint256 i;
        uint256 j;
        uint256 t;
        while (i < anchorsAt.length || j < dustAt.length) {
            bool isAnchor = j == dustAt.length || (i < anchorsAt.length && anchorsAt[i] <= dustAt[j]);
            t = isAnchor ? anchorsAt[i++] : dustAt[j++];
            vm.warp(ORIGIN + t);
            if (isAnchor) {
                _anchor(dusty, DEEP);
                _anchor(clean, DEEP);
            } else {
                for (uint256 k; k < dustEach; ++k) _tick(dusty, DEEP);
            }
        }
        _sameClock(id, _slot(dusty), _slot(clean), uint32(ORIGIN + t));
    }

    function _sameClock(string memory id, uint256 d, uint256 c, uint32 at) internal {
        uint256 psiD = BPC.psi(d, at, false, false);
        uint256 psiC = BPC.psi(c, at, false, false);
        emit log_named_uint(string.concat(id, " dusty tau"), BPC.decodeTau(d));
        emit log_named_uint(string.concat(id, " clean tau"), BPC.decodeTau(c));
        emit log_named_uint(string.concat(id, " dusty count"), BPC.decodeSwapCount(d));
        emit log_named_uint(string.concat(id, " clean count"), BPC.decodeSwapCount(c));
        emit log_named_uint(string.concat(id, " dusty lastTs"), BPC.decodeLastUpdateTs(d));
        emit log_named_uint(string.concat(id, " clean lastTs"), BPC.decodeLastUpdateTs(c));
        emit log_named_uint(string.concat(id, " dusty psi"), psiD);
        emit log_named_uint(string.concat(id, " clean psi"), psiC);
        assertEq(BPC.decodeTau(d), BPC.decodeTau(c), string.concat("RED ", id, ": dust moved tau"));
        assertEq(BPC.decodeSwapCount(d), BPC.decodeSwapCount(c), string.concat("RED ", id, ": dust moved the count"));
        assertEq(BPC.decodeLastUpdateTs(d), BPC.decodeLastUpdateTs(c), string.concat("RED ", id, ": dust moved lastTs"));
        assertEq(psiD, psiC, string.concat("RED ", id, ": dust moved psi"));
    }

    /// 3545-C1: one dust tick 30 days in re-stamped the row, and the anchor 2 s later closed 2 s.
    function test_3545C1_DustThirtyDaysInLeavesTheRowEqualToItsCleanTwin() public {
        _twins("3545-C1", _at(30 days + 2), _at(30 days), 1);
    }

    /// 3652: dust one second before the first anchor collapsed the unmeasured clock to 1 s.
    function test_3652_DustOneSecondBeforeTheFirstAnchorLeavesTheRowEqualToItsCleanTwin() public {
        _twins("3652", _at(100_000), _at(99_999), 1);
    }

    /// 3645: an hourly row, its clock measured by one clean hour, then 64 hourly anchors each with
    /// dust one second before: the EMA walks tau down to its dead zone (~8 s).
    function test_3645_DustBeforeEveryHourlyAnchorLeavesTheRowEqualToItsCleanTwin() public {
        _twins("3645", _hourly(1, 65, 0), _hourly(2, 64, 1), 1);
    }

    /// 3552-LA: 30 dust ticks inside the anchor's own second each added one to the count.
    function test_3552LA_ThirtyDustTicksInTheAnchorsSecondLeaveTheRowEqualToItsCleanTwin() public {
        _twins("3552-LA", _at(1), _at(1), 30);
    }

    /// 3555: 20 dust ticks after an anchor 2 s in raised the row's psi (count 22 / tau 2).
    function test_3555_TwentyDustTicksLeaveThePsiOfTheRowEqualToItsCleanTwin() public {
        _twins("3555", _at(2), _at(2), 20);
    }

    // ─── motor 2: admission (A1 + A2) ──────────────────────────────────────────────────────

    /// `seats` shallow rows fill the pair at ORIGIN; at `anchorAt` each takes one anchored tick and
    /// `dustEach` dust ticks; then a deep pool is offered. Returns the newcomer's slot (0 = refused).
    function _admission(uint256 seats, uint256 seatDepth, uint256 anchorAt, uint256 dustEach, uint256 newDepth)
        internal
        returns (uint256)
    {
        address[] memory inc = new address[](seats);
        for (uint256 i; i < seats; ++i) inc[i] = _seat(seatDepth);
        vm.warp(ORIGIN + anchorAt);
        for (uint256 i; i < seats; ++i) {
            _anchor(inc[i], seatDepth);
            for (uint256 k; k < dustEach; ++k) _tick(inc[i], seatDepth);
        }
        uint256 s = _slot(inc[0]);
        emit log_named_uint("incumbent bucket weight", BPC.bucketWeight(BPC.depthBucket(seatDepth)));
        emit log_named_uint("incumbent tau", BPC.decodeTau(s));
        emit log_named_uint("incumbent count", BPC.decodeSwapCount(s));
        emit log_named_uint("incumbent psi (conc)", BPC.psi(s, uint32(ORIGIN + anchorAt), false, true));
        emit log_named_uint("newcomer psi", BPC.bucketWeight(BPC.depthBucket(newDepth)));
        return _slot(_offer(newDepth));
    }

    /// 3663: 16 shallow seats (1e14), each anchored 7 s in and dusted 30 times, outranked a 1e24
    /// newcomer. Sealed: each seat holds count 1 at tau 5376, psi 1, and the newcomer (weight 512) is in.
    function test_3663_DustOnSixteenShallowSeatsDoesNotKeepADeepPoolOut() public {
        assertGt(_admission(16, SHALLOW, 7, 30, DEEP), 0, "RED 3663: dust on 16 shallow seats kept a deep pool out");
    }

    // ─── motor 3: the first interval (A2) ──────────────────────────────────────────────────

    /// A row seated at ORIGIN, idle for `idle` seconds, then one anchored tick: the tau it reads.
    function _firstInterval(uint256 idle) internal returns (uint32) {
        address p = _seat(DEEP);
        vm.warp(ORIGIN + idle);
        _anchor(p, DEEP);
        return BPC.decodeTau(_slot(p));
    }

    /// 3545-C2: oracle tau = 6144 + ceil((2592000 - 6144) / 8) = 6144 + 323232 = 329376.
    function test_3545C2_AThirtyDayFirstIntervalMovesTauAnEighthFromTheUnmeasuredStep() public {
        assertEq(_firstInterval(30 days), 329_376, "RED 3545-C2: the first interval was read whole");
    }

    /// 3575: oracle tau = 6144 + ceil((86400 - 6144) / 8) = 6144 + 10032 = 16176.
    function test_3575_ADayLongFirstIntervalMovesTauAnEighthFromTheUnmeasuredStep() public {
        assertEq(_firstInterval(1 days), 16_176, "RED 3575: the first interval was read whole");
    }

    // ─── motor 4: Core.tickSlot alone (C3) ─────────────────────────────────────────────────

    /// A slot stamped at ORIGIN with `tau0` and `count0`, then `n` anchored ticks `step` seconds
    /// apart. Each tick is stamped as every caller of b46b183 stamps it (Core.stampTs); a tickSlot
    /// that stamps itself makes that stamp a no-op.
    function _pureTicks(uint32 tau0, uint32 count0, uint32 step, uint256 n) internal pure returns (uint256 s) {
        uint32 t = uint32(ORIGIN);
        s = (uint256(tau0) << 224) | (uint256(count0) << 160) | (uint256(t) << 64);
        for (uint256 i; i < n; ++i) {
            t += step;
            s = BPC.stampTs(BPC.tickSlot(s, true, DEEP, t), t);
        }
    }

    /// 3545-C3a: at tau 9 a 2 s cadence moves tau by (9 - 2) >> 3 = 0, forever. Oracle: the cadence
    /// is the fixed point, tau == dt == 2.
    function test_3545C3a_ATwoSecondCadenceBringsTauToTwo() public pure {
        assertEq(BPC.decodeTau(_pureTicks(9, 1, 2, 400)), 2, "RED 3545-C3a: the EMA stalled in its dead zone");
    }

    /// 3545-C3b: 100 anchors inside the stamped second close no interval: tau and count stay.
    function test_3545C3b_AnchorsInsideTheStampedSecondLeaveTauAndCount() public pure {
        uint256 s = _pureTicks(86_400, 1, 0, 100);
        assertEq(BPC.decodeTau(s), 86_400, "RED 3545-C3b: zero-length intervals moved tau");
        assertEq(BPC.decodeSwapCount(s), 1, "RED 3545-C3b: zero-length intervals were counted");
    }
}

/// Motor 5 (A3): the V4 code a token learned. Harness = test/mocks/MockV4ScanManager with the real
/// Hub, X/BRG with BRG a bridge, as the L2b red-first of 3537.
contract DustSealFamilyV4Test is Test {
    BlazePhoenixHub hub;
    MockV4ScanManager mgr;
    MockERC20 brg;
    MockERC20 x;

    address constant ATT = address(0xA77A);
    uint8 constant MODE_V4_DERIVE = 9;
    uint24 constant EF = 12345; // exotic: not canonical, not an extra
    int24 constant ET = 77;
    uint128 constant DEEP = 1e24;
    uint256 constant CODE_BITS = (1 << 48) - 1; // fee << 24 | tickSpacing

    function weth() external pure returns (address) { return address(0); }

    function setUp() public {
        mgr = new MockV4ScanManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        brg = new MockERC20("BRG", "BRG");
        x = new MockERC20("X", "X");
        hub.addBridge(address(brg));
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), new uint24[](0), new int24[](0));
        x.mint(address(mgr), 1e18);
    }

    function _plantId(bytes32 pid, uint128 liq) private returns (address) {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
        return address(uint160(uint256(pid)));
    }

    function _plant(address a, address b, uint24 f, int24 ts, uint128 liq) private returns (address) {
        (address s0, address s1) = BPC.sortTokens(a, b);
        return _plantId(BPC.computeV4PoolId(s0, s1, f, ts, address(0)), liq);
    }

    function _code(uint24 f, int24 ts) private pure returns (uint256) {
        return (uint256(f) << 24) | uint256(uint24(ts));
    }

    /// X learns the exotic tier from a deep claim on X/BRG.
    function _teach() private {
        _plant(address(x), address(brg), EF, ET, DEEP);
        hub.claimV4(address(x), address(brg), EF, ET);
    }

    /// The learned code right before the attack, checked to be the exotic one.
    function _learned() private view returns (uint256 c) {
        c = hub.v4CodeOf(address(x));
        assertEq(c & CODE_BITS, _code(EF, ET), "precondition: exotic code learned");
    }

    /// 3537, refused arm: a claim the full pair refuses must not rewrite the code.
    function test_3537_ARefusedClaimLeavesTheLearnedV4CodeUnchanged() public {
        _teach();
        for (uint256 i; i < 15; ++i) {
            uint24 f = uint24(4000 + i * 100);
            int24 ts = int24(int256(70 + i));
            _plant(address(x), address(brg), f, ts, DEEP);
            hub.addV4(address(x), address(brg), f, ts, address(0));
        }
        assertEq(hub.getActivePools(address(x), address(brg)).length, 16, "precondition: pair full");
        _plant(address(x), address(brg), 3000, 60, 1);
        uint256 before = _learned();
        vm.prank(ATT);
        bytes32 key = hub.claimV4(address(x), address(brg), 3000, 60);
        assertEq(hub.getPool(key), address(0), "precondition: dust claim refused");
        assertEq(hub.v4CodeOf(address(x)), before, "RED 3537: a refused claim rewrote the learned code");
    }

    /// 3537, idempotent arm: re-claiming an already-registered X/BRG pool must not rewrite the code.
    function test_3537_AnIdempotentReclaimLeavesTheLearnedV4CodeUnchanged() public {
        _plant(address(x), address(brg), 3000, 60, DEEP);
        hub.addV4(address(x), address(brg), 3000, 60, address(0));
        _teach();
        uint256 before = _learned();
        vm.prank(ATT);
        hub.claimV4(address(x), address(brg), 3000, 60);
        assertEq(hub.v4CodeOf(address(x)), before, "RED 3537: an idempotent re-claim rewrote the learned code");
    }

    /// 3537, dust arm (coordinator decision 1): an admitted claim at liquidity 1 is a lighter
    /// witness than the one that taught the code, so it must not rewrite it.
    function test_3537_ADustClaimLeavesTheLearnedV4CodeUnchanged() public {
        _teach();
        _plant(address(x), address(brg), 3000, 60, 1);
        uint256 before = _learned();
        vm.prank(ATT);
        bytes32 key = hub.claimV4(address(x), address(brg), 3000, 60);
        assertTrue(hub.getPool(key) != address(0), "precondition: dust claim admitted (pair has room)");
        assertEq(hub.v4CodeOf(address(x)), before, "RED 3537: a dust claim rewrote the learned code");
    }

    /// 3537 sibling: an unanchored tick on a registered hookless V4 row must not rewrite the code.
    function test_3537Sibling_AnUnanchoredTickOnARegisteredV4RowLeavesTheLearnedCodeUnchanged() public {
        hub.setRoles(address(this), address(this), address(this)); // the test is the Router
        address row = _plant(address(x), address(brg), 3000, 60, DEEP);
        hub.addV4(address(x), address(brg), 3000, 60, address(0));
        (address t0, address t1) = BPC.sortTokens(address(x), address(brg));
        assertGt(hub.getSlot(hub.keyOf(row, t0, t1)), 0, "precondition: V4 row registered");
        _teach();
        uint256 before = _learned();
        hub.recordSwap(row, BPC.KIND_V4, 3000, address(0), address(x), address(brg), 1e18, 1e18, DEEP);
        assertEq(hub.v4CodeOf(address(x)), before, "RED 3537: an unanchored tick rewrote the learned code");
    }
}
