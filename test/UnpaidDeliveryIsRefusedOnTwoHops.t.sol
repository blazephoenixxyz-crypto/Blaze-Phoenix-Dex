// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A DELIVERY THAT PAID NO FEE IS REFUSED (morf-1106 INV-S1, refuta-mat; 4111)
//
//  The fee book's first check (`if (paid == 0) revert RouterE(15)`) was derived as
//  unreachable on a route of at most two hops. Two vectors, two fates:
//
//  1. The restatement vector (the file's first form, green at cb1d7d9): the route starts
//     in a bridge, so the fee is anchored at hop 0 and hop 1 is not charged; hop 0 commits
//     nothing and pays nothing; hop 1 spends `balance - baseline` of the middle token, and
//     a token whose `balanceOf` answers more on the second read of the transaction (a view
//     tells a cold slot from a warm one, EIP-2929) makes hop 1 run. It reached the book
//     until 7c4ad36 (4111): a later hop now spends `_owned` = min(balance - baseline, what
//     the previous hop delivered) = 0, nothing moves, and the swap stops at RouterE(8)
//     before the book is read. Those tests now guard 4111's cap from this side: red under
//     [1090] (`_owned` does not cap at what the legs delivered), where hop 1 spends the
//     phantom and the book is what refuses the first two, and the control delivers the
//     phantom's quote.
//
//  2. The padding vector (green at cb38bab): a direct B -> M swap padded with two hops that
//     commit nothing, B -> M -> A -> M with A the bridge. The fee is anchored at hop 2 (the
//     first hop whose input is a bridge), so hop 0 is not charged and delivers tokenOut;
//     hop 1 runs no leg (nothing in the loop refuses a non-final hop that executes
//     nothing: RouterE(5) wants `scaledAmt != 0` or `hopAttested != 0`) and hands hop 2 a
//     delivery of 0; hop 2 owns min(its A, 0) = 0 and charges nothing. Hop 0's output
//     reaches the delivery with nothing in the book, and Router:1679 is what refuses it.
//     Red under [inv-s1-1633] (the check removed): the route settles and the 28 bps the
//     direct swap pays are evaded by two dead hops. Since 051a0bb (hops2) MAX_HOPS is 2
//     (Core, read by Router:1039), so this three-hop route is refused at the hop ceiling
//     with RouterE(3) before any hop runs, and the derivation above holds again: on at
//     most two hops the book's first check is unreachable ([inv-s1-1633] retired as
//     equivalent in mutants.py). The test now pins that the padded route still does not
//     settle, and it is red under the ceiling raised by one (`> MAX_HOPS + 1`), where the
//     route walks past Router:1039 and is refused by the book with RouterE(15) instead.
//
//  forge test --match-path test/UnpaidDeliveryIsRefusedOnTwoHops.t.sol -vv
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// @notice An ERC20 that answers `balanceOf(target)` honestly on the first read after
///         `arm` and with `phantom` more on every later read of the same transaction.
///         The phantom part is conjured when `target` spends it.
contract TwoFacedToken {
    string  public constant name = "Two-Faced";
    string  public constant symbol = "TF";
    uint8   public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) private _b;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    uint256 public phantom;
    uint256 private epoch;
    mapping(uint256 => uint256) private probe;   // never written: only its warmth is read

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amt) external {
        _b[to] += amt;
        totalSupply += amt;
        emit Transfer(address(0), to, amt);
    }

    /// Starts a fresh probe: the next `balanceOf(target_)` is the honest one.
    function arm(address target_, uint256 phantom_) external {
        target = target_;
        phantom = phantom_;
        ++epoch;
    }

    function balanceOf(address who) external view returns (uint256 b) {
        b = _b[who];
        uint256 p = phantom;
        if (who != target || p == 0) return b;
        uint256 e = epoch;
        uint256 cost;
        uint256 v;
        assembly ("memory-safe") {
            mstore(0x00, e)
            mstore(0x20, probe.slot)
            let s := keccak256(0x00, 0x40)
            let g := gas()
            v := sload(s)
            cost := sub(g, gas())
        }
        if (cost < 1000) b += p;   // warm: this slot was read before in this transaction
        b += v;                    // always zero; keeps the read in the bytecode
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _move(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - amt;
        return _move(from, to, amt);
    }

    function _move(address from, address to, uint256 amt) private returns (bool) {
        uint256 have = _b[from];
        if (from == target && have < amt) {
            uint256 short = amt - have;
            phantom -= short;
            totalSupply += short;
            have = amt;
        }
        _b[from] = have - amt;
        _b[to] += amt;
        emit Transfer(from, to, amt);
        return true;
    }
}

