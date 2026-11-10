// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The swap doors on a gas ladder (EIP-150: a sub-call gets at most 63/64).
//
//  The caller of a swap chooses its gas. Whatever it chooses, a swap either
//  reverts (nothing happened) or settles, and what is asked here is whether a
//  swap that settles on little gas did the same things as the same swap on
//  ample gas.
//
//  One contract per (venue family, registry regime); the world is built in
//  setUp, so the measured swap is a later transaction than everything that
//  built it (true storage pricing), and every account it touches is cold.
//  Per door (the caller's route, the automatic route) one cell is measured:
//    - the reference: the swap on all the gas;
//    - three bisections, no literal: gMin (the least gas on which the swap
//      settles), gRow (settles and the registry is not as it was before),
//      gWhole (settles with the reference's registry effects);
//    - the rungs: an even ladder from gMin to past gWhole and the reference's
//      own cost; a sample under gMin (gMin - 2^i) and one under gRow.
//  Effects are split in two: the MONEY (what the recipient, the payer, the two
//  treasuries, the Router and the venue hold, the fees left owed, the amount
//  returned) and the REGISTRY (the venue's own row word, the pair's rows as the
//  read door lists them, the Volume events, a Gate wrapper's vitality).
//
//  Green in this file:
//    - every cell: a settled swap moved exactly the money of the reference, and
//      nothing settles on the sample under gMin;
//    - a pool the registry already knows (seated by an earlier swap, listed by
//      the operator's door, or a Gate wrapper): every rung from gMin up settles
//      and feeds the registry exactly as the reference;
//    - a pool's first swap: a settled rung leaves the reference's row, the row
//      with fee 0 (the Hub's declared answer for a frame too short for the fee
//      read), or the registry as it was - never a fourth thing; a concentrated
//      pool's first swap always writes its row.
//  The pair-shaped first swap that settles and leaves the registry as it was
//  is counted in RedSwapGasLadder.t.sol.
//
//  Instrument note: the test frame's own gas reading (`used`) is trusted for
//  the reference only. After vm.revertToState it no longer reads the call's
//  cost (a settled call read ~5 000), so no sentence here leans on it.
//
//  Matrix: 5 families x {first, seated} x 2 doors (the Gate wrapper on the
//  caller's route only) x (3 bisections + 25 rungs + 2 samples); dimensions
//  gas + mutant.
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixGate} from "../src/BlazePhoenixGate.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {MockV4ManagerNative} from "./RouterV4NativeEth.t.sol";
import {MockGateVenue, MockGateRegistry, MockGateAdapter} from "./mocks/MockGateAdapters.sol";

