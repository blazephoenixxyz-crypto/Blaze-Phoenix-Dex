// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Hostile-token ROWS x venue kinds x doors: the harness.
//
//  P2_HostileTokenMatrix crosses fee-on-transfer, rebase and decimals with five
//  kinds and three doors. This harness adds the rows it does not carry - a token
//  that lies in its ANSWER (true without moving, false while moving, no word, an
//  oversized word), that blocks ONE counterparty, burns the gas it is given,
//  calls back (ERC-777 style), rebases right after one chosen transfer, or
//  delivers a wei or two short - and aims each at one transfer of the swap: the
//  pull, the first treasury push, the payment to the venue, the venue's payment
//  to the Router, the delivery. It also adds the Algebra kind and the native door.
//
//  One rule per cell. The swap is REFUSED and nobody moved, or it SETTLES with
//    - returned == the recipient's balance delta >= userMinOut;
//    - the Router's own (foreign) SHARES of tokenIn and tokenOut never spent;
//    - on a non-rebasing token, nothing left on the Router beyond what it booked
//      as owed to a treasury slot;
//    - the fee accounted for: paid to the treasuries or booked as owed.
//  Outcomes print as `CELL <row> <kind> <door> <outcome>`; a broken rule prints
//  `VIOL <row> <kind> <door> <rule>` and fails the test at the end of the batch.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter, IPermit2} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixGate} from "../../src/BlazePhoenixGate.sol";
import {HostileERC20, TolerantPermit2} from "../mocks/HostileERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "../mocks/MockSolidlyPair.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";
import {MockAlgebraPool} from "../mocks/MockAlgebraPool.sol";
import {Origin} from "../mocks/MockOriginFactory.sol";
import {MockV4ManagerNative} from "../RouterV4NativeEth.t.sol";
import {MockGateVenue, MockGateRegistry, MockGateAdapter} from "../mocks/MockGateAdapters.sol";
import {Outcomes} from "./Outcomes.sol";

