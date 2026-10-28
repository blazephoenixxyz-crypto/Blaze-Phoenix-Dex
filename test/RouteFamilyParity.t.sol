// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// PAR (2026-10-27): ROUTE-FAMILY PARITY of the exact door with the Router.
// `Quoter.previewRouteExact(R, amountIn)` returns a rewritten route R' and a scalar exactOut, and
// two claims ride on them:
//  (i)  R'.legs are what the Router does when it executes R: each leg's amountIn is what its pool
//       receives and its expectedOut is what its pool pays. The loop of `_exact` funds the legs as
//       `_chargeHopFee` and `_hopScaleImpactAndQuote` do: the same fee base, rounded up, the same
//       hop-0 cap, the same floor split pro rata to the legs' sum;
//  (ii) exactOut == min(delivered(R), delivered(R')): the loop prices R as the Router runs it, and
//       `_fundedOut` prices R' as the Router runs it (`if (funded < exactOut) exactOut = funded`).
// The tests that pin each fix execute one route of one family. A test that executes only R' cannot
// see a broken loop, because the min() with `_fundedOut` hides it. So every case here executes BOTH
// routes from the same state, compares every pool's balance moves under R with R'.legs, executes
// R' with userMinOut = exactOut, and counts the Router's Fee events against the calendar.
// Families: A anchored (the bridge is hop 1's input), multi-leg; B exhaustion (no bridge, every
// hop pays on its input); C one hop into the bridge (the fee comes off the output); D Q773/T04
// (every hop declares an amountIn other than its legs' sum). A single hop that does not end in a
// bridge has no case here: the loop deducts its fee on the output and the Router on the input, so
// the scalar there is a floor and is not equal to delivery to the wei (`_exact`, the comment
// above `_fundedOut`'s call).
import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract RouteFamilyParityTest is Test {
    bytes32 constant FEE_TOPIC = keccak256("Fee(address,uint256,uint256,uint256)");

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    address user = address(0x5E4);

    // Anchored family: anch[0] -> anch[1] -> anch[2], and anch[1] is the only bridge.
    // Exhaustion family: exh[0] -> ... -> exh[3], and none of them is a bridge.
    MockERC20[3] anch;
    MockERC20[4] exh;
    MockV2Pair[3][2] anchPools; // [hop][leg]
    MockV2Pair[3][3] exhPools; // [hop][leg]

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );
        for (uint256 i; i < 3; i++) anch[i] = new MockERC20("ANCH", "ANCH");
        for (uint256 i; i < 4; i++) exh[i] = new MockERC20("EXH", "EXH");
        hub.setRoles(address(this), address(solver), address(quoter));
        for (uint256 h; h < 2; h++) {
            for (uint256 l; l < 3; l++) anchPools[h][l] = _pair(anch[h], anch[h + 1]);
        }
        for (uint256 h; h < 3; h++) {
            for (uint256 l; l < 3; l++) exhPools[h][l] = _pair(exh[h], exh[h + 1]);
        }
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(address(anch[1]));
        vm.startPrank(user);
        anch[0].approve(address(router), type(uint256).max);
        exh[0].approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _pair(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        Origin.wire(hub, address(p), address(x), address(y), BPC.KIND_V2, 30);
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(x), address(y), 1e18, 1e18, 1e24);
        }
    }

    function _fill(MockV2Pair p, MockERC20 x, MockERC20 y, uint256 rx, uint256 ry) private {
        x.mint(address(p), rx);
        y.mint(address(p), ry);
        (uint256 r0, uint256 r1) = address(x) < address(y) ? (rx, ry) : (ry, rx);
        p.setReserves(uint112(r0), uint112(r1));
    }

    function _pick(uint256 seed, bytes32 tag, uint256 lo, uint256 hi) private pure returns (uint256) {
        return lo + uint256(keccak256(abi.encode(seed, tag))) % (hi - lo + 1);
    }

    /// @dev The order against the hop-0 commitment: exactly it, under it (the Router scales the
    ///      legs down), or over it (T04: hop 0 pays its fee out of the surplus, then caps).
    function _order(uint256 seed, uint256 legSum) private pure returns (uint256) {
        uint256 mode = _pick(seed, "mode", 0, 2);
        if (mode == 0) return legSum;
        if (mode == 1) return _pick(seed, "under", legSum / 2, legSum - 1);
        return _pick(seed, "over", legSum + 1, 2 * legSum);
    }

    struct Ctx {
        bool anchored;
        uint256 seed;
        uint256 minLegs;
        uint256 sIn; // the hop input's units per unit of value, 1e18-scaled
        uint256 sOut; // the hop output's
        uint256 value; // the order, in value
    }

    /// @dev Draws one route of a family from `seed`, fills the pools it uses and mints the order
    ///      to the user. Prices are coherent along the path (one scale per token, each pool of a
    ///      hop within 5% of the others), depths are 1e21..1e24 of value and the order is at most
    ///      1/64 of the shallowest, so no leg moves its pool by more than about 1%. Leg weights
    ///      are 1..5 among at most three legs: no leg is under 1/11 of its hop, so none is priced
    ///      at zero on a non-final hop (RouterE(5) is a refusal, not a parity case).
    function _draw(bool anchored, uint256 nHops, uint256 minLegs, uint256 seed, bool declareOther)
        private returns (Route memory route, uint256 amountIn)
    {
        Ctx memory c = Ctx(anchored, seed, minLegs, _pick(seed, "scale", 1e17, 1e19), 0,
            _pick(seed, "value", 1e12, uint256(1e21) / 64));
        route.hops = new Hop[](nHops);
        for (uint256 h; h < nHops; h++) {
            c.sOut = _pick(seed, keccak256(abi.encode("scale", h + 1)), 1e17, 1e19);
            route.hops[h] = _drawHop(c, h);
            if (h == 0) amountIn = _order(seed, route.hops[h].amountIn);
            if (declareOther) route.hops[h].amountIn = _declared(seed, h, route.hops[h].amountIn);
            c.sIn = c.sOut;
        }
        (anchored ? anch[0] : exh[0]).mint(user, amountIn);
    }

    /// @dev A figure other than the legs' sum, anywhere from 1 to three times it.
    function _declared(uint256 seed, uint256 h, uint256 legSum) private pure returns (uint256 d) {
        d = _pick(seed, keccak256(abi.encode("declared", h)), 1, 3 * legSum);
        if (d == legSum) d += 1;
    }

    /// @dev One hop, its amountIn the legs' sum (as the Solver writes it).
    function _drawHop(Ctx memory c, uint256 h) private returns (Hop memory hop) {
        hop.tokenIn = address(c.anchored ? anch[h] : exh[h]);
        hop.tokenOut = address(c.anchored ? anch[h + 1] : exh[h + 1]);
        hop.expectedOut = 1;
        hop.legs = new Leg[](c.minLegs + _pick(c.seed, keccak256(abi.encode("legs", h)), 0, 3 - c.minLegs));
        uint256 wSum;
        for (uint256 l; l < hop.legs.length; l++) {
            hop.legs[l].amountIn = _pick(c.seed, keccak256(abi.encode("w", h, l)), 1, 5);
            wSum += hop.legs[l].amountIn;
        }
        // Hop 0 commits the order's legs; a later hop's legs are proportions only.
        uint256 unit = h == 0
            ? c.value * c.sIn / 1e18 / wSum
            : _pick(c.seed, keccak256(abi.encode("unit", h)), 1e3, 1e24);
        for (uint256 l; l < hop.legs.length; l++) {
            hop.legs[l] = _drawLeg(c, h, l, hop.tokenIn, hop.tokenOut, hop.legs[l].amountIn * unit);
            hop.amountIn += hop.legs[l].amountIn;
        }
    }

    function _drawLeg(Ctx memory c, uint256 h, uint256 l, address x, address y, uint256 weighted)
        private returns (Leg memory leg)
    {
        MockV2Pair p = c.anchored ? anchPools[h][l] : exhPools[h][l];
        uint256 depth = _pick(c.seed, keccak256(abi.encode("depth", h, l)), 1e21, 1e24);
        uint256 skew = _pick(c.seed, keccak256(abi.encode("skew", h, l)), 950, 1050);
        _fill(p, MockERC20(x), MockERC20(y), depth * c.sIn / 1e18, depth * c.sOut / 1e18 * skew / 1000);
        leg.pool = address(p);
        leg.kind = BPC.KIND_V2;
        leg.fee = 30;
        leg.zeroForOne = x < y;
        leg.amountIn = weighted + _pick(c.seed, keccak256(abi.encode("dust", h, l)), 0, 999);
        leg.expectedOut = 1;
    }

    /// @dev The calendar's regime, asserted and not assumed: if a fixture change moved a bridge,
    ///      these cases would test another family and must fail here instead.
    function _assertRegimes() private view {
        assertFalse(hub.isBridgeToken(address(anch[0])), "premise: anch[0] is not a bridge");
        assertTrue(hub.isBridgeToken(address(anch[1])), "premise: anch[1] is the bridge");
        assertFalse(hub.isBridgeToken(address(anch[2])), "premise: anch[2] is not a bridge");
        for (uint256 i; i < 4; i++) {
            assertFalse(hub.isBridgeToken(address(exh[i])), "premise: no exhaustion token is a bridge");
        }
    }

    function _poolBalances(Route memory r) private view returns (uint256[] memory b) {
        uint256 n;
        for (uint256 h; h < r.hops.length; h++) n += r.hops[h].legs.length;
        b = new uint256[](2 * n);
        uint256 k;
        for (uint256 h; h < r.hops.length; h++) {
            for (uint256 l; l < r.hops[h].legs.length; l++) {
                address p = r.hops[h].legs[l].pool;
                b[k++] = MockERC20(r.hops[h].tokenIn).balanceOf(p);
                b[k++] = MockERC20(r.hops[h].tokenOut).balanceOf(p);
            }
        }
    }

    /// @dev Claim (i): every leg of R' is the move its pool made when the Router executed R.
    function _assertLegsAreTheMoves(Route memory r, Route memory back, uint256[] memory pre)
        private view
    {
        assertEq(back.hops.length, r.hops.length, "R' keeps the hops");
        uint256 k;
        for (uint256 h; h < r.hops.length; h++) {
            assertEq(back.hops[h].legs.length, r.hops[h].legs.length, "R' keeps the legs");
            for (uint256 l; l < r.hops[h].legs.length; l++) {
                address p = r.hops[h].legs[l].pool;
                assertEq(back.hops[h].legs[l].pool, p, "R' keeps the pools in their order");
                uint256 got = MockERC20(r.hops[h].tokenIn).balanceOf(p) - pre[k++];
                uint256 paid = pre[k++] - MockERC20(r.hops[h].tokenOut).balanceOf(p);
                assertEq(back.hops[h].legs[l].amountIn, got,
                    "R' leg amountIn is what its pool received when the Router executed R");
                assertEq(back.hops[h].legs[l].expectedOut, paid,
                    "R' leg expectedOut is what its pool paid when the Router executed R");
            }
        }
    }

    /// @dev Exactly the calendar's charges, in order, each in the token it is charged in.
    function _assertFees(Vm.Log[] memory logs, address[] memory tokens) private view {
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics.length == 0
                || logs[i].topics[0] != FEE_TOPIC) continue;
            assertLt(n, tokens.length, "no Fee event beyond the calendar's charges");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), tokens[n],
                "each Fee event is in the token the calendar charges");
            n++;
        }
        assertEq(n, tokens.length, "one Fee event per charge of the calendar");
    }

    function _swap(Route memory r, uint256 amountIn, uint256 minOut, MockERC20 out)
        private returns (uint256)
    {
        uint256 before = out.balanceOf(user);
        uint256 deadline = block.timestamp;
        vm.prank(user);
        router.swapExactIn(r, amountIn, minOut, user, deadline);
        return out.balanceOf(user) - before;
    }

    /// @dev Both claims on one route, R and R' executed from the same state.
    function _parity(Route memory route, uint256 amountIn, address[] memory feeTokens) private {
        _assertRegimes();
        MockERC20 out = MockERC20(route.hops[route.hops.length - 1].tokenOut);
        (Route memory back, uint256 exactOut) = quoter.previewRouteExact(route, amountIn);
        assertGt(exactOut, 0, "premise: the exact door prices the route");
        uint256 snap = vm.snapshotState();

        // R as built, at the loosest floor: what the Router does with it.
        uint256[] memory pre = _poolBalances(route);
        vm.recordLogs();
        uint256 deliveredR = _swap(route, amountIn, 1, out);
        _assertFees(vm.getRecordedLogs(), feeTokens);
        _assertLegsAreTheMoves(route, back, pre);

        // R' as returned, at the floor it promised.
        vm.revertToState(snap);
        vm.recordLogs();
        uint256 deliveredBack = _swap(back, amountIn, exactOut, out);
        _assertFees(vm.getRecordedLogs(), feeTokens);

        assertEq(exactOut, deliveredR < deliveredBack ? deliveredR : deliveredBack,
            "exactOut is min(delivered(R), delivered(R'))");
    }

    function _one(address t) private pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = t;
    }

    /// @notice A, anchored and multi-leg (2-3 legs at each hop): hop 0 pays nothing, hop 1 pays once
    ///         on its input, in the bridge. The order sits under, at or over the hop-0 commitment.
    function testFuzz_A_AnchoredMultiLeg_LegsAreTheFillAndTheScalarIsTheMin(uint256 seed) public {
        (Route memory route, uint256 amountIn) = _draw(true, 2, 2, seed, false);
        _parity(route, amountIn, _one(address(anch[1])));
    }

    /// @notice B, exhaustion (no bridge, 2-3 hops of 1-3 legs): every hop pays on its own input,
    ///         and the loop charges each hop where the Router charges it.
    function testFuzz_B_Exhaustion_EveryHopPaysWhereTheRouterCharges(uint256 seed) public {
        uint256 nHops = 2 + _pick(seed, "hops", 0, 1);
        (Route memory route, uint256 amountIn) = _draw(false, nHops, 1, seed, false);
        address[] memory fees = new address[](nHops);
        for (uint256 h; h < nHops; h++) fees[h] = address(exh[h]);
        _parity(route, amountIn, fees);
    }

    /// @notice C, one hop into the bridge (1-3 legs): the fee comes off the output, rounded up, and
    ///         `_fundedOut` does not bound it, so the deduction itself must be the delivery.
    function testFuzz_C_OneHopIntoTheBridge_FeeOffTheOutputIsTheDelivery(uint256 seed) public {
        (Route memory route, uint256 amountIn) = _draw(true, 1, 1, seed, false);
        _parity(route, amountIn, _one(address(anch[1])));
    }

    /// @notice D, Q773/T04 multi-leg: every hop declares an amountIn other than its legs' sum
    ///         (2-3 legs at each hop). The Router never reads the declared figure, and the legs of
    ///         a later hop split what reached it by their own sum.
    function testFuzz_D_DeclaredHopAmountsAreNotTheCommitment(uint256 seed) public {
        (Route memory route, uint256 amountIn) = _draw(true, 2, 2, seed, true);
        _parity(route, amountIn, _one(address(anch[1])));
    }
}
