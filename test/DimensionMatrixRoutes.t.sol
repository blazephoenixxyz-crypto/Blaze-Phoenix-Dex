// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE ROUTE RULES, WALKED ACROSS EVERY DIMENSION THEY TOUCH.
//
//  A fix that holds in the cell its report named and fails one cell over is the
//  pattern behind most residuals this codebase has paid for: a guard read on the
//  anchor hop and not on hop 0, a door sealed and its sibling not. So the two
//  route rules of 2026-10-07 are asserted here over their whole matrix, not at
//  the reported point:
//
//   (1) leg state x hop position x route length. A leg with neither an
//       attestation nor an in-frame quote (blind) is refused on every hop but
//       the last; on the last hop it settles under the hop-level figure. An
//       attested leg and a quoted leg settle at every position.
//   (2) input re-entry x hop index. A route that takes its input token again at
//       any later hop is refused; a chain through distinct tokens, and a round
//       trip that only ENDS in the input token, settle.
//
//  The blind pool here fills honestly (full swap liquidity), so a refusal can
//  only come from the structural rule, never from a floor catching a bad fill.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract DimensionMatrixRoutesTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20[4] tk;

    address user = address(0xBEEF);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = uint128(1e27);
    uint256 constant AMT = 1_000e18;

    enum LegState { Quoted, Attested, Blind }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        for (uint256 i; i < 4; ++i) tk[i] = new MockERC20("T", "T");
        tk[0].mint(user, 100 * AMT);
        vm.prank(user);
        tk[0].approve(address(router), type(uint256).max);
    }

    // ── fixtures ────────────────────────────────────────────────────────────

    /// @dev A V3 pool on (x, y). `priced` false makes it report zero liquidity, so the
    ///      frame cannot quote it; it still swaps with full liquidity (an honest fill).
    function _pool(MockERC20 x, MockERC20 y, bool priced) internal returns (MockV3Pool p) {
        p = new MockV3Pool(address(x), address(y), 3000);
        p.setState(Q96, priced ? LIQ : 0);
        if (!priced) p.setSwapLiquidity(LIQ);
        x.mint(address(p), 1_000_000e18);
        y.mint(address(p), 1_000_000e18);
    }

    function _q(uint256 amt, address a, address b) internal pure returns (uint256) {
        return BPC.outV3(amt, Q96, LIQ, 3000, a < b, 0);
    }

    function _leg(address pool, address a, address b, uint256 amt, uint256 exp) internal pure returns (Leg memory) {
        return Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: a < b, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
    }

    /// @dev A chain of `n` hops tk[0] -> tk[1] -> ... ; hop `p` splits in two legs, the
    ///      second of which is in `state`; every other leg is quoted and attested.
    function _chain(uint256 n, uint256 p, LegState state) internal returns (Route memory r) {
        Hop[] memory hops = new Hop[](n);
        uint256 amt = AMT;
        for (uint256 h; h < n; ++h) {
            address a = address(tk[h]);
            address b = address(tk[h + 1]);
            uint256 whole = _q(amt, a, b);
            Leg[] memory legs;
            if (h == p) {
                legs = new Leg[](2);
                uint256 half = amt / 2;
                legs[0] = _leg(address(_pool(tk[h], tk[h + 1], true)), a, b, half, _q(half, a, b));
                MockV3Pool second = _pool(tk[h], tk[h + 1], state != LegState.Blind);
                uint256 exp = state == LegState.Quoted ? 0 : (state == LegState.Attested ? _q(amt - half, a, b) : 0);
                legs[1] = _leg(address(second), a, b, amt - half, exp);
            } else {
                legs = new Leg[](1);
                legs[0] = _leg(address(_pool(tk[h], tk[h + 1], true)), a, b, amt, whole);
            }
            hops[h] = Hop({tokenIn: a, tokenOut: b, amountIn: amt, expectedOut: whole, legs: legs});
            amt = whole;
        }
        r = Route({hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _swap(Route memory r) external returns (uint256) {
        vm.prank(user);
        return router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    function _e(uint16 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, c);
    }

    // ── (1) leg state x hop position x route length ─────────────────────────

    function test_Matrix_LegStateByHopPositionByRouteLength() public {
        uint256 cells;
        for (uint256 n = 1; n <= 3; ++n) {
            for (uint256 p; p < n; ++p) {
                for (uint8 s; s < 3; ++s) {
                    LegState st = LegState(s);
                    uint256 snap = vm.snapshotState();
                    Route memory r = _chain(n, p, st);
                    bool mustRefuse = st == LegState.Blind && p + 1 != n;
                    if (mustRefuse) {
                        vm.expectRevert(_e(5));
                        this._swap(r);
                    } else {
                        uint256 out = this._swap(r);
                        assertGt(out, 0, "a cell the rule allows did not settle");
                    }
                    vm.revertToState(snap);
                    ++cells;
                }
            }
        }
        assertEq(cells, 18, "the matrix is 6 (length, position) pairs x 3 leg states");
    }

    /// The cell that decides "last hop", not "a hop that makes the output": in A -> C -> B -> C
    /// hop 0 also produces the route's output token, but the floor's base is the last hop's,
    /// so a blind leg on hop 0 would be bounded by nothing. Refused.
    function test_Matrix_BlindLegOnAnEarlierHopThatAlsoMakesTheOutput() public {
        Hop[] memory hops = new Hop[](3);
        uint256 half = AMT / 2;
        address a = address(tk[0]);
        address c = address(tk[2]);
        address b = address(tk[1]);
        uint256 whole0 = _q(AMT, a, c);
        Leg[] memory l0 = new Leg[](2);
        l0[0] = _leg(address(_pool(tk[0], tk[2], true)), a, c, half, _q(half, a, c));
        l0[1] = _leg(address(_pool(tk[0], tk[2], false)), a, c, AMT - half, 0);   // blind
        hops[0] = Hop({tokenIn: a, tokenOut: c, amountIn: AMT, expectedOut: whole0, legs: l0});
        uint256 out1;
        (hops[1], out1) = _hop(tk[2], tk[1], whole0);
        uint256 out2;
        (hops[2], out2) = _hop(tk[1], tk[2], out1);
        Route memory r = Route({hops: hops, totalOut: out2, singleOut: out2, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        vm.expectRevert(_e(5));
        this._swap(r);
    }

    // ── (2) input re-entry x hop index ──────────────────────────────────────

    function _hop(MockERC20 x, MockERC20 y, uint256 amt) internal returns (Hop memory h, uint256 out) {
        out = _q(amt, address(x), address(y));
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(address(_pool(x, y, true)), address(x), address(y), amt, out);
        h = Hop({tokenIn: address(x), tokenOut: address(y), amountIn: amt, expectedOut: out, legs: legs});
    }

    function _path(uint256[] memory ix) internal returns (Route memory r) {
        Hop[] memory hops = new Hop[](ix.length - 1);
        uint256 amt = AMT;
        for (uint256 h; h + 1 < ix.length; ++h) (hops[h], amt) = _hop(tk[ix[h]], tk[ix[h + 1]], amt);
        r = Route({hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _ix(uint256 a, uint256 b, uint256 c, uint256 d, uint256 len) internal pure returns (uint256[] memory x) {
        x = new uint256[](len);
        x[0] = a; x[1] = b;
        if (len > 2) x[2] = c;
        if (len > 3) x[3] = d;
    }

    function test_Matrix_InputReentryByHopIndex() public {
        // Re-entry of the input at hop 2 (A -> B -> A -> C): refused.
        Route memory back = _path(_ix(0, 1, 0, 2, 4));
        vm.expectRevert(_e(3));
        this._swap(back);

        // Re-entry at hop 2 of a longer detour (A -> B -> C -> A is a round trip, it only ENDS in A): settles.
        uint256 snap = vm.snapshotState();
        assertGt(this._swap(_path(_ix(0, 1, 2, 0, 4))), 0, "a route that only ends in its input settles");
        vm.revertToState(snap);

        // A two-hop round trip (A -> B -> A): settles.
        snap = vm.snapshotState();
        assertGt(this._swap(_path(_ix(0, 1, 0, 0, 3))), 0, "a round trip settles");
        vm.revertToState(snap);

        // A chain through distinct tokens (A -> B -> C -> D): settles.
        assertGt(this._swap(_path(_ix(0, 1, 2, 3, 4))), 0, "a chain through distinct tokens settles");
    }
}