abstract contract HostileRowsHarness is Test {
    enum Row {
        PLAIN, IN_BARE,
        IN_PULL_TRUE_NOMOVE, IN_PULL_FALSE_NOMOVE, IN_PULL_FALSE_MOVES, IN_PULL_OVERSIZED, IN_PULL_BLOCKED,
        IN_PULL_GASBURN, IN_PULL_HOOK, IN_PULL_SHORT1,
        IN_VENUE_BLOCKED, IN_VENUE_TRUE_NOMOVE, IN_VENUE_SHORT2, IN_VENUE_REB_DN,
        IN_FEE_BLOCKED, IN_FEE_FALSE, IN_FEE_GASBURN, IN_FEE_FALSE_MOVES, IN_FEE_OVERSIZED, IN_FEE_TRUE_NOMOVE,
        IN_FEE_HOOK, IN_FEE_REB_UP,
        IN_DEC0, IN_DEC2, IN_REVERT_ZERO, IN_FOT30,
        OUT_BARE,
        OUT_RECIP_BLOCKED, OUT_RECIP_TRUE_NOMOVE, OUT_RECIP_FALSE_NOMOVE, OUT_RECIP_FALSE_MOVES, OUT_RECIP_OVERSIZED,
        OUT_RECIP_GASBURN, OUT_RECIP_HOOK, OUT_RECIP_SHORT1, OUT_RECIP_REB_UP, OUT_RECIP_REB_DN,
        OUT_ROUTER_TRUE_NOMOVE, OUT_ROUTER_BLOCKED, OUT_ROUTER_HOOK, OUT_ROUTER_SHORT2, OUT_ROUTER_REB_UP,
        OUT_ROUTER_REB_DN,
        OUT_DEC0, OUT_DEC24, OUT_REVERT_ZERO, OUT_FOT30
    }
    enum Kind { V2, SOLIDLY, V3, ALGEBRA, V4, EXT }
    enum Door { EXACT, PERMIT2, BEST, NATIVE }

    uint256 constant NROWS = 47;
    uint256 constant FIRST_OUT = 26;
    /// @dev every swap runs under a block-sized gas budget: a token that burns its gas burns
    ///      at most this, and the batch goes on.
    uint256 constant BLOCK_GAS = 30_000_000;
    // where a row aims: 0 nothing, 1 the pull (tokenIn -> Router), 2 the Router's payment to
    // the venue, 3 the first treasury push, 4 the delivery (tokenOut -> recipient), 5 the
    // venue's payment to the Router.
    uint8 constant AT_PULL = 1;
    uint8 constant AT_VENUE = 2;
    uint8 constant AT_FEE = 3;
    uint8 constant AT_RECIP = 4;
    uint8 constant AT_ROUTER = 5;
    uint8 constant SETTLE = 0;
    uint8 constant REFUSE = 1;
    uint8 constant EITHER = 2;

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
    TolerantPermit2 p2;
    HostileERC20 tIn;
    HostileERC20 tOut;
    address venue;
    uint8 kind;
    uint24 fee;
    int24 ts;
    uint256 amt;
    uint256 depthIn;
    uint256 depthOut;
    string tag;
    uint256 nViol;
    uint256 nSettled;
    uint256 nRefused;

    // ------------------------------------------------------------------ tables
    function _rowName(Row r) internal pure returns (string memory) {
        string[47] memory n = [
            "PLAIN", "IN_BARE",
            "IN_PULL_TRUE_NOMOVE", "IN_PULL_FALSE_NOMOVE", "IN_PULL_FALSE_MOVES", "IN_PULL_OVERSIZED", "IN_PULL_BLOCKED",
            "IN_PULL_GASBURN", "IN_PULL_HOOK", "IN_PULL_SHORT1",
            "IN_VENUE_BLOCKED", "IN_VENUE_TRUE_NOMOVE", "IN_VENUE_SHORT2", "IN_VENUE_REB_DN",
            "IN_FEE_BLOCKED", "IN_FEE_FALSE", "IN_FEE_GASBURN", "IN_FEE_FALSE_MOVES", "IN_FEE_OVERSIZED", "IN_FEE_TRUE_NOMOVE",
            "IN_FEE_HOOK", "IN_FEE_REB_UP",
            "IN_DEC0", "IN_DEC2", "IN_REVERT_ZERO", "IN_FOT30",
            "OUT_BARE",
            "OUT_RECIP_BLOCKED", "OUT_RECIP_TRUE_NOMOVE", "OUT_RECIP_FALSE_NOMOVE", "OUT_RECIP_FALSE_MOVES", "OUT_RECIP_OVERSIZED",
            "OUT_RECIP_GASBURN", "OUT_RECIP_HOOK", "OUT_RECIP_SHORT1", "OUT_RECIP_REB_UP", "OUT_RECIP_REB_DN",
            "OUT_ROUTER_TRUE_NOMOVE", "OUT_ROUTER_BLOCKED", "OUT_ROUTER_HOOK", "OUT_ROUTER_SHORT2", "OUT_ROUTER_REB_UP",
            "OUT_ROUTER_REB_DN",
            "OUT_DEC0", "OUT_DEC24", "OUT_REVERT_ZERO", "OUT_FOT30"
        ];
        return n[uint256(r)];
    }
    function _kindName(Kind k) internal pure returns (string memory) {
        string[6] memory n = ["V2", "SOLIDLY", "V3", "ALGEBRA", "V4", "EXT"];
        return n[uint256(k)];
    }
    function _doorName(Door d) internal pure returns (string memory) {
        string[4] memory n = ["EXACT", "PERMIT2", "BEST", "NATIVE"];
        return n[uint256(d)];
    }
    /// @dev where the row aims (AT_*).
    function _at(Row r) internal pure returns (uint8) {
        uint8[47] memory w = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0,
                              0, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 0, 0, 0, 0];
        return w[uint256(r)];
    }
    /// @dev the mode the row arms at that transfer.
    function _mode(Row r) internal pure returns (HostileERC20.Mode) {
        uint8[47] memory m = [0, 0, 1, 2, 3, 4, 5, 6, 7, 10, 5, 1, 10, 9, 5, 2, 6, 3, 4, 1, 7, 8, 0, 0, 0, 0,
                              0, 5, 1, 2, 3, 4, 6, 7, 10, 8, 9, 1, 5, 7, 10, 8, 9, 0, 0, 0, 0];
        return HostileERC20.Mode(m[uint256(r)]);
    }
    function _rebases(Row r) internal pure returns (bool) {
        HostileERC20.Mode m = _mode(r);
        return m == HostileERC20.Mode.REBASE_UP || m == HostileERC20.Mode.REBASE_DN;
    }

    // ----------------------------------------------------------------- fixture
    function _stack() internal {
        mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        p2 = new TolerantPermit2();
        router.setPermit2(address(p2));
    }

    function _tokens(Row r, Kind k) internal {
        uint8 dIn = r == Row.IN_DEC0 ? 0 : (r == Row.IN_DEC2 ? 2 : 18);
        uint8 dOut = r == Row.OUT_DEC0 ? 0 : (r == Row.OUT_DEC24 ? 24 : 18);
        tIn = new HostileERC20(dIn);
        tOut = new HostileERC20(dOut);
        amt = 1_000 * 10 ** dIn;
        depthIn = 1_000_000 * 10 ** dIn;
        depthOut = 1_000_000 * 10 ** dOut;
        // V3 / Algebra / V4 / Gate price 1:1 in raw units: the output side must out-hold the input side in raw
        if (k != Kind.V2 && k != Kind.SOLIDLY && depthOut < depthIn) depthOut = depthIn;
    }

    function _pid() internal view returns (bytes32) {
        (address c0, address c1) = address(tIn) < address(tOut) ? (address(tIn), address(tOut)) : (address(tOut), address(tIn));
        return BPC.computeV4PoolId(c0, c1, FEE4, TS4, address(0));
    }

    function _venue(Kind k) internal {
        address a = address(tIn);
        address b = address(tOut);
        if (k == Kind.V2 || k == Kind.SOLIDLY) {
            if (k == Kind.V2) { venue = address(new MockV2Pair(a, b)); kind = BPC.KIND_V2; }
            else { venue = address(new MockSolidlyPair(a, b, false)); kind = BPC.KIND_SOLIDLY; }
            fee = 30; ts = 0;
            (uint112 r0, uint112 r1) = a < b ? (uint112(depthIn), uint112(depthOut)) : (uint112(depthOut), uint112(depthIn));
            MockV2Pair(venue).setReserves(r0, r1);
            Origin.wire(hub, venue, a, b, kind, fee, false);
        } else if (k == Kind.V3) {
            MockV3Pool p = new MockV3Pool(a, b, 3000);
            p.setState(Q96, LIQ);
            venue = address(p); kind = BPC.KIND_V3; fee = 3000; ts = 60;
            Origin.wire(hub, venue, a, b, kind, fee, false);
        } else if (k == Kind.ALGEBRA) {
            MockAlgebraPool p = new MockAlgebraPool(a, b, 3000);
            p.setState(Q96, LIQ);
            venue = address(p); kind = BPC.KIND_ALGEBRA; fee = 0; ts = 0;
            hub.seedPool(venue, kind, 0, address(0), a, b);
        } else if (k == Kind.V4) {
            bytes32 base = keccak256(abi.encode(_pid(), uint256(6)));
            mgr.setSlot(base, bytes32(uint256(Q96)));
            mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
            venue = address(mgr); kind = BPC.KIND_V4; fee = FEE4; ts = TS4;
            (address c0, address c1) = a < b ? (a, b) : (b, a);
            try hub.claimV4(c0, c1, FEE4, TS4) {} catch {}
        } else {
            BlazePhoenixGate gate = new BlazePhoenixGate(address(this));
            MockGateRegistry reg = new MockGateRegistry();
            MockGateVenue gv = new MockGateVenue(a, b);
            reg.add(address(gv));
            tIn.mint(address(gv), depthIn);
            tOut.mint(address(gv), depthOut);
            gv.sync();
            MockGateAdapter adapter = new MockGateAdapter(gate, reg);
            gate.proposeAdapter(1, address(adapter));
            vm.warp(block.timestamp + gate.ADAPTER_DELAY());
            gate.acceptAdapter(1);
            venue = gate.create(a, b, GKEY, abi.encode(address(gv)));
            uint24[] memory fees = new uint24[](1);
            fees[0] = GKEY;
            hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0));
            kind = BPC.KIND_EXTERNAL; fee = GKEY; ts = 0;
            return;
        }
        address holder = k == Kind.V4 ? address(mgr) : venue;
        tIn.mint(holder, depthIn);
        tOut.mint(holder, depthOut);
    }

    function _route() internal view returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: kind == BPC.KIND_V4 ? address(uint160(uint256(_pid()))) : venue,
            hooks: address(0), kind: kind, fee: fee, tickSpacing: ts, zeroForOne: address(tIn) < address(tOut),
            stable: false, amountIn: amt, expectedOut: 0,
            auxId: kind == BPC.KIND_V4 ? bytes32(uint256(uint160(address(tOut)))) : bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut), amountIn: amt, expectedOut: 0, legs: legs});
        route = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
                       confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _calldata(Door d) internal view returns (bytes memory) {
        uint256 dl = block.timestamp + 1;
        if (d == Door.EXACT) return abi.encodeCall(router.swapExactIn, (_route(), amt, 1, recipient, dl));
        if (d == Door.BEST) return abi.encodeCall(router.swapBestExactIn, (address(tIn), address(tOut), amt, 1, recipient, dl));
        if (d == Door.NATIVE) return abi.encodeCall(router.swapExactInNative, (_route(), 1, recipient, dl));
        IPermit2.PermitTransferFrom memory pm = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(tIn), amount: amt}), nonce: 0, deadline: dl
        });
        return abi.encodeCall(router.swapExactInWithPermit2, (_route(), amt, 1, recipient, dl, pm, ""));
    }

    /// @dev what a HOOK row calls back on the Router: 0 swapExactIn, 1 swapExactInWithPermit2,
    ///      2 swapBestExactIn, 3 swapExactInNative, 4 claimFee, 5 selfExecutePrePulled.
    uint8 payload;
    /// @dev a single test may aim another mode at a row's transfer (the row is then only the aim).
    bool armOverride;
    HostileERC20.Mode armMode;

    function _m(Row r) internal view returns (HostileERC20.Mode) { return armOverride ? armMode : _mode(r); }
    function _restates(Row r) internal view returns (bool) {
        if (!armOverride) return _rebases(r);
        return armMode == HostileERC20.Mode.REBASE_UP || armMode == HostileERC20.Mode.REBASE_DN;
    }

    function _hookData() internal view returns (bytes memory) {
        uint256 dl = block.timestamp + 1;
        if (payload == 1) return _calldata(Door.PERMIT2);
        if (payload == 2) return _calldata(Door.BEST);
        if (payload == 3) return _calldata(Door.NATIVE);
        if (payload == 4) return abi.encodeCall(router.claimFee, (address(tIn)));
        if (payload == 5) return abi.encodeCall(router.selfExecutePrePulled, (_route(), amt, 1, recipient, dl, user));
        return _calldata(Door.EXACT);
    }

    /// @dev Aim the row's mode at its transfer.
    function _arm(Row r) internal {
        address R = address(router);
        uint8 at = _at(r);
        HostileERC20.Mode m = _m(r);
        HostileERC20 t = at >= AT_RECIP ? tOut : tIn;
        if (m == HostileERC20.Mode.HOOK) {
            t.setHook(R, _hookData());
        }
        if (m == HostileERC20.Mode.SHORT) t.setShortBy(at == AT_PULL || at == AT_RECIP ? 1 : 2);
        if (at == AT_PULL) tIn.setModeTo(R, m);
        else if (at == AT_VENUE) {
            // every tokenIn transfer the Router sends, bar the treasury pushes and a refund
            tIn.setExemptTo(T1, true); tIn.setExemptTo(T2, true); tIn.setExemptTo(user, true);
            tIn.setModeFrom(R, m);
        }
        else if (at == AT_FEE) tIn.setModeTo(T1, m);
        else if (at == AT_RECIP) tOut.setModeTo(recipient, m);
        else if (at == AT_ROUTER) tOut.setModeTo(R, m);
        else if (r == Row.IN_BARE) { tIn.setBareFor(R, true); tIn.setBareFor(address(p2), true); }
        else if (r == Row.OUT_BARE) tOut.setBareFor(R, true);
        else if (r == Row.IN_REVERT_ZERO) tIn.setRevertOnZero(true);
        else if (r == Row.OUT_REVERT_ZERO) tOut.setRevertOnZero(true);
        else if (r == Row.IN_FOT30) tIn.setTaxBps(3_000);
        else if (r == Row.OUT_FOT30) tOut.setTaxBps(3_000);
    }

    function _chk(bool cond, string memory rule) internal {
        if (cond) return;
        ++nViol;
        console2.log("VIOL", tag, rule);
    }

    function _reentryRefused(HostileERC20 t) internal {
        _chk(t.hookCalls() == 1, "the hook fired once");
        _chk(!t.hookOk(), "the re-entering call was refused");
        // the self-only door answers RouterE(1) to any caller that is not the Router; the rest are locked: RouterE(7)
        uint16 code = payload == 5 ? 1 : 7;
        _chk(t.hookRetHash() == keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code)),
             "the re-entering call was not refused with the door's own code");
    }
}