abstract contract SwapGasLadderBase is Test {
    enum Kind { V2, SOLIDLY, V3, V4, EXT }
    enum Door { EXACT, BEST }

    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    address user = address(0xBEEF);
    address recipient = address(0xCAFE);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = 1e27;
    uint24 constant FEE4 = 500;
    int24 constant TS4 = 10;
    uint24 constant GKEY = uint24(uint256(1) << 16 | 1);
    uint256 constant AMT = 1_000e18;
    uint256 constant DEPTH = 1_000_000e18;
    uint256 constant RUNGS = 24;
    // re-derived from the declaration in BlazePhoenixHub.sol, not imported from the contract under test
    bytes32 constant VOLUME_SIG = keccak256("Volume(bytes32,uint256,uint256)");

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockV4ManagerNative mgr;
    BlazePhoenixGate gate;
    MockERC20 tIn;
    MockERC20 tOut;
    address venue;
    address holder;      // who holds the venue's tokens
    uint8 kind;
    uint24 fee;
    int24 ts;
    address[] touched;

    struct Effects {
        bool settled;
        uint256 delivered;
        bytes32 money;
        bytes32 registry;
        uint256 volumes;     // Volume events the Hub emitted in this call
        uint256 slot;        // the venue's own registry row
        PoolInfo[] rows;     // the pair's rows as the read door lists them
        uint256 used;        // trusted for the reference only (see the header)
        bytes ret;
    }

    /// What one cell measured, all in gas the caller gives the swap.
    struct Cell {
        uint256 gRef;        // what the reference spent on all the gas
        uint256 gMin;        // the least gas on which the swap settles (bisection)
        uint256 gRow;        // the least gas on which it settles and the registry is not as it was before
        uint256 gWhole;      // the least gas on which it settles with the reference's registry effects
        uint256 settled;     // rungs gMin..top that settled
        uint256 holes;       // rungs gMin..top that did not settle
        uint256 below;       // sampled gas under gMin that settled
        uint256 under;       // sampled gas between gMin and gRow (gRow - 2^i) that did not settle
        uint256 moneyMoved;  // settled rungs whose money differs from the reference
        uint256 skipped;     // settled rungs that left the registry exactly as it was before the swap
        uint256 liveRead;    // settled rungs whose row is the reference's with fee 0 (the declared live read)
        uint256 torn;        // settled rungs whose registry is none of the three
        bool refWrote;       // the reference changed the registry
        bool refPaidFee;     // the reference paid a protocol fee
    }

    function _stack() private {
        mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        tIn = new MockERC20("IN", "IN");
        tOut = new MockERC20("OUT", "OUT");
        delete touched;
        touched.push(address(mgr)); touched.push(address(hub)); touched.push(address(solver));
        touched.push(address(router)); touched.push(address(tIn)); touched.push(address(tOut));
        touched.push(T1); touched.push(T2); touched.push(recipient); touched.push(user);
    }

    function _pid() internal view returns (bytes32) {
        (address c0, address c1) = address(tIn) < address(tOut) ? (address(tIn), address(tOut)) : (address(tOut), address(tIn));
        return BPC.computeV4PoolId(c0, c1, FEE4, TS4, address(0));
    }

    function _venue(Kind k) private {
        if (k == Kind.V2 || k == Kind.SOLIDLY) {
            if (k == Kind.V2) { venue = address(new MockV2Pair(address(tIn), address(tOut))); kind = BPC.KIND_V2; }
            else { venue = address(new MockSolidlyPair(address(tIn), address(tOut), false)); kind = BPC.KIND_SOLIDLY; }
            fee = 30; ts = 0;
            MockV2Pair(venue).setReserves(uint112(DEPTH), uint112(DEPTH));
            touched.push(address(Origin.wire(hub, venue, address(tIn), address(tOut), kind, fee, false)));
        } else if (k == Kind.V3) {
            MockV3Pool p = new MockV3Pool(address(tIn), address(tOut), 3000);
            p.setState(Q96, LIQ);
            venue = address(p); kind = BPC.KIND_V3; fee = 3000; ts = 60;
            touched.push(address(Origin.wire(hub, venue, address(tIn), address(tOut), kind, fee, false)));
        } else if (k == Kind.V4) {
            bytes32 base = keccak256(abi.encode(_pid(), uint256(6)));
            mgr.setSlot(base, bytes32(uint256(Q96)));
            mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
            venue = address(mgr); kind = BPC.KIND_V4; fee = FEE4; ts = TS4;
            (address c0, address c1) = address(tIn) < address(tOut) ? (address(tIn), address(tOut)) : (address(tOut), address(tIn));
            hub.addV4(c0, c1, FEE4, TS4, address(0));
        } else {
            gate = new BlazePhoenixGate(address(this));
            MockGateRegistry reg = new MockGateRegistry();
            MockGateVenue gv = new MockGateVenue(address(tIn), address(tOut));
            reg.add(address(gv));
            tIn.mint(address(gv), DEPTH);
            tOut.mint(address(gv), DEPTH);
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
            holder = address(gv);
            touched.push(address(gate)); touched.push(address(reg)); touched.push(address(gv));
            touched.push(address(adapter)); touched.push(venue);
            return;
        }
        holder = venue;
        touched.push(venue);
        tIn.mint(holder, DEPTH);
        tOut.mint(holder, DEPTH);
    }

    function _route() internal view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: kind == BPC.KIND_V4 ? address(uint160(uint256(_pid()))) : venue,
            hooks: address(0), kind: kind, fee: fee, tickSpacing: ts, zeroForOne: address(tIn) < address(tOut), stable: false,
            amountIn: AMT, expectedOut: 0,
            auxId: kind == BPC.KIND_V4 ? bytes32(uint256(uint160(address(tOut)))) : bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut), amountIn: AMT, expectedOut: 0, legs: legs});
        route = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
                       confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _calldata(Door d) internal view returns (bytes memory) {
        uint256 dl = block.timestamp + 1;
        if (d == Door.EXACT) return abi.encodeCall(router.swapExactIn, (_route(), AMT, 1, recipient, dl));
        return abi.encodeCall(router.swapBestExactIn, (address(tIn), address(tOut), AMT, 1, recipient, dl));
    }

    function _money(uint256 delivered) private view returns (bytes32) {
        return keccak256(abi.encode(
            delivered,
            tOut.balanceOf(recipient), tIn.balanceOf(user),
            tIn.balanceOf(T1), tIn.balanceOf(T2), tOut.balanceOf(T1), tOut.balanceOf(T2),
            tIn.balanceOf(address(router)), tOut.balanceOf(address(router)),
            tIn.balanceOf(holder), tOut.balanceOf(holder),
            router.owed(address(tIn), 0), router.owed(address(tIn), 1),
            router.owed(address(tOut), 0), router.owed(address(tOut), 1)
        ));
    }

    function _sorted() private view returns (address c0, address c1) {
        (c0, c1) = address(tIn) < address(tOut) ? (address(tIn), address(tOut)) : (address(tOut), address(tIn));
    }

    /// The registry's record of the pair: the venue's own row, the pair's rows as the read door
    /// lists them, the Volume events, and for a Gate wrapper (which the Hub holds no row of) the
    /// wrapper's own vitality word. The money: every balance the swap can touch.
    function _seal(Effects memory e) private view {
        (address c0, address c1) = _sorted();
        address regPool = kind == BPC.KIND_V4 ? address(uint160(uint256(_pid()))) : venue;
        e.slot = hub.getSlot(hub.keyOf(regPool, c0, c1));
        e.rows = hub.getActivePools(address(tIn), address(tOut));
        uint256 v; uint256 d18;
        if (kind == BPC.KIND_EXTERNAL) (v, d18,) = gate.vitalOf(venue);
        e.registry = keccak256(abi.encode(e.volumes, e.slot, e.rows, v, d18));
        e.money = _money(e.delivered);
    }

    /// Everything the two treasuries hold or are owed.
    function _paid() private view returns (uint256) {
        return tIn.balanceOf(T1) + tIn.balanceOf(T2) + tOut.balanceOf(T1) + tOut.balanceOf(T2)
            + router.owed(address(tIn), 0) + router.owed(address(tIn), 1)
            + router.owed(address(tOut), 0) + router.owed(address(tOut), 1);
    }

    /// The swap on exactly `gasLimit`, every account cold.
    function _run(bytes memory cd, uint256 gasLimit) internal returns (Effects memory e) {
        for (uint256 i; i < touched.length; ++i) vm.cool(touched[i]);
        vm.recordLogs();
        vm.prank(user);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = address(router).call{gas: gasLimit}(cd);
        e.used = g0 - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        e.settled = ok;
        e.ret = ret;
        if (ok) e.delivered = abi.decode(ret, (uint256));
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hub) && logs[i].topics.length > 0 && logs[i].topics[0] == VOLUME_SIG) ++e.volumes;
        }
        _seal(e);
    }

    /// The row is the reference's row with the fee field zero and nothing else changed: the Hub's
    /// declared answer for a frame too short for the fee read (the live read). The fee field's
    /// place is re-derived from `decodeFee`'s declaration (bits 8..31), and the read door's list
    /// must agree with the fee patched back.
    function _isTheLiveRead(Effects memory e, Effects memory ref) private pure returns (bool) {
        uint256 refFee = uint256(BPC.decodeFee(ref.slot));
        if (e.volumes != ref.volumes || refFee == 0 || e.slot == 0) return false;
        if ((e.slot ^ ref.slot) != (refFee << 8)) return false;
        if (e.rows.length != ref.rows.length) return false;
        for (uint256 i; i < e.rows.length; ++i) {
            if (e.rows[i].pool == ref.rows[i].pool && e.rows[i].fee == 0) e.rows[i].fee = ref.rows[i].fee;
        }
        return keccak256(abi.encode(e.rows)) == keccak256(abi.encode(ref.rows));
    }

    // what a bisection asks of a run
    uint8 constant SETTLES = 0;
    uint8 constant WRITES = 1;    // settles and the registry is not as it was before
    uint8 constant WHOLE = 2;     // settles with the reference's registry effects

    /// What every run of one cell shares.
    struct Ctx { bytes cd; uint256 snap; bytes32 before; bytes32 whole; }

    function _holds(Ctx memory x, uint256 g, uint8 ask) private returns (bool) {
        vm.revertToState(x.snap);
        Effects memory e = _run(x.cd, g);
        if (!e.settled) return false;
        if (ask == WRITES) return e.registry != x.before;
        if (ask == WHOLE) return e.registry == x.whole;
        return true;
    }

    function _least(Ctx memory x, uint256 lo, uint256 hi, uint8 ask) private returns (uint256) {
        require(_holds(x, hi, ask), "fixture: twice the reference's gas does not do what the reference did");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_holds(x, mid, ask)) hi = mid; else lo = mid;
        }
        return hi;
    }

    /// The world of one cell. Called from setUp, so the measured swap is a later transaction than
    /// everything that built the world (no `vm.cool` here: an account cooled in setUp and not
    /// called again before it returns loses what setUp wrote to it).
    function _world(Kind k) internal {
        _stack();
        _venue(k);
        tIn.mint(user, 8 * AMT);
        vm.prank(user);
        tIn.approve(address(router), type(uint256).max);
    }

    /// The pool's first swap, on all the gas: it seats the row a later swap finds.
    function _seat() internal {
        vm.prank(user);
        uint256 out = router.swapExactIn(_route(), AMT, 1, recipient, block.timestamp + 1);
        require(out > 0, "fixture: the seating swap delivered nothing");
    }

    /// One cell: the reference, the three bisections, the rungs, the two samples.
    function _measure(Door d, string memory tag) internal returns (Cell memory c) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        Effects memory before;
        _seal(before);
        uint256 paidBefore = _paid();
        Ctx memory x;
        x.cd = _calldata(d);
        x.before = before.registry;
        x.snap = vm.snapshotState();

        Effects memory ref = _run(x.cd, gasleft());
        require(ref.settled && ref.delivered > 0, "fixture: the reference swap did not settle");
        x.whole = ref.registry;
        c.gRef = ref.used;
        c.refWrote = ref.registry != before.registry;
        c.refPaidFee = _paid() > paidBefore;

        c.gMin = _least(x, 0, 2 * c.gRef, SETTLES);
        c.gRow = c.refWrote ? _least(x, c.gMin - 1, 2 * c.gRef, WRITES) : c.gMin;
        c.gWhole = _least(x, c.gMin - 1, 2 * c.gRef, WHOLE);
        _rungs(x, tag, c, ref);
        _samples(x, c);
        vm.revertToState(x.snap);
        _report(tag, c);
    }

    /// The rungs: an even ladder from gMin to past the reference's cost and past gWhole.
    function _rungs(Ctx memory x, string memory tag, Cell memory c, Effects memory ref) private {
        uint256 top = c.gWhole > c.gRef ? c.gWhole : c.gRef;
        top += top / 8;
        for (uint256 i; i <= RUNGS; ++i) {
            uint256 g = c.gMin + (top - c.gMin) * i / RUNGS;
            vm.revertToState(x.snap);
            Effects memory e = _run(x.cd, g);
            if (!e.settled) {
                ++c.holes;
                emit log_string(string.concat(
                    "HOLE ", tag, " gas=", vm.toString(g), " returndata=", vm.toString(e.ret)));
                continue;
            }
            ++c.settled;
            if (e.money != ref.money) ++c.moneyMoved;
            if (e.registry == ref.registry) continue;
            if (e.registry == x.before) ++c.skipped;
            else if (_isTheLiveRead(e, ref)) ++c.liveRead;
            else ++c.torn;
        }
    }

    /// The sample under gMin (gMin - 2^i) and the sample just under gRow (gRow - 2^i, above gMin).
    function _samples(Ctx memory x, Cell memory c) private {
        for (uint256 i; i < 16; ++i) {
            if (c.gMin <= (uint256(1) << i)) break;
            vm.revertToState(x.snap);
            if (_run(x.cd, c.gMin - (uint256(1) << i)).settled) ++c.below;
        }
        for (uint256 i; i < 16; ++i) {
            if (c.gRow <= c.gMin + (uint256(1) << i)) break;
            vm.revertToState(x.snap);
            if (!_run(x.cd, c.gRow - (uint256(1) << i)).settled) ++c.under;
        }
    }

    function _report(string memory tag, Cell memory c) private {
        emit log_string(string.concat(
            "CELL ", tag, " gRef=", vm.toString(c.gRef), " gMin=", vm.toString(c.gMin),
            " gRow=", vm.toString(c.gRow), " gWhole=", vm.toString(c.gWhole)));
        emit log_string(string.concat(
            "     ", tag, " settled=", vm.toString(c.settled), " holes=", vm.toString(c.holes),
            " below=", vm.toString(c.below), " under=", vm.toString(c.under), " moneyMoved=", vm.toString(c.moneyMoved),
            " skipped=", vm.toString(c.skipped), " liveRead=", vm.toString(c.liveRead),
            " torn=", vm.toString(c.torn), c.refWrote ? " refWrote=1" : " refWrote=0",
            c.refPaidFee ? " refPaidFee=1" : " refPaidFee=0"));
    }

    function _tag(Door d) internal view returns (string memory) {
        return string.concat(_label(), d == Door.EXACT ? " caller-route" : " automatic-route");
    }

    function _label() internal view virtual returns (string memory);
}

