// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// 4111 (bug bounty, 2026-11-11): a bridge that restates its balances while the Router holds it.
// Hop h>=1 spent `bal - bridgeBase[h-1]` and paid its fee on the same delta. A positive
// restatement fired OUTSIDE a measured leg window — the hop-0 fee push through a hooked input,
// the hop-1 fee push itself — grows the stranded balance too, and that growth travelled to the
// swapper as hop h's input (OUT-DELTA-RESTATEMENT's published escape: "the hop scaling and the
// hop fee base of hop h>=1 are still uncapped deltas"). DEX-11 compares got with declared only
// inside a leg window; a fee push is not one.
//
// The fix mirrors #45 and 3310: what a hop may spend of its bridge, and what its fee is charged
// on, is `owned` (SHARED_QUANTITIES.md): the balance past the baseline AND no more than the
// previous hop's legs were measured to deliver (`hopGot`); what the balance holds past that is
// written back into the baseline, so the sweep leaves it with the rescue instead of paying it to
// the payer.
//
// Red at e01b503 (main, 2026-11-11): both restatement tests. The honest two-hop swap is the
// control and holds on both sides of the fix.
//
// 4111/D1: the write-back cannot see a restatement fired AFTER the scale, inside a leg window of
// the hop that spends the bridge (its output landing on the Router). The sweep paid the payer the
// whole balance past the baseline, so the stranded holder's gain rode out through it. The sweep
// now pays each bridge no more than this swap's unspent input of it. Red at 2e4fdaa
// (fix-4111-fu, 2026-11-13): the in-leg restatement-up tests; the in-leg controls hold on both
// sides of the fix.
//
// 4111/D1 (input): the tokenIn sweep (`residIn - baseIn`) and the cyclic refund
// (`resid0 - baseIn`) had the bridge sweep's shape: a restatement of tokenIn fired inside a leg
// window paid the payer F*(k-1) of the stranded input. Both now pay no more than hop 0 left
// unspent. Red at the bridge fix (fix-4111-fu, 2026-11-13): the in-leg input tests; the input
// controls hold on both sides of the fix.
//
// forge test --match-path test/BridgeInputNeverExceedsWhatHop0Delivered.t.sol -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, MAX_HOPS} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

interface IMintable {
    function mint(address to, uint256 amt) external;
}

/// @dev A plain token whose transfer to one address, once, restates ANOTHER token: the hop-0 fee
///      push (tokenIn to the fee sink) fires the bridge's rebase before hop 1 reads its balance.
contract HookedERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address private landing;
    PathologicalERC20 private target;
    uint256 private num;
    uint256 private den;

    function decimals() external pure returns (uint8) { return 18; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { _move(msg.sender, to, amt); return true; }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - amt;
        _move(from, to, amt);
        return true;
    }
    function arm(address landing_, PathologicalERC20 target_, uint256 num_, uint256 den_) external {
        landing = landing_; target = target_; num = num_; den = den_;
    }
    function _move(address from, address to, uint256 amt) private {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        if (to == landing && landing != address(0)) {
            landing = address(0);
            target.setRebase(num, den);
        }
    }
}

