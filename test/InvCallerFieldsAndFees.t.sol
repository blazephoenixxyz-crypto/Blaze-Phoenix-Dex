// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  INV-5  — caller route fields can only TIGHTEN; the effective minimum is a
//           three-way max (userMinOut, route.singleOutFloor, protocolFloorOut).
//  INV-15 — the fee base never exceeds min(quote, delivery); an understated
//           quote charges on delivery.
//
//  Measurement only. Nothing here reads the Router's own opinion of the fee:
//  the base is recovered from the TREASURIES' balance delta.
//
//  Reported by Seavia Resources through the bug bounty programme; this file is
//  their proof of concept, written against d96c32b. The POC route (W -> A -> W -> B)
//  starved the fee anchor: hop 0 committed dust, and hop 2 came back for the
//  route's input and spent the uncommitted pull fee-free. Since 2026-10-07 a
//  route that comes back for its input token is refused (RouterE(3)), so the POC
//  pins the refusal and the leak-as-measured test is gone with the leak.
// =============================================================================
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

interface IERC20Min2 { function transfer(address to, uint256 a) external returns (bool); function balanceOf(address w) external view returns (uint256); }

/// @dev A V4 PoolManager singleton with a fixed linear price, enough for the
///      Router's unlock/settle/take dance. Copied in shape from the one the
///      repo's own V4 route tests use; kept local so this file stands alone.
contract FeeV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    mapping(bytes32 => uint256) public rate;   // out = in * rate / 1000
    mapping(bytes32 => bytes32) public slots;
    /// @notice when non-zero the next swap CONSUMES only this much of the input
    uint256 public partialTake;
    address pendingCur; uint256 pendingOwe; bool synced; address syncedCur; uint256 syncBal;
    function setRate(bytes32 pid, uint256 r) external { rate[pid] = r; }
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function setPartialTake(uint256 x) external { partialTake = x; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }
    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        require(pendingOwe == 0, "CurrencyNotSettled");
        return ret;
    }
    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (int256) {
        bytes32 pid = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        require(p.amountSpecified < 0, "exact-in only");
        uint160 sp = uint160(uint256(slots[keccak256(abi.encode(pid, uint256(6)))]));
        require(p.zeroForOne
            ? (p.sqrtPriceLimitX96 < sp && p.sqrtPriceLimitX96 > 4295128739)
            : (p.sqrtPriceLimitX96 > sp && p.sqrtPriceLimitX96 < 1461446703485210103287273052203988822378723970342),
            "PriceLimitOutOfBounds");
        uint256 amt = uint256(-p.amountSpecified);
        if (partialTake != 0 && partialTake < amt) { amt = partialTake; partialTake = 0; }
        uint256 out = p.zeroForOne ? amt * rate[pid] / 1000 : amt * 1000 / rate[pid];
        pendingCur = p.zeroForOne ? key.currency0 : key.currency1;
        pendingOwe = amt;
        int128 owe = -int128(int256(amt));
        int128 recv = int128(int256(out));
        return p.zeroForOne
            ? int256((uint256(uint128(owe)) << 128) | uint256(uint128(recv)))
            : int256((uint256(uint128(recv)) << 128) | uint256(uint128(owe)));
    }
    function sync(address c) external { synced = true; syncedCur = c; syncBal = IERC20Min2(c).balanceOf(address(this)); }
    function settle() external payable returns (uint256) {
        require(synced && syncedCur == pendingCur, "settle: not synced");
        require(IERC20Min2(pendingCur).balanceOf(address(this)) - syncBal >= pendingOwe, "settle: unpaid");
        synced = false; pendingCur = address(0); pendingOwe = 0; return 0;
    }
    function take(address c, address to, uint256 a) external { require(IERC20Min2(c).transfer(to, a), "take"); }
}

