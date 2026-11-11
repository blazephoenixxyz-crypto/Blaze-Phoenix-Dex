// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The encode doors answer pool math; the payer's own eth_call to the Router is the settlement oracle.
//
// What the doors measure: the pools, the fee, the floors, the deadline, the hooks, and the
// concentrated legs' input (`_inputTaxedIn`). What they cannot measure from inside a quote: a
// token whose transfer depends on who moves it, or on the state it meets. The second
// verification of the 4135 fix (2026-11-11) showed four such shapes a probe inside a quote
// cannot imitate, because the Router pays BEFORE the pair's `swap` and from the PAYER:
//   R1 a swap-back inside the pair's lock (the commonest taxed-token template);
//   R2 a holder cap (`maxWallet`) a third party can arm with a donation;
//   R3 `transferFrom` taxed where `transfer` is not (the FOT-01 class `Router._received` names);
//   R4 exemptions (the Router, the Hub or the payer exempt), which turn a probe's measurement
//      into a regression in one direction or the other.
// So the door's `canExecute` says "the pool math clears the floor"; it does not say "these bytes
// settle for you". The one instrument that says that is the transaction itself, dry-run: the
// Router's bytes, from the payer, at the quoted block. The SDK's `simulate`/`execute` and the
// local MCP's `simulate_swap` run exactly that call and fail closed on a revert.
//
// This file FIXES the declared behaviour (bounty uid 4135, internal QME-01), at 2957178:
//   * a yes is pool math: whatever the tax, the door says yes and carries bytes;
//   * the payer's call is the verdict: it refuses with RouterE(5) exactly where the delivery
//     is under the floor the bytes carry, and where it settles its return IS the delivery;
//   * a no is pool math too: a floor above the pool-math delivery gets no bytes, and the
//     Router would refuse that call as well.
//
// Matrix: range  {tax 0, 100, 250, 500 bps, fuzz 0..1000; 1e18 in pairs of 1e30}
//       x vector {plain tax; swap-back inside the pair's lock (R1); maxWallet armed by a
//                 donation to the Quoter (R2); transferFrom-only tax (R3); the Router, the Hub
//                 or the payer exempt (R4); a floor above pool math}
//       x venue  {V2 pair, a V2 pair with UniswapV2Pair's lock; one hop and two hops}
//       x door   {previewAndEncode, previewAndEncodeWithMinOut, previewPlanExact, the Router
//                 from the payer}.
// Mutants (`.github/scripts/mutants.py`, 4135b): the caller's floor dropped on entry to
// `Router._execute` (both floor checks read it), the Router's return not the delivery, the
// caller's floor dropped from `effectiveMinOut` (`_pack` and `_encode` both read it). Each is
// killed by a test named there; a mutant of one of the two redundant checks alone is not, by
// design: the acceptance predicates stay redundant.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

