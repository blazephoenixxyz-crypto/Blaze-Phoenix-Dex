// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ATQ-inv (atq-1111): stateful campaign over the Router between transactions.
//
// One handler drives a multi-actor, multi-block sequence of swaps (7 route shapes x 4 doors x
// 4 amount bands, optionally two swaps in one transaction), fee claims, treasury blocking,
// treasury moves, pause, renounce, the rescue timelock, donations, warps and stranger pokes.
// Every transition is checked against a ghost model that never reads the code under test for
// its expectation, and four families of invariants are checked after every call:
//
//   L1  token.balanceOf(router) == owed[token][0] + owed[token][1] + stray[token]   (equality)
//   L2  sum(treasury balances) + owed == sum(Fee events)                            (non-FoT)
//   D   actor balance + ghost spent == funded, token and ETH (no foreign debit)
//   C   treasuries / paused / renounced / admin / rescueEta mirror the ghost model,
//       and the nine transient context slots read zero after every Router call.
//
// The transient slots are read by etching a tiny reader over the Router's address AFTER the
// call returned (no Router frame on the stack) and etching the Router back. The reader has a
// positive control (the kept slot, deliberately not cleared inside a transaction) in
// test_AtqBlockedTreasury_OwedBookedClaimExact.
//
// fail_on_revert is false in this repo, so a handler-side check cannot revert: it records the
// first violation and the invariant asserts the counter is zero.
//
// Mutants: [ATQ-inv-n] in .github/scripts/mutants.py.

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockV4HookedManager} from "./mocks/MockV4HookedManager.sol";

/// @dev Minimal ERC20 with a recipient blocklist and an optional transfer fee (burned).
contract AtqToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public immutable fotBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(string memory s, uint256 fot) { name = s; symbol = s; fotBps = fot; }

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; emit Transfer(address(0), to, a); }
    function setBlocked(address who, bool b) external { blocked[who] = b; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        require(!blocked[to], "AtqToken: blocked");
        balanceOf[f] -= a;
        uint256 fee = a * fotBps / 10_000;
        balanceOf[to] += a - fee;
        totalSupply -= fee;
        emit Transfer(f, to, a - fee);
    }
}

contract AtqWETH is AtqToken {
    constructor() AtqToken("WETH", 0) {}
    function deposit() external payable { balanceOf[msg.sender] += msg.value; totalSupply += msg.value; }
    function withdraw(uint256 a) external {
        balanceOf[msg.sender] -= a;
        totalSupply -= a;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "AtqWETH: send");
    }
}

/// @dev Etched over the Router's address to read its transient storage. Slot names are the
///      Router's private constants, written out here so the instrument does not import them.
contract AtqTransientReader {
    function read() external view returns (uint256[9] memory v) {
        bytes32[9] memory k = [
            keccak256("blaze.r.pool"), keccak256("blaze.r.token"), keccak256("blaze.r.amt"),
            keccak256("blaze.r.v4in"), keccak256("blaze.r.v4out"), keccak256("blaze.r.lock"),
            keccak256("blaze.r.fot"), keccak256("blaze.r.fee"), keccak256("blaze.r.ethok")
        ];
        for (uint256 i; i < 9; ++i) {
            bytes32 s = k[i];
            uint256 x;
            assembly { x := tload(s) }
            v[i] = x;
        }
    }

    function kept(address token) external view returns (uint256 x) {
        bytes32 s = keccak256(abi.encode(token, uint256(keccak256("blaze.r.kept"))));
        assembly { x := tload(s) }
    }
}

struct AtqWorld {
    BlazePhoenixRouter router;
    BlazePhoenixHub hub;
    MockPermit2 permit2;
    AtqToken A;
    AtqToken B;
    AtqToken C;
    AtqToken F;
    AtqWETH W;
    MockV2Pair pAB;
    MockV2Pair pBC;
    MockV2Pair pWA;
    MockV2Pair pFB;
    MockV3Pool qAB;
    bytes32 pid4;
    address[3] actors;
    address[4] tpool;
    address[2] dests;
}