/// @notice Two swaps from the same input token in one call; keeps the second one's refusal.
contract TwoSwapsOneCall {
    function run(BlazePhoenixRouter router, Route calldata r1, Route calldata r2, uint256 amt)
        external returns (bool ok1, bool ok2, bytes memory err2)
    {
        MockERC20(r1.hops[0].tokenIn).approve(address(router), 2 * amt);
        try router.swapExactIn(r1, amt, 1, address(this), block.timestamp + 1) returns (uint256) { ok1 = true; }
        catch (bytes memory) {}
        try router.swapExactIn(r2, amt, 1, address(this), block.timestamp + 1) returns (uint256) { ok2 = true; }
        catch (bytes memory e) { err2 = e; }
    }
}

contract UnpaidDeliveryIsRefusedOnTwoHopsTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20     a;      // a bridge: a route that starts in it is anchored at hop 0
    TwoFacedToken m;      // the middle token
    MockERC20     b;
    MockV3Pool    pAM;    // hop 0
    MockV3Pool    pMB;    // hop 1
    MockV3Pool    pAB;    // the direct, paid swap

    uint24  constant PFEE  = 3000;
    uint256 constant DEPTH = 1_000_000e18;
    uint256 constant AIN   = 10e18;   // what the caller hands the Router
    uint256 constant X     = 5e18;    // what the middle token shows after the baseline
    address constant TO    = address(0xCAFE);
    address constant T1    = address(0xFEE1);
    address constant T2    = address(0xFEE2);

    bytes32 constant FEE_SIG  = keccak256("Fee(address,uint256,uint256,uint256)");
    bytes32 constant SWAP_SIG = keccak256("Swap(address,address,address,uint256,uint256,uint256)");

    function _pool(address t0, address t1) private returns (MockV3Pool p) {
        p = new MockV3Pool(t0, t1, PFEE);
        p.setState(uint160(BPC.Q96), uint128(DEPTH));
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(this));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);

        a = new MockERC20("A", "A");
        b = new MockERC20("B", "B");
        m = new TwoFacedToken();
        hub.addBridge(address(a));

        pAM = _pool(address(a), address(m));
        pMB = _pool(address(m), address(b));
        pAB = _pool(address(a), address(b));
        a.mint(address(pAM), DEPTH); m.mint(address(pAM), DEPTH);
        m.mint(address(pMB), DEPTH); b.mint(address(pMB), DEPTH);
        a.mint(address(pAB), DEPTH); b.mint(address(pAB), DEPTH);
    }

    function _q(uint256 amt, address tIn, address tOut) private pure returns (uint256) {
        return BPC.outV3(amt, uint160(BPC.Q96), uint128(DEPTH), PFEE, tIn < tOut, 0);
    }

    function _hop(MockV3Pool p, address tIn, address tOut, uint256 amt) private pure returns (Hop memory) {
        uint256 q = amt == 0 ? 0 : _q(amt, tIn, tOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: PFEE, tickSpacing: 60,
                       zeroForOne: tIn < tOut, stable: false, amountIn: amt, expectedOut: q, auxId: bytes32(0)});
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: q, legs: legs});
    }

    function _wrap(Hop[] memory hops) private pure returns (Route memory) {
        uint256 q = hops[hops.length - 1].expectedOut;
        return Route({hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0,
                      expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// A -> M -> B, hop 0 committing `commit0` of A and hop 1 `commit1` of M.
    function _amb(uint256 commit0, uint256 commit1) private view returns (Route memory) {
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(pAM, address(a), address(m), commit0);
        hops[1] = _hop(pMB, address(m), address(b), commit1);
        return _wrap(hops);
    }

    /// Like `_wrap`, with the route's figures set to `q` (a padded route's last hop quotes 0).
    function _wrapOut(Hop[] memory hops, uint256 q) private pure returns (Route memory) {
        return Route({hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0,
                      expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _swap(Route memory r, uint256 amountIn) private returns (bool settled, bytes memory err) {
        return _swapFrom(a, r, amountIn);
    }

    function _swapFrom(MockERC20 tIn, Route memory r, uint256 amountIn) private returns (bool settled, bytes memory err) {
        tIn.mint(address(this), amountIn);
        tIn.approve(address(router), amountIn);
        try router.swapExactIn(r, amountIn, 1, TO, block.timestamp + 1) returns (uint256) { settled = true; }
        catch (bytes memory e) { err = e; }
    }

    function _refusal(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    function _count(Vm.Log[] memory logs) private view returns (uint256 fees, uint256 swaps) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router)) continue;
            bytes32 sig = logs[i].topics[0];
            if (sig == FEE_SIG) ++fees;
            else if (sig == SWAP_SIG) ++swaps;
        }
    }

    // ─── the guard: a delivery that paid no fee (the padding vector) ───

    /// B -> M -> A -> M, tokenOut = M. Hop 0 delivers tokenOut and is not the fee hop; hop 1
    /// commits nothing and hands on 0; hop 2 (input A, the bridge) is the fee hop and owns
    /// min(what it holds of A past its baseline, 0) = 0, so `_chargeHopFee` returns before
    /// `_payFee`. The delivery is hop 0's whole output and the book is empty.
    /// FAILS IF DELETED: yes - with the hop ceiling raised by one (Router:1039, `> MAX_HOPS + 1`)
    /// the route reaches the fee book and is refused with RouterE(15), not RouterE(3); with
    /// both gone it would settle: one Swap, no Fee, hop 0's output at the recipient. The
    /// direct swap of the same pair (the control below) pays 28 bps.
    function test_ADirectSwapPaddedWithTwoDeadHops_DeliversAndIsRefusedForPayingNoFee() public {
        Hop[] memory hops = new Hop[](3);
        hops[0] = _hop(pMB, address(b), address(m), AIN); // delivers tokenOut; not charged
        hops[1] = _hop(pAM, address(m), address(a), 0);   // runs nothing: hands hop 2 a 0
        hops[2] = _hop(pAM, address(a), address(m), 0);   // the fee hop: owns 0, charges nothing
        (bool settled, bytes memory err) = _swapFrom(b, _wrapOut(hops, hops[0].expectedOut), AIN);
        assertFalse(settled, "a delivery that paid no fee settled");
        // Three hops > MAX_HOPS = 2 (051a0bb): Router:1039 refuses before the book is read.
        assertEq(err, _refusal(3), "the padded route is past the hop ceiling (RouterE(3), MAX_HOPS = 2 since 051a0bb)");
    }

    /// Control: the same pair, direct. No bridge on the route, so the one hop pays on its
    /// input (exhaustion): exactly one Fee, in B, and the quote on the net input is delivered.
    function test_TheSamePairDirect_PaysOneFeeAndSettles() public {
        Hop[] memory one = new Hop[](1);
        one[0] = _hop(pMB, address(b), address(m), AIN);
        uint256 fee = (AIN * BPC.PROTOCOL_FEE_BPS + BPC.BPS - 1) / BPC.BPS;
        vm.recordLogs();
        (bool settled, bytes memory err) = _swapFrom(b, _wrap(one), AIN);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(err, bytes(""), "setup: the direct swap was refused");
        assertTrue(settled, "setup: the direct swap settled");
        (uint256 fees, uint256 swaps) = _count(logs);
        assertEq(swaps, 1, "one delivery");
        assertEq(fees, 1, "exactly one Fee");
        assertEq(b.balanceOf(T1) + b.balanceOf(T2), fee, "the full rate on the input, in B");
        assertEq(m.balanceOf(TO), _q(AIN - fee, address(b), address(m)), "the quote on the net input");
    }

    // ─── the restatement vector: refused upstream since 7c4ad36 (4111) ───

    /// Hop 1 spends min(what the middle token shows past the baseline, what hop 0 delivered)
    /// = min(X, 0) = 0: nothing runs, nothing is delivered, the book is never read.
    /// FAILS IF DELETED: yes - with 4111's cap removed ([1090]: `_owned` does not cap at what
    /// the legs delivered) hop 1 spends the phantom and delivers, and the refusal moves
    /// downstream to the fee book (RouterE(15)).
    function test_ATwoHopRouteFedAfterTheBaseline_SpendsNothingAndDeliversNothing() public {
        m.arm(address(router), X);
        (bool settled, bytes memory err) = _swap(_amb(0, X), AIN);
        assertFalse(settled, "a two-hop route fed after the baseline settled");
        assertEq(err, _refusal(8), "hop 1 spends min(shown, delivered by hop 0) = 0: nothing delivered (RouterE(8))");
    }

    /// One call: a direct A -> B swap that pays its fee, then the route above. The paid swap
    /// leaves nothing behind that lets the second one spend the phantom.
    /// FAILS IF DELETED: yes - under [1090] the second swap spends the phantom and is refused
    /// by the book (RouterE(15)) instead of upstream.
    function test_AfterAPaidSwapInTheSameCall_TheRouteFedAfterTheBaselineStillDeliversNothing() public {
        TwoSwapsOneCall caller = new TwoSwapsOneCall();
        a.mint(address(caller), 2 * AIN);
        Hop[] memory one = new Hop[](1);
        one[0] = _hop(pAB, address(a), address(b), AIN);
        m.arm(address(router), X);
        (bool ok1, bool ok2, bytes memory err2) = caller.run(router, _wrap(one), _amb(0, X), AIN);
        assertTrue(ok1, "setup: the paid swap settled");
        assertFalse(ok2, "a route fed after the baseline settled behind a paid swap of the same call");
        assertEq(err2, _refusal(8), "the second swap delivers nothing (RouterE(8))");
    }

    // ─── controls: the same world, where the book has nothing to refuse ───

    /// The middle token is never armed, so it shows what it holds: hop 1 has nothing to
    /// spend, nothing is delivered and the swap stops before the book is read.
    function test_TheSameRouteThroughAMiddleTokenThatShowsNothing_DeliversNothing() public {
        (bool settled, bytes memory err) = _swap(_amb(0, X), AIN);
        assertFalse(settled, "a route whose hops moved nothing settled");
        assertEq(err, _refusal(8), "nothing delivered (RouterE(8))");
    }

    /// Hop 0 commits the caller's input: it pays the full rate on it, once, and the route
    /// settles - with the same middle token showing the same phantom balance to hop 1, which
    /// spends only what hop 0 delivered (4111): the phantom never reaches the recipient.
    /// FAILS IF DELETED: yes - under [1090] hop 1 spends the phantom too and delivers q(q0 + X).
    function test_TheSameRouteWithHopZeroCommitted_PaysOneFeeAndSettles() public {
        m.arm(address(router), X);
        uint256 fee = (AIN * BPC.PROTOCOL_FEE_BPS + BPC.BPS - 1) / BPC.BPS;
        uint256 q0  = _q(AIN - fee, address(a), address(m));
        vm.recordLogs();
        (bool settled, bytes memory err) = _swap(_amb(AIN, q0 + X), AIN);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(err, bytes(""), "setup: the paid route was refused");
        assertTrue(settled, "setup: the paid route settled");
        (uint256 fees, uint256 swaps) = _count(logs);
        assertEq(swaps, 1, "one delivery");
        assertEq(fees, 1, "exactly one Fee");
        assertEq(a.balanceOf(T1) + a.balanceOf(T2), fee, "the full rate on hop 0's commitment, in the bridge");
        assertEq(b.balanceOf(TO), _q(q0, address(m), address(b)), "hop 1 spent hop 0's output, not the phantom (4111)");
    }
}
