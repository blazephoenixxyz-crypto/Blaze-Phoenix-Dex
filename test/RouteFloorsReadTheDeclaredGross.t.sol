// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The route floors read the declared gross (2026-11-16). Red at 969bcc6.
//  The protocol floor and the caller's `singleOutFloor` price GROSS amounts (the last hop's
//  in-frame quote, the Solver's attested output). Until this change the Router compared them
//  with `amountOut`, the NET it measured after the tokenOut's own transfer tax, so a buy of a
//  token that taxes the venue->Router transfer was refused once the tax passed the floor's
//  slack, and a one-wei transfer remainder (stETH-like) failed a `singleOutFloor` set at
//  the gross. They now read `outCap`: what the venues declared they paid in tokenOut, net of
//  what the route took back out, which on an untaxed token IS `amountOut`. The per-leg floor and
//  the hop budget stay on the measured delta against the attestation, the whole last hop is held
//  on the measured output against `LEG_FLOOR_BPS` of its figure (the one floor an output tax
//  moves), and `userMinOut` stays on what lands at the recipient.
//  Oracle: the Router's own execution at tax 0 (every edge found by bisection over the Router),
//  the gross read at the venues (what left the pools' tokenOut balances), and the TOKEN's
//  arithmetic for the net (`g - g * bps / 1e4`, floor), never the Router's.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// A token whose every transfer delivers `shortWei` less than it moves (the share-rounding
/// remainder of a rebasing token such as stETH), and no more.
contract ShortWeiToken {
    string public name = "S";
    string public symbol = "S";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public shortWei;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setShortWei(uint256 s) external { shortWei = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }
    function _move(address f, address to, uint256 a) private {
        balanceOf[f] -= a;
        balanceOf[to] += a > shortWei ? a - shortWei : 0;
    }
}