contract AtqLedgerHandler is Test {
    uint256 public constant NK = 7;
    uint256 internal constant PERMIT_SLACK = 7;
    uint24 internal constant FEE4 = 3000;
    int24 internal constant TS = 60;
    bytes32 internal constant FEE_SIG = keccak256("Fee(address,uint256,uint256,uint256)");
    address internal constant TWIN = address(uint160(uint256(keccak256("atq.router.twin"))));
    address public constant RECIP = address(0xBEEF01);
    address public constant STRANGER = address(0xBAD5EED);

    AtqWorld internal w;
    AtqTransientReader internal reader;
    address[5] public toks; // A, B, C, F, W

    // ---- ghost model ----
    mapping(address => uint256) public stray;
    mapping(address => uint256) public feeSum;
    mapping(address => mapping(address => uint256)) public spent;
    mapping(address => uint256) public ethSpent;
    mapping(bytes32 => uint256) public gEta;
    address public gT1;
    address public gT2;
    bool public gPaused;
    bool public gRenounced;

    // ---- verdicts and anti-vacuity counters ----
    uint256 public nBad;
    string public bad;
    mapping(uint256 => uint256) public settled; // kind * 4 + door
    uint256 public ctxReads;
    uint256 public claims;
    uint256 public rescues;
    uint256 public pokes;
    uint256 public nativeResiduals;
    uint256 public maxFeeEvents;
    address public lastFeeToken;
    uint256 internal nonce;

    constructor(AtqWorld memory w_) {
        w = w_;
        reader = new AtqTransientReader();
        toks = [address(w_.A), address(w_.B), address(w_.C), address(w_.F), address(w_.W)];
        gT1 = w_.router.treasury1();
        gT2 = w_.router.treasury2();
        vm.etch(TWIN, address(w_.router).code);
    }

    // ------------------------------------------------------------------ helpers
    function _h(uint256 x) internal pure returns (uint256) { return uint256(keccak256(abi.encode(x))); }
    function _fail(string memory what) internal { if (nBad == 0) bad = what; ++nBad; }
    function _bal(address t, address who) internal view returns (uint256) { return AtqToken(t).balanceOf(who); }

    function _isE(bytes memory e, uint16 code) internal pure returns (bool) {
        return keccak256(e) == keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code));
    }

    function _amt(uint256 s) internal pure returns (uint256) {
        uint256 h = _h(s);
        uint256 r = h >> 8;
        if (h % 4 == 0) return 1 + r % 1e4;
        if (h % 4 == 1) return 1e6 + r % 1e12;
        if (h % 4 == 2) return 1e15 + r % 1e18;
        return 1e18 + r % 1e21;
    }

    function _who5(uint256 s) internal view returns (address) {
        uint256 i = _h(s) % 5;
        return i == 4 ? STRANGER : w.tpool[i];
    }

    function keyOf(uint256 i) public view returns (bytes32) {
        return keccak256(abi.encodePacked(toks[(i / 2) % 3], w.dests[i % 2]));
    }

    function _ctxCheck() internal {
        address r = address(w.router);
        vm.etch(r, address(reader).code);
        uint256[9] memory v = AtqTransientReader(r).read();
        vm.etch(r, TWIN.code);
        ++ctxReads;
        for (uint256 i; i < 9; ++i) {
            if (v[i] != 0) { _fail(string.concat("transient context left live after a call: slot ", vm.toString(i))); break; }
        }
    }

    /// A swap and, in the SAME top-level call, the Router's kept counter for the fee token and
    /// for a control token: this Foundry resets transient storage between the top-level calls of
    /// a test, so a read made from the test contract afterwards would see zero whatever happened.
    function walkSwapKept(uint256 kind, uint256 door, uint256 actor, uint256 amt, address ctl)
        external returns (bool ok, uint256 kept, uint256 keptCtl)
    {
        ok = _swapOnce(kind, door, w.actors[actor], amt);
        address r = address(w.router);
        vm.etch(r, address(reader).code);
        kept = AtqTransientReader(r).kept(lastFeeToken);
        keptCtl = AtqTransientReader(r).kept(ctl);
        vm.etch(r, TWIN.code);
    }

    // ------------------------------------------------------------------ routes
    function _v2(MockV2Pair p, address tin, address tout, uint256 amt) internal pure returns (Leg memory) {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: tin < tout, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
    }

    function _hop(address tin, address tout, uint256 amt, uint256 exp, Leg memory l) internal pure returns (Hop memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        return Hop({tokenIn: tin, tokenOut: tout, amountIn: amt, expectedOut: exp, legs: ls});
    }

    function _wrap(Hop[] memory hs, uint256 out, bool surplus) internal pure returns (Route memory) {
        return Route({hops: hs, totalOut: out, singleOut: out, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: surplus, isV4Bundle: false});
    }

    function _one(Hop memory h, uint256 out, bool surplus) internal pure returns (Route memory) {
        Hop[] memory hs = new Hop[](1);
        hs[0] = h;
        return _wrap(hs, out, surplus);
    }

    function _route(uint256 kind, uint256 door, uint256 amt) internal view returns (Route memory r, address tIn, address tOut) {
        address A = address(w.A);
        address B = address(w.B);
        address C = address(w.C);
        if (door == 2) {
            tIn = address(w.W);
            tOut = A;
            r = _one(_hop(tIn, tOut, amt, 0, _v2(w.pWA, tIn, tOut, amt)), 0, false);
        } else if (door == 3) {
            if (kind == 1) (tIn, tOut) = (B, A);
            else if (kind == 2) (tIn, tOut) = (A, C);
            else if (kind == 6) (tIn, tOut) = (C, B);
            else (tIn, tOut) = (A, B);
        } else if (kind == 0) {
            (tIn, tOut) = (A, B);
            r = _one(_hop(A, B, amt, 0, _v2(w.pAB, A, B, amt)), 0, false);
        } else if (kind == 1) {
            (tIn, tOut) = (B, A);
            r = _one(_hop(B, A, amt, 0, _v2(w.pAB, B, A, amt)), 0, false);
        } else if (kind == 2) {
            (tIn, tOut) = (A, C);
            Hop[] memory hs = new Hop[](2);
            hs[0] = _hop(A, B, amt, 0, _v2(w.pAB, A, B, amt));
            hs[1] = _hop(B, C, amt, 0, _v2(w.pBC, B, C, amt));
            r = _wrap(hs, 0, false);
        } else if (kind == 3) {
            (tIn, tOut) = (A, B);
            Leg memory l = Leg({pool: address(w.qAB), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
                zeroForOne: w.qAB.token0() == A, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
            r = _one(_hop(A, B, amt, 0, l), 0, false);
        } else if (kind == 4) {
            (tIn, tOut) = (A, B);
            Leg memory l = Leg({pool: address(uint160(uint256(w.pid4))), hooks: address(0), kind: BPC.KIND_V4, fee: FEE4,
                tickSpacing: TS, zeroForOne: A < B, stable: false, amountIn: amt, expectedOut: amt / 2,
                auxId: bytes32(uint256(uint160(B)))});
            r = _one(_hop(A, B, amt, amt / 2, l), amt / 2, true);
        } else if (kind == 5) {
            (tIn, tOut) = (address(w.F), B);
            r = _one(_hop(tIn, B, amt, 0, _v2(w.pFB, tIn, B, amt)), 0, false);
        } else {
            (tIn, tOut) = (C, B);
            r = _one(_hop(C, B, amt, 0, _v2(w.pBC, C, B, amt)), 0, false);
        }
    }

    function _door(uint256 door, Route memory r, address tIn, address tOut, uint256 amt, address payer)
        internal returns (bool ok, uint256 out, bytes memory err)
    {
        uint256 dl = block.timestamp + 1;
        vm.prank(payer);
        if (door == 2) {
            try w.router.swapExactInNative{value: amt}(r, 1, RECIP, dl) returns (uint256 o) { return (true, o, ""); }
            catch (bytes memory e) { return (false, 0, e); }
        }
        if (door == 1) {
            // The permit covers more than the swap: the door may pull amountIn and nothing else.
            IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: tIn, amount: amt + PERMIT_SLACK}), nonce: ++nonce, deadline: dl});
            try w.router.swapExactInWithPermit2(r, amt, 1, RECIP, dl, p, "") returns (uint256 o) { return (true, o, ""); }
            catch (bytes memory e) { return (false, 0, e); }
        }
        if (door == 3) {
            try w.router.swapBestExactIn(tIn, tOut, amt, 1, RECIP, dl) returns (uint256 o) { return (true, o, ""); }
            catch (bytes memory e) { return (false, 0, e); }
        }
        try w.router.swapExactIn(r, amt, 1, RECIP, dl) returns (uint256 o) { return (true, o, ""); }
        catch (bytes memory e) { return (false, 0, e); }
    }

    function _tallyFees(Vm.Log[] memory logs) internal returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(w.router) || logs[i].topics.length != 2 || logs[i].topics[0] != FEE_SIG) continue;
            (uint256 a, uint256 t1, uint256 t2) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            if (t1 + t2 != a) _fail("fee split does not add up to the fee");
            lastFeeToken = address(uint160(uint256(logs[i].topics[1])));
            feeSum[lastFeeToken] += a;
            ++n;
        }
    }

    function _swapOnce(uint256 kind, uint256 door, address payer, uint256 amt) internal returns (bool ok) {
        (Route memory r, address tIn, address tOut) = _route(kind, door, amt);
        uint256 in0 = door == 2 ? payer.balance : _bal(tIn, payer);
        uint256 out0 = _bal(tOut, RECIP);
        vm.recordLogs();
        uint256 out;
        bytes memory err;
        (ok, out, err) = _door(door, r, tIn, tOut, amt, payer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _ctxCheck();
        if (gPaused && (ok || !_isE(err, 2))) _fail("a paused door did not refuse with RouterE(2)");
        if (!ok) return false;

        ++settled[kind * 4 + door];
        if (door == 2) {
            uint256 debit = in0 - payer.balance;
            if (debit > amt) _fail("native payer debited more than msg.value");
            if (debit < amt) ++nativeResiduals;
            ethSpent[payer] += debit;
        } else {
            if (in0 - _bal(tIn, payer) != amt) _fail("payer debit != amountIn");
            spent[payer][tIn] += amt;
        }
        uint256 got = _bal(tOut, RECIP) - out0;
        if (got != out) _fail("returned amountOut != amount delivered to the recipient");
        if (got == 0) _fail("a swap settled delivering nothing with userMinOut = 1");
        uint256 n = _tallyFees(logs);
        if (n == 0) _fail("a swap settled without a Fee event");
        if (n > maxFeeEvents) maxFeeEvents = n;
    }

    // ------------------------------------------------------------------ fuzzed actions
    function swap(uint256 kS, uint256 dS, uint256 aS, uint256 mS, bool twice) external {
        _swapOnce(_h(kS) % NK, _h(dS) % 4, w.actors[_h(aS) % 3], _amt(mS));
        if (twice) _swapOnce(_h(kS ^ 1) % NK, _h(dS ^ 1) % 4, w.actors[_h(aS ^ 1) % 3], _amt(mS ^ 1));
    }

    function claim(uint256 whoS, uint256 tokS) external { _claim(_who5(whoS), toks[_h(tokS) % 5]); }

    function blockTreasury(uint256 whoS, uint256 tokS, bool on) external {
        AtqToken(toks[_h(tokS) % 5]).setBlocked(w.tpool[_h(whoS) % 4], on);
    }

    function moveTreasury(uint256 whoS, uint256 toS) external {
        uint256 j = _h(toS) % 5;
        _move(_who5(whoS), j == 4 ? address(0) : w.tpool[j]);
    }

    function setTreasuries(uint256 s1, uint256 s2) external {
        uint256 i = _h(s1) % 5;
        uint256 j = _h(s2) % 5;
        address t1 = i == 4 ? address(0) : w.tpool[i];
        address t2 = j == 4 ? address(0) : w.tpool[j];
        (bool ok, bytes memory err) = address(w.router).call(abi.encodeCall(w.router.setTreasuries, (t1, t2)));
        if (gRenounced) { if (ok || !_isE(err, 1)) _fail("setTreasuries open after renounce"); }
        else if (t1 == address(0) || t2 == address(0)) { if (ok || !_isE(err, 3)) _fail("zero treasury accepted"); }
        else { if (!ok) _fail("setTreasuries refused"); gT1 = t1; gT2 = t2; }
    }

    function pause(uint256 s) external { _pause(_h(s) % 4 == 0); }

    function renounce(uint256 s) external { if (_h(s) % 16 == 0) _renounce(); }

    function rescue(uint256 opS, uint256 tokS, uint256 dstS) external {
        _rescue(_h(opS) % 4, toks[_h(tokS) % 3], w.dests[_h(dstS) % 2]);
    }

    function donate(uint256 tokS, uint256 amtS) external { _donate(toks[_h(tokS) % 5], 1 + _h(amtS) % 1e20); }

    function warp(uint256 s) external {
        uint256 h = _h(s);
        uint256 t0 = block.timestamp;
        uint256 target = t0 + 1 + (h >> 8) % 30 hours;
        if (h % 4 < 2) {
            for (uint256 i; i < 6; ++i) {
                uint256 e = gEta[keyOf(i)];
                if (e > t0 + 1) { target = h % 4 == 0 ? e : e - 1; break; }
            }
        }
        vm.warp(target);
        vm.roll(block.number + 1 + h % 5);
    }

    function poke(uint256 s) external {
        uint256 m = _h(s) % 9;
        bytes memory cd;
        if (m == 0) cd = abi.encodeCall(w.router.setAdmin, (STRANGER));
        else if (m == 1) cd = abi.encodeCall(w.router.setTreasuries, (STRANGER, STRANGER));
        else if (m == 2) cd = abi.encodeCall(w.router.setPaused, (true));
        else if (m == 3) cd = abi.encodeCall(w.router.renounceControl, ());
        else if (m == 4) cd = abi.encodeCall(w.router.queueRescue, (toks[0], STRANGER));
        else if (m == 5) cd = abi.encodeCall(w.router.cancelRescue, (toks[0], w.dests[0]));
        else if (m == 6) cd = abi.encodeCall(w.router.executeRescue, (toks[0], w.dests[0]));
        else if (m == 7) cd = abi.encodeCall(w.router.setPermit2, (STRANGER));
        else {
            (Route memory r,,) = _route(0, 0, 1e18);
            cd = abi.encodeCall(w.router.selfExecutePrePulled, (r, 1e18, 1, STRANGER, block.timestamp + 1, w.actors[0]));
        }
        vm.prank(STRANGER);
        (bool ok, bytes memory err) = address(w.router).call(cd);
        if (ok || !_isE(err, 1)) _fail("a stranger passed a control door");
        ++pokes;
    }

    // ------------------------------------------------------------------ model transitions
    function _claim(address who, address t) internal {
        uint256 o0 = w.router.owed(t, 0);
        uint256 o1 = w.router.owed(t, 1);
        uint256 exp = (who == gT1 ? o0 : 0) + (who == gT2 ? o1 : 0);
        uint256 b0 = _bal(t, who);
        vm.prank(who);
        (bool ok, bytes memory err) = address(w.router).call(abi.encodeCall(w.router.claimFee, (t)));
        _ctxCheck();
        if (exp == 0) { if (ok || !_isE(err, 1)) _fail("claim with nothing owed did not refuse with RouterE(1)"); return; }
        if (AtqToken(t).blocked(who)) { if (ok) _fail("claim paid a blocked holder"); return; }
        if (!ok) { _fail("a due claim was refused"); return; }
        if (t != address(w.F) && _bal(t, who) - b0 != exp) _fail("claim paid != the holder's owed slots");
        if (w.router.owed(t, 0) != (who == gT1 ? 0 : o0) || w.router.owed(t, 1) != (who == gT2 ? 0 : o1))
            _fail("claim cleared or kept the wrong owed slot");
        ++claims;
    }

    function _move(address who, address to) internal {
        vm.prank(who);
        (bool ok, bytes memory err) = address(w.router).call(abi.encodeCall(w.router.moveTreasury, (to)));
        if (to == address(0)) { if (ok || !_isE(err, 3)) _fail("moveTreasury(0) did not refuse with RouterE(3)"); }
        else if (who == gT1) { if (!ok) _fail("holder 1 could not move its slot"); gT1 = to; }
        else if (who == gT2) { if (!ok) _fail("holder 2 could not move its slot"); gT2 = to; }
        else if (ok || !_isE(err, 1)) _fail("a stranger moved a treasury");
    }

    function _pause(bool b) internal {
        (bool ok, bytes memory err) = address(w.router).call(abi.encodeCall(w.router.setPaused, (b)));
        if (gRenounced) { if (ok || !_isE(err, 1)) _fail("setPaused open after renounce"); }
        else { if (!ok) _fail("setPaused refused"); gPaused = b; }
    }

    function _renounce() internal {
        (bool ok, bytes memory err) = address(w.router).call(abi.encodeCall(w.router.renounceControl, ()));
        if (gRenounced) { if (ok || !_isE(err, 1)) _fail("renounce twice"); }
        else if (gPaused) { if (ok || !_isE(err, 2)) _fail("renounced while paused"); }
        else { if (!ok) _fail("renounce refused"); gRenounced = true; }
    }

    function _donate(address t, uint256 a) internal {
        AtqToken(t).mint(address(w.router), a);
        stray[t] += a;
    }

    function _rescue(uint256 op, address t, address to) internal {
        bytes32 k = keccak256(abi.encodePacked(t, to));
        bool ok;
        bytes memory err;
        if (op < 2) {
            (ok, err) = address(w.router).call(op == 0
                ? abi.encodeCall(w.router.queueRescue, (t, to)) : abi.encodeCall(w.router.cancelRescue, (t, to)));
            if (gRenounced) { if (ok || !_isE(err, 1)) _fail("rescue queue open after renounce"); return; }
            if (!ok) _fail("rescue queue/cancel refused");
            gEta[k] = op == 0 ? block.timestamp + 48 hours : 0;
            return;
        }
        uint256 o = w.router.owed(t, 0) + w.router.owed(t, 1);
        uint256 d0 = _bal(t, to);
        (ok, err) = address(w.router).call(abi.encodeCall(w.router.executeRescue, (t, to)));
        if (gRenounced) { if (ok || !_isE(err, 1)) _fail("rescue open after renounce"); return; }
        if (gEta[k] == 0 || block.timestamp < gEta[k]) {
            if (ok || !_isE(err, 14)) _fail("rescue executed unqueued or inside its timelock");
            return;
        }
        if (!ok) { _fail("a due rescue was refused"); return; }
        if (_bal(t, to) - d0 != stray[t]) _fail("rescue amount != stray balance");
        if (w.router.owed(t, 0) + w.router.owed(t, 1) != o) _fail("rescue changed owed");
        gEta[k] = 0;
        stray[t] = 0;
        ++rescues;
    }

    // ------------------------------------------------------------------ scripted entry points
    function walkSwap(uint256 kind, uint256 door, uint256 actor, uint256 amt) external returns (bool) {
        return _swapOnce(kind, door, w.actors[actor], amt);
    }
    function walkClaim(address who, address t) external { _claim(who, t); }
    function walkMove(address who, address to) external { _move(who, to); }
    function walkPause(bool b) external { _pause(b); }
    function walkRenounce() external { _renounce(); }
    function walkDonate(address t, uint256 a) external { _donate(t, a); }
    function walkRescue(uint256 op, address t, address to) external { _rescue(op, t, to); }
}