interface IERC20T {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev MockV2Pair with UniswapV2Pair's `lock`: swap and sync refuse re-entry ("UniswapV2: LOCKED").
contract LockedV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 private unlocked = 1;

    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external lock {
        if (amount0Out > 0) IERC20T(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20T(token1).transfer(to, amount1Out);
        reserve0 = uint112(IERC20T(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20T(token1).balanceOf(address(this)));
    }

    function sync() external lock {
        reserve0 = uint112(IERC20T(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20T(token1).balanceOf(address(this)));
    }
}

/// @dev A taxed token with the features real taxed tokens carry, each a coordinate: `mode`
///      (0 every transfer, 1 into a pair, 2 not into a pair, 3 out of a pair, 4 either side
///      of a pair, 5 none); `exempt` (from OR to exempt: untaxed); `onlyFrom` (only
///      transferFrom is taxed); `maxWallet` (a non-pair recipient may not hold more); a
///      swap-back (before moving, when not inside one and not from a pair, with the contract
///      holding >= threshold: sell the contract's balance into `mainPair`). The tax goes to the
///      contract: it funds the swap-back.
contract HostileTaxToken {
    string public name = "HTAX";
    string public symbol = "HTAX";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public pair;
    mapping(address => bool) public exempt;
    uint16 public bps;
    uint8 public mode;
    bool public onlyFrom;
    uint256 public maxWallet;
    address public mainPair;
    address public other;
    address public sink = address(0xBEEF);
    uint256 public threshold;
    bool private inSwap;
    bool private viaFrom;

    function set(uint16 b, uint8 m) external { bps = b; mode = m; }
    function mark(address p) external { pair[p] = true; }
    function setExempt(address a, bool e) external { exempt[a] = e; }
    function setOnlyFrom(bool e) external { onlyFrom = e; }
    function setMaxWallet(uint256 m) external { maxWallet = m; }
    function setSwapBack(address p, address o, uint256 th) external { mainPair = p; other = o; threshold = th; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        viaFrom = true;
        _move(f, to, a);
        viaFrom = false;
        return true;
    }

    function _move(address f, address to, uint256 a) private {
        if (threshold != 0 && !inSwap && !pair[f] && balanceOf[address(this)] >= threshold) _swapBack();
        bool taxed = mode == 0 || (mode == 1 && pair[to]) || (mode == 2 && !pair[to])
            || (mode == 3 && pair[f]) || (mode == 4 && (pair[f] || pair[to]));
        if (exempt[f] || exempt[to]) taxed = false;
        if (onlyFrom && !viaFrom) taxed = false;
        if (inSwap) taxed = false;
        uint256 fee = taxed ? a * bps / 10_000 : 0;
        balanceOf[f] -= a;
        balanceOf[to] += a - fee;
        balanceOf[address(this)] += fee;
        if (maxWallet != 0 && !pair[to] && to != address(this)) require(balanceOf[to] <= maxWallet, "max wallet");
    }

    function _swapBack() private {
        inSwap = true;
        uint256 amt = balanceOf[address(this)];
        balanceOf[address(this)] = 0;
        balanceOf[mainPair] += amt;
        (uint112 r0, uint112 r1,) = LockedV2Pair(mainPair).getReserves();
        bool zero = address(this) < other;
        uint256 rIn = zero ? r0 : r1;
        uint256 rOut = zero ? r1 : r0;
        uint256 out = rOut * amt * 997 / (rIn * 1000 + amt * 997);
        LockedV2Pair(mainPair).swap(zero ? 0 : out, zero ? out : 0, sink, "");
        inSwap = false;
    }
}

contract EncodeDoorsAnswerPoolMathThePayersCallSettlesTest is Test {
    uint256 constant DEPTH = 1e30;
    uint256 constant AMT = 1e18;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    HostileTaxToken hx;         // on MockV2Pair (no lock): exemptions, onlyFrom, maxWallet
    HostileTaxToken sb;         // on LockedV2Pair: the swap-back
    MockERC20 weth;             // the bridge
    MockERC20 usdc;
    MockERC20 dai;
    address payer = makeAddr("payer");
    address recipient = makeAddr("recipient");

    struct Row {
        bool canExecute;
        uint256 bytesLen;
        uint256 encodedMin;
        bool encOk;             // the payer's call with the door's bytes
        uint16 encCode;
        uint256 encRet;         // what that call returned
        uint256 encDelivered;   // what the recipient received
        bool ownOk;             // the same route with the payer's own floor of 1 wei
        uint256 ownDelivered;
        uint256 exactOut;
        uint256 netOut;         // the plan estimate (the view doors' figure)
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2"));
        hub.setRoles(address(router), address(solver), address(quoter));

        weth = new MockERC20("WETH", "WETH");
        usdc = new MockERC20("USDC", "USDC");
        dai = new MockERC20("DAI", "DAI");
        hub.addBridge(address(weth));
        _v2(address(weth), address(usdc), DEPTH, DEPTH);

        hx = new HostileTaxToken();
        hx.mark(_v2(address(hx), address(weth), DEPTH, DEPTH));
        hx.mark(_v2(address(hx), address(dai), DEPTH, DEPTH));

        sb = new HostileTaxToken();
        address sbWeth = _locked(address(sb), address(weth));
        sb.mark(sbWeth);
        sb.setSwapBack(sbWeth, address(weth), 1e15);
    }

    function _v2(address tX, address tY, uint256 rX, uint256 rY) internal returns (address) {
        MockV2Pair p = new MockV2Pair(tX, tY);
        MockERC20(tX).mint(address(p), rX);
        MockERC20(tY).mint(address(p), rY);
        p.setReserves(uint112(tX < tY ? rX : rY), uint112(tX < tY ? rY : rX));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tX, tY);
        return address(p);
    }

    function _locked(address tX, address tY) internal returns (address) {
        LockedV2Pair p = new LockedV2Pair(tX, tY);
        MockERC20(tX).mint(address(p), DEPTH);
        MockERC20(tY).mint(address(p), DEPTH);
        p.setReserves(uint112(DEPTH), uint112(DEPTH));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tX, tY);
        return address(p);
    }

    function _code(bytes memory ret) internal pure returns (uint16 c) {
        if (ret.length == 36 && bytes4(ret) == BlazePhoenixRouter.RouterE.selector) {
            assembly { c := mload(add(ret, 36)) }
        } else {
            c = type(uint16).max; // not a RouterE
        }
    }

    /// The transaction itself, dry-run as the SDK's `simulate` runs it: the Router's bytes,
    /// from the payer, in the quoted state. Returns the Router's own answer and the recipient's
    /// measured delta.
    function _submit(address tIn, address tOut, uint256 amt, bytes memory data)
        internal returns (bool ok, uint16 code, uint256 ret, uint256 delivered)
    {
        MockERC20(tIn).mint(payer, amt);
        vm.prank(payer);
        MockERC20(tIn).approve(address(router), amt);
        uint256 b0 = MockERC20(tOut).balanceOf(recipient);
        bytes memory raw;
        vm.prank(payer);
        (ok, raw) = address(router).call(data);
        if (ok) {
            ret = abi.decode(raw, (uint256));
            delivered = MockERC20(tOut).balanceOf(recipient) - b0;
        } else {
            code = _code(raw);
        }
    }

    /// One row from the same state: the door and its bytes, the exact door, the payer's call
    /// with the bytes, and the payer's call with their own floor of 1 wei (where only the
    /// Router's own floors bind: what the Router delivers for this token).
    function _row(address tIn, address tOut, uint256 amt, uint256 userMinOut) internal returns (Row memory r) {
        uint256 snap = vm.snapshotState();
        BlazePhoenixQuoter.Preview memory pv;
        bytes memory data;
        if (userMinOut == 0) {
            (pv, data) = quoter.previewAndEncode(tIn, tOut, amt, recipient, block.timestamp + 1);
        } else {
            (pv, data) = quoter.previewAndEncodeWithMinOut(tIn, tOut, amt, userMinOut, recipient, block.timestamp + 1);
        }
        (, r.exactOut) = quoter.previewPlanExact(tIn, tOut, amt);
        r.canExecute = pv.canExecute;
        r.bytesLen = data.length;
        r.encodedMin = pv.effectiveMinOut;
        r.netOut = pv.netOut;
        if (data.length != 0) (r.encOk, r.encCode, r.encRet, r.encDelivered) = _submit(tIn, tOut, amt, data);
        vm.revertToState(snap);
        if (pv.route.hops.length != 0) {
            bytes memory own = abi.encodeCall(
                BlazePhoenixRouter.swapExactIn, (pv.route, amt, 1, recipient, block.timestamp + 1));
            (r.ownOk,,, r.ownDelivered) = _submit(tIn, tOut, amt, own);
        }
        vm.revertToState(snap);
    }

    function _show(string memory tag, Row memory r) internal {
        emit log_string(tag);
        emit log_named_uint("  canExecute", r.canExecute ? 1 : 0);
        emit log_named_uint("  encodedMin", r.encodedMin);
        emit log_named_uint("  encOk", r.encOk ? 1 : 0);
        emit log_named_uint("  encCode", r.encCode);
        emit log_named_uint("  encRet", r.encRet);
        emit log_named_uint("  encDelivered", r.encDelivered);
        emit log_named_uint("  ownDelivered", r.ownDelivered);
        emit log_named_uint("  exactOut", r.exactOut);
        emit log_named_uint("  netOut", r.netOut);
    }

    /// The door says yes (pool math) and carries bytes.
    function _yes(Row memory r, string memory tag) internal {
        _show(tag, r);
        assertTrue(r.canExecute, string.concat(tag, ": the door's yes is pool math; it must say yes"));
        assertGt(r.bytesLen, 0, string.concat(tag, ": a yes carries bytes"));
    }

    /// The payer's call refuses the bytes with RouterE(5): the Router delivers under the floor
    /// the bytes carry. The route itself is sound (the payer's own floor settles).
    function _refused(Row memory r, string memory tag) internal {
        assertFalse(r.encOk, string.concat(tag, ": the payer's call must refuse these bytes"));
        assertEq(r.encCode, 5, string.concat(tag, ": refused with RouterE(5), the floor inside the bytes"));
        assertTrue(r.ownOk, string.concat(tag, ": the same route with the payer's own floor settles"));
        assertLt(r.ownDelivered, r.encodedMin, string.concat(tag, ": the delivery is under the encoded floor"));
    }

    /// The payer's call settles, over the floor, and its return IS the recipient's delta.
    function _settled(Row memory r, string memory tag) internal {
        assertTrue(r.encOk, string.concat(tag, ": the payer's call must settle"));
        assertGe(r.encDelivered, r.encodedMin, string.concat(tag, ": the delivery clears the encoded floor"));
        assertEq(r.encRet, r.encDelivered, string.concat(tag, ": the call's return is the delivery"));
    }

    // ------------------------------------------------------------------ controls

    /// @notice An untaxed input: yes, bytes, the payer's call settles and returns the delivery;
    ///         the exact scalar is at or under it.
    function test_Control_AnUntaxedInput_TheDoorSaysYes_ThePayersCallSettlesAndReturnsTheDelivery() public {
        hx.set(0, 0);
        Row memory r = _row(address(hx), address(weth), AMT, 0);
        _yes(r, "untaxed toBridge");
        _settled(r, "untaxed toBridge");
        assertLe(r.exactOut, r.encDelivered, "untaxed: exactOut above the delivery");
        r = _row(address(hx), address(usdc), AMT, 0);
        _yes(r, "untaxed twoHops");
        _settled(r, "untaxed twoHops");
        assertLe(r.exactOut, r.encDelivered, "untaxed twoHops: exactOut above the delivery");
    }

    /// @notice A tax the encoded floor absorbs (100 bps at 1e18 in 1e30): the door says yes by
    ///         pool math, and the payer's call settles; the exact scalar is pool math and sits
    ///         above the taxed delivery, which the call's return measures.
    function test_Control_ATaxTheFloorAbsorbs_TheDoorSaysYes_ThePayersCallSettles() public {
        hx.set(100, 0);
        Row memory r = _row(address(hx), address(weth), AMT, 0);
        _yes(r, "tax 100 toBridge");
        _settled(r, "tax 100 toBridge");
        assertGt(r.exactOut, r.encDelivered, "tax 100: the exact scalar is pool math, above a taxed delivery");
    }

    /// @notice A no is pool math too: a caller's floor one wei above the pool-math delivery gets
    ///         canExecute = false and no bytes, and the Router would refuse that call as well.
    function test_Control_AFloorAbovePoolMath_TheDoorSaysNo_AndCarriesNoBytes() public {
        hx.set(0, 0);
        Row memory plain = _row(address(hx), address(weth), AMT, 0);
        Row memory r = _row(address(hx), address(weth), AMT, plain.encDelivered + 1);
        _show("floor above pool math", r);
        assertFalse(r.canExecute, "a floor above pool math: the door must say no");
        assertEq(r.bytesLen, 0, "a no carries no bytes");
        (BlazePhoenixQuoter.Preview memory pv,,) = quoter.previewPlan(address(hx), address(weth), AMT);
        bytes memory own = abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (pv.route, AMT, plain.encDelivered + 1, recipient, block.timestamp + 1));
        (bool ok, uint16 code,,) = _submit(address(hx), address(weth), AMT, own);
        assertFalse(ok, "the Router refuses the same floor");
        assertEq(code, 5, "refused with RouterE(5)");
    }

