// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  P2 - the pool's identity is derived, the token's is not: a hostile-TOKEN
//  matrix crossed with venue kinds and doors.
//
//  The single cells (FoT on one kind, a donation on one door) have their own
//  tests. This file crosses them: input/output token pathologies x the venue
//  kinds that execute locally (V2, Solidly, V3, V4, kind-9 Gate standing in for
//  Curve NG / Balancer) x the doors (swapExactIn, swapExactInWithPermit2,
//  swapBestExactIn). The Router holds a foreign balance of BOTH tokens in every
//  cell, so "nothing left on the Router" and "nothing foreign leaves it" are
//  measured, not assumed.
//
//  One rule per cell: the swap is refused (user untouched), or it settles with
//    - delivered == the recipient's balance delta, delivered >= userMinOut;
//    - the fee measured at the treasuries is at most 28 bps of what was ASKED
//      (the pull is capped at the ask, #45) and, on a plain/FoT input, at least
//      28 bps of what the Router MEASURED, net of the token's own tax;
//    - the Router's foreign balance of tokenIn is never spent (in SHARES, so a
//      rebase cannot hide it) and, on a non-rebasing token, it holds exactly its
//      foreign balance of each token afterwards.
//  Outcomes print as `CELL <row> <kind> <door> <outcome>`.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {MockV4ManagerNative} from "./RouterV4NativeEth.t.sol";
import {BlazePhoenixGate} from "../src/BlazePhoenixGate.sol";
import {MockGateVenue, MockGateRegistry, MockGateAdapter} from "./mocks/MockGateAdapters.sol";
import {Outcomes} from "./regime/Outcomes.sol";