contract InvCallerFieldsAndFeesTest is Test {
    BlazePhoenixHub  hub;
    BlazePhoenixRouter router;
    FeeV4Manager mgr;

    MockERC20 A; MockERC20 B; MockERC20 C; MockERC20 W;   // W is the bridge coin
    MockV2Pair pAB; MockV2Pair pBC; MockV2Pair pAW; MockV2Pair pWB; MockV2Pair pAB2;
    MockV3Pool v3AB;

    address user = address(0xBEEF);
    address T1 = address(0xFEE1);
    address T2 = address(0xFEE2);

    uint24 constant V4FEE = 3000; int24 constant V4TS = 60;
    bytes32 v4pid; address vc0; address vc1;
    MockERC20 V0; MockERC20 V1;

    uint256 constant RES = 1_000_000e18;

    function setUp() public {
        mgr = new FeeV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        router = new BlazePhoenixRouter(address(hub), address(0x5011), address(this), T1, T2);

        A = new MockERC20("A", "A"); B = new MockERC20("B", "B");
        C = new MockERC20("C", "C"); W = new MockERC20("W", "W");
        hub.addBridge(address(W));

        pAB  = _pair(address(A), address(B));
        pAB2 = _pair(address(A), address(B));
        pBC  = _pair(address(B), address(C));
        pAW  = _pair(address(A), address(W));
        pWB  = _pair(address(W), address(B));

        v3AB = new MockV3Pool(address(A), address(B), 3000);
        v3AB.setState(uint160(BPC.Q96), uint128(1e27));           // price 1, deep
        A.mint(address(v3AB), RES); B.mint(address(v3AB), RES);

        V0 = new MockERC20("V0", "V0"); V1 = new MockERC20("V1", "V1");
        (vc0, vc1) = address(V0) < address(V1) ? (address(V0), address(V1)) : (address(V1), address(V0));
        v4pid = BPC.computeV4PoolId(vc0, vc1, V4FEE, V4TS, address(0));
        bytes32 base = keccak256(abi.encode(v4pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));             // sqrtP = 1
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(1e30)));
        mgr.setRate(v4pid, 1000);                                 // 1:1
        MockERC20(vc0).mint(address(mgr), RES); MockERC20(vc1).mint(address(mgr), RES);

        A.mint(user, 100_000e18); W.mint(user, 100_000e18);
        MockERC20(vc0).mint(user, 100_000e18);
        vm.startPrank(user);
        A.approve(address(router), type(uint256).max);
        W.approve(address(router), type(uint256).max);
        MockERC20(vc0).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _pair(address a, address b) internal returns (MockV2Pair p) {
        p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), RES); MockERC20(b).mint(address(p), RES);
        p.setReserves(uint112(RES), uint112(RES));
    }

    // ── route builders ───────────────────────────────────────────────────────

    function _v2Leg(MockV2Pair p, address tIn, uint256 amt, uint256 att) internal view returns (Leg memory) {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
                    zeroForOne: p.token0() == tIn, stable: false, amountIn: amt, expectedOut: att, auxId: bytes32(0)});
    }
    function _v2Quote(MockV2Pair p, address tIn, uint256 amt) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool zfo = p.token0() == tIn;
        return BPC.outV2(amt, zfo ? r0 : r1, zfo ? r1 : r0, 30);
    }
    function _v3Leg(uint256 amt, uint256 att) internal view returns (Leg memory) {
        return Leg({pool: address(v3AB), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 60,
                    zeroForOne: v3AB.token0() == address(A), stable: false, amountIn: amt, expectedOut: att, auxId: bytes32(0)});
    }
    function _v4Leg(uint256 amt, uint256 att) internal view returns (Leg memory) {
        return Leg({pool: address(uint160(uint256(v4pid))), hooks: address(0), kind: BPC.KIND_V4, fee: V4FEE,
                    tickSpacing: V4TS, zeroForOne: vc0 == address(V0) ? true : false, stable: false,
                    amountIn: amt, expectedOut: att, auxId: bytes32(uint256(uint160(vc1)))});
    }
    function _one(address tIn, address tOut, uint256 hopIn, Leg memory leg) internal pure returns (Route memory r) {
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: hopIn, expectedOut: leg.expectedOut, legs: legs});
        r = Route({hops: hops, totalOut: leg.expectedOut, singleOut: leg.expectedOut, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    // ── fee-base recovery: never reads the Router's own number ───────────────

    function _treas(MockERC20 t) internal view returns (uint256) { return t.balanceOf(T1) + t.balanceOf(T2); }

    /// @dev recovers the base b from fee = ceil(b * 28 / 10000)
    function _baseFromFee(uint256 fee) internal pure returns (uint256 lo, uint256 hi) {
        // fee = ceil(b*28/1e4)  =>  b in ((fee-1)*1e4/28 , fee*1e4/28]
        lo = fee == 0 ? 0 : ((fee - 1) * BPC.BPS) / BPC.PROTOCOL_FEE_BPS + 1;
        hi = (fee * BPC.BPS) / BPC.PROTOCOL_FEE_BPS;
    }

    function _report(string memory what, uint256 feePaid, uint256 committed, uint256 delivered) internal {
        (uint256 lo, uint256 hi) = _baseFromFee(feePaid);
        emit log_named_string("arm", what);
        emit log_named_uint("  fee paid          ", feePaid);
        emit log_named_uint("  implied base (lo) ", lo);
        emit log_named_uint("  implied base (hi) ", hi);
        emit log_named_uint("  committed input   ", committed);
        emit log_named_uint("  delivered out     ", delivered);
    }

    // =========================================================================
    //  A. FEE BASE, ARM BY ARM
    // =========================================================================

    function test_measure_FeeBase_Pair_Honest() public {
        uint256 amt = 1000e18;
        uint256 q = _v2Quote(pAB, address(A), amt);
        Route memory r = _one(address(A), address(B), amt, _v2Leg(pAB, address(A), amt, q));
        uint256 f0 = _treas(A);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 fee = _treas(A) - f0;
        _report("pair / honest", fee, amt, got);
        assertEq(fee, BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "base == measured pull");
    }

    /// The caller UNDER-declares what the route commits. The base follows the
    /// declaration (it is the smaller of the two) - and so does the routed
    /// amount, because scaleNum is capped at scaleDen. The unrouted remainder
    /// is refunded. Fee/routed stays exactly the rate.
    function test_measure_FeeBase_Pair_UnderDeclared() public {
        uint256 pull = 1000e18;
        uint256 commit_ = 400e18;
        uint256 q = _v2Quote(pAB, address(A), commit_);
        Route memory r = _one(address(A), address(B), pull, _v2Leg(pAB, address(A), commit_, q));
        uint256 f0 = _treas(A); uint256 u0 = A.balanceOf(user);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, pull, 1, user, block.timestamp + 1);
        uint256 fee = _treas(A) - f0;
        uint256 spentByUser = u0 - A.balanceOf(user);
        _report("pair / under-declared commit", fee, commit_, got);
        emit log_named_uint("  user A actually spent", spentByUser);
        assertEq(fee, BPC.mulDivUp(commit_, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "base == committed, not pull");
        assertEq(spentByUser, commit_ + fee, "the unrouted remainder came back: the rate is exactly 28 bps of what routed");
    }

    /// Over-declaring cannot inflate the base above the measured pull.
    function test_measure_FeeBase_Pair_OverDeclared() public {
        uint256 pull = 1000e18;
        uint256 commit_ = 5000e18;
        Route memory r = _one(address(A), address(B), pull, _v2Leg(pAB, address(A), commit_, 1));
        uint256 f0 = _treas(A);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, pull, 1, user, block.timestamp + 1);
        uint256 fee = _treas(A) - f0;
        _report("pair / over-declared commit", fee, pull, got);
        assertEq(fee, BPC.mulDivUp(pull, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "capped at the measured pull");
    }

    /// INV-15's literal words: `route.totalOut` is read by nothing, and neither
    /// is a deflated `leg.expectedOut`, as far as the FEE is concerned.
    function test_measure_FeeBase_Pair_UnderstatedQuote() public {
        uint256 amt = 1000e18;
        Route memory r = _one(address(A), address(B), amt, _v2Leg(pAB, address(A), amt, 1));
        r.totalOut = 1; r.singleOut = 1;
        uint256 f0 = _treas(A);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 fee = _treas(A) - f0;
        _report("pair / totalOut=1, expectedOut=1", fee, amt, got);
        assertEq(fee, BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "a lied-about quote does not move the base");
    }

    function test_measure_FeeBase_V3() public {
        uint256 amt = 1000e18;
        Route memory r = _one(address(A), address(B), amt, _v3Leg(amt, 0));
        uint256 f0 = _treas(A);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 fee = _treas(A) - f0;
        _report("V3 / honest", fee, amt, got);
        assertEq(fee, BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "V3 base == measured pull");
    }

    /// A forged `leg.fee` near 1e6 drives the in-frame V3 quote toward 0. The
    /// fee base must not move with it (A1/C1b/T1).
    function test_measure_FeeBase_V3_ForgedLegFee() public {
        uint256 amt = 1000e18;
        Leg memory l = _v3Leg(amt, 0); l.fee = 999_000;
        Route memory r = _one(address(A), address(B), amt, l);
        uint256 f0 = _treas(A);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 fee = _treas(A) - f0;
        _report("V3 / leg.fee = 999000", fee, amt, got);
        assertEq(fee, BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "forged leg.fee does not shrink the base");
    }

    function test_measure_FeeBase_V4() public {
        uint256 amt = 1000e18;
        Route memory r = _one(vc0, vc1, amt, _v4Leg(amt, 0));
        r.hops[0].legs[0].zeroForOne = true;
        uint256 f0 = MockERC20(vc0).balanceOf(T1) + MockERC20(vc0).balanceOf(T2);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 fee = MockERC20(vc0).balanceOf(T1) + MockERC20(vc0).balanceOf(T2) - f0;
        _report("V4 / honest", fee, amt, got);
        assertEq(fee, BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "V4 base == measured pull");
    }

    /// Two hops, bridge coin is hop 1's input: the anchor is hop 1 and the base
    /// is the MEASURED bridge balance, in the bridge coin.
    function test_measure_FeeBase_MultiHop_AnchoredOnBridge() public {
        uint256 amt = 1000e18;
        uint256 q0 = _v2Quote(pAW, address(A), amt);
        uint256 q1 = _v2Quote(pWB, address(W), q0);
        Leg[] memory l0 = new Leg[](1); l0[0] = _v2Leg(pAW, address(A), amt, q0);
        Leg[] memory l1 = new Leg[](1); l1[0] = _v2Leg(pWB, address(W), q0, q1);
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(W), amountIn: amt, expectedOut: q0, legs: l0});
        hops[1] = Hop({tokenIn: address(W), tokenOut: address(B), amountIn: q0, expectedOut: q1, legs: l1});
        Route memory r = Route({hops: hops, totalOut: q1, singleOut: q1, singleOutFloor: 0, expectedImpactBps: 0,
                                confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        uint256 fA0 = _treas(A); uint256 fW0 = _treas(W);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 feeA = _treas(A) - fA0; uint256 feeW = _treas(W) - fW0;
        _report("2-hop A>W>B / anchored on W", feeW, q0, got);
        emit log_named_uint("  fee in A (must be 0)", feeA);
        assertEq(feeA, 0, "nothing charged off the anchor");
        assertEq(feeW, BPC.mulDivUp(q0, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "base == the measured bridge balance");
    }

    /// No bridge coin is any hop's input: the exhaustion regime, every hop pays
    /// on its own measured input.
    function test_measure_FeeBase_MultiHop_Exhaustion() public {
        uint256 amt = 1000e18;
        uint256 q0 = _v2Quote(pAB, address(A), amt);
        uint256 q1 = _v2Quote(pBC, address(B), q0);
        Leg[] memory l0 = new Leg[](1); l0[0] = _v2Leg(pAB, address(A), amt, q0);
        Leg[] memory l1 = new Leg[](1); l1[0] = _v2Leg(pBC, address(B), q0, q1);
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: amt, expectedOut: q0, legs: l0});
        hops[1] = Hop({tokenIn: address(B), tokenOut: address(C), amountIn: q0, expectedOut: q1, legs: l1});
        Route memory r = Route({hops: hops, totalOut: q1, singleOut: q1, singleOutFloor: 0, expectedImpactBps: 0,
                                confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        uint256 fA0 = _treas(A); uint256 fB0 = _treas(B);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 feeA = _treas(A) - fA0; uint256 feeB = _treas(B) - fB0;
        _report("2-hop A>B>C / exhaustion, hop 0", feeA, amt, got);
        emit log_named_uint("  fee in B (hop 1)     ", feeB);
        assertEq(feeA, BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "hop 0 on its measured pull");
        assertGt(feeB, 0, "hop 1 pays too");
    }

    /// Direct route INTO a bridge coin: the fee comes out of the OUTPUT, and the
    /// base is the delivered amount.
    function test_measure_FeeBase_FeeOnOut() public {
        uint256 amt = 1000e18;
        uint256 q = _v2Quote(pAW, address(A), amt);
        Route memory r = _one(address(A), address(W), amt, _v2Leg(pAW, address(A), amt, q));
        uint256 fA0 = _treas(A); uint256 fW0 = _treas(W);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 feeA = _treas(A) - fA0; uint256 feeW = _treas(W) - fW0;
        _report("direct A>W / fee on out", feeW, amt, got);
        assertEq(feeA, 0, "input side untouched");
        assertEq(feeW, BPC.mulDivUp(got + feeW, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "base == gross delivery");
    }

    // =========================================================================
    //  B. THE THREE-WAY MAX
    // =========================================================================

    function test_ThreeWayMax_SingleOutFloorOnlyTightens() public {
        uint256 amt = 1000e18;
        uint256 q = _v2Quote(pAB, address(A), amt);
        // a singleOutFloor ABOVE what the pool can deliver must revert
        Route memory r = _one(address(A), address(B), amt, _v2Leg(pAB, address(A), amt, q));
        r.singleOutFloor = q * 2;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        // a singleOutFloor of ZERO does not lower the protocol floor: the same
        // route with an honest floor settles, and the protocol floor still ran.
        Route memory r2 = _one(address(A), address(B), amt, _v2Leg(pAB, address(A), amt, q));
        r2.singleOutFloor = 0;
        vm.prank(user);
        uint256 got = router.swapExactIn(r2, amt, 1, user, block.timestamp + 1);
        assertGt(got, 0, "control: the honest route settles");
    }

    // =========================================================================
    //  C. FIELD-BY-FIELD: the inert scalars
    // =========================================================================

    /// Every Route scalar except singleOutFloor is inert in the Router: filling
    /// them with adversarial values changes nothing the user receives.
    function test_InertRouteScalars_ChangeNothing() public {
        uint256 amt = 1000e18;
        uint256 q = _v2Quote(pAB, address(A), amt);
        Route memory honest = _one(address(A), address(B), amt, _v2Leg(pAB, address(A), amt, q));
        uint256 f0 = _treas(A);
        vm.prank(user);
        uint256 gotHonest = router.swapExactIn(honest, amt, 1, user, block.timestamp + 1);
        uint256 feeHonest = _treas(A) - f0;

        // reset the pools so the second run sees the same state
        setUp();
        uint256 q2 = _v2Quote(pAB, address(A), amt);
        assertEq(q2, q, "fixtures reset");
        Route memory lying = _one(address(A), address(B), amt, _v2Leg(pAB, address(A), amt, q));
        lying.totalOut = type(uint128).max;
        lying.singleOut = type(uint128).max;
        lying.expectedImpactBps = type(uint256).max;
        lying.confidenceWad = type(uint256).max;
        lying.estGas = type(uint256).max;
        lying.hasSurplus = true;
        lying.isV4Bundle = true;
        lying.hops[0].amountIn = 1;           // hop.amountIn is inert too
        uint256 g0 = _treas(A);
        vm.prank(user);
        uint256 gotLying = router.swapExactIn(lying, amt, 1, user, block.timestamp + 1);
        uint256 feeLying = _treas(A) - g0;
        assertEq(gotLying, gotHonest, "inert scalars move no output");
        assertEq(feeLying, feeHonest, "inert scalars move no fee");
    }

    /// hop.expectedOut is NOT inert at this pin (Router:1357) - but it can only
    /// RAISE the floor, and only on a hop that carries an unmeasured leg.
    /// On a fully measured hop it is inert in both directions.
    function test_HopExpectedOut_InertWhenNothingIsBlind() public {
        uint256 amt = 1000e18;
        uint256 q = _v2Quote(pAB, address(A), amt);
        Route memory r = _one(address(A), address(B), amt, _v2Leg(pAB, address(A), amt, q));
        r.hops[0].expectedOut = type(uint128).max;   // absurd, and not blind
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        assertGt(got, 0, "no blind leg: hop.expectedOut never enters hopBase");
    }

    // =========================================================================
    //  D. THE ANCHOR HOP CAN BE STARVED BY ITS OWN DECLARED COMMITMENT
    //
    //  `_chargeHopFee` (Router:658-660) caps the hop-0 fee base at
    //  `_legSum(hop)` - the SUM THE CALLER DECLARED. `scaleNum` is capped the
    //  same way (Router:1169), so the uncommitted remainder is simply LEFT IN
    //  THE ROUTER. It is not refunded until after the hop loop (Router:1377).
    //  A later hop whose `tokenIn` is that same token picks it up in full,
    //  because its own base is `bal - foreignBase` and `foreignBase` is
    //  `baseIn` - the PRE-SWAP remainder, not this swap's pull (Router:1115).
    //  No attacker-owned pool, no injected value: the user's own WETH crosses
    //  the real pool at hop 2 and the rate was charged on hop 0's dust.
    // =========================================================================

    /// CONTROL: the honest direct route pays the full rate on the whole pull.
    function test_CONTROL_DirectBridgeRoute_PaysTheFullRate() public {
        uint256 amt = 1000e18;
        uint256 q = _v2Quote(pWB, address(W), amt);
        Route memory r = _one(address(W), address(B), amt, _v2Leg(pWB, address(W), amt, q));
        uint256 f0 = _treas(W);
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        uint256 fee = _treas(W) - f0;
        _report("CONTROL direct W>B", fee, amt, got);
        assertEq(fee, BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "28 bps of the whole pull");
    }

    /// POC: same pull, same destination pool, same delivered value - but the
    /// anchor hop commits dust, so the rate is charged on dust.
    function test_POC_AnchorStarvedByDeclaredCommitment() public {
        uint256 amt  = 1000e18;
        uint256 dust = 1e12;

        // hop 0: W -> A, committing only `dust` of the 1000 W pulled
        uint256 q0 = _v2Quote(pAW, address(W), dust);
        Leg[] memory l0 = new Leg[](1); l0[0] = _v2Leg(pAW, address(W), dust, q0);
        // hop 1: A -> W, the dust comes straight back
        uint256 q1 = _v2Quote(pAW, address(A), q0);
        Leg[] memory l1 = new Leg[](1); l1[0] = _v2Leg(pAW, address(A), q0, q1);
        // hop 2: W -> B, tokenIn is the ROUTE's tokenIn, so foreignBase == baseIn == 0
        // and this hop spends every W the Router is still holding.
        uint256 q2 = _v2Quote(pWB, address(W), amt);
        Leg[] memory l2 = new Leg[](1); l2[0] = _v2Leg(pWB, address(W), amt, q2);

        Hop[] memory hops = new Hop[](3);
        hops[0] = Hop({tokenIn: address(W), tokenOut: address(A), amountIn: dust, expectedOut: q0, legs: l0});
        hops[1] = Hop({tokenIn: address(A), tokenOut: address(W), amountIn: q0,   expectedOut: q1, legs: l1});
        hops[2] = Hop({tokenIn: address(W), tokenOut: address(B), amountIn: amt,  expectedOut: q2, legs: l2});
        Route memory r = Route({hops: hops, totalOut: q2, singleOut: q2, singleOutFloor: 0,
                                expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                                hasSurplus: false, isV4Bundle: false});

        uint256 fW0 = _treas(W);
        uint256 wPool0 = W.balanceOf(address(pWB));
        // INV-15: the fee base is the measured pull. The shape that starved it is refused.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        assertEq(_treas(W), fW0, "no fee on a refused route");
        assertEq(W.balanceOf(address(pWB)), wPool0, "and nothing crossed the pool");
    }


}