// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/console2.sol";
import {BlazePhoenixCore as BPC, Route} from "../../../src/BlazePhoenixCore.sol";
import {BlazePhoenixRouter} from "../../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixAdapterLB} from "../../../src/adapters/BlazePhoenixAdapterLB.sol";
import {S9Lib} from "./proto/S9Lib.sol";

/// @notice S9 gas battery on the Avalanche fork (FORK_BLOCK), without a plan: this tree has no
///         BlazePhoenixCert, so each cell is measured in three modes (discovery = the Quoter's
///         previewPlanExact as an eth_call; quoted = Router.swapExactIn on that route; on-chain =
///         Router.swapBestExactIn) and the fourth (on-chain with a plan) is written as "na".
/// @dev    Hub rows: Uniswap V3 (mode 5), Pharaoh V3 (mode 3, the mode whose execution
///         AvaxCoreV3 checks), the Blackhole base Algebra row (mode 5, kind 6, as in
///         AvaxBlackholeCore) and the Gate with the LFJ v2.1, LFJ v2.2 and Pharaoh DLMM adapters:
///         one wrapper per chosen LBPair (TVL >= 1k USD, highest first, at most 4 per sorted
///         pair, 3 where a Blackhole custom venue >= 1k USD keeps a slot for its own adapter).
///         Bridges: WAVAX, USDC, BTC.b (AvaxForkBase). Cells: celulas-avax.tsv refiltered to
///         these venues and bridges, at most 2 hops, one test per fee regime of the Quoter
///         (Quoter.sol:820-835). Each cell ASSERTS that the quoted swap succeeds and pays the
///         recipient at least the quote (to the wei, or above it where the Quoter returns a
///         floor by design: Quoter.sol:832-846) and at least minOut, and that the on-chain swap
///         succeeds with at least minOut; a cell pinned in KNOWN must instead fail exactly as
///         pinned. A cell without a route, or quoted 0, is a row with its cause, not a failure
///         (unless it is pinned). S9_ONLY (comma list of cell ids) restricts a run to those cells.
///         Rows: out/pc-trace/s9-avax/rows-<test>.tsv, rewritten by each run of the test.
///         Every cell runs under a snapshot the loop reverts, so no cell inherits the state an
///         earlier one left (its funding and approval): without it 134 of the 172 swap figures
///         depended on the cells run before them, by up to 37 000 gas.
///         Run it with FOUNDRY_GAS_LIMIT=9223372036854775807, FOUNDRY_DISABLE_BLOCK_GAS_LIMIT=true
///         and FOUNDRY_MEMORY_LIMIT=536870912: a test spends up to 2.9G gas (TwoHops_ExotBridge),
///         past the default limit of 1 073 741 824, and an inline forge-config gas_limit is not
///         applied by forge 1.8.5. Scope it with FOUNDRY_TEST=test/fork/avax and --match-path.
contract AvaxS9BatteryTest is S9Lib {
    address internal constant COQ = 0x420FcA0121DC28039145009570975747295f2329;
    address internal constant SAVAX = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address internal constant JOE = 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd;
    address internal constant ARENA = 0xB8d7710f7d8349A506b75dD184F05777c82dAd0C;
    address internal constant QI = 0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5;
    address internal constant LINKE = 0x5947BB275c521040051D82396192181b413227A3;
    address internal constant BLACK = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;

    // Blackhole base (Algebra): the row AvaxBlackholeCore admits.
    address internal constant BH_FACTORY = 0x512eb749541B7cf294be882D636218c84a5e9E5F;
    bytes32 internal constant BH_INIT = 0xeaa3eea3233916c82fe1281a51bd9cde844b7c4673c0714ca0028a57f5634752;

    // Liquidity Book factories; Gate family 1, 2, 3 in this order (as in AvaxLB).
    address internal constant LB21_FACTORY = 0x8e42f2F4101563bF679975178e880FD87d3eFd4e;
    address internal constant LB22_FACTORY = 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c;
    address internal constant DLMM_FACTORY = 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D;

    /// minOut = quote less 50 bps (an assumed SDK default slippage).
    uint256 internal constant SDK_SLIP_BPS = 50;
    string internal constant NO_PLAN = "no plan in this tree (no BlazePhoenixCert)";

    /// The cells that do not pass at FORK_BLOCK, 3 bytes each: id, then the RouterE code of the
    /// quoted swap and of the on-chain swap (0 = passes). A record of the block, not a pass
    /// list: a pinned cell that passes, finds no route or fails with another error fails its
    /// test like any other cell, so a fix in src shows up here as a red cell to unpin.
    /// RouterE(5), 44 quoted and 37 on-chain. The site of each, from a run with every site's
    /// code renamed: the leg floor of `_execScaled` (38 quoted, 34 on-chain), the route floor
    /// `amountOut < effMin` (6 quoted, 2 on-chain: c002, c014, c055, c056, c063, c064) and the
    /// hop check of `_execScaled` (1 on-chain: c118). Both floors rest on the Router's in-frame
    /// quote, which prices a V3 leg at the liquidity of its current band (no boundary clamp,
    /// Core `outV3`): the leg floor through the coverage lift (half the in-frame quote, the
    /// MIN_QUOTE_COVERAGE_BPS bound) and the route floor through the protocol floor (the
    /// in-frame quote of the final hop). Where the next bands are thin that quote sits far above
    /// what the leg pays, and an honest route trips the floor. With the lift and the protocol
    /// floor both removed every quoted cell passes; 5 on-chain cells still fail, at the hop
    /// check (c118, c119, c120) and at the leg floor on the plan's own figure (c173, c181,
    /// routed in 3 hops). RouterE(17), 11 on-chain: the Solver runs past SOLVE_GAS.
    bytes internal constant KNOWN = hex"0205050305050405050b05050c05050e05051700111800111f05112005112105052205052905052a05053705113805113f05114005115800115f05116005117305057405057600057705057805057b05057c05057f05058005058305058405058705058805059d05059e0505a10505a20505a50505a60505a90505aa0505ad0505b50505c70505c80505cd0505ce0505";

    // Cells, 4 bytes each: id (cNNN, the order of the refiltered list), token in, token out (the
    // index in _tok), amount in thousands of USD. Generated from the refiltered cell list.
    bytes internal constant CELLS_INTO_BRIDGE = hex"010300010203000a03030064040300fa110400011204000a13040064140400fa210500012205000a23050064240500fa310600013206000a33060064340600fa410700014207000a43070064440700fa510800015208000a53080064540800fa610900016209000a63090064640900fa";
    bytes internal constant CELLS_FROM_BRIDGE = hex"050003010600030a07000364080003fa150004011600040a17000464180004fa250005012600050a27000564280005fa350006013600060a37000664380006fa450007014600070a47000764480007fa550008015600080a57000864580008fa650009016600090a67000964680009fa";
    bytes internal constant CELLS_TWO_HOPS_EXOT_BRIDGE = hex"090301010a03010a0b0301640c0301fa0d0103010e01030a0f010364100103fa190401011a04010a1b0401641c0401fa1d0104011e01040a1f010464200104fa290501012a05010a2b0501642c0501fa2d0105012e01050a2f010564300105fa390601013a06010a3b0601643c0601fa3d0106013e01060a3f010664400106fa490701014a07010a4b0701644c0701fa4d0107014e01070a4f010764500107fa590801015a08010a5b0801645c0801fa5d0108015e01080a5f010864600108fa690901016a09010a6b0901646c0901fa6d0109016e01090a6f010964700109fac5030201c603020ac7030264c80302fac9040201ca04020acb040264cc0402facd050201ce05020acf050264d00502fad1060201d206020ad3060264d40602fad5070201d607020ad7070264d80702fad9080201da08020adb080264dc0802fadd090201de09020adf090264e00902fa";
    bytes internal constant CELLS_TWO_HOPS_EXOT_EXOT = hex"710304017203040a73030464740304fa750305017603050a77030564780305fa790306017a03060a7b0306647c0306fa7d0307017e03070a7f030764800307fa810308018203080a83030864840308fa850309018603090a87030964880309fa890405018a04050a8b0405648c0405fa8d0406018e04060a8f040664900406fa910407019204070a93040764940407fa950408019604080a97040864980408fa990409019a04090a9b0409649c0409fa9d0506019e05060a9f050664a00506faa1050701a205070aa3050764a40507faa5050801a605080aa7050864a80508faa9050901aa05090aab050964ac0509faad060701ae06070aaf060764b00607fab1060801b206080ab3060864b40608fab5060901b606090ab7060964b80609fab9070801ba07080abb070864bc0708fabd070901be07090abf070964c00709fac1080901c208090ac3080964c40809fa";

    struct Cell {
        uint8 n;
        string id;
        address tIn;
        address tOut;
        uint256 usd;
        string pair;
    }

    struct Tally {
        uint256 run;
        uint256 routed;
        uint256 eq;
        uint256 bad;
    }

    function _afterDeploy() internal override {
        user = makeAddr("s9-user");
        _addUniV3Row();
        _addPharaohV3Row(MODE_CALL_V3CL);
        _addRow(BH_FACTORY, BPC.KIND_ALGEBRA, MODE_CREATE2_V3, BH_INIT, new uint24[](1), new int24[](0));
        _mountLB();
    }

    /// @dev propose -> ADAPTER_DELAY -> accept for the three families, back to the block's own
    ///      time (the Algebra and LB fees read it), one wrapper per chosen LBPair (hint = its bin
    ///      step), then the Gate's Hub row with the venue keys in use.
    function _mountLB() internal {
        address[3] memory fac = [LB21_FACTORY, LB22_FACTORY, DLMM_FACTORY];
        for (uint8 f = 1; f <= 3; ++f) {
            gate.proposeAdapter(f, address(new BlazePhoenixAdapterLB(address(gate), fac[f - 1])));
        }
        uint256 t0 = block.timestamp;
        vm.warp(t0 + gate.ADAPTER_DELAY());
        for (uint8 f = 1; f <= 3; ++f) gate.acceptAdapter(f);
        vm.warp(t0);
        // family, slot, sorted pair, bin step, name; TVL in USD at FORK_BLOCK
        _lb(1, 1, BTCB, USDC, 10, "lb21/10"); // 961806
        _lb(3, 1, BTCB, USDC, 5, "dlmm/5"); // 678574
        _lb(3, 2, BTCB, USDC, 25, "dlmm/25"); // 193452
        _lb(1, 1, BTCB, WAVAX, 10, "lb21/10"); // 161798
        _lb(2, 1, BTCB, WAVAX, 5, "lb22/5"); // 51195
        _lb(1, 1, COQ, USDC, 100, "lb21/100"); // 7478
        _lb(2, 1, COQ, WAVAX, 50, "lb22/50"); // 7169
        _lb(1, 1, COQ, WAVAX, 100, "lb21/100"); // 3621
        _lb(1, 1, JOE, WAVAX, 15, "lb21/15"); // 39910
        _lb(2, 1, JOE, WAVAX, 25, "lb22/25"); // 4200
        _lb(2, 1, QI, WAVAX, 25, "lb22/25"); // 13071
        _lb(1, 1, QI, WAVAX, 25, "lb21/25"); // 2477
        _lb(2, 1, WAVAX, ARENA, 100, "lb22/100"); // 85868
        _lb(2, 1, WAVAX, BLACK, 10, "lb22/10"); // 7192
        _lb(3, 1, WAVAX, USDC, 5, "dlmm/5"); // 3715391
        _lb(2, 1, WAVAX, USDC, 10, "lb22/10"); // 361991
        _lb(1, 1, WAVAX, USDC, 20, "lb21/20"); // 169270
        _lb(2, 1, SAVAX, WAVAX, 5, "lb22/5"); // 100747
        _lb(1, 1, SAVAX, WAVAX, 5, "lb21/5"); // 1934
        uint24[] memory keys = new uint24[](4);
        (keys[0], keys[1], keys[2], keys[3]) = (_key(1, 1), _key(2, 1), _key(3, 1), _key(3, 2));
        _addRow(address(gate), BPC.KIND_EXTERNAL, MODE_CREATE2_V3, gate.WRAPPER_INIT_HASH(), keys, new int24[](0));
    }

    function _key(uint8 family, uint8 slot) internal pure returns (uint24) {
        return (uint24(family) << 16) | slot;
    }

    /// @dev One wrapper. An LBPair the adapter refuses (an AFTER_SWAP hook, for one) is logged
    ///      and left out, so it cannot end the whole setUp.
    function _lb(uint8 family, uint8 slot, address a, address b, uint256 binStep, string memory name) internal {
        try gate.create(a, b, _key(family, slot), abi.encode(binStep)) returns (address w) {
            venueName[w] = name;
        } catch (bytes memory err) {
            console2.log(string.concat("S9|lb-skip|", name, "|", _sym(a), "-", _sym(b), "|", vm.toString(err)));
        }
    }

    function _tok(uint256 i) internal pure returns (address) {
        if (i == 0) return WAVAX;
        if (i == 1) return USDC;
        if (i == 2) return BTCB;
        if (i == 3) return COQ;
        if (i == 4) return SAVAX;
        if (i == 5) return JOE;
        if (i == 6) return ARENA;
        if (i == 7) return QI;
        if (i == 8) return LINKE;
        if (i == 9) return BLACK;
        revert("S9: token index");
    }

    function _sym(address t) internal pure override returns (string memory) {
        if (t == WAVAX) return "WAVAX";
        if (t == USDC) return "USDC";
        if (t == BTCB) return "BTC.b";
        if (t == COQ) return "COQ";
        if (t == SAVAX) return "sAVAX";
        if (t == JOE) return "JOE";
        if (t == ARENA) return "ARENA";
        if (t == QI) return "QI";
        if (t == LINKE) return "LINK.e";
        if (t == BLACK) return "BLACK";
        return vm.toString(t);
    }

    // ------------------------------------------------------------------ one test per fee regime

    /// Expected 1 hop into a bridge (a 1-hop route into a bridge pays the fee on the output).
    function test_S9_Direct_IntoBridge() public {
        _battery("IntoBridge", CELLS_INTO_BRIDGE);
    }

    /// Expected 1 hop out of a bridge (the fee is taken on the input).
    function test_S9_Direct_FromBridge() public {
        _battery("FromBridge", CELLS_FROM_BRIDGE);
    }

    /// Expected 2 hops, exotic to bridge (a 2-hop route pays at its anchor hop's input).
    function test_S9_TwoHops_ExotBridge() public {
        _battery("TwoHopsExotBridge", CELLS_TWO_HOPS_EXOT_BRIDGE);
    }

    /// Expected 2 hops, exotic to exotic through a bridge.
    function test_S9_TwoHops_ExotExot() public {
        _battery("TwoHopsExotExot", CELLS_TWO_HOPS_EXOT_EXOT);
    }

    function _battery(string memory name, bytes memory cells) internal {
        string memory file = string.concat(OUTDIR, "rows-", name, ".tsv");
        vm.createDir(OUTDIR, true);
        if (vm.exists(file)) vm.removeFile(file);
        string memory only = string.concat(",", vm.envOr("S9_ONLY", string("")), ",");
        bool all = bytes(only).length == 2;
        _price(WAVAX);
        Tally memory t;
        for (uint256 i; i + 3 < cells.length; i += 4) {
            Cell memory c = _decode(cells, i);
            if (!all && vm.indexOf(only, string.concat(",", c.id, ",")) == type(uint256).max) continue;
            ++t.run;
            _price(c.tIn); // the price cache outlives the cell's snapshot
            _price(c.tOut);
            uint256 snap = vm.snapshotState();
            try this.cellExt(name, file, cells, i) returns (bool routed, bool eq, uint256 bad) {
                if (routed) ++t.routed;
                else if (_pinned(c.n)) ++t.bad; // a pinned cell that no longer reaches its swaps
                if (eq) ++t.eq;
                t.bad += bad;
            } catch (bytes memory err) {
                ++t.bad;
                vm.writeLine(file, string.concat(c.id, "\t", name, "\t", c.pair, "\t", vm.toString(c.usd),
                    "\t-\tcell\terror\t-\t-\t-\t-\t-\t-\t-\t-\t-\t", vm.toString(err)));
            }
            vm.revertToStateAndDelete(snap);
        }
        console2.log(string.concat("S9|", name, "|run=", vm.toString(t.run), "|routed=", vm.toString(t.routed),
            "|eq=", vm.toString(t.eq), "|bad=", vm.toString(t.bad), "|basefee=", vm.toString(block.basefee),
            "|ts=", vm.toString(block.timestamp)));
        if (t.run != 0) assertGt(t.routed, 0, "S9: no cell of this test found a route");
        assertEq(t.bad, 0, "S9: a cell left its pinned outcome, or a swap paid less than its bound");
    }

    /// @dev One cell in its own call frame, under the caller's snapshot: its memory is freed on
    ///      return, its state is reverted after it, and an unexpected revert is caught by the
    ///      caller and counted as a failure.
    function cellExt(string memory name, string memory file, bytes memory cells, uint256 i)
        external
        returns (bool routed, bool eq, uint256 bad)
    {
        require(msg.sender == address(this), "S9: self only");
        Cell memory c = _decode(cells, i);
        _price(c.tIn);
        _price(c.tOut);
        Row memory w;
        (w.cell, w.test, w.pair, w.usd, w.tOut) = (c.id, name, c.pair, c.usd, c.tOut);
        w.amountIn = c.usd * out100[c.tIn] / 100;
        if (w.amountIn == 0) {
            _stop(file, w, "no_price", "no house quote for 100 USDC to the token in");
            return (false, false, 0);
        }
        try this.fundExt(c.tIn, w.amountIn) {}
        catch {
            _stop(file, w, "no_fund", "stdstore could not deal the token in");
            return (false, false, 0);
        }
        Measured memory d = _measure(
            address(quoter),
            abi.encodeCall(BlazePhoenixQuoter.previewPlanExact, (c.tIn, c.tOut, w.amountIn)),
            address(0)
        );
        if (!d.ok) {
            _stop(file, w, "no_route", string.concat("previewPlanExact reverted: ", vm.toString(d.ret)));
            return (false, false, 0);
        }
        (Route memory rt, uint256 q) = abi.decode(d.ret, (Route, uint256));
        (w.measured, w.gas, w.quoted, w.quote) = (true, d.gas, true, q);
        (w.hops, w.route) = (rt.hops.length, _routeText(rt));
        if (q == 0) {
            _stop(file, w, "quote_zero", "the Quoter returned a route quoted 0");
            return (false, false, 0);
        }
        (eq, bad) = _swaps(file, w, c, rt);
        routed = true;
    }

    /// @dev The four rows of a cell that stops before any swap, each with the cause.
    function _stop(string memory file, Row memory w, string memory status, string memory note) internal {
        (w.mode, w.status, w.note) = ("discovery", status, note);
        _write(file, w);
        (w.measured, w.hops, w.route) = (false, 0, "");
        w.mode = "quoted";
        _write(file, w);
        w.mode = "onchain_no_plan";
        _write(file, w);
        (w.mode, w.status, w.note) = ("onchain_with_plan", "na", NO_PLAN);
        _write(file, w);
    }

    /// @dev The quoted swap on the given route and the on-chain swap, both cold, then the rows.
    function _swaps(string memory file, Row memory w, Cell memory c, Route memory rt)
        internal
        returns (bool eq, uint256 bad)
    {
        uint256 q = w.quote;
        uint256 gD = w.gas;
        w.minOut = q * (10_000 - SDK_SLIP_BPS) / 10_000;
        if (w.minOut == 0) w.minOut = 1;
        uint256 dl = block.timestamp + 600;
        Measured memory e = _measure(
            address(router),
            abi.encodeCall(BlazePhoenixRouter.swapExactIn, (rt, w.amountIn, w.minOut, user, dl)),
            c.tOut
        );
        Measured memory b = _measure(
            address(router),
            abi.encodeCall(BlazePhoenixRouter.swapBestExactIn, (c.tIn, c.tOut, w.amountIn, w.minOut, user, dl)),
            c.tOut
        );
        (uint256 qk, uint256 bk) = _known(c.n);
        eq = e.ok && e.out == q;
        if ((e.ok ? 0 : _routerCode(e.ret)) != qk || (e.ok && (e.out < q || e.out < w.minOut))) ++bad;
        if ((b.ok ? 0 : _routerCode(b.ret)) != bk || (b.ok && b.out < w.minOut)) ++bad;
        (w.mode, w.status, w.note) = ("discovery", "route", "");
        _write(file, w);
        (w.mode, w.measured, w.gas, w.executed, w.exec) = ("quoted", e.ok, e.gas, e.ok, e.out);
        w.status = !e.ok ? "reverted" : e.out == q ? "eq" : e.out > q ? "floor" : "below_quote";
        w.note = e.ok ? "" : string.concat("swapExactIn reverted: ", vm.toString(e.ret));
        _write(file, w);
        (w.mode, w.measured, w.gas, w.executed, w.exec) = ("onchain_no_plan", b.ok, b.gas, b.ok, b.out);
        (w.hops, w.route) = (0, "");
        w.status = !b.ok ? "reverted" : b.out < w.minOut ? "below_min" : b.out == e.out ? "eq_quoted" : "diff_quoted";
        w.note = !b.ok
            ? string.concat("swapBestExactIn reverted: ", vm.toString(b.ret))
            : string.concat("onchain minus quoted exec wei: ", vm.toString(int256(b.out) - int256(e.out)));
        _write(file, w);
        (w.mode, w.status, w.measured, w.executed, w.note) = ("onchain_with_plan", "na", false, false, NO_PLAN);
        _write(file, w);
        console2.log(string.concat("S9|", c.id, "|", c.pair, "|", vm.toString(c.usd), "|q=", vm.toString(q),
            "|x=", vm.toString(e.out), "|b=", vm.toString(b.out), "|gD=", vm.toString(gD), "|gX=",
            vm.toString(e.gas), "|gB=", vm.toString(b.gas)));
    }

    /// The pinned outcome of cell n: (0, 0) unless KNOWN lists it.
    function _known(uint8 n) internal pure returns (uint256 q, uint256 b) {
        bytes memory k = KNOWN;
        for (uint256 i; i + 2 < k.length; i += 3) {
            if (uint8(k[i]) == n) return (uint8(k[i + 1]), uint8(k[i + 2]));
        }
    }

    function _pinned(uint8 n) internal pure returns (bool) {
        (uint256 q, uint256 b) = _known(n);
        return (q | b) != 0;
    }

    /// The code of a RouterE revert; type(uint256).max for any other revert data.
    function _routerCode(bytes memory ret) internal pure returns (uint256 code) {
        if (ret.length != 36 || bytes4(ret) != BlazePhoenixRouter.RouterE.selector) return type(uint256).max;
        assembly ("memory-safe") {
            code := mload(add(ret, 36))
        }
    }

    function _id(uint8 n) internal pure returns (string memory) {
        return string.concat(n < 10 ? "c00" : n < 100 ? "c0" : "c", vm.toString(uint256(n)));
    }

    function _decode(bytes memory cells, uint256 i) internal pure returns (Cell memory c) {
        c.n = uint8(cells[i]);
        c.id = _id(c.n);
        c.tIn = _tok(uint8(cells[i + 1]));
        c.tOut = _tok(uint8(cells[i + 2]));
        c.usd = uint256(uint8(cells[i + 3])) * 1000;
        c.pair = string.concat(_sym(c.tIn), ">", _sym(c.tOut));
    }
}