contract BridgeInputNeverExceedsWhatHop0DeliveredTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    address user = address(0xBEEF);
    address recip = address(0xCAFE);

    uint256 constant RESERVE = 1_000_000e18;
    uint256 constant IN = 100e18;
    uint256 constant FOREIGN = 100e18; // stranded bridge shares the rescue holds for their owner

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        MockPermit2 permit2 = new MockPermit2();
        router.setPermit2(address(permit2));
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _quoteV2(MockV2Pair p, address tIn, uint256 amtIn) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool zfo = p.token0() == tIn;
        return BPC.outV2(amtIn, zfo ? r0 : r1, zfo ? r1 : r0, 30);
    }

    /// @dev The input near IN whose hop-0 delivery D and D's fee are both even: at factor 2 the
    ///      mock holds shares = display / 2, so an odd transfer lands a wei short, and that wei
    ///      sends `_execPairAmt` down its fee-on-transfer branch, which prices the pair's
    ///      `balance - reserve` as a real pair would (the mock's balance is not its reserve).
    ///      Even amounts keep every transfer exact, so the test measures the Router, not the mock.
    function _pickIn(MockV2Pair pairAB, address tA) internal view returns (uint256 amtIn) {
        // The fee's parity flips every ~540 wei of input: the first hit sits at IN + 433.
        for (amtIn = IN; amtIn < IN + 2048; ++amtIn) {
            uint256 d = _quoteV2(pairAB, tA, amtIn - BPC.mulDivUp(amtIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
            if (d % 2 == 0 && BPC.mulDivUp(d, BPC.PROTOCOL_FEE_BPS, BPC.BPS) % 2 == 0) return amtIn;
        }
        revert("no even input found");
    }

    /// @dev Reserves 200e18 each; the bridge side is funded DEEP so a restated display balance
    ///      never trips the `heldBy` gate of the leg quote.
    function _pair(address ta, address tb, uint256 fundA, uint256 fundB) internal returns (MockV2Pair p) {
        p = new MockV2Pair(ta, tb);
        IMintable(ta).mint(address(p), fundA);
        IMintable(tb).mint(address(p), fundB);
        p.setReserves(uint112(200e18), uint112(200e18));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), ta, tb);
    }

    function _route2(
        MockV2Pair p0, address tA, address tB, uint256 amt0, uint256 exp0,
        MockV2Pair p1, address tC, uint256 amt1, uint256 exp1
    ) internal view returns (Route memory r) {
        Leg[] memory legs0 = new Leg[](1);
        legs0[0] = Leg({
            pool: address(p0), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p0.token0() == tA, stable: false, amountIn: amt0, expectedOut: exp0, auxId: bytes32(0)
        });
        Leg[] memory legs1 = new Leg[](1);
        legs1[0] = Leg({
            pool: address(p1), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p1.token0() == tB, stable: false, amountIn: amt1, expectedOut: exp1, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: tA, tokenOut: tB, amountIn: amt0, expectedOut: exp0, legs: legs0});
        hops[1] = Hop({tokenIn: tB, tokenOut: tC, amountIn: amt1, expectedOut: exp1, legs: legs1});
        r = Route({
            hops: hops, totalOut: exp1, singleOut: exp1, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    struct Run {
        bool ok;
        uint256 delivered;      // C paid to the recipient
        uint256 routerShares;   // B shares the Router ends with (the rescue's)
        uint256 payerB;         // B the sweep handed the payer
        uint256 rebaseNum;      // 2 once the restatement fired
        uint256 routerBal;      // B the Router ends with, in the units it measures
        uint256 rebaseDen;      // 2 once a restatement down fired
    }

    /// @notice A->B->C, two V2 hops, no bridge registered (the fee is charged on every hop's
    ///         input). `foreign` B shares sit on the Router before the swap. `when` picks the
    ///         window of the x2 restatement of B: 0 none, 1 the hop-0 fee push (A lands on T1,
    ///         a hooked tokenIn), 2 the hop-1 fee push (B lands on T1). Hop 1 is attested at the
    ///         figure the pre-fix Router measured, so the pre-fix swap settles at scale 1.
    function _run(uint256 foreign, uint8 when) internal returns (Run memory res) {
        return _runAt(foreign, when, 2, 1);
    }

    /// @notice `_run` with the restatement factor num/den. A restatement DOWN (num < den) attests
    ///         hop 1 at the honest figure, D less its fee: the swap is priced as if nothing fired.
    function _runAt(uint256 foreign, uint8 when, uint256 num, uint256 den) internal returns (Run memory res) {
        HookedERC20 tA = new HookedERC20();
        PathologicalERC20 tB = new PathologicalERC20("B", "B", 18);
        MockERC20 tC = new MockERC20("C", "C");
        MockV2Pair pairAB = _pair(address(tA), address(tB), 200e18, RESERVE);
        MockV2Pair pairBC = _pair(address(tB), address(tC), RESERVE, 200e18);
        if (foreign != 0) tB.mint(address(router), foreign);
        if (when == 1) tA.arm(T1, tB, num, den);
        if (when == 2) tB.setRebaseOnTransferTo(T1, num, den);
        uint256 amtIn = _pickIn(pairAB, address(tA));
        tA.mint(user, amtIn);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);

        uint256 d = _quoteV2(pairAB, address(tA), amtIn - BPC.mulDivUp(amtIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
        // The pre-fix hop-1 measurement, by window: the fee base and the input it spends.
        uint256 base1 = when == 1 && num > den ? foreign + d : d;
        uint256 fee1 = BPC.mulDivUp(base1, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 m = when == 0 || num < den ? d - fee1 : (when == 1 ? foreign + d - fee1 : foreign + 2 * (d - fee1));
        Route memory route = _route2(
            pairAB, address(tA), address(tB), amtIn, d, pairBC, address(tC), m, _quoteV2(pairBC, address(tB), m)
        );
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(
            abi.encodeCall(router.swapExactIn, (route, amtIn, 1, recip, block.timestamp + 100))
        );
        res.ok = ok;
        if (ok) res.delivered = abi.decode(ret, (uint256));
        res.routerShares = tB.sharesOf(address(router));
        res.payerB = tB.balanceOf(user);
        res.rebaseNum = tB.rebaseNum();
        res.routerBal = tB.balanceOf(address(router));
        res.rebaseDen = tB.rebaseDen();
    }

    // ═════════════════════════════════════════════════════════════════════

    /// @notice Control: no foreign balance, no restatement. Hop 1 spends what hop 0 delivered
    ///         less its fee, and the Router holds nothing of the bridge afterwards.
    function test_AnHonestTwoHopSwapSpendsWhatHop0Delivered() public {
        Run memory h = _run(0, 0);
        assertTrue(h.ok, "the honest swap settles");
        assertEq(h.rebaseNum, 1, "no restatement fired");
        assertEq(h.routerShares, 0, "the Router holds no bridge after an honest swap");
        assertEq(h.payerB, 0, "nothing of the bridge went back to the payer");
        assertGt(h.delivered, 0, "the recipient was paid");
    }

    /// @notice The hop-1 fee push restates the bridge x2 (a reflection or rebase fired by the fee
    ///         transfer). Pre-fix: hop 1 spends F + 2(D - fee), the foreign holder's whole rebase
    ///         gain goes to the swapper and the Router ends with F/2 shares of the F it held.
    function test_ARestatementFiredByTheHop1FeePushStaysWithTheStrandedBridge() public {
        Run memory h = _run(0, 0);
        Run memory r = _run(FOREIGN, 2);
        assertTrue(r.ok, "the swap settles: the honest value is delivered, not refused");
        assertEq(r.rebaseNum, 2, "the restatement fired");
        assertEq(r.delivered, h.delivered, "the swapper is paid what hop 0 delivered buys, not the restatement");
        assertGe(r.routerShares, FOREIGN, "the stranded shares stay with the rescue");
        assertEq(r.payerB, 0, "the sweep hands the payer none of the restatement");
    }

    /// @notice The hop-0 fee push (tokenIn landing on T1) restates the bridge x2 BEFORE hop 0's
    ///         leg delivers, so hop 1's fee base and input read F + D past the baseline. Pre-fix:
    ///         the fee is charged on the foreign holder's gain and hop 1 spends it.
    function test_ARestatementFiredByTheHop0FeePushStaysWithTheStrandedBridge() public {
        Run memory h = _run(0, 0);
        Run memory r = _run(FOREIGN, 1);
        assertTrue(r.ok, "the swap settles: the honest value is delivered, not refused");
        assertEq(r.rebaseNum, 2, "the restatement fired");
        assertEq(r.delivered, h.delivered, "the swapper is paid what hop 0 delivered buys, not the restatement");
        assertGe(r.routerShares, FOREIGN, "the stranded shares stay with the rescue");
        assertEq(r.payerB, 0, "the sweep hands the payer none of the restatement");
    }

    // ─── the balance arm of `owned`: a restatement DOWN outside a leg window ───
    //
    // `owned` is the balance past the baseline AND no more than hopGot. The cap (hopGot) binds when
    // the bridge grows; the balance arm (bal - bridgeBase) binds when it shrinks between the leg
    // that measured hopGot and the read, and only a fee push sits there. Inside a leg window the
    // two agree (hopGot already measured the shrink), which is why the restatements DEX-11 sees
    // never told the arm from `own = decl`. Without it hop 1 spends hopGot of a balance that no
    // longer holds it, and the difference comes out of the stranded bridge (R3 / BP-15's drain,
    // reopened by the cap).

    /// @notice The hop-1 fee push restates the bridge x1/2 after the fee base was read and
    ///         before the scale reads it: the Router holds (F + D - fee)/2 and hop 1 may spend
    ///         only what lies past F. Spending hopGot - fee instead runs past the balance.
    function test_ARestatementDownFiredByTheHop1FeePushSpendsOnlyTheBalancePastTheBaseline() public {
        uint256 f = 10e18;
        Run memory h = _run(0, 0);
        Run memory r = _runAt(f, 2, 1, 2);
        assertTrue(r.ok, "the swap settles on the balance past the baseline");
        assertEq(r.rebaseDen, 2, "the restatement fired (factor 1/2)");
        assertLt(r.delivered, h.delivered, "the swapper bears the restatement's cut, as a short delivery");
        assertGt(r.delivered, 0, "the recipient was paid");
        assertGe(r.routerShares, 2 * f, "the Router keeps F in the units it measures: 2F shares at 1/2");
        assertEq(r.payerB, 0, "the sweep hands the payer none of the bridge");
    }

    /// @notice The hop-0 fee push (A lands on T1) restates the bridge x1/2 before hop 0's leg:
    ///         the leg measures D at the new factor, the Router holds F/2 + D, and hop 1's fee
    ///         base and input are what lies past F. Spending hopGot leaves the Router below F.
    function test_ARestatementDownFiredByTheHop0FeePushLeavesTheRouterItsBaseline() public {
        uint256 f = 10e18;
        Run memory h = _run(0, 0);
        Run memory r = _runAt(f, 1, 1, 2);
        assertTrue(r.ok, "the swap settles on the balance past the baseline");
        assertEq(r.rebaseDen, 2, "the restatement fired (factor 1/2)");
        assertLt(r.delivered, h.delivered, "the swapper bears the restatement's cut, as a short delivery");
        assertGt(r.delivered, 0, "the recipient was paid");
        assertGe(r.routerBal, f, "the Router never ends below the bridge it held before the swap");
        assertEq(r.payerB, 0, "the sweep hands the payer none of the bridge");
    }

    /// @notice Gamut: any stranded balance from dust to 4x the delivery, either fee-push window,
    ///         either direction (x2, x1/2). A swap that settles leaves the Router at least the
    ///         bridge it held before, in shares and in the units it measures, and pays the payer
    ///         none of it. A swap the Router refuses moves nothing.
    function testFuzz_TheRouterNeverEndsBelowTheBridgeItHeldBeforeTheSwap(uint256 foreign, bool hop1, bool up)
        public
    {
        foreign = bound(foreign, 1, 4 * IN);
        Run memory r = _runAt(foreign, hop1 ? 2 : 1, up ? 2 : 1, up ? 1 : 2);
        if (!r.ok) {
            assertEq(r.routerShares, foreign, "a refused swap moves nothing of the stranded bridge");
            return;
        }
        assertGe(r.routerShares, foreign, "the stranded shares stay with the rescue");
        assertGe(r.routerBal, foreign, "the Router never ends below the bridge it held before the swap");
        assertEq(r.payerB, 0, "the sweep hands the payer none of the bridge");
    }

    // ─── 4111/D1: a restatement fired INSIDE the hop-1 leg window, and the sweep ───
    //
    // The scale writes back what the balance holds past hop 1's input, but a restatement fired
    // after it (the hop's output landing on the Router) grows the stranded balance again. The
    // sweep paid the payer every unit past the baseline, so the stranded holder's gain,
    // F * (num/den - 1), rode out to the payer: linear in F and bounded by nothing the swap sized.
    // The sweep pays each bridge no more than this swap's unspent input of it.

    /// @notice A->B->C, two V2 hops; `foreign` B shares sit on the Router. With `num` != 0 the
    ///         C hook restates B by num/den when hop 1's leg pays C to the Router: inside the leg
    ///         window, after the scale wrote the baseline back. Both hops are attested at the
    ///         honest figure.
    function _runInLeg(uint256 foreign, uint256 num, uint256 den) internal returns (Run memory res) {
        HookedERC20 tA = new HookedERC20();
        PathologicalERC20 tB = new PathologicalERC20("B", "B", 18);
        HookedERC20 tC = new HookedERC20();
        MockV2Pair pairAB = _pair(address(tA), address(tB), 200e18, RESERVE);
        MockV2Pair pairBC = _pair(address(tB), address(tC), RESERVE, 200e18);
        if (foreign != 0) tB.mint(address(router), foreign);
        if (num != 0) tC.arm(address(router), tB, num, den);
        uint256 amtIn = _pickIn(pairAB, address(tA));
        tA.mint(user, amtIn);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);

        uint256 d = _quoteV2(pairAB, address(tA), amtIn - BPC.mulDivUp(amtIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
        uint256 m = d - BPC.mulDivUp(d, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        Route memory route = _route2(
            pairAB, address(tA), address(tB), amtIn, d, pairBC, address(tC), m, _quoteV2(pairBC, address(tB), m)
        );
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(
            abi.encodeCall(router.swapExactIn, (route, amtIn, 1, recip, block.timestamp + 100))
        );
        res.ok = ok;
        if (ok) res.delivered = abi.decode(ret, (uint256));
        res.routerShares = tB.sharesOf(address(router));
        res.payerB = tB.balanceOf(user);
        res.rebaseNum = tB.rebaseNum();
        res.routerBal = tB.balanceOf(address(router));
        res.rebaseDen = tB.rebaseDen();
    }

    /// @dev The same stranded F with and without the in-leg restatement: the restated swap leaves
    ///      the Router F shares, sweeps the payer exactly the residual the plain swap sweeps, and
    ///      delivers the same C.
    function _assertTheSweepLeavesTheRestatementWithTheRescue(uint256 f, uint256 num, uint256 den) internal {
        Run memory h = _runInLeg(f, 0, 0);
        Run memory r = _runInLeg(f, num, den);
        assertTrue(h.ok, "the plain swap settles");
        assertTrue(r.ok, "the restated swap settles: the honest value is delivered, not refused");
        assertEq(r.rebaseNum, num, "the restatement fired");
        assertEq(r.rebaseDen, den, "the restatement fired");
        assertGe(r.routerShares, f, "the stranded shares stay with the rescue");
        assertEq(r.payerB, h.payerB, "the sweep hands the payer the honest residual and none of the restatement");
        assertEq(r.delivered, h.delivered, "the recipient is paid what hop 0 delivered buys, not the restatement");
    }

    /// @notice One token stranded, the bridge doubles inside the hop-1 leg. Pre-fix: the payer
    ///         is swept 1e18 B, half the stranded holder's shares.
    function test_ARestatementInsideTheHop1LegLeavesOneStrandedTokenWithTheRescue() public {
        _assertTheSweepLeavesTheRestatementWithTheRescue(1e18, 2, 1);
    }

    /// @notice 100 tokens stranded, x2 inside the hop-1 leg. Pre-fix: 100e18 B to the payer.
    function test_ARestatementInsideTheHop1LegLeavesTheStrandedBridgeWithTheRescue() public {
        _assertTheSweepLeavesTheRestatementWithTheRescue(FOREIGN, 2, 1);
    }

    /// @notice Four times the swap's input stranded, x2: the gain is not bounded by the swap's
    ///         size, so neither may the test be. Pre-fix: 400e18 B to the payer.
    function test_ARestatementInsideTheHop1LegLeavesFourInputsStrandedWithTheRescue() public {
        _assertTheSweepLeavesTheRestatementWithTheRescue(4 * IN, 2, 1);
    }

    /// @notice A 1 % restatement over 100 stranded tokens. Pre-fix: ~1e18 B to the payer.
    function test_AOnePercentRestatementInsideTheHop1LegLeavesTheStrandedBridgeWithTheRescue() public {
        _assertTheSweepLeavesTheRestatementWithTheRescue(FOREIGN, 101, 100);
    }

    /// @notice Control: nothing stranded, nothing restated. The in-leg route settles, the Router
    ///         ends with none of the bridge and the payer is swept nothing.
    /// The Router keeps what the swap left unspent of the bridge in bridgeBase[n - 1], the one slot
    /// that is never a baseline because the last hop has no bridge. That holds for one bridge only:
    /// with MAX_HOPS = 3 slot n - 1 would be bridge 1's baseline and the cap would overwrite it.
    /// Raising the ceiling must come with a slot per bridge; this pin goes red first.
    function test_TheHopCeilingPinsTheBridgeLayout() public pure {
        assertEq(MAX_HOPS, 2, "4111/D1: bridgeBase[n - 1] holds the unspent bridge only while MAX_HOPS = 2");
    }

    function test_AnHonestInLegRouteSweepsNothingAndKeepsNothing() public {
        Run memory h = _runInLeg(0, 0, 0);
        assertTrue(h.ok, "the honest swap settles");
        assertEq(h.rebaseNum, 1, "no restatement fired");
        assertEq(h.routerShares, 0, "the Router holds no bridge after an honest swap");
        assertEq(h.payerB, 0, "the honest swap leaves no bridge residual");
        assertGt(h.delivered, 0, "the recipient was paid");
    }

    /// @notice Control: 100 tokens stranded, nothing restated. The sweep leaves them exactly.
    function test_AStrandedBridgeWithNoRestatementIsLeftExactly() public {
        Run memory h = _runInLeg(0, 0, 0);
        Run memory r = _runInLeg(FOREIGN, 0, 0);
        assertTrue(r.ok, "the swap settles");
        assertEq(r.routerShares, FOREIGN, "the stranded shares are left exactly");
        assertEq(r.payerB, 0, "the sweep hands the payer none of the bridge");
        assertEq(r.delivered, h.delivered, "the stranded balance does not change the delivery");
    }

    /// @notice Control: the bridge halves inside the hop-1 leg. The balance past the baseline is
    ///         gone, so the sweep has nothing to pay and the Router keeps every stranded share.
    function test_ARestatementDownInsideTheHop1LegSweepsNothing() public {
        Run memory h = _runInLeg(FOREIGN, 0, 0);
        Run memory r = _runInLeg(FOREIGN, 1, 2);
        assertTrue(r.ok, "the swap settles");
        assertEq(r.rebaseDen, 2, "the restatement fired (factor 1/2)");
        assertEq(r.routerShares, FOREIGN, "the Router keeps every stranded share");
        assertEq(r.payerB, 0, "the sweep hands the payer none of the bridge");
        assertEq(r.delivered, h.delivered, "the leg had already spent its input: the delivery is unchanged");
    }

    /// @notice Gamut: stranded from 1 wei to 4x the input, restated up by 1 % to x3 inside the
    ///         hop-1 leg. A swap that settles leaves the Router at least the shares it held,
    ///         sweeps the payer exactly the plain swap's residual and delivers the same C; a swap
    ///         the Router refuses moves nothing.
    function testFuzz_TheSweepNeverPaysTheStrandedBridgesRestatementToThePayer(uint256 foreign, uint256 num)
        public
    {
        foreign = bound(foreign, 1, 4 * IN);
        num = bound(num, 101, 300);
        Run memory h = _runInLeg(foreign, 0, 0);
        Run memory r = _runInLeg(foreign, num, 100);
        if (!r.ok) {
            assertEq(r.routerShares, foreign, "a refused swap moves nothing of the stranded bridge");
            return;
        }
        assertGe(r.routerShares, foreign, "the stranded shares stay with the rescue");
        assertEq(r.payerB, h.payerB, "the sweep hands the payer the honest residual and none of the restatement");
        assertEq(r.delivered, h.delivered, "the recipient is paid what hop 0 delivered buys, not the restatement");
    }

    uint8 constant ONE_HOP = 0;
    uint8 constant TWO_HOPS = 1;
    uint8 constant CYCLIC = 2;

    struct InRun {
        bool ok;
        uint256 delivered;     // amountOut the Router returned
        uint256 routerShares;  // shares of the restated token the Router ends with (the rescue's)
        uint256 payerA;        // tokenIn swept or refunded to the payer
        uint256 rebaseNum;
        uint256 rebaseDen;
    }

    function _hop1(MockV2Pair p, address tIn, address tOut, uint256 amt, uint256 exp)
        internal view returns (Hop memory)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)
        });
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: exp, legs: legs});
    }

    function _swap(Hop[] memory hops) internal returns (bool ok, uint256 delivered) {
        uint256 e = hops[hops.length - 1].expectedOut;
        Route memory route = Route({
            hops: hops, totalOut: e, singleOut: e, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
        vm.prank(user);
        bytes memory ret;
        (ok, ret) = address(router).call(
            abi.encodeCall(router.swapExactIn, (route, IN, 1, recip, block.timestamp + 100))
        );
        if (ok) delivered = abi.decode(ret, (uint256));
    }

    /// @notice tokenIn A restates (PathologicalERC20); `foreign` A shares sit on the Router.
    ///         shape: A->B, A->B->C, or the cyclic A->B->A. when: 0 none, 1 inside the hop-0 leg
    ///         (B lands on the Router), 2 inside the hop-1 leg (C lands on the Router).
    ///         `half`: hop 0 commits IN/2, so half the input is unspent and swept back.
    function _runInputInLeg(uint256 foreign, uint8 shape, uint8 when, uint256 num, uint256 den, bool half)
        internal returns (InRun memory res)
    {
        PathologicalERC20 tA = new PathologicalERC20("A", "A", 18);
        HookedERC20 tB = new HookedERC20();
        HookedERC20 tC = new HookedERC20();
        MockV2Pair pAB = _pair(address(tA), address(tB), RESERVE, RESERVE);
        if (foreign != 0) tA.mint(address(router), foreign);
        if (when == 1) tB.arm(address(router), tA, num, den);
        if (when == 2) tC.arm(address(router), tA, num, den);
        tA.mint(user, IN);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
        uint256 l0 = half ? IN / 2 : IN;
        uint256 d = _quoteV2(pAB, address(tA), half ? l0 : IN - BPC.mulDivUp(IN, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
        Hop[] memory hops = new Hop[](shape == ONE_HOP ? 1 : 2);
        hops[0] = _hop1(pAB, address(tA), address(tB), l0, d);
        if (shape != ONE_HOP) {
            uint256 m = d - BPC.mulDivUp(d, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
            address t1 = shape == TWO_HOPS ? address(tC) : address(tA);
            MockV2Pair p1 = _pair(address(tB), t1, RESERVE, RESERVE);
            hops[1] = _hop1(p1, address(tB), t1, m, _quoteV2(p1, address(tB), m));
        }
        (res.ok, res.delivered) = _swap(hops);
        res.routerShares = tA.sharesOf(address(router));
        res.payerA = tA.balanceOf(user);
        res.rebaseNum = tA.rebaseNum();
        res.rebaseDen = tA.rebaseDen();
    }

    /// @dev The same stranded input with and without the in-leg restatement: the restated swap
    ///      leaves the Router its stranded shares, sweeps the payer the plain swap's residual (the
    ///      rebasing token may round the transfer down by one wei) and delivers the same output.
    function _assertTheInputSweepLeavesTheRestatementWithTheRescue(
        uint256 f, uint8 shape, uint8 when, uint256 num, uint256 den, bool half
    ) internal {
        InRun memory h = _runInputInLeg(f, shape, 0, 0, 0, half);
        InRun memory r = _runInputInLeg(f, shape, when, num, den, half);
        assertTrue(h.ok, "the plain swap settles");
        assertTrue(r.ok, "the restated swap settles: the honest value is delivered, not refused");
        assertEq(r.rebaseNum, num, "the restatement fired");
        assertEq(r.rebaseDen, den, "the restatement fired");
        assertGe(r.routerShares, f, "the stranded input shares stay with the rescue");
        assertLe(r.payerA, h.payerA, "the payer is swept no more than the plain swap's residual");
        assertApproxEqAbs(r.payerA, h.payerA, 1, "the payer is swept the plain swap's residual");
        // The cyclic output is the restated token itself: its transfer rounds down by up to 2 wei.
        assertLe(r.delivered, h.delivered, "the delivery is not raised by the restatement");
        assertApproxEqAbs(r.delivered, h.delivered, 2, "the delivery is unchanged (token rounding)");
    }

    /// @notice 100 input tokens stranded, x2 inside the hop-0 leg of a one-hop route. Pre-fix: the
    ///         sweep pays the payer 100e18 A, half the stranded holder's shares.
    function test_ARestatementInsideTheHop0LegLeavesTheStrandedInputWithTheRescue() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(FOREIGN, ONE_HOP, 1, 2, 1, false);
    }

    /// @notice One input token stranded, x2. Pre-fix: the Router ends with 0.5e18 shares.
    function test_ARestatementInsideTheHop0LegLeavesOneStrandedInputTokenWithTheRescue() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(1e18, ONE_HOP, 1, 2, 1, false);
    }

    /// @notice Four inputs stranded, x2: the gain is not bounded by the swap's size.
    function test_ARestatementInsideTheHop0LegLeavesFourInputsOfStrandedInputWithTheRescue() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(4 * IN, ONE_HOP, 1, 2, 1, false);
    }

    /// @notice A 1 % restatement over 100 stranded input tokens. Pre-fix: ~1e18 A to the payer.
    function test_AOnePercentRestatementInsideTheHop0LegLeavesTheStrandedInputWithTheRescue() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(FOREIGN, ONE_HOP, 1, 101, 100, false);
    }

    /// @notice Half the input unspent: the payer gets that half back, and none of the restatement.
    function test_AnInputRestatementWithHalfTheInputUnspentSweepsOnlyTheUnspentHalf() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(FOREIGN, ONE_HOP, 1, 2, 1, true);
    }

    /// @notice Two hops, the input restated inside the hop-1 leg (after hop 0 spent it).
    function test_AnInputRestatementInsideTheHop1LegLeavesTheStrandedInputWithTheRescue() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(FOREIGN, TWO_HOPS, 2, 2, 1, false);
    }

    /// @notice Two hops, the input restated inside the hop-0 leg.
    function test_AnInputRestatementInsideTheHop0LegOfATwoHopRouteLeavesItWithTheRescue() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(FOREIGN, TWO_HOPS, 1, 2, 1, false);
    }

    /// @notice Cyclic A->B->A: the refund at the start of hop 1 (`resid0`) had the same shape.
    function test_ACyclicRefundLeavesTheInputRestatementWithTheRescue() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(FOREIGN, CYCLIC, 1, 2, 1, false);
    }

    /// @notice Cyclic, half the input unspent: the refund is that half, none of the restatement.
    function test_ACyclicRefundWithHalfTheInputUnspentRefundsOnlyThatHalf() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(FOREIGN, CYCLIC, 1, 2, 1, true);
    }

    /// @notice Control (dust): one stranded wei, x2. The sweep's 1-wei excess is 0 shares in the
    ///         token's own rounding, so the Router keeps its share on both sides of the fix.
    function test_AOneWeiStrandedInputIsBelowTheTokensOwnRounding() public {
        _assertTheInputSweepLeavesTheRestatementWithTheRescue(1, ONE_HOP, 1, 2, 1, false);
    }

    /// @notice Control: stranded input, nothing restated, every shape. Left exactly; a committed
    ///         input sweeps nothing and a half-committed one sweeps the unspent half.
    function test_AStrandedInputWithNoRestatementIsLeftExactlyInEveryShape() public {
        for (uint8 s; s < 3; ++s) {
            InRun memory h = _runInputInLeg(FOREIGN, s, 0, 0, 0, false);
            assertTrue(h.ok, "the swap settles");
            assertEq(h.routerShares, FOREIGN, "the stranded input is left exactly");
            assertEq(h.payerA, 0, "a fully committed input sweeps nothing");
            InRun memory u = _runInputInLeg(FOREIGN, s, 0, 0, 0, true);
            assertTrue(u.ok, "the half-committed swap settles");
            assertEq(u.routerShares, FOREIGN, "the stranded input is left exactly");
            assertGt(u.payerA, 0, "the unspent half is swept back");
        }
    }

    /// @notice Control: the input halves inside the hop-0 leg. Nothing is past the baseline, so
    ///         nothing is swept; the cyclic shape's output delta underflows and fails closed.
    function test_AnInputRestatementDownSweepsNothing() public {
        for (uint8 s; s < 3; ++s) {
            InRun memory r = _runInputInLeg(FOREIGN, s, 1, 1, 2, false);
            if (s == CYCLIC && !r.ok) {
                assertEq(r.routerShares, FOREIGN, "a refused swap moves nothing");
                continue;
            }
            assertTrue(r.ok, "the swap settles");
            assertEq(r.rebaseDen, 2, "the restatement fired (factor 1/2)");
            assertEq(r.routerShares, FOREIGN, "the Router keeps every stranded share");
            assertEq(r.payerA, 0, "the sweep hands the payer none of the input");
        }
    }

    /// @notice Gamut: stranded input from 1 wei to 4x the swap, restated up by 1 % to x3, in
    ///         every shape and in either leg window, committed or half unspent.
    function testFuzz_TheInputSweepNeverPaysTheStrandedRestatementToThePayer(
        uint256 foreign, uint256 num, uint8 shape, bool hop1, bool half
    ) public {
        foreign = bound(foreign, 1, 4 * IN);
        num = bound(num, 101, 300);
        shape = uint8(bound(shape, 0, 2));
        uint8 when = (shape == TWO_HOPS && hop1) ? 2 : 1;
        InRun memory h = _runInputInLeg(foreign, shape, 0, 0, 0, half);
        InRun memory r = _runInputInLeg(foreign, shape, when, num, 100, half);
        if (!r.ok) {
            assertEq(r.routerShares, foreign, "a refused swap moves nothing");
            return;
        }
        assertGe(r.routerShares, foreign, "the stranded input shares stay with the rescue");
        assertLe(r.payerA, h.payerA, "the payer is swept no more than the plain residual");
        // Both runs sweep the same X (the cap binds at what hop 0 left unspent). At factor num/100
        // the token moves floor(X * 100 / num) shares and shows floor(shares * num / 100), which is
        // short of X by at most ceil((num - 1) / 100) wei: 1 at num <= 101, 3 at num = 300.
        assertApproxEqAbs(r.payerA, h.payerA, (num + 98) / 100, "the payer is swept the plain residual");
        // The cyclic output is the restated token itself: the Router's balance past baseIn may sit
        // up to 1 wei under the venue's figure (the output lands as floor(Q * 100 / num) shares),
        // and the payout to the recipient rounds down by up to ceil((num - 1) / 100) more.
        assertLe(r.delivered, h.delivered, "the delivery is not raised by the restatement");
        assertApproxEqAbs(r.delivered, h.delivered, (num + 198) / 100, "the delivery is unchanged (token rounding)");
    }

    /// @notice The output side is already capped (3310): C restates x2 inside the hop-0 leg over
    ///         100 stranded C. The delta is capped at what the venues declared; the restatement stays.
    function test_AStrandedOutputRestatedInsideTheHop0LegStaysWithTheRescue() public {
        for (uint256 i; i < 2; ++i) {
            HookedERC20 tA = new HookedERC20();
            HookedERC20 tB = new HookedERC20();
            PathologicalERC20 tC = new PathologicalERC20("C", "C", 18);
            MockV2Pair pAB = _pair(address(tA), address(tB), RESERVE, RESERVE);
            MockV2Pair pBC = _pair(address(tB), address(tC), RESERVE, RESERVE);
            tC.mint(address(router), FOREIGN);
            if (i == 1) tB.arm(address(router), tC, 2, 1);
            tA.mint(user, IN);
            vm.prank(user);
            tA.approve(address(router), type(uint256).max);
            uint256 d = _quoteV2(pAB, address(tA), IN - BPC.mulDivUp(IN, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
            uint256 m = d - BPC.mulDivUp(d, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
            // Quoted before the swap: the mock pair syncs its reserves to its (deep) balances after.
            uint256 q = _quoteV2(pBC, address(tB), m);
            Hop[] memory hops = new Hop[](2);
            hops[0] = _hop1(pAB, address(tA), address(tB), IN, d);
            hops[1] = _hop1(pBC, address(tB), address(tC), m, q);
            (bool ok, uint256 delivered) = _swap(hops);
            assertTrue(ok, "the swap settles");
            assertGe(tC.sharesOf(address(router)), FOREIGN, "the stranded output shares stay with the rescue");
            assertApproxEqAbs(delivered, q, 1, "the recipient is paid the venue's figure");
        }
    }
}
