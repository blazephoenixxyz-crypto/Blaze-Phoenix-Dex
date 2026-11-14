// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Hostile-token rows x venue kinds (V2, Solidly, V3, Algebra, V4, kind-9 Gate) x doors
// (swapExactIn, swapExactInWithPermit2, swapBestExactIn, swapExactInNative). The rows, the
// fixture and the per-cell rule are in regime/HostileRowsHarness.sol.

import {console2} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {HostileERC20} from "./mocks/HostileERC20.sol";
import {HostileRowsHarness} from "./regime/HostileRowsHarness.sol";
import {Outcomes} from "./regime/Outcomes.sol";

abstract contract HostileRowsCells is HostileRowsHarness {
    struct Snap {
        uint256 userSh; uint256 userBal; uint256 userEth;
        uint256 recBal; uint256 recSh; uint256 t1; uint256 t2; uint256 fShIn; uint256 fShOut;
    }

    function _pair(Kind k) internal pure returns (bool) { return k == Kind.V2 || k == Kind.SOLIDLY; }
    function _callback(Kind k) internal pure returns (bool) { return k == Kind.V3 || k == Kind.ALGEBRA || k == Kind.EXT; }

    /// @dev what the row must do at this door: SETTLE, REFUSE, or EITHER (the rule alone decides).
    function _want(Row r, Kind k, Door d) internal pure virtual returns (uint8) {
        uint8[47] memory w = [0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2,
                              0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 2, 2, 0, 0, 0, 2];
        // Permit2 carries the pull: it reads an oversized answer as a success, and the Router measures the delta
        if (r == Row.IN_PULL_OVERSIZED && d == Door.PERMIT2) return SETTLE;
        // a pair leg trades on what arrived; a leg settled inside a callback (V3 shape, V4, Gate) is owed an exact amount
        if (r == Row.IN_VENUE_SHORT2 || r == Row.IN_FOT30) return _pair(k) ? SETTLE : REFUSE;
        // tokenOut restated up inside the leg is more than the venue declared it paid
        if (r == Row.OUT_ROUTER_REB_UP && k != Kind.EXT) return REFUSE;
        return w[uint256(r)];
    }

    /// @dev the refusal a REFUSE cell must carry ("" = any).
    function _wantWhat(Row r, Kind k, Door d) internal pure virtual returns (string memory) {
        if (r == Row.IN_PULL_TRUE_NOMOVE) return "RouterE(8)";
        if (r == Row.IN_PULL_FALSE_NOMOVE || r == Row.IN_PULL_FALSE_MOVES || r == Row.IN_PULL_BLOCKED
            || r == Row.IN_PULL_GASBURN || r == Row.IN_PULL_OVERSIZED)
            return d == Door.PERMIT2 ? "TRANSFER_FROM_FAILED" : "BPC:transferFrom";
        if (r == Row.IN_VENUE_BLOCKED && k != Kind.V4) return "BPC:transfer";
        if (r == Row.IN_VENUE_TRUE_NOMOVE) return _pair(k) ? "RouterE(8)" : _callback(k) ? "RouterE(13)" : "";
        if (r == Row.IN_FOT30 && _callback(k)) return "RouterE(13)";
        if (r == Row.OUT_RECIP_BLOCKED || r == Row.OUT_RECIP_FALSE_NOMOVE || r == Row.OUT_RECIP_FALSE_MOVES
            || r == Row.OUT_RECIP_OVERSIZED || r == Row.OUT_RECIP_GASBURN) return "BPC:transfer";
        if (r == Row.OUT_RECIP_TRUE_NOMOVE) return "RouterE(5)";
        if (r == Row.OUT_ROUTER_REB_UP && k != Kind.EXT) return "RouterE(20)";
        return "";
    }

    // per-test overrides (the guards file drives single cells with them)
    uint8 forceWant = 255;
    uint256 wrapBps = 10_000;
    bool wrapRestates;
    bool loose;
    /// @dev leave a booked share standing (the cell does not claim it).
    bool noProbe;
    bool again;
    uint256 lastGas;
    bool lastOk;
    string lastWhat;

    /// @dev cells that are not part of the batch: each has a test of its own.
    function _known(Row r, Kind k, Door) internal pure virtual returns (bool) {
        return r == Row.IN_FEE_TRUE_NOMOVE || (r == Row.IN_FEE_REB_UP && _pair(k)) || (r == Row.OUT_ROUTER_REB_UP && k == Kind.EXT);
    }

    function _snap() private view returns (Snap memory s) {
        s.userSh = tIn.sharesOf(user); s.userBal = tIn.balanceOf(user); s.userEth = user.balance;
        s.recBal = tOut.balanceOf(recipient); s.recSh = tOut.sharesOf(recipient);
        s.t1 = tIn.balanceOf(T1); s.t2 = tIn.balanceOf(T2);
        s.fShIn = tIn.sharesOf(address(router)); s.fShOut = tOut.sharesOf(address(router));
    }

    function _fixture(Row r, Kind k, Door d) private {
        _stack();
        _tokens(r, k);
        _venue(k);
        // the Router's foreign balances (mis-sent money no swap may touch) and a recipient who already holds tokenOut
        tIn.mint(address(router), amt / 2);
        tOut.mint(address(router), 7 * 10 ** tOut.decimals());
        tOut.mint(recipient, depthOut / 100);
        if (d == Door.NATIVE) {
            router.setWeth(address(tIn));
            vm.deal(user, amt);
            tIn.setDepositBps(wrapBps);
            tIn.setDepositRebasesUp(wrapRestates);
        } else {
            tIn.mint(user, amt);
            vm.startPrank(user);
            tIn.approve(address(router), type(uint256).max);
            tIn.approve(address(p2), type(uint256).max);
            vm.stopPrank();
        }
        _arm(r);
    }

    function _cell(Row r, Kind k, Door d) internal {
        _fixture(r, k, d);
        again = false;
        _run(r, k, d);
    }

    /// @dev a second swap on what the last cell left standing: the same Router, pool and tokens.
    function _again(Row r, Kind k, Door d) internal {
        tIn.mint(user, amt);
        again = true;
        _run(r, k, d);
    }

    function _run(Row r, Kind k, Door d) private {
        tag = string.concat(_rowName(r), " ", _kindName(k), " ", _doorName(d), again ? " AGAIN" : "");
        Snap memory s = _snap();
        bytes memory cd = _calldata(d);
        uint256 value = d == Door.NATIVE ? amt : 0;
        vm.prank(user);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(router).call{gas: BLOCK_GAS, value: value}(cd);
        lastGas = g - gasleft();
        lastOk = ok;
        uint8 want = forceWant != 255 ? forceWant : _want(r, k, d);
        if (!ok) {
            (bool ours, string memory what) = Outcomes.classify(ret);
            lastWhat = what;
            string memory ww = forceWant != 255 ? "" : _wantWhat(r, k, d);
            if (bytes(ww).length != 0) _chk(keccak256(bytes(ww)) == keccak256(bytes(what)), string.concat("refused with ", what, ", expected ", ww));
            ++nRefused;
            _chk(tIn.sharesOf(user) == s.userSh && user.balance == s.userEth, "a refusal leaves the user untouched");
            _chk(want != SETTLE, string.concat("expected to settle, refused: ", what));
            console2.log("CELL", tag, string.concat(ours ? "REFUSED " : "REFUSED_FOREIGN ", what));
            return;
        }
        ++nSettled;
        _chk(want != REFUSE, "expected a refusal, settled");
        _settled(r, d, s, abi.decode(ret, (uint256)));
        console2.log("CELL", tag, "SETTLED");
    }

    function _kept(uint256 nowSh, uint256 wasSh, string memory rule) private {
        if (nowSh >= wasSh) return;
        _chk(false, rule);
        console2.log("     shares before / after", wasSh, nowSh);
    }

    function _settled(Row r, Door d, Snap memory s, uint256 got) private {
        // The Router reads the recipient's balance around the delivery alone. A tokenOut restated on its
        // way INTO the Router moved what the recipient already held before that read: value it at the
        // rate of the delivery.
        uint256 was = (_at(r) == AT_ROUTER && _restates(r)) ? s.recSh * tOut.num() / tOut.den() : s.recBal;
        uint256 rb = tOut.balanceOf(recipient);
        _chk(got == (rb > was ? rb - was : 0), "returned != the recipient's balance delta");
        _chk(got >= 1, "delivered below userMinOut");
        _kept(tIn.sharesOf(address(router)), s.fShIn, "the Router's foreign tokenIn shares were spent");
        _kept(tOut.sharesOf(address(router)), s.fShOut, "the Router's foreign tokenOut shares were spent");
        uint256 o0 = router.owed(address(tIn), 0);
        uint256 o1 = router.owed(address(tIn), 1);
        uint256 f1 = tIn.balanceOf(T1) - s.t1 + o0;
        uint256 f2 = tIn.balanceOf(T2) - s.t2 + o1;
        _chk(f1 + f2 > 0, "the fee was neither paid nor booked");
        if (_at(r) == AT_FEE && f1 == 0) {
            _chk(false, "treasury 1's share was neither paid nor booked");
            if (d != Door.NATIVE) console2.log("     the user paid / the ask", s.userBal - tIn.balanceOf(user), amt);
        }
        if (!_restates(r) && !loose) {
            // a token that delivers one wei short leaves that wei with the sender: here, the Router
            uint256 dust = (_m(r) == HostileERC20.Mode.SHORT && _at(r) == AT_RECIP) ? 1 : 0;
            _chk(tIn.sharesOf(address(router)) == s.fShIn + o0 + o1, "tokenIn residue on the Router");
            _chk(tOut.sharesOf(address(router)) == s.fShOut + dust, "tokenOut residue on the Router");
            _chk(f1 + f2 <= BPC.mulDivUp(amt, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "the fee exceeds 28 bps of the ask");
            if (d != Door.NATIVE) _chk(s.userBal - tIn.balanceOf(user) <= amt, "the user paid more than the ask");
        }
        if (d == Door.NATIVE) _chk(address(router).balance == 0, "ETH left on the Router");
        if (_m(r) == HostileERC20.Mode.HOOK) _reentryRefused(_at(r) >= AT_RECIP ? tOut : tIn);
        if (!noProbe && (r == Row.IN_FEE_BLOCKED || r == Row.IN_FEE_FALSE || r == Row.IN_FEE_GASBURN)) _probeBooked(s, o0);
        if (r == Row.IN_FEE_FALSE_MOVES || r == Row.IN_FEE_OVERSIZED || r == Row.IN_FEE_HOOK) {
            _chk(o0 == 0, "a push that moved the share was booked as well");
            _chk(tIn.balanceOf(T1) > s.t1, "the share did not reach treasury 1");
        }
    }

    /// @dev A refused push: booked, not moved; a slot owed nothing claims nothing; the owed slot
    ///      claims exactly the booking, once the token lets it, and the Router is back to its own.
    function _probeBooked(Snap memory s, uint256 o0) private {
        _chk(o0 > 0, "a refused push was not booked");
        _chk(tIn.balanceOf(T1) == s.t1, "a refused push moved tokens");
        tIn.setModeTo(T1, HostileERC20.Mode.NONE);
        bytes memory claim = abi.encodeCall(router.claimFee, (address(tIn)));
        vm.prank(T2);
        (bool ok2, bytes memory r2) = address(router).call(claim);
        _chk(!ok2 && keccak256(r2) == keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(1))),
             "a slot owed nothing must be refused with RouterE(1)");
        vm.prank(T1);
        (bool ok1,) = address(router).call(claim);
        _chk(ok1, "the owed slot could not claim");
        _chk(tIn.balanceOf(T1) - s.t1 == o0, "the claim did not pay exactly the booking");
        _chk(router.owed(address(tIn), 0) == 0, "the booking was not cleared");
        _chk(tIn.sharesOf(address(router)) == s.fShIn, "after the claim the Router holds more than its own");
    }

    function _batch(Kind k, Door d, uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            Row r = Row(i);
            if (d == Door.NATIVE && _at(r) == AT_PULL) continue; // the wrap is the pull: its own rows below
            if (_known(r, k, d)) continue;
            _cell(r, k, d);
        }
        console2.log("TOTAL settled/refused/violations", nSettled, nRefused, nViol);
        assertGt(nSettled, 0, "no cell settled: the fixture is broken");
        assertGt(nRefused, 0, "no cell was refused: the rows are not hostile");
        assertEq(nViol, 0, "a cell broke its rule: see the VIOL lines");
    }
}