contract AtqLedgerContextInvariantTest is Test {
    uint256 internal constant R = 1e24;
    uint256 internal constant FUND = 1e27;
    uint160 internal constant Q96 = uint160(1 << 96);
    uint128 internal constant LIQ3 = 1e27;
    uint128 internal constant LIQ4 = 1e26;

    AtqWorld internal w;
    AtqLedgerHandler internal h;

    function _pair(AtqToken a, AtqToken b) internal returns (MockV2Pair p) {
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        p = new MockV2Pair(t0, t1);
        a.mint(address(p), R);
        b.mint(address(p), R);
        p.setReserves(uint112(R), uint112(R));
    }

    function setUp() public {
        w.A = new AtqToken("A", 0);
        w.B = new AtqToken("B", 0);
        w.C = new AtqToken("C", 0);
        w.F = new AtqToken("F", 100);
        w.W = new AtqWETH();
        for (uint256 i; i < 4; ++i) w.tpool[i] = address(uint160(0x7100 + i));
        for (uint256 i; i < 3; ++i) w.actors[i] = address(uint160(0xA100 + i));
        w.dests = [address(0xD001), address(0xD002)];

        MockV4HookedManager mgr = new MockV4HookedManager();
        w.hub = new BlazePhoenixHub(address(this));
        w.hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(w.hub), address(0));
        w.router = new BlazePhoenixRouter(address(w.hub), address(solver), address(this), w.tpool[0], w.tpool[1]);
        w.hub.setRoles(address(w.router), address(solver), address(this));
        w.permit2 = new MockPermit2();
        w.router.setPermit2(address(w.permit2));
        w.router.setWeth(address(w.W));

        w.pAB = _pair(w.A, w.B);
        w.pBC = _pair(w.B, w.C);
        w.pWA = _pair(AtqToken(address(w.W)), w.A);
        w.pFB = _pair(w.F, w.B);
        MockV2Factory factory = new MockV2Factory();
        w.hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        factory.setPair(address(w.A), address(w.B), address(w.pAB));
        factory.setPair(address(w.B), address(w.C), address(w.pBC));
        w.hub.addBridge(address(w.B));

        w.qAB = new MockV3Pool(address(w.A), address(w.B), 3000);
        w.qAB.setState(Q96, LIQ3);
        w.A.mint(address(w.qAB), R);
        w.B.mint(address(w.qAB), R);

        (address c0, address c1) = BPC.sortTokens(address(w.A), address(w.B));
        w.pid4 = BPC.computeV4PoolId(c0, c1, 3000, 60, address(0));
        mgr.initialize(w.pid4, mgr.sqrtAt(60), 60, 3000);
        mgr.addPosition(w.pid4, 0, 120, 60, LIQ4);
        w.hub.addV4(c0, c1, 3000, 60, address(0));
        w.A.mint(address(mgr), R);
        w.B.mint(address(mgr), R);

        address[5] memory ts = [address(w.A), address(w.B), address(w.C), address(w.F), address(w.W)];
        for (uint256 a; a < 3; ++a) {
            vm.deal(w.actors[a], FUND);
            vm.startPrank(w.actors[a]);
            for (uint256 i; i < 5; ++i) {
                AtqToken(ts[i]).approve(address(w.router), type(uint256).max);
                AtqToken(ts[i]).approve(address(w.permit2), type(uint256).max);
            }
            vm.stopPrank();
            for (uint256 i; i < 5; ++i) AtqToken(ts[i]).mint(w.actors[a], FUND);
        }

        h = new AtqLedgerHandler(w);
        w.router.setAdmin(address(h));

        bytes4[] memory sels = new bytes4[](11);
        sels[0] = h.swap.selector;
        sels[1] = h.claim.selector;
        sels[2] = h.blockTreasury.selector;
        sels[3] = h.moveTreasury.selector;
        sels[4] = h.setTreasuries.selector;
        sels[5] = h.pause.selector;
        sels[6] = h.renounce.selector;
        sels[7] = h.rescue.selector;
        sels[8] = h.donate.selector;
        sels[9] = h.warp.selector;
        sels[10] = h.poke.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function _e(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    function _checkAll() internal view {
        assertEq(h.nBad(), 0, h.bad());
        address r = address(w.router);
        for (uint256 i; i < 5; ++i) {
            address t = h.toks(i);
            uint256 o = w.router.owed(t, 0) + w.router.owed(t, 1);
            assertEq(AtqToken(t).balanceOf(r), o + h.stray(t), "L1: router balance != owed + stray");
            if (t != address(w.F)) {
                uint256 s = o;
                for (uint256 j; j < 4; ++j) s += AtqToken(t).balanceOf(w.tpool[j]);
                assertEq(s, h.feeSum(t), "L2: treasuries + owed != fees charged");
            }
            for (uint256 a; a < 3; ++a) {
                assertEq(AtqToken(t).balanceOf(w.actors[a]) + h.spent(w.actors[a], t), FUND, "D: foreign token debit");
            }
        }
        assertEq(r.balance, 0, "L1: router holds ETH");
        for (uint256 a; a < 3; ++a) assertEq(w.actors[a].balance + h.ethSpent(w.actors[a]), FUND, "D: foreign ETH debit");

        assertEq(w.router.treasury1(), h.gT1(), "C: treasury1 drift");
        assertEq(w.router.treasury2(), h.gT2(), "C: treasury2 drift");
        assertEq(w.router.paused(), h.gPaused(), "C: paused drift");
        assertEq(w.router.controlRenounced(), h.gRenounced(), "C: renounced drift");
        assertFalse(w.router.paused() && w.router.controlRenounced(), "C: paused and renounced");
        assertEq(w.router.admin(), address(h), "C: admin changed");
        assertEq(w.router.permit2(), address(w.permit2), "C: permit2 changed");
        assertEq(w.router.weth(), address(w.W), "C: weth changed");
        for (uint256 i; i < 6; ++i) assertEq(w.router.rescueEta(h.keyOf(i)), h.gEta(h.keyOf(i)), "C: rescue eta drift");
    }

    function invariant_AtqRouterStateMachine() public view {
        _checkAll();
    }

    /// Anti-vacuity for the campaign: every route shape settles through every door at three
    /// magnitudes, inside one transaction, and the checks above hold after each of them.
    function test_AtqWalk_EveryKindAndDoorSettles() public {
        uint256[3] memory amts = [uint256(3e9), 1e18, 7e20];
        for (uint256 k; k < 7; ++k) {
            for (uint256 d; d < 4; ++d) {
                for (uint256 m; m < 3; ++m) {
                    assertTrue(h.walkSwap(k, d, (k + d + m) % 3, amts[m]),
                        string.concat("did not settle: kind ", vm.toString(k), " door ", vm.toString(d), " amount ", vm.toString(m)));
                }
                assertEq(h.settled(k * 4 + d), 3, "settled counter");
            }
        }
        assertEq(h.ctxReads(), 84, "every call had its context read");
        _checkAll();
    }

    /// The fee token is chosen by the Router's fee calendar, so the tests below take it from the
    /// Fee event instead of assuming it: both candidates are blocked and the one charged is used.
    function _blockedSwap() internal returns (AtqToken T, uint256 o0, uint256 o1) {
        for (uint256 j; j < 2; ++j) {
            w.A.setBlocked(w.tpool[j], true);
            w.B.setBlocked(w.tpool[j], true);
        }
        (bool ok, uint256 kept, uint256 keptCtl) = h.walkSwapKept(0, 0, 0, 1e18, address(w.C));
        assertTrue(ok, "swap with both treasuries blocked");
        T = AtqToken(h.lastFeeToken());
        assertTrue(address(T) == address(w.A) || address(T) == address(w.B), "fee token is a route token");
        o0 = w.router.owed(address(T), 0);
        o1 = w.router.owed(address(T), 1);
        assertGt(o0, 0, "slot 0 booked");
        assertGt(o1, 0, "slot 1 booked");
        assertEq(o0 + o1, h.feeSum(address(T)), "refused pushes are booked in full");
        // Positive and negative control of the transient reader, and the Router's own rule: what
        // it kept in this transaction is exactly what it booked as owed.
        assertEq(kept, o0 + o1, "the kept counter equals what was booked in this transaction");
        assertEq(keptCtl, 0, "nothing kept for a token that paid no fee");
    }

    function test_AtqBlockedTreasury_OwedBookedClaimExact() public {
        address t1 = w.tpool[0];
        address t2 = w.tpool[1];
        (AtqToken T, uint256 o0, uint256 o1) = _blockedSwap();
        address t = address(T);
        _checkAll();

        h.walkClaim(t1, t); // still blocked: the slot stays
        assertEq(w.router.owed(t, 0), o0, "blocked holder keeps its slot");
        T.setBlocked(t2, false);
        h.walkClaim(t2, t);
        assertEq(T.balanceOf(t2), o1, "treasury 2 is paid its own slot only");
        assertEq(w.router.owed(t, 0), o0, "slot 0 untouched by treasury 2");
        assertEq(w.router.owed(t, 1), 0, "slot 1 cleared");
        T.setBlocked(t1, false);
        h.walkClaim(t1, t);
        assertEq(T.balanceOf(t1), o0, "treasury 1 is paid its own slot only");
        vm.expectRevert(_e(1));
        vm.prank(t1);
        w.router.claimFee(t);
        h.walkClaim(h.STRANGER(), t);
        assertEq(h.claims(), 2, "two claims paid");
        _checkAll();
    }

    function test_AtqRescue_TimelockBoundarySingleUseOwedShield() public {
        address to = w.dests[0];
        (AtqToken T, uint256 o0, uint256 o1) = _blockedSwap();
        address t = address(T);
        uint256 o = o0 + o1;
        h.walkDonate(t, 5e18);

        h.walkRescue(2, t, to); // not queued
        h.walkRescue(0, t, to);
        uint256 eta = w.router.rescueEta(keccak256(abi.encodePacked(t, to)));
        assertEq(eta, vm.getBlockTimestamp() + 48 hours, "eta is now + 48 h");
        vm.warp(eta - 1);
        h.walkRescue(2, t, to);
        assertEq(T.balanceOf(to), 0, "nothing leaves one second before eta");
        vm.warp(eta);
        h.walkRescue(2, t, to);
        assertEq(T.balanceOf(to), 5e18, "rescue returns the stray balance at eta");
        assertEq(T.balanceOf(address(w.router)), o, "owed fees stay in the Router");
        assertEq(h.rescues(), 1, "one rescue executed");
        h.walkRescue(2, t, to); // single use

        h.walkDonate(t, 1e18);
        h.walkRescue(0, t, to);
        h.walkRescue(1, t, to);
        vm.warp(vm.getBlockTimestamp() + 49 hours);
        h.walkRescue(2, t, to);
        assertEq(T.balanceOf(to), 5e18, "a cancelled rescue never executes");

        vm.expectRevert(_e(3));
        vm.prank(address(h));
        w.router.queueRescue(t, address(0));
        _checkAll();
    }

    function test_AtqControl_GuardCodesAndSlotMoves() public {
        address t1 = w.tpool[0];
        address t2 = w.tpool[1];
        address n1 = w.tpool[2];
        address n2 = w.tpool[3];
        vm.startPrank(address(h));
        vm.expectRevert(_e(3));
        w.router.setAdmin(address(0));
        vm.expectRevert(_e(3));
        w.router.setTreasuries(address(0), n1);
        vm.expectRevert(_e(3));
        w.router.setTreasuries(n1, address(0));
        vm.stopPrank();
        vm.expectRevert(_e(3));
        vm.prank(t1);
        w.router.moveTreasury(address(0));

        h.walkMove(h.STRANGER(), n1);
        h.walkMove(t2, n2);
        assertEq(w.router.treasury1(), t1, "holder 2 does not move slot 1");
        assertEq(w.router.treasury2(), n2, "holder 2 moved slot 2");
        h.walkMove(t1, n1);
        assertEq(w.router.treasury1(), n1, "holder 1 moved slot 1");
        assertEq(w.router.treasury2(), n2, "holder 1 does not move slot 2");

        h.walkPause(true);
        for (uint256 d; d < 4; ++d) assertFalse(h.walkSwap(0, d, 0, 1e18), "a paused door settled");
        h.walkRenounce(); // refused with RouterE(2) while paused
        assertFalse(w.router.controlRenounced(), "renounce while paused");
        h.walkPause(false);
        assertTrue(h.walkSwap(0, 0, 0, 1e18), "unpaused door settles");

        h.walkRenounce();
        assertTrue(w.router.controlRenounced(), "renounced");
        h.walkPause(true);
        h.walkRescue(0, address(w.A), w.dests[0]);
        h.walkRescue(2, address(w.A), w.dests[0]);
        h.walkRenounce();
        for (uint256 s; s < 40; ++s) h.poke(s);
        assertEq(h.pokes(), 40, "pokes ran");
        h.walkMove(n1, t1); // moving a slot stays open to its holder after renounce
        assertEq(w.router.treasury1(), t1, "holder moves after renounce");
        assertTrue(h.walkSwap(1, 1, 1, 1e18), "swaps stay live after renounce");
        _checkAll();
    }
}