/// One (family, registry regime): the world is built in setUp, each test measures in its own
/// transaction.
abstract contract SwapGasLadderCase is SwapGasLadderBase {
    function _family() internal pure virtual returns (Kind);
    function _seated() internal pure virtual returns (bool) { return false; }
    /// The Gate wrapper is laddered on the caller's route only.
    function _doors() internal pure virtual returns (uint256) { return _family() == Kind.EXT ? 1 : 2; }

    function _label() internal view override returns (string memory) {
        string[5] memory kn = ["V2", "SOLIDLY", "V3", "V4", "GATE"];
        return string.concat(kn[uint256(_family())], _seated() ? " seated" : " first");
    }

    function setUp() public {
        _world(_family());
        if (_seated()) _seat();
    }
}

/// Every cell: the money.
abstract contract MoneyOnTheLadder is SwapGasLadderCase {
    function test_Ladder_ASettledSwapMovesTheMoneyOfTheReference() public {
        for (uint256 d; d < _doors(); ++d) {
            string memory tag = _tag(Door(d));
            Cell memory c = _measure(Door(d), tag);
            assertTrue(c.refPaidFee, string.concat(tag, ": the reference paid no protocol fee"));
            assertGe(c.settled, RUNGS / 2, string.concat(tag, ": the ladder has too few settled rungs"));
            assertEq(c.moneyMoved, 0, string.concat(tag, ": a swap that settled on less gas moved different money"));
            assertEq(c.below, 0, string.concat(tag, ": a swap settled on less than the least gas that settles"));
        }
    }
}