contract P2_HostileTokenMatrixTest is Test {
    enum Row { PLAIN, FOT1, REB_UP, REB_DN, FOT_REB_UP, DEC6, DEC24, OUT_FOT1, OUT_BRIDGE_FOT1, DONATED_FOT1, IN_BRIDGE_FOT1 }
    enum Kind { V2, SOLIDLY, V3, V4, EXT }
    enum Door { EXACT, PERMIT2, BEST }
    uint256 constant NROWS = 11;

    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    address user = address(0xBEEF);
    address recipient = address(0xCAFE);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = 1e27;
    uint24 constant FEE4 = 500;
    int24 constant TS4 = 10;
    uint24 constant GKEY = uint24(uint256(1) << 16 | 1);

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockV4ManagerNative mgr;
    MockPermit2 p2;
    PathologicalERC20 tIn;
    PathologicalERC20 tOut;
    address venue;
    uint8 kind;
    uint24 fee;
    int24 ts;
    uint256 amt;
    uint256 depthIn;
    uint256 depthOut;
    uint256 foreignShIn;
    uint256 foreignOut;
    bool feeInOut;

    // ─── counters, printed at the end of each test ───
    uint256 nSettled; uint256 nOurs; uint256 nForeign;

    function _rowName(Row r) private pure returns (string memory) {
        string[11] memory n = ["PLAIN", "FOT1", "REB_UP", "REB_DN", "FOT_REB_UP", "DEC6", "DEC24", "OUT_FOT1",
                               "OUT_BRIDGE_FOT1", "DONATED_FOT1", "IN_BRIDGE_FOT1"];
        return n[uint256(r)];
    }
    function _kindName(Kind k) private pure returns (string memory) {
        string[5] memory n = ["V2", "SOLIDLY", "V3", "V4", "EXT"];
        return n[uint256(k)];
    }
    function _doorName(Door d) private pure returns (string memory) {
        string[3] memory n = ["EXACT", "PERMIT2", "BEST"];
        return n[uint256(d)];
    }
    function _rebases(Row r) private pure returns (bool) {
        return r == Row.REB_UP || r == Row.REB_DN || r == Row.FOT_REB_UP;
    }
    function _inFotBps(Row r) private pure returns (uint256) {
        return (r == Row.FOT1 || r == Row.FOT_REB_UP || r == Row.DONATED_FOT1 || r == Row.IN_BRIDGE_FOT1) ? 100 : 0;
    }

    function _stack() private {
        mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        p2 = new MockPermit2();
        router.setPermit2(address(p2));
    }

    function _tokens(Row r) private {
        uint8 dIn = r == Row.DEC6 ? 6 : (r == Row.DEC24 ? 24 : 18);
        tIn = new PathologicalERC20("IN", "IN", dIn);
        tOut = new PathologicalERC20("OUT", "OUT", 18);
        amt = 1_000 * 10 ** dIn;
        depthIn = 1_000_000 * 10 ** dIn;
        // V3/V4/Gate price 1:1 in raw units: the output side must out-hold the input side in raw
        depthOut = 1_000_000e18 > depthIn ? 1_000_000e18 : depthIn;
        uint256 fin = _inFotBps(r);
        if (fin != 0) tIn.setFeeOnTransferBps(uint16(fin));
        if (r == Row.OUT_FOT1 || r == Row.OUT_BRIDGE_FOT1) tOut.setFeeOnTransferBps(100);
        if (r == Row.REB_UP || r == Row.FOT_REB_UP) tIn.setRebaseOnTransferTo(address(router), 11, 10);
        if (r == Row.REB_DN) tIn.setRebaseOnTransferTo(address(router), 9, 10);
        if (r == Row.OUT_BRIDGE_FOT1) hub.addBridge(address(tOut));
        if (r == Row.IN_BRIDGE_FOT1) hub.addBridge(address(tIn));
        feeInOut = r == Row.OUT_BRIDGE_FOT1;
    }

    function _venue(Kind k, Row r) private {
        if (k == Kind.V2 || k == Kind.SOLIDLY) {
            if (k == Kind.V2) { venue = address(new MockV2Pair(address(tIn), address(tOut))); kind = BPC.KIND_V2; }
            else { venue = address(new MockSolidlyPair(address(tIn), address(tOut), false)); kind = BPC.KIND_SOLIDLY; }
            fee = 30; ts = 0;
            (uint112 r0, uint112 r1) = address(tIn) < address(tOut)
                ? (uint112(depthIn), uint112(depthOut)) : (uint112(depthOut), uint112(depthIn));
            MockV2Pair(venue).setReserves(r0, r1);
            Origin.wire(hub, venue, address(tIn), address(tOut), kind, fee, false);
        } else if (k == Kind.V3) {
            MockV3Pool p = new MockV3Pool(address(tIn), address(tOut), 3000);
            p.setState(Q96, LIQ);
            venue = address(p); kind = BPC.KIND_V3; fee = 3000; ts = 60;
            Origin.wire(hub, venue, address(tIn), address(tOut), kind, fee, false);
        } else if (k == Kind.V4) {
            bytes32 pid = _pid();
            bytes32 base = keccak256(abi.encode(pid, uint256(6)));
            mgr.setSlot(base, bytes32(uint256(Q96)));
            mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
            venue = address(mgr); kind = BPC.KIND_V4; fee = FEE4; ts = TS4;
        } else {
            BlazePhoenixGate gate = new BlazePhoenixGate(address(this));
            MockGateRegistry reg = new MockGateRegistry();
            MockGateVenue gv = new MockGateVenue(address(tIn), address(tOut));
            reg.add(address(gv));
            tIn.mint(address(gv), depthIn);
            tOut.mint(address(gv), depthOut);
            gv.sync();
            MockGateAdapter adapter = new MockGateAdapter(gate, reg);
            gate.proposeAdapter(1, address(adapter));
            vm.warp(block.timestamp + gate.ADAPTER_DELAY());
            gate.acceptAdapter(1);
            venue = gate.create(address(tIn), address(tOut), GKEY, abi.encode(address(gv)));
            uint24[] memory fees = new uint24[](1);
            fees[0] = GKEY;
            hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0));
            kind = BPC.KIND_EXTERNAL; fee = GKEY; ts = 0;
            return;
        }
        address holder = k == Kind.V4 ? address(mgr) : venue;
        tIn.mint(holder, depthIn);
        tOut.mint(holder, depthOut);
        if (r == Row.DONATED_FOT1) tIn.mint(holder, amt);   // a balance above the reserve the pool reports
    }

    function _pid() private view returns (bytes32) {
        (address c0, address c1) = address(tIn) < address(tOut) ? (address(tIn), address(tOut)) : (address(tOut), address(tIn));
        return BPC.computeV4PoolId(c0, c1, FEE4, TS4, address(0));
    }

    function _route() private view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        bool zfo = address(tIn) < address(tOut);
        legs[0] = Leg({
            pool: kind == BPC.KIND_V4 ? address(uint160(uint256(_pid()))) : venue,
            hooks: address(0), kind: kind, fee: fee, tickSpacing: ts, zeroForOne: zfo, stable: false,
            amountIn: amt, expectedOut: 0,
            auxId: kind == BPC.KIND_V4 ? bytes32(uint256(uint160(address(tOut)))) : bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut), amountIn: amt, expectedOut: 0, legs: legs});
        route = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
                       confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _call(Door d) private view returns (bytes memory) {
        uint256 dl = block.timestamp + 1;
        if (d == Door.EXACT) return abi.encodeCall(router.swapExactIn, (_route(), amt, 1, recipient, dl));
        if (d == Door.BEST) return abi.encodeCall(router.swapBestExactIn, (address(tIn), address(tOut), amt, 1, recipient, dl));
        IPermit2.PermitTransferFrom memory pm = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(tIn), amount: amt}), nonce: 0, deadline: dl
        });
        return abi.encodeCall(router.swapExactInWithPermit2, (_route(), amt, 1, recipient, dl, pm, ""));
    }

    function _feeBal(address t) private view returns (uint256) {
        return PathologicalERC20(t).balanceOf(T1) + PathologicalERC20(t).balanceOf(T2);
    }

    function _cell(Row r, Kind k, Door d) private {
        _stack();
        _tokens(r);
        _venue(k, r);
        // the Router's foreign balances: mis-sent money that no swap may touch
        tIn.mint(address(router), amt / 2);
        tOut.mint(address(router), 7e18);
        foreignShIn = tIn.sharesOf(address(router));
        foreignOut = tOut.balanceOf(address(router));
        tIn.mint(user, amt);
        vm.startPrank(user);
        tIn.approve(address(router), type(uint256).max);
        tIn.approve(address(p2), type(uint256).max);
        vm.stopPrank();

        string memory tag = string.concat(_rowName(r), " ", _kindName(k), " ", _doorName(d));
        address feeTok = feeInOut ? address(tOut) : address(tIn);
        uint256 feeBefore = _feeBal(feeTok);
        uint256 recBefore = tOut.balanceOf(recipient);
        uint256 inBefore = tIn.balanceOf(user);

        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(_call(d));

        if (!ok) {
            (bool ours, string memory what) = Outcomes.classify(ret);
            assertEq(tIn.balanceOf(user), inBefore, string.concat(tag, ": a refusal leaves the user untouched"));
            if (ours) { ++nOurs; console2.log("CELL", tag, string.concat("REFUSED ", what)); }
            else { ++nForeign; console2.log("CELL", tag, string.concat("REFUSED_FOREIGN ", what)); }
            return;
        }
        ++nSettled;
        uint256 got = abi.decode(ret, (uint256));
        uint256 delta = tOut.balanceOf(recipient) - recBefore;
        assertEq(got, delta, string.concat(tag, ": delivered == recipient delta"));
        assertGe(got, 1, string.concat(tag, ": delivered >= userMinOut"));

        // the Router never spends what it held before the swap (in shares: a rebase cannot hide it)
        assertGe(tIn.sharesOf(address(router)), foreignShIn, string.concat(tag, ": the Router's foreign tokenIn was spent"));
        assertEq(tOut.balanceOf(address(router)), foreignOut, string.concat(tag, ": tokenOut residue on the Router"));
        if (!_rebases(r)) {
            assertEq(tIn.sharesOf(address(router)), foreignShIn, string.concat(tag, ": tokenIn residue on the Router"));
        }

        uint256 feeGot = _feeBal(feeTok) - feeBefore;
        assertGt(feeGot, 0, string.concat(tag, ": a settled swap pays the fee"));
        if (!feeInOut) {
            // upper bound: 28 bps of what was ASKED (in the display units after the swap)
            assertLe(feeGot, BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS),
                     string.concat(tag, ": the fee exceeds 28 bps of the ask"));
            uint256 paid = inBefore - tIn.balanceOf(user);
            assertLe(paid, amt, string.concat(tag, ": the user paid more than the ask"));
            if (!_rebases(r)) {
                // lower bound on what the user really parted with (a partial fill refunds the
                // rest, so `paid` and not `amt` is the base); the token's own tax is levied on the
                // pull, the refund and each treasury push - 300 bps of slack covers all three.
                uint256 owed = BPC.mulDiv(paid, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
                assertGe(feeGot + 2, owed * 9_700 / 10_000,
                         string.concat(tag, ": the fee is below 28 bps of the measured input"));
            }
        } else {
            assertLe(feeGot, BPC.mulDivUp(got + feeGot, BPC.PROTOCOL_FEE_BPS, BPC.BPS - BPC.PROTOCOL_FEE_BPS) + 2,
                     string.concat(tag, ": the output fee exceeds 28 bps of the measured output"));
        }
        console2.log("CELL", tag, string.concat("SETTLED ", vm.toString(got), " fee ", vm.toString(feeGot)));
    }

    function _rows(Kind k, Door d) private {
        for (uint256 i; i < NROWS; ++i) _cell(Row(i), k, d);
        console2.log("TOTAL settled/ours/foreign", nSettled, nOurs, nForeign);
    }

    // The #45 line, alone: a 1% tax AND a +10% rebase on the pull, so `received` exceeds the ask.
    // A pure-FoT pull never reaches the cap (received < amountIn), so this is the FoT row that can see it.
    function test_P2_FotRebaseUpPull_NeverSpendsTheRoutersForeignBalance_Exact()   public { _cell(Row.FOT_REB_UP, Kind.V2, Door.EXACT); }
    function test_P2_FotRebaseUpPull_NeverSpendsTheRoutersForeignBalance_Permit2() public { _cell(Row.FOT_REB_UP, Kind.V2, Door.PERMIT2); }
    function test_P2_FotRebaseUpPull_NeverSpendsTheRoutersForeignBalance_Best()    public { _cell(Row.FOT_REB_UP, Kind.V2, Door.BEST); }

    function test_P2_Matrix_V2_Exact()        public { _rows(Kind.V2, Door.EXACT); }
    function test_P2_Matrix_V2_Permit2()      public { _rows(Kind.V2, Door.PERMIT2); }
    function test_P2_Matrix_V2_Best()         public { _rows(Kind.V2, Door.BEST); }
    function test_P2_Matrix_Solidly_Exact()   public { _rows(Kind.SOLIDLY, Door.EXACT); }
    function test_P2_Matrix_Solidly_Permit2() public { _rows(Kind.SOLIDLY, Door.PERMIT2); }
    function test_P2_Matrix_Solidly_Best()    public { _rows(Kind.SOLIDLY, Door.BEST); }
    function test_P2_Matrix_V3_Exact()        public { _rows(Kind.V3, Door.EXACT); }
    function test_P2_Matrix_V3_Permit2()      public { _rows(Kind.V3, Door.PERMIT2); }
    function test_P2_Matrix_V3_Best()         public { _rows(Kind.V3, Door.BEST); }
    function test_P2_Matrix_V4_Exact()        public { _rows(Kind.V4, Door.EXACT); }
    function test_P2_Matrix_V4_Permit2()      public { _rows(Kind.V4, Door.PERMIT2); }
    function test_P2_Matrix_Ext_Exact()       public { _rows(Kind.EXT, Door.EXACT); }
    function test_P2_Matrix_Ext_Permit2()     public { _rows(Kind.EXT, Door.PERMIT2); }

    // ─── tokenIn == tokenOut: a cycle A->B->A on two V2 pools, A taxed 1% ───
    function _leg(address pool, address a, address b, uint256 x) private pure returns (Leg[] memory l) {
        l = new Leg[](1);
        l[0] = Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0, zeroForOne: a < b,
                    stable: false, amountIn: x, expectedOut: 0, auxId: bytes32(0)});
    }

    function _cycle(uint16 fotBps, Door d) private {
        _stack();
        tIn = new PathologicalERC20("A", "A", 18);
        tOut = new PathologicalERC20("B", "B", 18);
        amt = 1_000e18;
        if (fotBps != 0) tIn.setFeeOnTransferBps(fotBps);
        address[2] memory pools;
        for (uint256 i; i < 2; ++i) {
            MockV2Pair p = new MockV2Pair(address(tIn), address(tOut));
            p.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
            tIn.mint(address(p), 1_000_000e18);
            tOut.mint(address(p), 1_000_000e18);
            Origin.wire(hub, address(p), address(tIn), address(tOut), BPC.KIND_V2, 30, false);
            pools[i] = address(p);
        }
        tIn.mint(address(router), amt / 2);
        tOut.mint(address(router), 7e18);
        foreignShIn = tIn.sharesOf(address(router));
        foreignOut = tOut.balanceOf(address(router));
        tIn.mint(user, amt);
        vm.startPrank(user);
        tIn.approve(address(router), type(uint256).max);
        tIn.approve(address(p2), type(uint256).max);
        vm.stopPrank();
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut), amountIn: amt, expectedOut: 0,
                       legs: _leg(pools[0], address(tIn), address(tOut), amt)});
        hops[1] = Hop({tokenIn: address(tOut), tokenOut: address(tIn), amountIn: amt * 99 / 100, expectedOut: 0,
                       legs: _leg(pools[1], address(tOut), address(tIn), amt * 99 / 100)});
        Route memory route = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
                                    confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        uint256 dl = block.timestamp + 1;
        bytes memory c = d == Door.EXACT
            ? abi.encodeCall(router.swapExactIn, (route, amt, 1, recipient, dl))
            : abi.encodeCall(router.swapExactInWithPermit2, (route, amt, 1, recipient, dl,
                IPermit2.PermitTransferFrom({permitted: IPermit2.TokenPermissions({token: address(tIn), amount: amt}),
                                             nonce: 0, deadline: dl}), ""));
        uint256 recBefore = tIn.balanceOf(recipient);
        string memory tag = string.concat("CYCLE_FOT", vm.toString(uint256(fotBps)), " V2V2 ", _doorName(d));
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(c);
        if (!ok) {
            (bool ours, string memory what) = Outcomes.classify(ret);
            assertEq(tIn.balanceOf(user), amt, string.concat(tag, ": a refusal leaves the user untouched"));
            assertTrue(ours, string.concat(tag, ": refused without a selector of ours: ", what));
            console2.log("CELL", tag, string.concat("REFUSED ", what));
            return;
        }
        uint256 got = abi.decode(ret, (uint256));
        assertEq(got, tIn.balanceOf(recipient) - recBefore, string.concat(tag, ": delivered == recipient delta"));
        assertEq(tIn.sharesOf(address(router)), foreignShIn, string.concat(tag, ": tokenIn (== tokenOut) residue or spend on the Router"));
        assertEq(tOut.balanceOf(address(router)), foreignOut, string.concat(tag, ": bridge residue on the Router"));
        assertLe(amt - tIn.balanceOf(user), amt, string.concat(tag, ": the user paid more than the ask"));
        console2.log("CELL", tag, string.concat("SETTLED ", vm.toString(got), " refund ", vm.toString(tIn.balanceOf(user))));
    }

    function test_P2_Cycle_Plain_Exact()   public { _cycle(0, Door.EXACT); }
    function test_P2_Cycle_Fot_Exact()     public { _cycle(100, Door.EXACT); }
    function test_P2_Cycle_Fot_Permit2()   public { _cycle(100, Door.PERMIT2); }
}
