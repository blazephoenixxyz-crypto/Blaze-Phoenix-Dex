// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC, Route, Leg} from "../../../../src/BlazePhoenixCore.sol";
import {BlazePhoenixQuoter} from "../../../../src/BlazePhoenixQuoter.sol";
import {AvaxForkBase} from "../AvaxForkBase.sol";

/// @dev The ERC-20 read and the approval the battery needs.
interface IS9Token {
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Measurement helpers of the S9 gas battery on the Avalanche fork. No assertion lives
///         here: the battery (AvaxS9Battery.t.sol) decides what each measurement must satisfy.
/// @dev    Gas is measured cold: a recon run records every account the call touches, the state
///         is reverted, each touched account is cooled (vm.cool), and the call runs again under a
///         snapshot that is reverted too. The figure is the execution gas of that call (no 21k
///         intrinsic, no calldata gas). A swap's output is the recipient's balance delta, never
///         the call's return value. The recon's state diff is read in place (only the touched
///         accounts are copied out): decoding it whole grows the measuring frame's memory by
///         megabytes, and the copy of the measured call's return data would then pay for that
///         memory inside the figure.
abstract contract S9Lib is AvaxForkBase {
    string internal constant OUTDIR = "out/pc-trace/s9-avax/";

    /// The swapper of every cell (an EOA, set by the battery's _afterDeploy).
    address internal user;
    /// Output of the house quote for 100 USDC, per token: the battery's price unit.
    mapping(address => uint256) internal out100;
    /// Readable name of each Gate wrapper (family/binStep), set when it is created.
    mapping(address => string) internal venueName;

    struct Measured {
        bool ok;
        uint256 gas;
        uint256 out;
        bytes ret;
    }

    /// One TSV row: a cell in one gas mode ("-" where the mode has no value).
    struct Row {
        string cell;
        string test;
        string pair;
        uint256 usd;
        uint256 amountIn;
        address tOut;
        string mode;
        string status;
        bool measured;
        uint256 gas;
        bool quoted;
        uint256 quote;
        bool executed;
        uint256 exec;
        uint256 minOut;
        uint256 hops;
        string route;
        string note;
    }

    /// @dev Short name of a battery token (the battery owns the token table).
    function _sym(address t) internal view virtual returns (string memory);

    /// @dev The house price of `t`: what the Quoter gives for 100 USDC (6 decimals), under a
    ///      snapshot. Zero when it finds no route: the cell then says so instead of guessing.
    function _price(address t) internal {
        if (out100[t] != 0) return;
        uint256 h = 100e6;
        if (t == USDC) {
            out100[t] = h;
            return;
        }
        uint256 s = vm.snapshotState();
        (bool ok, bytes memory r) =
            address(quoter).call(abi.encodeCall(BlazePhoenixQuoter.previewPlanExact, (USDC, t, h)));
        vm.revertToStateAndDelete(s);
        if (ok) (, out100[t]) = abi.decode(r, (Route, uint256));
    }

    /// @dev Gas in tOut wei at the block basefee, paid in WAVAX (no L1 data fee on Avalanche).
    function _gasIn(address tOut, uint256 g) internal view returns (uint256) {
        uint256 w = g * block.basefee;
        if (tOut == WAVAX) return w;
        return out100[WAVAX] == 0 ? 0 : w * out100[tOut] / out100[WAVAX];
    }

    /// @dev Cold measurement of `entry.call(cd)` sent by the user. Never commits, never reverts
    ///      the test. `tOut` zero skips the balance read (the discovery call pays nobody). The
    ///      balance is read before the cooling and after the gas figure, so it costs it nothing.
    function _measure(address entry, bytes memory cd, address tOut) internal returns (Measured memory m) {
        uint256 b0 = tOut == address(0) ? 0 : IS9Token(tOut).balanceOf(user);
        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(user);
        (bool ok, bytes memory ret) = entry.call(cd);
        address[] memory touched = _stopAndReadAccounts();
        vm.revertToStateAndDelete(snap);
        if (!ok) {
            m.ret = ret;
            return m;
        }
        _coolAll(touched, entry);
        snap = vm.snapshotState();
        vm.prank(user);
        uint256 g = gasleft();
        (m.ok, m.ret) = entry.call(cd);
        m.gas = g - gasleft();
        if (m.ok && tOut != address(0)) m.out = IS9Token(tOut).balanceOf(user) - b0;
        vm.revertToStateAndDelete(snap);
    }

    /// @dev Cools every touched account but the sender, the entry (warm in a real call: it is
    ///      the transaction's target), this contract, the cheatcode and console addresses and the
    ///      precompiles.
    function _coolAll(address[] memory acc, address entry) internal {
        for (uint256 i; i < acc.length; ++i) {
            address a = acc[i];
            if (a == user || a == entry || a == address(this) || a == address(vm) || uint160(a) < 0x100
                || a == CONSOLE) continue;
            vm.cool(a);
        }
    }

    /// @dev vm.stopAndReturnStateDiff without decoding it: the account of each AccountAccess is
    ///      copied straight from the return data. Layout: word 0 the array's offset o, at o its
    ///      length n, then n element offsets counted from o + 32; an element's head is chainInfo
    ///      (2 words), kind, account.
    function _stopAndReadAccounts() internal returns (address[] memory a) {
        address cheat = address(vm);
        bytes4 sel = vm.stopAndReturnStateDiff.selector;
        assembly ("memory-safe") {
            a := mload(0x40)
            mstore(a, sel)
            if iszero(call(gas(), cheat, 0, a, 4, 0, 0)) { revert(0, 0) }
            returndatacopy(a, 0, 0x20)
            let base := add(mload(a), 0x20)
            returndatacopy(a, sub(base, 0x20), 0x20)
            let n := mload(a)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let w := add(a, mul(add(i, 1), 0x20))
                returndatacopy(w, add(base, mul(i, 0x20)), 0x20)
                returndatacopy(w, add(add(base, mload(w)), 0x60), 0x20)
            }
            mstore(0x40, add(a, mul(add(n, 1), 0x20)))
        }
    }

