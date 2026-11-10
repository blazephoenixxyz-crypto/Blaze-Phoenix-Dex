// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The preview mirrors the Router's leg dispatch.
//
// RED at e01b503. `Quoter._hookRefusedIn` asked the Router's shape, hook and key questions, and
// for a leg that is not a V4 leg it asked only "does the pool trade the hop's pair?". The
// Router asks one more thing of that leg before it touches a pool (`_execScaled`):
//
//   - a kind with no settlement engine (tombstones 2, 3 and 7, and every number above 9) falls
//     into the dispatch's `else` and reverts RouterE(8);
//   - a kind-9 leg whose pool is not a live wrapper of the admitted Gate (a cleared family, or
//     a pool that only claims the kind) reverts RouterE(19).
//
// A route built off-chain with one such leg beside a delivering leg therefore read
// `canExecute == true` at `previewRoute` and a positive scalar at `previewRouteExact`, and
// reverted at the Router. The Solver never plans these legs; the hand-built-route doors did.
//
// Each refusal is asserted by selector AND code at the Router, which is the oracle: the
// preview is compared against what the Router does with the same route, never against itself.
//
// Matrix: vector {cleared Gate family, impostor kind-9 pool, no-engine kinds 2/3/7/10/77/255}
//       x composition {alone, beside a delivering leg (either position), second hop}
//       x door {previewRoute (view), previewRouteExact (dry-run), Router}.
// Controls (what must NOT be refused): a live Gate leg, the four pool kinds the dispatch has
// an engine for, and a zero-input no-engine leg, which the Router skips before the dispatch.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {MockGateVenue, MockGateRegistry, MockGateAdapter} from "./mocks/MockGateAdapters.sol";

contract QuoterDispatchRefusalMirrorTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    BlazePhoenixGate gate;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;
    MockV2Pair good;    // A/B, the delivering leg
    MockV2Pair other;   // A/B, a second deep pair: the mislabelled leg (a pool twice in a hop is OC-07)
    MockV2Pair bridge;  // B/C, the delivering leg of the second hop
    MockV2Pair bridge2; // B/C, the mislabelled leg of the second hop
    address wrapper;
    uint8 constant FAM = 1;
    uint24 constant KEY = uint24(uint256(FAM) << 16 | 1);
    address user = address(0xBEEF);
    uint256 constant R = 100_000e18;
    uint256 constant X = 100e18;
    uint256 constant Y = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        good = _pair(tokenA, tokenB);
        other = _pair(tokenA, tokenB);
        bridge = _pair(tokenB, tokenC);
        bridge2 = _pair(tokenB, tokenC);

        (MockERC20 t0, MockERC20 t1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        gate = new BlazePhoenixGate(address(this));
        MockGateRegistry reg = new MockGateRegistry();
        MockGateVenue venue = new MockGateVenue(address(t0), address(t1));
        reg.add(address(venue));
        t0.mint(address(venue), 1_000_000e18);
        t1.mint(address(venue), 1_000_000e18);
        venue.sync();
        MockGateAdapter adapter = new MockGateAdapter(gate, reg);
        gate.proposeAdapter(FAM, address(adapter));
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(FAM);
        wrapper = gate.create(address(t1), address(t0), KEY, abi.encode(address(venue)));
        uint24[] memory fees = new uint24[](1);
        fees[0] = KEY;
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0));

        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
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

    /// A leg on `pool` in the direction `tIn -> *`, labelled `kind`.
    function _leg(address pool, address tIn, uint8 kind, uint24 fee, uint256 amtIn, uint256 exp)
        internal view returns (Leg memory)
    {
        return Leg({pool: pool, hooks: address(0), kind: kind, fee: fee, tickSpacing: 0,
            zeroForOne: tIn == BPC.token0Of(pool), stable: false, amountIn: amtIn, expectedOut: exp,
            auxId: bytes32(0)});
    }

    function _v2(MockV2Pair p, address tIn, uint256 amtIn) internal view returns (Leg memory) {
        return _leg(address(p), tIn, BPC.KIND_V2, 30, amtIn, BPC.outV2(amtIn, R, R, 30));
    }

    function _gateLeg(uint256 amtIn) internal returns (Leg memory l) {
        l = _leg(wrapper, address(tokenA), BPC.KIND_EXTERNAL, KEY, amtIn, 0);
        (, l.expectedOut, ) = BPC.gateQuote(
            address(hub), wrapper, address(tokenA), address(tokenB), KEY, l.zeroForOne, amtIn, false);
        if (l.expectedOut == 0) l.expectedOut = amtIn; // a dead wrapper quotes nothing: keep a claim
    }

    function _hop(address tIn, address tOut, Leg memory a, Leg memory b, bool two)
        internal pure returns (Hop memory h)
    {
        Leg[] memory legs = new Leg[](two ? 2 : 1);
        legs[0] = a;
        if (two) legs[1] = b;
        uint256 inSum = a.amountIn + (two ? b.amountIn : 0);
        uint256 outSum = a.expectedOut + (two ? b.expectedOut : 0);
        h = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: inSum, expectedOut: outSum, legs: legs});
    }

    function _route1(Hop memory h0) internal pure returns (Route memory r) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = h0;
        r = _wrap(hops);
    }

    function _wrap(Hop[] memory hops) internal pure returns (Route memory) {
        uint256 total = hops[hops.length - 1].expectedOut;
        return Route({hops: hops, totalOut: total, singleOut: total, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// The three doors on one route: the view says no, the dry-run scalar is zero, and the
    /// Router refuses with exactly `code`.
    function _assertRefusedEverywhere(Route memory r, uint256 amountIn, uint16 code, string memory tag) internal {
        assertFalse(quoter.previewRoute(r, 0).canExecute, string.concat(tag, ": view door says executable"));
        (, uint256 exactOut) = quoter.previewRouteExact(r, amountIn);
        assertEq(exactOut, 0, string.concat(tag, ": dry-run door promises an output"));
        vm.prank(user);
        vm.expectRevert(_rerr(code));
        router.swapExactIn(r, amountIn, 1, user, block.timestamp + 1);
    }

    // ───────────────────────── cleared Gate family -> RouterE(19) ─────────────────────────

    function test_ClearedGateFamily_BesideADeliveringLeg_IsRefusedAtEveryDoor() public {
        Leg memory g = _gateLeg(Y);
        gate.clearAdapter(FAM);
        Leg memory v = _v2(good, address(tokenA), X);
        _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), v, g, true)), X + Y, 19, "gate second");
        _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), g, v, true)), X + Y, 19, "gate first");
        _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), g, g, false)), Y, 19, "gate alone");
    }

    /// Control, and the other side of the mutant: the same leg while its family is live is
    /// executable at both doors, and the Router settles at least the promised scalar.
    function test_LiveGateFamily_BesideADeliveringLeg_StaysExecutableAndSettles() public {
        Route memory r = _route1(
            _hop(address(tokenA), address(tokenB), _v2(good, address(tokenA), X), _gateLeg(Y), true));
        assertTrue(quoter.previewRoute(r, 0).canExecute, "a live Gate leg is refused by the view door");
        (Route memory rx, uint256 exactOut) = quoter.previewRouteExact(r, X + Y);
        assertGt(exactOut, 0, "a live Gate leg is refused by the dry-run door");
        vm.prank(user);
        uint256 out = router.swapExactIn(rx, X + Y, exactOut, user, block.timestamp + 1);
        assertGe(out, exactOut, "the Router settles what the dry-run promised");
        assertEq(tokenB.balanceOf(user), out);
    }

    // ───────────────────────── impostor kind-9 pool -> RouterE(19) ─────────────────────────

    /// A real pair on the hop's tokens that only CLAIMS kind 9: it has no gate(), so the
    /// derivation misses and the Router refuses it. The claim is the calldata's, not an identity.
    function test_ImpostorGatePool_IsRefusedAtEveryDoor() public {
        Leg memory imp = _leg(address(other), address(tokenA), BPC.KIND_EXTERNAL, KEY, Y, Y);
        Leg memory v = _v2(good, address(tokenA), X);
        _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), v, imp, true)), X + Y, 19, "impostor second");
        _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), imp, v, true)), X + Y, 19, "impostor first");
        _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), imp, imp, false)), Y, 19, "impostor alone");
    }

    // ───────────────────────── kinds with no engine -> RouterE(8) ─────────────────────────

    function _noEngineKinds() internal pure returns (uint8[6] memory) {
        return [uint8(2), 3, 7, 10, 77, 255];
    }

    function test_NoEngineKinds_BesideADeliveringLeg_AreRefusedAtEveryDoor() public {
        uint8[6] memory kinds = _noEngineKinds();
        Leg memory v = _v2(good, address(tokenA), X);
        for (uint256 i; i < kinds.length; i++) {
            Leg memory bad = _leg(address(other), address(tokenA), kinds[i], 30, Y, Y);
            string memory tag = string.concat("kind ", vm.toString(kinds[i]));
            _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), v, bad, true)), X + Y, 8, tag);
            _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), bad, v, true)), X + Y, 8, tag);
            _assertRefusedEverywhere(_route1(_hop(address(tokenA), address(tokenB), bad, bad, false)), Y, 8, tag);
        }
    }

    /// The same vector one hop later: A -> B is clean, the mislabelled leg sits in B -> C.
    function test_NoEngineKinds_InTheSecondHop_AreRefusedAtEveryDoor() public {
        uint8[6] memory kinds = _noEngineKinds();
        Leg memory a = _v2(good, address(tokenA), X + Y);
        uint256 mid = a.expectedOut;
        for (uint256 i; i < kinds.length; i++) {
            Hop[] memory hops = new Hop[](2);
            hops[0] = _hop(address(tokenA), address(tokenB), a, a, false);
            hops[1] = _hop(address(tokenB), address(tokenC),
                _v2(bridge, address(tokenB), mid / 2),
                _leg(address(bridge2), address(tokenB), kinds[i], 30, mid - mid / 2, mid - mid / 2), true);
            _assertRefusedEverywhere(_wrap(hops), X + Y, 8, string.concat("hop 1 kind ", vm.toString(kinds[i])));
        }
    }

    /// Every kind the Router has an engine for keeps its verdict on the same pair. The kinds
    /// that read reserves settle; this pins that the refusal is by kind, not by this fixture.
    function test_Control_TheSamePairLabelledV2_IsExecutableAndSettles() public {
        Route memory r = _route1(_hop(address(tokenA), address(tokenB),
            _v2(good, address(tokenA), X), _v2(other, address(tokenA), Y), true));
        assertTrue(quoter.previewRoute(r, 0).canExecute);
        (Route memory rx, uint256 exactOut) = quoter.previewRouteExact(r, X + Y);
        assertGt(exactOut, 0);
        vm.prank(user);
        assertGe(router.swapExactIn(rx, X + Y, exactOut, user, block.timestamp + 1), exactOut);
    }

    /// Mirrored, not tightened: the four pool kinds the Router's dispatch has an engine for
    /// (written here by hand from `_execScaled`, not read from the table the mirror reads) are
    /// not refused by kind. Asked at the view door, which reads the leg's shape and never prices.
    function test_Control_EveryKindWithAPoolEngine_IsNotRefusedByKind() public view {
        uint8[4] memory kinds = [uint8(0), 1, 5, 6]; // V2, V3, Solidly, Algebra
        for (uint256 i; i < kinds.length; i++) {
            Route memory r = _route1(_hop(address(tokenA), address(tokenB), _v2(good, address(tokenA), X),
                _leg(address(other), address(tokenA), kinds[i], 30, Y, BPC.outV2(Y, R, R, 30)), true));
            assertTrue(quoter.previewRoute(r, 0).canExecute,
                string.concat("kind ", vm.toString(kinds[i]), ": refused by kind though the Router has an engine"));
        }
    }

    /// Mirrored, not tightened: `_execScaled` returns on a zero input BEFORE the dispatch, so a
    /// no-engine leg that carries nothing is a no-op at the Router. The preview may not refuse a
    /// route the Router fills.
    function test_Control_ZeroInputNoEngineLeg_IsANoOpAtTheRouter_AndNotRefused() public {
        uint8[6] memory kinds = _noEngineKinds();
        for (uint256 i; i < kinds.length; i++) {
            uint256 snap = vm.snapshotState();
            Route memory r = _route1(_hop(address(tokenA), address(tokenB),
                _v2(good, address(tokenA), X), _leg(address(other), address(tokenA), kinds[i], 30, 0, 0), true));
            assertTrue(quoter.previewRoute(r, 0).canExecute, "view door refuses a route the Router fills");
            (Route memory rx, uint256 exactOut) = quoter.previewRouteExact(r, X);
            assertGt(exactOut, 0, "dry-run door refuses a route the Router fills");
            vm.prank(user);
            assertGe(router.swapExactIn(rx, X, exactOut, user, block.timestamp + 1), exactOut);
            vm.revertToState(snap);
        }
    }
}