contract RouteFloorsReadTheDeclaredGrossTest is Test {
    uint128 constant DEEP_L = 1e30;
    uint256 constant ORDER = 1e18 + 7;
    /// The untaxed edge of `ORDER` on one V3 leg (fee 500, band 1e30), measured at 969bcc6.
    uint256 constant E0 = 23552594165924258899;

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    address recipient = makeAddr("recipient");

    MockV3Pool[] legs;      // hop 0 legs, tA -> tOut, the knob (fill liquidity) moves all of them
    address tOut;
    uint256 singleOutFloor; // 0: 1
    uint256 minOut;         // 0: 1
    uint256[] lastPaid;     // what each leg's venue paid on the last `_at`, read at the venue

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2"));
        hub.setRoles(address(router), address(solver), address(this));
    }

    // ------------------------------------------------------------------ fixtures

    function _legs(uint256 n, address out) internal {
        delete legs;
        tOut = out;
        singleOutFloor = 0;
        minOut = 0;
        for (uint256 i; i < n; ++i) {
            MockV3Pool p = new MockV3Pool(address(tA), out, 500);
            p.setState(uint160(BPC.Q96), DEEP_L);
            tA.mint(address(p), 1 << 125);
            MockERC20(out).mint(address(p), 1 << 125);
            hub.seedPool(address(p), BPC.KIND_V3, 500, address(0), address(tA), out);
            legs.push(p);
        }
    }

    /// What `p` pays (gross) for `amt` from the liquidity it fills with: the mock's own math.
    function _pays(MockV3Pool p, uint256 amt) internal view returns (uint256) {
        uint128 l = p.swapLiquidity() != 0 ? p.swapLiquidity() : p.liquidity();
        return BPC.outV3(amt, p.sqrtPriceX96(), l, p.fee(), p.token0() == address(tA), 0);
    }

    /// The plan: `order` split evenly over the legs, each attested at what it pays (gross).
    function _build(uint256 knob, uint256 order) internal returns (Route memory r, uint256 pay, uint256 gross) {
        uint256 n = legs.length;
        Leg[] memory ls = new Leg[](n);
        for (uint256 i; i < n; ++i) {
            legs[i].setSwapLiquidity(uint128(knob));
            uint256 a = i + 1 == n ? order - (order / n) * (n - 1) : order / n;
            uint256 g = _pays(legs[i], a);
            gross += g;
            ls[i] = Leg({
                pool: address(legs[i]), hooks: address(0), kind: BPC.KIND_V3, fee: 500, tickSpacing: 1,
                zeroForOne: legs[i].token0() == address(tA), stable: false, amountIn: a, expectedOut: g,
                auxId: bytes32(0)
            });
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: tOut, amountIn: order, expectedOut: gross, legs: ls});
        r = Route({hops: hops, totalOut: gross, singleOut: 0, singleOutFloor: singleOutFloor == 0 ? 1 : singleOutFloor,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        pay = hub.isBridgeToken(tOut) ? order : order + BPC.mulDivUp(order, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// One swap at `knob`, state reverted after: settled, the revert data, what the recipient got,
    /// and the gross the venues paid, read at the venues (the protocol fee leaves the input first,
    /// so the venues fill less than `order`; the pools' own balances say how much they paid).
    function _at(uint256 knob, uint256 order)
        internal returns (bool settled, bytes memory ret, uint256 delivered, uint256 gross)
    {
        uint256 snap = vm.snapshotState();
        Route memory r;
        uint256 pay;
        (r, pay, ) = _build(knob, order);
        uint256[] memory p0 = new uint256[](legs.length);
        for (uint256 i; i < legs.length; ++i) p0[i] = MockERC20(tOut).balanceOf(address(legs[i]));
        bytes memory data = abi.encodeCall(
            router.swapExactIn, (r, order, minOut == 0 ? 1 : minOut, recipient, block.timestamp + 1));
        tA.mint(address(this), pay);
        tA.approve(address(router), pay);
        uint256 b0 = MockERC20(tOut).balanceOf(recipient);
        (settled, ret) = address(router).call(data);
        delivered = MockERC20(tOut).balanceOf(recipient) - b0;
        for (uint256 i; i < legs.length; ++i) {
            p0[i] -= MockERC20(tOut).balanceOf(address(legs[i]));
            gross += p0[i];
        }
        vm.revertToState(snap);
        delete lastPaid;
        for (uint256 i; i < p0.length; ++i) lastPaid.push(p0[i]);
    }

    function _assertRouterE(bytes memory ret, uint256 code, string memory tag) internal pure {
        assertEq(ret.length, 36, string.concat(tag, ": refused with a RouterE word"));
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, string.concat(tag, ": refused as RouterE"));
        bytes memory t = new bytes(32);
        for (uint256 i; i < 32; ++i) t[i] = ret[i + 4];
        assertEq(abi.decode(t, (uint256)), code, string.concat(tag, ": with its code"));
    }

    /// The least knob the Router settles at in [lo, hi]: `lo` refused (RouterE(5)), `hi` settled.
    function _edge(uint256 lo, uint256 hi, uint256 order, string memory tag) internal returns (uint256) {
        (bool sLo, bytes memory rLo, , ) = _at(lo, order);
        assertFalse(sLo, string.concat(tag, ": premise, refused at the low end"));
        _assertRouterE(rLo, 5, string.concat(tag, " low end"));
        (bool sHi, bytes memory rHi, , ) = _at(hi, order);
        assertTrue(sHi, string.concat(tag, ": premise, settled at the high end: ", vm.toString(rHi)));
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            (bool s, , , ) = _at(mid, order);
            if (s) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function _net(uint256 g, uint256 bps) internal pure returns (uint256) {
        return g - g * bps / 10_000;
    }

    /// The per-leg share (`LEG_FLOOR_BPS`), rounded up. Literal on purpose: the oracle does not
    /// read the constant under test.
    function _legShare(uint256 x) internal pure returns (uint256) {
        return (x * 8_000 + 9_999) / 10_000;
    }

    /// The last hop's figure for `order`, read at the venue: untaxed, filling with the liquidity
    /// it quotes with, the venue pays what the Router quotes in frame.
    function _figure(uint256 order) internal returns (uint256 h) {
        bool s;
        (s, , , h) = _at(DEEP_L, order);
        assertTrue(s, "premise: the deep fill settles untaxed");
    }

    /// What lands at the recipient under `bps`, by the token's arithmetic: each venue's transfer
    /// to the Router is taxed on its own, then the Router's single transfer to the recipient.
    function _landed(uint256 bps) internal view returns (uint256 atRouter) {
        for (uint256 i; i < lastPaid.length; ++i) atRouter += _net(lastPaid[i], bps);
        return _net(atRouter, bps);
    }

    /// Under `bps` on tOut the Router settles at the untaxed edge `e0` and refuses RouterE(5)
    /// at `e0 - 1`; the recipient gets the token's net of the token's net.
    function _settlesAtTheUntaxedEdge(uint256 e0, uint256 order, uint16 bps, string memory tag) internal {
        MockERC20(tOut).setFeeOnTransferBps(bps);
        (bool s, bytes memory ret, uint256 d, ) = _at(e0, order);
        assertTrue(s, string.concat(tag, ": settles at the untaxed edge: ", vm.toString(ret)));
        assertEq(d, _landed(bps), string.concat(tag, ": the recipient gets the token's net"));
        (s, ret, , ) = _at(e0 - 1, order);
        assertFalse(s, string.concat(tag, ": refused one knob under it"));
        _assertRouterE(ret, 5, string.concat(tag, " edge-1"));
        MockERC20(tOut).setFeeOnTransferBps(0);
    }

    // ------------------------------------------------------------------ F1

    /// Red at 969bcc6: under any output tax the Router refused RouterE(5) at the untaxed edge
    /// (the floor read the net). The gross a venue pays at a knob does not depend on the tax,
    /// so neither does the edge, while the net at that edge clears the per-leg share of the
    /// hop's figure.
    function test_UnderAnOutputTax_TheRoutersEdgeIsTheUntaxedEdge() public {
        _legs(1, address(tB));
        uint16[6] memory taxes = [uint16(1), 100, 390, 410, 1000, 1600];
        uint256[3] memory orders = [uint256(1e15), ORDER, 1e21];
        for (uint256 o; o < 3; ++o) {
            uint256 order = orders[o];
            string memory ot = string.concat("order ", vm.toString(order));
            uint256 e0 = _edge(order, order * 99, order, string.concat(ot, " tax 0"));
            uint256 share = _legShare(_figure(order));
            (, , , uint256 g0) = _at(e0, order);
            for (uint256 i; i < 6; ++i) {
                string memory tag = string.concat(ot, " tax bps ", vm.toString(taxes[i]));
                assertGe(_net(g0, taxes[i]), share, string.concat(tag, ": premise, the net at the untaxed edge clears the per-leg share"));
                _settlesAtTheUntaxedEdge(e0, order, taxes[i], tag);
            }
        }
    }

    /// Red at 64aa218 (it settled at the untaxed edge). Past that slack the tax moves the edge,
    /// to the last hop's measured floor: the least fill whose net at the Router is the per-leg
    /// share of the hop's figure. One knob under it the route floors are still met (it settles
    /// untaxed) and the net is short of the share.
    function test_UnderAnOutputTaxPastTheSlack_TheEdgeIsTheMeasuredShare() public {
        _legs(1, address(tB));
        uint16[3] memory taxes = [uint16(1800), 1900, 1999];
        uint256[3] memory orders = [uint256(1e15), ORDER, 1e21];
        for (uint256 o; o < 3; ++o) {
            uint256 order = orders[o];
            uint256 e0 = _edge(order, order * 99, order, "tax 0");
            uint256 share = _legShare(_figure(order));
            for (uint256 i; i < 3; ++i) _edgeIsTheMeasuredShare(e0, order, share, taxes[i]);
        }
    }

    /// Under `bps` the edge moves past `e0` to the least knob whose net reaches `share`.
    function _edgeIsTheMeasuredShare(uint256 e0, uint256 order, uint256 share, uint16 bps) private {
        string memory tag = string.concat("order ", vm.toString(order), " tax bps ", vm.toString(bps));
        tB.setFeeOnTransferBps(bps);
        uint256 eM = _edge(e0, order * 1e6, order, tag);
        tB.setFeeOnTransferBps(0);
        (bool sHi, , , uint256 gHi) = _at(eM, order);
        (bool sLo, , , uint256 gLo) = _at(eM - 1, order);
        assertTrue(sHi && sLo, string.concat(tag, ": untaxed, both sides of the edge settle"));
        assertGe(_net(gHi, bps), share, string.concat(tag, ": at the edge the net reaches the share"));
        assertLt(_net(gLo, bps), share, string.concat(tag, ": one knob under it the net is short"));
    }

    // ------------------------------------------------------------------ F4

    /// Control, green at 969bcc6 by design: an untaxed output settles exactly as before, at the
    /// edge measured before the change, and the recipient gets every wei the venue paid.
    function test_AnUntaxedOutputSettlesAsBefore() public {
        _legs(1, address(tB));
        uint256 e0 = _edge(ORDER, ORDER * 99, ORDER, "tax 0");
        assertEq(e0, E0, "the untaxed edge, measured at 969bcc6");
        (bool s, , uint256 d, uint256 g) = _at(e0, ORDER);
        assertTrue(s, "settles at its edge");
        assertEq(d, g, "the recipient gets the gross");
        (bool s1, bytes memory r1, , ) = _at(e0 - 1, ORDER);
        assertFalse(s1, "refused one knob under it");
        _assertRouterE(r1, 5, "tax 0 edge-1");
    }

    // ------------------------------------------------------------------ F3

    /// Red at 969bcc6 (the `singleOutFloor = G` arm): a token that delivers one or two wei less
    /// than it moves, `singleOutFloor` set at the gross G the venue pays. The floor is gross, so
    /// it is read against the gross: G settles, G + 1 is refused (the caller's floor still binds).
    function test_AOneWeiShortfallKeepsTheCallersSingleOutFloor() public {
        ShortWeiToken s = new ShortWeiToken();
        for (uint256 w = 1; w <= 2; ++w) {
            s.setShortWei(w);
            _legs(1, address(s));
            (, , , uint256 g) = _at(DEEP_L, ORDER);
            singleOutFloor = g;
            (bool ok, bytes memory ret, uint256 d, ) = _at(DEEP_L, ORDER);
            string memory tag = string.concat("short wei ", vm.toString(w));
            assertTrue(ok, string.concat(tag, ": settles at singleOutFloor = gross: ", vm.toString(ret)));
            assertEq(d, g - 2 * w, string.concat(tag, ": two transfers, each short"));
            singleOutFloor = g + 1;
            (ok, ret, , ) = _at(DEEP_L, ORDER);
            assertFalse(ok, string.concat(tag, ": refused at singleOutFloor = gross + 1"));
            _assertRouterE(ret, 5, string.concat(tag, " gross + 1"));
        }
    }

    // ------------------------------------------------------------------ F6

    /// Red at 969bcc6: an output tax moves no route floor. The route settles under the tax where
    /// it settles untaxed and the net at the Router clears the last hop's measured floor (the
    /// per-leg share of its figure). The oracle is the same Router at tax 0, the gross read at
    /// the venue and the token's arithmetic.
    function testFuzz_TheOutputTaxMovesNoRouteFloor(uint16 bps, uint256 knob) public {
        bps = uint16(bound(bps, 1, 1999));
        knob = bound(knob, E0 / 2, E0 * 2);
        _legs(1, address(tB));
        uint256 share = _legShare(_figure(ORDER));
        (bool s0, , , uint256 g0) = _at(knob, ORDER);
        tB.setFeeOnTransferBps(bps);
        (bool s, bytes memory ret, uint256 d, ) = _at(knob, ORDER);
        assertEq(s, s0 && _net(g0, bps) >= share, "settles under the tax where it settles untaxed and the net clears the per-leg share");
        if (s) assertEq(d, _landed(bps), "the recipient gets the token's net");
        else _assertRouterE(ret, 5, "refused");
    }

    // ------------------------------------------------------------------ F7

    /// Red at 969bcc6: parallel taxed legs. Each leg's gross is summed, nothing compounds, so 2
    /// legs at 500 bps and 4 legs at 400 bps (under the hop budget, (BPS - `LEG_FLOOR_BPS`) / L)
    /// settle at the untaxed edge.
    function test_ParallelTaxedLegsAreNotOverDiscounted() public {
        uint256[2] memory ns = [uint256(2), 4];
        uint16[2] memory taxes = [uint16(500), 400];
        for (uint256 i; i < 2; ++i) {
            _legs(ns[i], address(tB));
            string memory tag = string.concat(vm.toString(ns[i]), " legs");
            uint256 e0 = _edge(ORDER, ORDER * 99, ORDER, string.concat(tag, " tax 0"));
            _settlesAtTheUntaxedEdge(e0, ORDER, taxes[i], string.concat(tag, " tax bps ", vm.toString(taxes[i])));
        }
    }

    // ------------------------------------------------------------------ F9a, F9b (pins)

    /// Pin, green at 969bcc6 by design (KNOWN_ISSUES): a tax over the per-leg floor (`LEG_FLOOR_BPS`) is a
    /// shortfall against the attestation, which a venue's word does not move. Refused, fill deep.
    function test_OutputTaxAboveTheLegFloorIsStillRefused() public {
        _legs(1, address(tB));
        tB.setFeeOnTransferBps(2500);
        (bool s, bytes memory ret, , ) = _at(DEEP_L, ORDER);
        assertFalse(s, "2500 bps on one leg refused");
        _assertRouterE(ret, 5, "2500 bps one leg");
    }

    /// Pin, green at 969bcc6 by design (KNOWN_ISSUES): over the hop budget ((BPS - `LEG_FLOOR_BPS`) / L), 600 bps on
    /// four legs is refused though each leg clears its own floor.
    function test_OutputTaxAboveTheHopBudgetIsStillRefused() public {
        _legs(4, address(tB));
        tB.setFeeOnTransferBps(600);
        (bool s, bytes memory ret, , ) = _at(DEEP_L, ORDER);
        assertFalse(s, "600 bps on four legs refused");
        _assertRouterE(ret, 5, "600 bps four legs");
    }

    // ------------------------------------------------------------------ F10 (pin)

    /// Pin, green at 969bcc6 by design (KNOWN_ISSUES): `userMinOut` is read on what lands. A
    /// token taxing both transfers: the gross as `userMinOut` is refused; the delivered amount,
    /// from the token's arithmetic, settles; one wei over it is refused.
    function test_TheUsersMinimumIsReadOnWhatLands() public {
        _legs(1, address(tB));
        tB.setFeeOnTransferBps(100);
        (bool s0, , , uint256 g) = _at(DEEP_L, ORDER);
        assertTrue(s0, "premise: settles at userMinOut 1");
        uint256 d = _landed(100);
        minOut = g;
        (bool s, bytes memory ret, , ) = _at(DEEP_L, ORDER);
        assertFalse(s, "userMinOut at the gross refused");
        _assertRouterE(ret, 5, "userMinOut = gross");
        minOut = d;
        uint256 got;
        (s, ret, got, ) = _at(DEEP_L, ORDER);
        assertTrue(s, string.concat("userMinOut at the delivered amount settles: ", vm.toString(ret)));
        assertEq(got, d, "delivered, by the token's arithmetic");
        minOut = d + 1;
        (s, ret, , ) = _at(DEEP_L, ORDER);
        assertFalse(s, "one wei over the delivered amount refused");
        _assertRouterE(ret, 5, "userMinOut = delivered + 1");
    }
}