/// A pool the registry already knows: seated by an earlier swap, listed by the operator's door
/// (V4), or a Gate wrapper, whose vitality the Gate keeps.
abstract contract RegisteredOnTheLadder is MoneyOnTheLadder {
    function test_Ladder_ASettledSwapOnARegisteredPoolFeedsTheRegistryAsTheReference() public {
        for (uint256 d; d < _doors(); ++d) {
            string memory tag = _tag(Door(d));
            Cell memory c = _measure(Door(d), tag);
            assertTrue(c.refWrote, string.concat(tag, ": the reference left the registry as it was"));
            assertEq(c.holes, 0, string.concat(tag, ": a rung above the least gas that settles did not settle"));
            assertEq(c.settled, RUNGS + 1, string.concat(tag, ": not every rung settled"));
            assertEq(c.skipped + c.liveRead + c.torn, 0,
                string.concat(tag, ": a settled swap fed the registry differently from the reference"));
            assertEq(c.gWhole, c.gMin, string.concat(tag, ": the least gas that settles does not feed the registry whole"));
        }
    }
}

/// A pool's first swap through the swap door: the registry holds no row of it yet.
abstract contract FirstSwapOnTheLadder is MoneyOnTheLadder {
    function test_Ladder_ASettledFirstSwapWritesTheReferenceRowTheLiveReadOrNothing() public {
        for (uint256 d; d < _doors(); ++d) {
            string memory tag = _tag(Door(d));
            Cell memory c = _measure(Door(d), tag);
            assertTrue(c.refWrote, string.concat(tag, ": the reference did not register the pool"));
            assertGe(c.settled, RUNGS / 2, string.concat(tag, ": the ladder has too few settled rungs"));
            assertEq(c.torn, 0, string.concat(tag, ": a settled swap left a row that is neither the reference's nor the live read"));
        }
    }
}