    function _fund(address tIn, uint256 x) internal {
        deal(tIn, user, x);
        vm.prank(user);
        IS9Token(tIn).approve(address(router), type(uint256).max);
    }

    /// @dev External door to _fund, so a token stdstore cannot deal ends one cell, not the test.
    function fundExt(address tIn, uint256 x) external {
        require(msg.sender == address(this), "S9: self only");
        _fund(tIn, x);
    }

    function _bps(int256 num, uint256 den) internal pure returns (int256) {
        return den == 0 ? int256(0) : num * 10_000 / int256(den);
    }

    function _or(string memory x, string memory d) internal pure returns (string memory) {
        return bytes(x).length == 0 ? d : x;
    }

    function _n(uint256 v, bool has) internal pure returns (string memory) {
        return has ? vm.toString(v) : "-";
    }

    /// @dev A Leg's first member (the venue address), read by offset as AvaxBlackholeCore does.
    function _legVenue(Leg memory l) internal pure returns (address a) {
        assembly ("memory-safe") {
            a := mload(l)
        }
    }

    /// @dev "family/parameter@venue": the Gate wrapper's name, the Algebra row, or, for the V3
    ///      kind, the factory the venue reports (Uniswap V3 by fee, Pharaoh V3 by spacing).
    function _venueLabel(Leg memory l) internal view returns (string memory s) {
        address v = _legVenue(l);
        s = venueName[v];
        if (bytes(s).length == 0) {
            if (l.kind == BPC.KIND_ALGEBRA) {
                s = "blackhole-algebra";
            } else if (l.kind == KIND_V3) {
                (bool ok, bytes memory r) = v.staticcall(abi.encodeWithSignature("factory()"));
                address f = ok && r.length == 32 ? abi.decode(r, (address)) : address(0);
                if (f == UNIV3_FACTORY) s = string.concat("univ3/", vm.toString(uint256(l.fee)));
                else if (f == PHARAOH_V3_FACTORY || f == PHARAOH_V3_DEPLOYER) {
                    s = string.concat("pharaoh-v3/", vm.toString(int256(l.tickSpacing)));
                } else {
                    s = string.concat("v3-other/", vm.toString(uint256(l.fee)));
                }
            } else {
                s = string.concat("kind", vm.toString(uint256(l.kind)));
            }
        }
        s = string.concat(s, "@", vm.toString(v));
    }

    /// @dev The route as "tIn>tOut:venue+venue | tIn>tOut:venue".
    function _routeText(Route memory rt) internal view returns (string memory s) {
        for (uint256 h; h < rt.hops.length; ++h) {
            s = string.concat(
                s, h == 0 ? "" : " | ", _sym(rt.hops[h].tokenIn), ">", _sym(rt.hops[h].tokenOut), ":"
            );
            for (uint256 k; k < rt.hops[h].legs.length; ++k) {
                s = string.concat(s, k == 0 ? "" : "+", _venueLabel(rt.hops[h].legs[k]));
            }
        }
    }

    /// @dev Columns: cell, test, pair, amount_usd, amount_in_wei, mode, status, gas_cold,
    ///      gas_cost_out_wei, quote_wei, exec_wei, exec_minus_quote_wei, div_bps, min_out_wei,
    ///      route_hops, route, note (the runner adds the header and the cell's scope columns).
    function _write(string memory file, Row memory r) internal {
        string memory s = string.concat(
            r.cell, "\t", r.test, "\t", r.pair, "\t", vm.toString(r.usd), "\t", vm.toString(r.amountIn), "\t",
            r.mode, "\t", r.status, "\t"
        );
        s = string.concat(
            s, _n(r.gas, r.measured), "\t", _n(_gasIn(r.tOut, r.gas), r.measured), "\t", _n(r.quote, r.quoted),
            "\t", _n(r.exec, r.executed), "\t"
        );
        bool cmp = r.executed && r.quoted;
        int256 d = int256(r.exec) - int256(r.quote);
        s = string.concat(
            s, cmp ? vm.toString(d) : "-", "\t", cmp ? vm.toString(_bps(d, r.quote)) : "-", "\t",
            _n(r.minOut, r.minOut != 0), "\t", _n(r.hops, r.hops != 0), "\t", _or(r.route, "-"), "\t",
            _or(r.note, "-")
        );
        vm.writeLine(file, s);
    }
}