    // ------------------------------------------------------------------ R1-R4: the payer's call is the verdict

    /// @notice R1: a swap-back inside the pair's lock. The contract holds its threshold, so the
    ///         payer's transfer sells into the pair before the Router moves a token; the door
    ///         cannot run that from inside a quote. The door says yes; the payer's call refuses.
    function test_R1_SwapBackInsideThePairsLock_TheDoorSaysYes_OnlyThePayersCallRefuses() public {
        sb.mint(address(sb), 1e16);
        sb.set(500, 0);
        Row memory r = _row(address(sb), address(weth), AMT, 0);
        _yes(r, "R1 swap-back >= threshold toBridge");
        _refused(r, "R1 swap-back >= threshold toBridge");
        r = _row(address(sb), address(usdc), AMT, 0);
        _yes(r, "R1 swap-back >= threshold twoHops");
        _refused(r, "R1 swap-back >= threshold twoHops");
    }

    /// @notice R2: a holder cap armed by a third party. A donation to the Quoter sits under the
    ///         cap and changes nothing in the pools; the door says yes; the payer's call refuses.
    function test_R2_MaxWalletWithADonationToTheQuoter_TheDoorSaysYes_OnlyThePayersCallRefuses() public {
        hx.setMaxWallet(3 * AMT / 2);
        hx.mint(address(quoter), AMT);
        hx.set(500, 0);
        Row memory r = _row(address(hx), address(weth), AMT, 0);
        _yes(r, "R2 maxWallet donation->Quoter toBridge");
        _refused(r, "R2 maxWallet donation->Quoter toBridge");
        r = _row(address(hx), address(usdc), AMT, 0);
        _yes(r, "R2 maxWallet donation->Quoter twoHops");
        _refused(r, "R2 maxWallet donation->Quoter twoHops");
    }

