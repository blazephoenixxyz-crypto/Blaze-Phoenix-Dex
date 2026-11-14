// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The dry-run doors measure the input tax of a concentrated leg where the Router measures it.
//
// RED at 04f40ff. `Router._v3Callback` pays a V3-family pool what it demands and measures what
// the pool received; a payment that arrives short (a fee-on-transfer tokenIn) is refused with
// RouterE(13), always (owner decision 2026-08-10: a taxed token is routed where the venue takes
// it, a reserve pair). The dry-run doors (`previewPlanExact`, `previewRouteExact`) priced such a
// leg by the pool's own swap, whose callback never pays, so no transfer was ever measured: the
// exact scalar was positive for a swap the Router refuses before it moves the output (bounty
// uid 3984, Caraxes Tigo).
//
// The exact doors and the encode doors now ask `_inputTaxed`, which runs the leg backwards on the same pool: the pool pays this frame the
// leg's input before it calls back (the order of UniswapV3Pool.swap and AlgebraPool.swap), the
// callback pays it to the pool and measures the pool's delta, exactly the Router's seam, and
// reverts with the verdict. Short is a tax: the scalar is zero. A pool that pays nothing
// backwards leaves no measurement, and no measurement is not a tax.
//
// The view door (`previewPlan`, `canExecute`) holds no token in a view frame and cannot
// measure a transfer; its verdict is not asserted here, so that nothing pins it as right.
//
// Matrix: range {tax 0, 1 bps..99.99 % (fuzz), a dust order whose tax rounds to zero,
//               a payment one wei short}
//       x vector {taxed tokenIn on hop 0, taxed bridge on hop 1, the same tax on a reserve pair}
//       x door {previewPlanExact (Solver route), previewRouteExact (hand-built), previewAndEncode and
//                previewAndEncodeWithMinOut (the bytes), Router}.
// The Router is the oracle, asserted by selector and code.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract QuoterMeasuresTheV3InputTaxTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;

    MockERC20 fot;   // the taxed token
    MockERC20 tB;
    MockERC20 tC;
    MockERC20 tA;
    MockV3Pool pool;    // fot / tB, the V3 leg the Router refuses
    MockV3Pool poolBC;  // fot / tC, the second hop of the hand-built route
    MockV2Pair pairA;   // tA / fot, a reserve pair delivering the taxed bridge
    MockV2Pair pairV2;  // fot / tB, the same tax on a reserve pair (routed where natural)

    address user = address(0x5E4);
    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant R = 1_000_000e18;
    uint16 constant TAX = 300;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );
        hub.setRoles(address(router), address(solver), address(quoter));

        fot = new MockERC20("FOT", "FOT");
        fot.setFeeOnTransferBps(TAX);
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        tA = new MockERC20("A", "A");

        pool = _v3(fot, tB);
        hub.seedPool(address(pool), BPC.KIND_V3, 3000, address(0), address(fot), address(tB));
        poolBC = _v3(fot, tC);
        pairA = _pair(tA, fot);
        pairV2 = _pair(fot, tB);

        fot.mint(user, 10_000e18);
        tA.mint(user, 10_000e18);
        // The Router holds enough of the taxed token for its payment itself never to fail on
        // balance: the pool receives the payment minus the tax, and the measured delta is what
        // fires (the PoC's own fixture).
        fot.mint(address(router), 10_000e18);
        vm.startPrank(user);
        fot.approve(address(router), type(uint256).max);
        tA.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _v3(MockERC20 a, MockERC20 b) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(a), address(b), 3000);
        p.setState(uint160(BPC.Q96), 1_000_000e18);
        a.mint(address(p), R);
        b.mint(address(p), R);
    }

    function _pair(MockERC20 a, MockERC20 b) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), R);
        b.mint(address(p), R);
        p.setReserves(uint112(R), uint112(R));
    }

    function _rerr(uint16 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, c);
    }

    function _leg(address p, address tIn, uint8 kind, uint24 fee, uint256 amtIn, uint256 exp)
        internal view returns (Leg memory)
    {
        return Leg({pool: p, hooks: address(0), kind: kind, fee: fee, tickSpacing: 0,
            zeroForOne: tIn == BPC.token0Of(p), stable: false, amountIn: amtIn, expectedOut: exp,
            auxId: bytes32(0)});
    }

    function _hop(address tIn, address tOut, Leg memory l) internal pure returns (Hop memory h) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = l;
        h = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: l.amountIn, expectedOut: l.expectedOut, legs: legs});
    }

    function _wrap(Hop[] memory hops) internal pure returns (Route memory) {
        uint256 total = hops[hops.length - 1].expectedOut;
        return Route({hops: hops, totalOut: total, singleOut: total, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// The Solver's own route for fot -> tB, hand-wrapped for the hand-built door.
    function _handBuilt(uint256 amtIn) internal view returns (Route memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(address(fot), address(tB), _leg(address(pool), address(fot), BPC.KIND_V3, 3000, amtIn,
            BPC.outV3(amtIn, uint160(BPC.Q96), 1_000_000e18, 3000, address(fot) == pool.token0(), 0)));
        return _wrap(hops);
    }

    // ───────────────────────── taxed tokenIn on hop 0 -> RouterE(13) ─────────────────────────

    function test_HopZero_V3LegWithATaxedInput_IsNotPromisedByEitherExactDoor() public {
        (Route memory rt, uint256 exactOut) = quoter.previewPlanExact(address(fot), address(tB), AMOUNT_IN);
        assertEq(rt.hops.length, 1, "pre-condition: the Solver seats the V3 pool");
        assertEq(exactOut, 0, "previewPlanExact promises an output the Router refuses");
        (, uint256 handOut) = quoter.previewRouteExact(_handBuilt(AMOUNT_IN), AMOUNT_IN);
        assertEq(handOut, 0, "previewRouteExact promises an output the Router refuses");

        vm.prank(user);
        vm.expectRevert(_rerr(13));
        router.swapExactIn(rt, AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    /// Range: every tax the token can charge, from one basis point up.
    function testFuzz_AnyInputTax_IsMeasuredAndNotPromised(uint16 bps) public {
        bps = uint16(bound(bps, 1, 9_999));
        fot.setFeeOnTransferBps(bps);
        (Route memory rt, uint256 exactOut) = quoter.previewPlanExact(address(fot), address(tB), AMOUNT_IN);
        assertEq(exactOut, 0, "a taxed input is promised");
        vm.prank(user);
        vm.expectRevert(_rerr(13));
        router.swapExactIn(rt, AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    /// The other family of the same seam: an Algebra pool, paid through the same callback.
    function test_HopZero_AlgebraLegWithATaxedInput_IsNotPromised() public {
        MockAlgebraPool alg = new MockAlgebraPool(address(fot), address(tB), 3000);
        alg.setState(uint160(BPC.Q96), 1_000_000e18);
        fot.mint(address(alg), R);
        tB.mint(address(alg), R);
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(address(fot), address(tB), _leg(address(alg), address(fot), BPC.KIND_ALGEBRA, 3000, AMOUNT_IN,
            BPC.outV3(AMOUNT_IN, uint160(BPC.Q96), 1_000_000e18, 3000, address(fot) == alg.token0(), 0)));
        Route memory r = _wrap(hops);
        (Route memory rx, uint256 exactOut) = quoter.previewRouteExact(r, AMOUNT_IN);
        assertEq(exactOut, 0, "a taxed input into an Algebra leg is promised");
        vm.prank(user);
        vm.expectRevert(_rerr(13));
        router.swapExactIn(rx, AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    // ───────────────────────── taxed bridge on hop 1 -> RouterE(13) ─────────────────────────

    /// tA -> fot on a reserve pair (which takes the tax), then fot -> tC on a V3 pool, which
    /// the Router pays short.
    function test_HopOne_V3LegWithATaxedBridge_IsNotPromised() public {
        uint256 mid = BPC.outV2(AMOUNT_IN, R, R, 30);
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(tA), address(fot), _leg(address(pairA), address(tA), BPC.KIND_V2, 30, AMOUNT_IN, mid));
        hops[1] = _hop(address(fot), address(tC), _leg(address(poolBC), address(fot), BPC.KIND_V3, 3000, mid,
            BPC.outV3(mid, uint160(BPC.Q96), 1_000_000e18, 3000, address(fot) == poolBC.token0(), 0)));
        Route memory r = _wrap(hops);
        (Route memory rx, uint256 exactOut) = quoter.previewRouteExact(r, AMOUNT_IN);
        assertEq(exactOut, 0, "a taxed bridge into a V3 leg is promised");
        vm.prank(user);
        vm.expectRevert(_rerr(13));
        router.swapExactIn(rx, AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    // ───────────────────────── controls ─────────────────────────

    /// No tax: the same route is promised and the Router settles at least the scalar.
    function test_Control_NoTax_IsPromisedAndSettled() public {
        fot.setFeeOnTransferBps(0);
        (Route memory rt, uint256 exactOut) = quoter.previewPlanExact(address(fot), address(tB), AMOUNT_IN);
        assertGt(exactOut, 0, "an untaxed input is refused");
        vm.prank(user);
        uint256 out = router.swapExactIn(rt, AMOUNT_IN, exactOut, user, block.timestamp + 1);
        assertGe(out, exactOut, "the Router settles what the dry-run promised");
    }

    /// The same tax on a reserve pair is routed where natural: the pair takes what arrives.
    /// The scalar of a taxed reserve leg is a question of its own (not this guard's); here only
    /// that the leg is not refused and the Router fills it.
    function test_Control_TheSameTaxOnAReservePair_IsNotRefusedAndFills() public {
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(address(fot), address(tB), _leg(address(pairV2), address(fot), BPC.KIND_V2, 30, AMOUNT_IN,
            BPC.outV2(AMOUNT_IN, R, R, 30)));
        Route memory r = _wrap(hops);
        (Route memory rx, uint256 exactOut) = quoter.previewRouteExact(r, AMOUNT_IN);
        assertGt(exactOut, 0, "a taxed reserve leg is refused");
        vm.prank(user);
        assertGt(router.swapExactIn(rx, AMOUNT_IN, 1, user, block.timestamp + 1), 0, "the Router does not fill");
    }

    /// Range, the floor: an order so small that the token's tax rounds to zero. The Router's
    /// payment arrives whole, so it fills; the instrument sees the same transfer and promises.
    function test_Control_DustOrder_WhoseTaxRoundsToZero_IsPromisedAndFilled() public {
        uint256 dust = 10_000 / TAX - 1; // amt * TAX / 10_000 == 0
        (Route memory rt, uint256 exactOut) = quoter.previewPlanExact(address(fot), address(tB), dust);
        assertGt(exactOut, 0, "an order the tax does not touch is refused");
        vm.prank(user);
        assertGt(router.swapExactIn(rt, dust, 1, user, block.timestamp + 1), 0, "the Router does not fill");
    }

    /// Range, one wei past the floor: at 1 bps an order of 15_000 is taxed one wei, and so is
    /// the probe's payment back to the pool (~14_909). The Router refuses a pool paid one wei
    /// short (`- bal0 < owed`); the probe reads the same strict edge, so nothing is promised.
    function test_OneWeiShort_IsMeasuredAndNotPromised() public {
        fot.setFeeOnTransferBps(1);
        uint256 amt = 15_000; // amt * 1 / 10_000 == 1
        (Route memory rt, uint256 exactOut) = quoter.previewPlanExact(address(fot), address(tB), amt);
        assertEq(rt.hops.length, 1, "pre-condition: the Solver seats the V3 pool");
        assertEq(exactOut, 0, "a payment one wei short is promised");
        (, uint256 handOut) = quoter.previewRouteExact(_handBuilt(amt), amt);
        assertEq(handOut, 0, "a hand-built leg paid one wei short is promised");

        vm.prank(user);
        vm.expectRevert(_rerr(13));
        router.swapExactIn(rt, amt, 1, user, block.timestamp + 1);
    }

    // ───────────────── the encode doors (not view: they dry-run the floor) -> no bytes ─────────────────

    /// RED at f979499 with the exact doors' probe in place: `previewAndEncode` and
    /// `previewAndEncodeWithMinOut` already dry-run the route (`_fundedOut`, for the floor) and
    /// still came back `canExecute` with the bytes of a leg the Router refuses with RouterE(13).
    /// The encode doors ask the same probe, after the floor; a refused route has empty bytes.
    function test_HopZero_V3LegWithATaxedInput_IsNotEncodedByEitherEncodeDoor() public {
        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            quoter.previewAndEncode(address(fot), address(tB), AMOUNT_IN, user, block.timestamp + 1);
        assertEq(pv.route.hops.length, 1, "pre-condition: the Solver seats the V3 pool");
        assertFalse(pv.canExecute, "previewAndEncode says executable for a leg the Router refuses");
        assertEq(call.length, 0, "previewAndEncode hands back bytes the Router refuses");
        (BlazePhoenixQuoter.Preview memory pv2, bytes memory call2) = quoter.previewAndEncodeWithMinOut(
            address(fot), address(tB), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertFalse(pv2.canExecute, "previewAndEncodeWithMinOut says executable for a leg the Router refuses");
        assertEq(call2.length, 0, "previewAndEncodeWithMinOut hands back bytes the Router refuses");

        // The oracle: the Router refuses the very route the doors would have encoded.
        vm.prank(user);
        vm.expectRevert(_rerr(13));
        router.swapExactIn(pv.route, AMOUNT_IN, pv.effectiveMinOut, user, block.timestamp + 1);
    }

    /// Range, the encode door: every tax the token can charge, from one basis point up.
    function testFuzz_AnyInputTax_IsNotEncoded(uint16 bps) public {
        bps = uint16(bound(bps, 1, 9_999));
        fot.setFeeOnTransferBps(bps);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            quoter.previewAndEncode(address(fot), address(tB), AMOUNT_IN, user, block.timestamp + 1);
        assertFalse(pv.canExecute, "a taxed input is encoded");
        assertEq(call.length, 0, "a taxed input has bytes");
    }

    /// Control, the encode door: no tax, the bytes are built and the Router settles them at or
    /// above the floor they carry.
    function test_Control_NoTax_EncodeDoorBuildsBytesTheRouterSettles() public {
        fot.setFeeOnTransferBps(0);
        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            quoter.previewAndEncode(address(fot), address(tB), AMOUNT_IN, user, block.timestamp + 1);
        assertTrue(pv.canExecute, "an untaxed input is refused by the encode door");
        assertGt(call.length, 0, "an untaxed input has no bytes");
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(call);
        assertTrue(ok, "the Router refuses the bytes of an untaxed leg");
        assertGe(abi.decode(ret, (uint256)), pv.effectiveMinOut, "the Router settles under the floor the bytes carry");
    }
}
