// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract RFRWeth is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { this.mint(msg.sender, msg.value); }
}

// =============================================================================
//  Which fields of a caller's Route the Router reads, pinned.
//
//  A Route carries three kinds of field. The legs and the tokens say what to
//  execute. Three figures may move the floor, and only upward:
//  `route.singleOutFloor` (Router `_execute`, the `fotSeen == 0` arm),
//  `hop.expectedOut` on a hop with a leg the frame could not price (the
//  `hopBlind` base) and `leg.expectedOut` (the attested legs). The rest is
//  informational today: `totalOut`, `singleOut`, `expectedImpactBps`,
//  `confidenceWad`, `estGas`, `hasSurplus`, `isV4Bundle` and `hop.amountIn` have
//  no reader in the Router. That is a coincidence of the current code, not a
//  rule of the codec, so it is pinned here rather than relied on: a rewrite of
//  the doors that starts reading one of them turns these tests red.
//
//  Written at cb1d7d9. These are pins, not fixes: every test is GREEN on that
//  tree, and each one is paired with the mutant that turns it red
//  (.github/scripts/mutants.py, labels [morf-ACP1-*]):
//    - M1 the declared floor is never applied        -> singleOutFloor test;
//    - M2 the hop base is the caller's `totalOut`     -> informational test;
//    - M3 the hop figure raises a measured hop's base -> hop-figure test.
//  Oracles are balance deltas and recorded events, never a figure the Router
//  returns about itself.
// =============================================================================
contract RouteFieldReadersPinTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockERC20 tD;
    RFRWeth weth;
    MockV2Pair pAB;
    MockV2Pair pAB2;
    MockV2Pair pBC;
    MockV2Pair pAC;
    MockV2Pair pWC;
    MockV3Pool pAD;

    address user = address(0xBEEF);
    address constant RECIP = address(0xCAFE);
    address constant FEE1 = address(0xFEE1);
    address constant FEE2 = address(0xFEE2);
    uint256 constant R = 100_000e18;
    uint256 constant AMT = 1_000e18;
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = uint128(1e27);

    /// What one call did, read from the outside.
    struct Outcome {
        bool ok;
        bytes ret;
        uint256 got;    // the recipient's balance delta in the output token
        uint256 feeOut; // the treasuries' balance delta in the output token
        bytes32 books;  // every (holder, token) balance after the call, and the ETH balances
        bytes32 logs;   // every event the call emitted, in order
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), FEE1, FEE2);
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        tD = new MockERC20("D", "D");
        weth = new RFRWeth();
        router.setWeth(address(weth));
        hub.addBridge(address(tB));
        pAB = _pair(tA, tB);
        pAB2 = _pair(tA, tB);
        pBC = _pair(tB, tC);
        pAC = _pair(tA, tC);
        pWC = _pair(MockERC20(address(weth)), tC);
        pAD = new MockV3Pool(address(tA), address(tD), 3000);
        pAD.setState(Q96, LIQ);
        tD.mint(address(pAD), 1_000_000e18);
        tA.mint(user, 100_000e18);
        vm.deal(user, 100_000 ether);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _pair(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), R);
        y.mint(address(p), R);
        p.setReserves(uint112(R), uint112(R));
    }

    // Oracle for the declared figures: x*y=k with the 30 bps V2 fee, written here.
    function _outV2(uint256 amtIn) private pure returns (uint256) {
        uint256 inAfterFee = amtIn * 9970;
        return (inAfterFee * R) / (R * 10_000 + inAfterFee);
    }

    function _e5() private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5));
    }

    function _leg(MockV2Pair p, address tIn, uint256 amtIn) private view returns (Leg memory) {
        // Declared at 99 % of the oracle: an honest attestation with room for the protocol fee.
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amtIn,
            expectedOut: _outV2(amtIn) * 99 / 100, auxId: bytes32(0)});
    }

    function _wrap(Hop[] memory hs, uint256 out) private pure returns (Route memory) {
        return Route({hops: hs, totalOut: out, singleOut: out, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 1e18, estGas: 200_000, hasSurplus: false, isV4Bundle: false});
    }

    function _oneHop(MockV2Pair p, address tIn, address tOut) private view returns (Route memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = _leg(p, tIn, AMT);
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: AMT, expectedOut: ls[0].expectedOut, legs: ls});
        return _wrap(hs, ls[0].expectedOut);
    }

    /// A -> B split over two pairs, then B -> C: two hops, three legs, B a bridge.
    function _twoHop() private view returns (Route memory) {
        Leg[] memory l0 = new Leg[](2);
        l0[0] = _leg(pAB, address(tA), AMT / 2);
        l0[1] = _leg(pAB2, address(tA), AMT / 2);
        uint256 q0 = l0[0].expectedOut + l0[1].expectedOut;
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _leg(pBC, address(tB), q0);
        Hop[] memory hs = new Hop[](2);
        hs[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: AMT, expectedOut: q0, legs: l0});
        hs[1] = Hop({tokenIn: address(tB), tokenOut: address(tC), amountIn: q0, expectedOut: l1[0].expectedOut, legs: l1});
        return _wrap(hs, l1[0].expectedOut);
    }

    /// The honest routes, rebuilt fresh on every call (a memory Route is a reference):
    /// 0 one hop, fee on the input; 1 one hop into a bridge, fee on the output;
    /// 2 two hops with a split hop, fee on the bridge hop's input; 3 one hop from native ETH.
    function _routeOf(uint256 id) private view returns (Route memory r, bool native) {
        if (id == 0) return (_oneHop(pAC, address(tA), address(tC)), false);
        if (id == 1) return (_oneHop(pAB, address(tA), address(tB)), false);
        if (id == 2) return (_twoHop(), false);
        return (_oneHop(pWC, address(weth), address(tC)), true);
    }

    /// One blind hop A -> D: a concentrated pool whose frame quote is zero (liquidity() == 0)
    /// fills at full depth, its leg declares nothing, and the hop declares `x`.
    function _blindHop(uint256 x) private view returns (Route memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = Leg({pool: address(pAD), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: pAD.token0() == address(tA), stable: false, amountIn: AMT, expectedOut: 0,
            auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(tA), tokenOut: address(tD), amountIn: AMT, expectedOut: x, legs: ls});
        return _wrap(hs, 0);
    }

    function _books() private view returns (bytes32) {
        address[5] memory who = [user, RECIP, address(router), FEE1, FEE2];
        address[5] memory tok = [address(tA), address(tB), address(tC), address(tD), address(weth)];
        bytes memory acc = abi.encode(user.balance, address(router).balance);
        for (uint256 i; i < 5; ++i) {
            for (uint256 j; j < 5; ++j) acc = bytes.concat(acc, abi.encode(MockERC20(tok[j]).balanceOf(who[i])));
        }
        return keccak256(acc);
    }

    /// Run the route from a snapshot, read what it did, and put the world back.
    function _run(Route memory r, bool native) private returns (Outcome memory o) {
        uint256 snap = vm.snapshotState();
        MockERC20 tOut = MockERC20(r.hops[r.hops.length - 1].tokenOut);
        uint256 g0 = tOut.balanceOf(RECIP);
        uint256 f0 = tOut.balanceOf(FEE1) + tOut.balanceOf(FEE2);
        bytes memory data = native
            ? abi.encodeCall(BlazePhoenixRouter.swapExactInNative, (r, 1, RECIP, block.timestamp + 1))
            : abi.encodeCall(BlazePhoenixRouter.swapExactIn, (r, AMT, 1, RECIP, block.timestamp + 1));
        vm.recordLogs();
        vm.prank(user);
        (o.ok, o.ret) = address(router).call{value: native ? AMT : 0}(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        o.logs = keccak256(abi.encode(logs));
        o.got = tOut.balanceOf(RECIP) - g0;
        o.feeOut = tOut.balanceOf(FEE1) + tOut.balanceOf(FEE2) - f0;
        o.books = _books();
        vm.revertToState(snap);
    }

    function _assertSame(Outcome memory o, Outcome memory ref, string memory what) private pure {
        assertEq(o.ok, ref.ok, string.concat(what, ": settles or refuses alike"));
        assertEq(o.ret, ref.ret, string.concat(what, ": returns the same bytes"));
        assertEq(o.got, ref.got, string.concat(what, ": delivers the same amount"));
        assertEq(o.feeOut, ref.feeOut, string.concat(what, ": takes the same fee"));
        assertEq(o.books, ref.books, string.concat(what, ": leaves every balance the same"));
        assertEq(o.logs, ref.logs, string.concat(what, ": emits the same events"));
    }

    function _setInformational(Route memory r, uint256[8] memory f, bool s, bool b) private pure {
        r.totalOut = f[0];
        r.singleOut = f[1];
        r.expectedImpactBps = f[2];
        r.confidenceWad = f[3];
        r.estGas = f[4];
        r.hasSurplus = s;
        r.isV4Bundle = b;
        r.hops[0].amountIn = f[5];
        r.hops[r.hops.length - 1].amountIn = f[6];
    }

    /// @notice The seven informational route fields and `hop.amountIn` do not move the execution:
    ///         at 0, 1, the maximum and an arbitrary value, the same route delivers the same amount,
    ///         takes the same fee, leaves every balance and emits every event exactly as the honest
    ///         one. One and two hops, a split hop, fee on the input and on the output, ERC-20 and ETH.
    function test_informativeFields_doNotMoveExecution() public {
        uint256[4] memory vals = [uint256(0), 1, type(uint256).max, uint256(keccak256("RouteFieldReadersPin"))];
        for (uint256 id; id < 4; ++id) {
            (Route memory honest, bool native) = _routeOf(id);
            Outcome memory ref = _run(honest, native);
            assertTrue(ref.ok, "premise: the honest route settles");
            assertGt(ref.got, 0, "premise: and delivers");
            for (uint256 k; k < 4; ++k) {
                (Route memory r, ) = _routeOf(id);
                uint256 v = vals[k];
                _setInformational(r, [v, v, v, v, v, v, v, v], v % 2 == 1, v != 0);
                _assertSame(_run(r, native), ref, "informational field");
            }
        }
    }

    /// @notice The same, with every informational field drawn on its own.
    function testFuzz_informativeFields_doNotMoveExecution(uint256 id, uint256[8] memory f, bool s, bool b) public {
        id = bound(id, 0, 3);
        (Route memory honest, bool native) = _routeOf(id);
        Outcome memory ref = _run(honest, native);
        assertTrue(ref.ok, "premise: the honest route settles");
        (Route memory r, ) = _routeOf(id);
        _setInformational(r, f, s, b);
        _assertSame(_run(r, native), ref, "fuzzed informational fields");
    }

    /// @notice A declared `singleOutFloor` one wei above the measured output is refused by
    ///         RouterE(5), and the same floor at the measured output admits the same fill. The
    ///         measured output is what the Router compares: the recipient's delta plus what the
    ///         treasuries took in the output token (a single hop into a bridge pays on the output).
    function test_singleOutFloor_aboveMeasured_refused() public {
        for (uint256 id; id < 4; ++id) {
            (Route memory r0, bool native) = _routeOf(id);
            Outcome memory m = _run(r0, native);
            assertTrue(m.ok, "premise: with no declared floor the route settles");
            uint256 measured = m.got + m.feeOut;

            (Route memory at, ) = _routeOf(id);
            at.singleOutFloor = measured;
            Outcome memory a = _run(at, native);
            assertTrue(a.ok, "a declared floor equal to the measured output admits the fill");
            assertEq(a.got, m.got, "and does not move it");

            (Route memory above, ) = _routeOf(id);
            above.singleOutFloor = measured + 1;
            Outcome memory b = _run(above, native);
            assertFalse(b.ok, "one wei above the measured output is refused");
            assertEq(b.ret, _e5(), "by the floor's code, RouterE(5)");
        }
    }

    /// @notice `hop.expectedOut` is read only for a hop with a leg the frame could not price,
    ///         and there it only raises the floor. On measured hops (every route above) the hop
    ///         figure at 0, one wei over the honest figure and the maximum moves nothing; on a
    ///         blind hop, no figure anchors nothing, a figure under the fill leaves the fill
    ///         standing, and a figure over it is refused by RouterE(5).
    function test_hopExpectedOut_onlyRaisesBlindBase() public {
        for (uint256 id; id < 4; ++id) {
            (Route memory honest, bool native) = _routeOf(id);
            Outcome memory ref = _run(honest, native);
            assertTrue(ref.ok, "premise: the honest route settles");
            uint256[3] memory xs = [uint256(0), honest.hops[honest.hops.length - 1].expectedOut + 1, type(uint256).max];
            for (uint256 k; k < 3; ++k) {
                (Route memory r, ) = _routeOf(id);
                for (uint256 h; h < r.hops.length; ++h) r.hops[h].expectedOut = xs[k];
                _assertSame(_run(r, native), ref, "hop figure on a measured hop");
            }
        }

        pAD.setState(Q96, 0);         // the frame cannot price the pool ...
        pAD.setSwapLiquidity(LIQ);    // ... and it still fills at full depth
        Outcome memory z = _run(_blindHop(0), false);
        assertTrue(z.ok, "premise: the blind hop fills, and with no figure nothing anchors its floor");
        assertGt(z.got, 1, "premise: and delivers");

        Outcome memory low = _run(_blindHop(z.got / 2), false);
        assertTrue(low.ok, "a hop figure under the fill leaves the fill standing");
        assertEq(low.got, z.got, "and does not move it");

        Outcome memory high = _run(_blindHop(type(uint256).max), false);
        assertFalse(high.ok, "a hop figure over the fill raises the floor over it");
        assertEq(high.ret, _e5(), "refused by RouterE(5)");
    }
}