    /// @notice R3: only transferFrom is taxed (the FOT-01 class `Router._received` names). The
    ///         Router's pull is a transferFrom; a pool's payment is a transfer. The door says yes;
    ///         the payer's call refuses.
    function test_R3_OnlyTransferFromTaxed_TheDoorSaysYes_OnlyThePayersCallRefuses() public {
        hx.setOnlyFrom(true);
        hx.set(500, 0);
        Row memory r = _row(address(hx), address(weth), AMT, 0);
        _yes(r, "R3 onlyTransferFrom toBridge");
        _refused(r, "R3 onlyTransferFrom toBridge");
    }

    /// @notice R4: the Router exempt. The token taxes everyone but the Router, so the bytes
    ///         settle in full: the door's yes is right, and a probe that measured a wallet
    ///         transfer would have refused it (the first cut's regression, 2026-11-11).
    function test_R4_TheRouterExempt_TheDoorSaysYes_ThePayersCallSettles() public {
        hx.setExempt(address(router), true);
        hx.set(500, 0);
        Row memory r = _row(address(hx), address(weth), AMT, 0);
        _yes(r, "R4 Router exempt");
        _settled(r, "R4 Router exempt");
        assertLe(r.exactOut, r.encDelivered, "R4 Router exempt: exactOut above the delivery");
    }

