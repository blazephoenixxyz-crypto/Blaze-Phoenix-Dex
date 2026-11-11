// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A DELIVERY THAT PAID NO FEE IS REFUSED, ON TWO HOPS (morf-1106 INV-S1, refuta-mat)
//
//  The fee book's first check (`if (paid == 0) revert RouterE(15)`) was derived as
//  unreachable on a route of at most two hops. It is reachable:
//    - the route starts in a bridge, so the fee is anchored at hop 0 and hop 1 is not
//      charged (`BPC.paysOnInput`);
//    - hop 0's legs commit nothing, so its base is min(pulled, committed) = 0: it pays
//      nothing (`_chargeHopFee` returns before `_payFee`) and runs nothing;
//    - hop 1 spends `balance - baseline` of the middle token. The baseline is read
//      before the hop loop and the balance inside it: two reads of one `balanceOf`.
//      A token whose `balanceOf` answers more on the second read makes hop 1 run.
//  The route then delivers with nothing in the book, and the check is what refuses it.
//
//  The middle token needs no write between the two reads: a view tells a cold storage
//  slot (2100 gas) from a warm one (100 gas, EIP-2929), and its own first read warms it.
//
//  Guards, green at cb1d7d9. Red under [inv-s1-1633] (the check removed): both
//  `test_A...` below. Without the check the first route settles with one Swap and no
//  Fee, the whole output of hop 1 at the recipient and nothing in the treasuries
//  (measured on cb1d7d9 with the check removed, 2026-11-10). The second guard is the
//  book's clear seen from this side: with the clear removed (mutants rv1023-8 /
//  inv-s1-1635) the first swap's payment stays in the book and hides the second
//  swap's missing one.
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

    function _swap(Route memory r, uint256 amountIn) private returns (bool settled, bytes memory err) {
        a.mint(address(this), amountIn);
        a.approve(address(router), amountIn);
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

    // ─── the guard ───

    /// FAILS IF DELETED: yes - with Router:1633 removed this route settles: hop 1's output
    /// reaches the recipient, the caller gets its whole input back and no Fee is emitted.
    function test_ATwoHopRouteFedAfterTheBaseline_DeliversAndIsRefusedForPayingNoFee() public {
        m.arm(address(router), X);
        (bool settled, bytes memory err) = _swap(_amb(0, X), AIN);
        assertFalse(settled, "a two-hop delivery that paid no fee settled");
        assertEq(err, _refusal(15), "the refusal is the fee book's: delivered, nothing paid (RouterE(15))");
    }

    /// One call: a direct A -> B swap that pays its fee, then the route above.
    /// FAILS IF DELETED: yes - with Router:1633 removed the second swap settles. With the
    /// book's clear (Router:1635) removed the first swap's payment is still in the book when
    /// the second one is settled, and it settles as well [derived].
    function test_AfterAPaidSwapInTheSameCall_TheUnpaidDeliveryIsStillRefused() public {
        TwoSwapsOneCall caller = new TwoSwapsOneCall();
        a.mint(address(caller), 2 * AIN);
        Hop[] memory one = new Hop[](1);
        one[0] = _hop(pAB, address(a), address(b), AIN);
        m.arm(address(router), X);
        (bool ok1, bool ok2, bytes memory err2) = caller.run(router, _wrap(one), _amb(0, X), AIN);
        assertTrue(ok1, "setup: the paid swap settled");
        assertFalse(ok2, "an unpaid delivery settled behind a paid swap of the same call");
        assertEq(err2, _refusal(15), "the second swap is refused by the fee book (RouterE(15))");
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
    /// settles - with the same middle token showing the same phantom balance to hop 1.
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
        assertEq(b.balanceOf(TO), _q(q0 + X, address(m), address(b)), "hop 1 spent hop 0's output and the phantom");
    }
}