contract HostileTokenRowsByDoorTest is HostileRowsCells {
    // The best door is not driven at V4 and at the Gate leg: on-chain discovery does not seat this
    // fixture's V4 pool nor its Gate wrapper (SolverE(5) on the honest row), so those cells would say nothing.
    function test_HostileRows_In_V2_Exact() public { _batch(Kind.V2, Door.EXACT, 0, FIRST_OUT); }
    function test_HostileRows_In_V2_Permit2() public { _batch(Kind.V2, Door.PERMIT2, 0, FIRST_OUT); }
    function test_HostileRows_In_V2_Best() public { _batch(Kind.V2, Door.BEST, 0, FIRST_OUT); }
    function test_HostileRows_In_V2_Native() public { _batch(Kind.V2, Door.NATIVE, 0, FIRST_OUT); }
    function test_HostileRows_In_Solidly_Exact() public { _batch(Kind.SOLIDLY, Door.EXACT, 0, FIRST_OUT); }
    function test_HostileRows_In_Solidly_Permit2() public { _batch(Kind.SOLIDLY, Door.PERMIT2, 0, FIRST_OUT); }
    function test_HostileRows_In_Solidly_Best() public { _batch(Kind.SOLIDLY, Door.BEST, 0, FIRST_OUT); }
    function test_HostileRows_In_Solidly_Native() public { _batch(Kind.SOLIDLY, Door.NATIVE, 0, FIRST_OUT); }
    function test_HostileRows_In_V3_Exact() public { _batch(Kind.V3, Door.EXACT, 0, FIRST_OUT); }
    function test_HostileRows_In_V3_Permit2() public { _batch(Kind.V3, Door.PERMIT2, 0, FIRST_OUT); }
    function test_HostileRows_In_V3_Best() public { _batch(Kind.V3, Door.BEST, 0, FIRST_OUT); }
    function test_HostileRows_In_V3_Native() public { _batch(Kind.V3, Door.NATIVE, 0, FIRST_OUT); }
    function test_HostileRows_In_Algebra_Exact() public { _batch(Kind.ALGEBRA, Door.EXACT, 0, FIRST_OUT); }
    function test_HostileRows_In_Algebra_Permit2() public { _batch(Kind.ALGEBRA, Door.PERMIT2, 0, FIRST_OUT); }
    function test_HostileRows_In_Algebra_Best() public { _batch(Kind.ALGEBRA, Door.BEST, 0, FIRST_OUT); }
    function test_HostileRows_In_Algebra_Native() public { _batch(Kind.ALGEBRA, Door.NATIVE, 0, FIRST_OUT); }
    function test_HostileRows_In_V4_Exact() public { _batch(Kind.V4, Door.EXACT, 0, FIRST_OUT); }
    function test_HostileRows_In_V4_Permit2() public { _batch(Kind.V4, Door.PERMIT2, 0, FIRST_OUT); }
    function test_HostileRows_In_V4_Native() public { _batch(Kind.V4, Door.NATIVE, 0, FIRST_OUT); }
    function test_HostileRows_In_Ext_Exact() public { _batch(Kind.EXT, Door.EXACT, 0, FIRST_OUT); }
    function test_HostileRows_In_Ext_Permit2() public { _batch(Kind.EXT, Door.PERMIT2, 0, FIRST_OUT); }
    function test_HostileRows_In_Ext_Native() public { _batch(Kind.EXT, Door.NATIVE, 0, FIRST_OUT); }
    function test_HostileRows_Out_V2_Exact() public { _batch(Kind.V2, Door.EXACT, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V2_Permit2() public { _batch(Kind.V2, Door.PERMIT2, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V2_Best() public { _batch(Kind.V2, Door.BEST, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V2_Native() public { _batch(Kind.V2, Door.NATIVE, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Solidly_Exact() public { _batch(Kind.SOLIDLY, Door.EXACT, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Solidly_Permit2() public { _batch(Kind.SOLIDLY, Door.PERMIT2, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Solidly_Best() public { _batch(Kind.SOLIDLY, Door.BEST, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Solidly_Native() public { _batch(Kind.SOLIDLY, Door.NATIVE, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V3_Exact() public { _batch(Kind.V3, Door.EXACT, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V3_Permit2() public { _batch(Kind.V3, Door.PERMIT2, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V3_Best() public { _batch(Kind.V3, Door.BEST, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V3_Native() public { _batch(Kind.V3, Door.NATIVE, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Algebra_Exact() public { _batch(Kind.ALGEBRA, Door.EXACT, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Algebra_Permit2() public { _batch(Kind.ALGEBRA, Door.PERMIT2, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Algebra_Best() public { _batch(Kind.ALGEBRA, Door.BEST, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Algebra_Native() public { _batch(Kind.ALGEBRA, Door.NATIVE, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V4_Exact() public { _batch(Kind.V4, Door.EXACT, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V4_Permit2() public { _batch(Kind.V4, Door.PERMIT2, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_V4_Native() public { _batch(Kind.V4, Door.NATIVE, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Ext_Exact() public { _batch(Kind.EXT, Door.EXACT, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Ext_Permit2() public { _batch(Kind.EXT, Door.PERMIT2, FIRST_OUT, NROWS); }
    function test_HostileRows_Out_Ext_Native() public { _batch(Kind.EXT, Door.NATIVE, FIRST_OUT, NROWS); }
}