    /// @notice R4: the Hub exempt. A probe pulling into the Hub would see no tax; the Router's
    ///         pull is taxed. The door says yes; the payer's call refuses.
    function test_R4_TheHubExempt_TheDoorSaysYes_OnlyThePayersCallRefuses() public {
        hx.setExempt(address(hub), true);
        hx.set(250, 0);
        Row memory r = _row(address(hx), address(weth), AMT, 0);
        _yes(r, "R4 Hub exempt");
        _refused(r, "R4 Hub exempt");
    }

    /// @notice R4: the payer exempt. The pull is untaxed, the push into the pair is taxed, the
    ///         delivery clears the floor: the payer's call settles under the exact scalar, and its
    ///         return is the number to trust.
    function test_R4_ThePayerExempt_TheDoorSaysYes_ThePayersCallSettlesUnderTheExactScalar() public {
        hx.setExempt(payer, true);
        hx.set(250, 0);
        Row memory r = _row(address(hx), address(weth), AMT, 0);
        _yes(r, "R4 payer exempt");
        _settled(r, "R4 payer exempt");
        assertGt(r.exactOut, r.encDelivered, "R4 payer exempt: the exact scalar is pool math, above the delivery");
    }

    // ------------------------------------------------------------------ the class, by fuzz

    /// @notice Whatever the tax on every transfer, the door says yes and carries bytes (pool
    ///         math sees no tax), and the payer's call answers exactly as the floor inside the
    ///         bytes compares with what the Router delivers for this token.
    function testFuzz_AnyTax_TheDoorSaysYesByPoolMath_ThePayersCallIsTheVerdict(uint16 t) public {
        t = uint16(bound(t, 0, 1000));
        hx.set(t, 0);
        Row memory r = _row(address(hx), address(weth), AMT, 0);
        _yes(r, "fuzz toBridge");
        assertTrue(r.ownOk, "the route itself settles at the payer's own floor");
        assertEq(r.encOk, r.ownDelivered >= r.encodedMin, "the payer's call is the floor's verdict");
        if (r.encOk) _settled(r, "fuzz toBridge");
        else assertEq(r.encCode, 5, "refused with RouterE(5)");
    }
}