/// A concentrated pool's first swap: the row is written on every settled rung, with the fee the
/// reference wrote or with 0.
abstract contract FirstConcentratedSwapOnTheLadder is FirstSwapOnTheLadder {
    function test_Ladder_ASettledFirstConcentratedSwapAlwaysWritesItsRow() public {
        for (uint256 d; d < _doors(); ++d) {
            string memory tag = _tag(Door(d));
            Cell memory c = _measure(Door(d), tag);
            assertTrue(c.refWrote, string.concat(tag, ": the reference did not register the pool"));
            assertGt(c.liveRead, 0, string.concat(tag, ": the ladder never reached the frame too short for the fee read"));
            assertEq(c.skipped, 0, string.concat(tag, ": a settled swap left the pool unregistered"));
            assertEq(c.holes + c.under, 0, string.concat(tag, ": a gas limit above the least that settles did not settle"));
            assertEq(c.gRow, c.gMin, string.concat(tag, ": the least gas that settles does not write the row"));
        }
    }
}

contract SwapGasLadderV2FirstTest       is FirstSwapOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.V2; } }
contract SwapGasLadderSolidlyFirstTest  is FirstSwapOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.SOLIDLY; } }
contract SwapGasLadderV3FirstTest       is FirstConcentratedSwapOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.V3; } }
contract SwapGasLadderV2SeatedTest      is RegisteredOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.V2; }      function _seated() internal pure override returns (bool) { return true; } }
contract SwapGasLadderSolidlySeatedTest is RegisteredOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.SOLIDLY; } function _seated() internal pure override returns (bool) { return true; } }
contract SwapGasLadderV3SeatedTest      is RegisteredOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.V3; }      function _seated() internal pure override returns (bool) { return true; } }
// V4: the operator's door (addV4) lists the pool, so its first swap already finds a row.
contract SwapGasLadderV4ListedTest      is RegisteredOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.V4; } }
contract SwapGasLadderV4SeatedTest      is RegisteredOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.V4; }      function _seated() internal pure override returns (bool) { return true; } }
// Gate wrapper: the Hub holds no row of it; the Gate keeps its vitality from the first swap on.
contract SwapGasLadderGateFirstTest     is RegisteredOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.EXT; } }
contract SwapGasLadderGateSeatedTest    is RegisteredOnTheLadder { function _family() internal pure override returns (Kind) { return Kind.EXT; }     function _seated() internal pure override returns (bool) { return true; } }
