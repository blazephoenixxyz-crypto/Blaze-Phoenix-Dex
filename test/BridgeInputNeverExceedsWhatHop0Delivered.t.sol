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
// forge test --match-path test/BridgeInputNeverExceedsWhatHop0Delivered.t.sol -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
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
    }

    /// @notice A->B->C, two V2 hops, no bridge registered (the fee is charged on every hop's
    ///         input). `foreign` B shares sit on the Router before the swap. `when` picks the
    ///         window of the x2 restatement of B: 0 none, 1 the hop-0 fee push (A lands on T1,
    ///         a hooked tokenIn), 2 the hop-1 fee push (B lands on T1). Hop 1 is attested at the
    ///         figure the unfixed Router measured, so the unfixed swap settles at scale 1.
    function _run(uint256 foreign, uint8 when) internal returns (Run memory res) {
        HookedERC20 tA = new HookedERC20();
        PathologicalERC20 tB = new PathologicalERC20("B", "B", 18);
        MockERC20 tC = new MockERC20("C", "C");
        MockV2Pair pairAB = _pair(address(tA), address(tB), 200e18, RESERVE);
        MockV2Pair pairBC = _pair(address(tB), address(tC), RESERVE, 200e18);
        if (foreign != 0) tB.mint(address(router), foreign);
        if (when == 1) tA.arm(T1, tB, 2, 1);
        if (when == 2) tB.setRebaseOnTransferTo(T1, 2, 1);
        uint256 amtIn = _pickIn(pairAB, address(tA));
        tA.mint(user, amtIn);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);

        uint256 d = _quoteV2(pairAB, address(tA), amtIn - BPC.mulDivUp(amtIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
        // The unfixed hop-1 measurement, by window: the fee base and the input it spends.
        uint256 base1 = when == 1 ? foreign + d : d;
        uint256 fee1 = BPC.mulDivUp(base1, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 m = when == 0 ? d - fee1 : (when == 1 ? foreign + d - fee1 : foreign + 2 * (d - fee1));
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
    ///         transfer). Unfixed: hop 1 spends F + 2(D - fee), the foreign holder's whole rebase
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
    ///         leg delivers, so hop 1's fee base and input read F + D past the baseline. Unfixed:
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
}
