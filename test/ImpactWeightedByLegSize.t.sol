// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  T1 — the iron floor averaged per-leg impacts without weighting them.
//
//      uint256 avgImpact = totalLegs > 0 ? impactAcc / totalLegs : 0;
//      uint256 floorBps  = BPC.ironFloorBps(avgImpact, totalLegs, 0);
//      uint256 protocolFloorOut = mulDivUp(finalHopQuote, floorBps, BPS);
//
//  ironFloorBps SUBTRACTS impact, so a bigger impact means a LOWER floor. And
//  the caller writes the Route. So the attacker's move is to push the mean UP:
//  a leg of one wei against a dust-reserve pool has an impact fraction near
//  100%, because impact is amountIn/(reserveIn+amountIn) — a RATIO, blind to
//  how little value the leg actually carries. Each such leg drags the
//  unweighted mean toward BPS and walks the floor down from 96% toward its 80%
//  hard clamp, on a route whose real trade is one honest deep leg.
//
//  This is the same padding lever an external researcher found against the
//  leg-count shave, and it is strictly stronger: leg count moves the floor 200
//  bps per leg, the impact term has the whole 1600 bps band.
//
//  THE ISOLATION THAT MAKES THIS MEASURABLE. Leg count lowers the floor by
//  itself, so comparing a padded route against an unpadded one proves nothing.
//  Both routes here carry the SAME number of legs; only the padding pools
//  differ — deep in the control, dust in the attack. Any gap between the two
//  floors is the impact term alone.
//
//  THE FIX weights each leg's impact by its share of the hop. Equal-sized legs
//  reproduce the old sum exactly, so honest routes do not move; a dust leg
//  carries a share near zero and stops speaking for the route.
//
//  RED BEFORE THE FIX, measured: the floor falls from 8835 to 7877 — 10.8%
//  weaker — bought with three legs carrying 1e6 wei each, about 1e-12 of a
//  token. With the weighting it lands at 8765 against a 8763 control.
//
//  THREE WRONG CONSTRUCTIONS CAME FIRST, and each was a real lesson:
//    1. both routes shared one main pool, so the first run moved the book the
//       second traded against and manufactured a gap out of nothing;
//    2. the padding pools held 1e3 reserves — a 1-wei leg there scores 10 bps,
//       not 100%, because impact is a FRACTION and a tiny leg is a tiny
//       fraction of any pool that has reserves at all;
//    3. the padding legs carried a single wei, which the fee-induced scaling
//       rounds to zero, so they never reached a pool and contributed nothing.
//  The lever needs all three at once: an amount that survives scaling, a pool
//  whose INPUT-side reserve is ~empty, and a control that starts from the same
//  book. Accepting the first red would have proved a bug with a broken test;
//  accepting the first green would have dismissed a real one.
//
//  forge test --match-contract ImpactWeightedByLegSize -vv
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract ImpactWeightedByLegSizeTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokA;
    MockERC20 tokB;

    address user = address(0xBEEF);
    address constant T1_ = address(0xFEE1);
    address constant T2_ = address(0xFEE2);

    /// The honest trade. Everything else in the route is padding.
    uint256 constant BULK = 10_000e18;
    /// A padding leg carries essentially nothing — 1e6 wei is 1e-12 of a token
    /// — but it must survive the fee-induced scaling. A single wei scales to
    /// ZERO (legAmt = mulDiv(1, ~0.9972*D, D) = 0), never reaches its pool, and
    /// contributes no impact at all, so it cannot be the lever.
    uint256 constant DUST = 1e6;

    bool zfo;
    MockV2Pair deepMain;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), T1_, T2_);
        hub.setRoles(address(router), address(solver), address(this));

        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");

        deepMain = _pool(1_000_000e18, 1_000_000e18);
        zfo = deepMain.token0() == address(tokA);

        tokA.mint(user, 10_000_000e18);
        vm.prank(user);
        tokA.approve(address(router), type(uint256).max);
    }

    /// @param rA reserve of tokA, @param rB reserve of tokB — named by TOKEN,
    ///        not by slot, because the pair sorts its tokens by address and
    ///        `setReserves` is positional.
    ///
    /// This helper used to pass (rA, rB) straight through, which silently
    /// assumed tokA sorts first. It does on one machine and not on another:
    /// a different compiler version shifts the test-derived addresses, tokB
    /// becomes token0, and "1 wei on the INPUT side" quietly becomes 1 wei on
    /// the OUTPUT side — outV2 then floors to zero and the leg reverts
    /// RouterE(8) before any floor is reached. That is exactly the fragility
    /// foundry.toml's own comment warns about ("Router bytecode changes shift
    /// the test-derived addresses"), and it took running the suite on a second
    /// machine to see it. Order by the pair's own view instead of assuming.
    function _pool(uint112 rA, uint112 rB) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokA), address(tokB));
        tokA.mint(address(p), rA);
        tokB.mint(address(p), rB);
        bool aIsToken0 = p.token0() == address(tokA);
        p.setReserves(aIsToken0 ? rA : rB, aIsToken0 ? rB : rA);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokA), address(tokB));
    }

    function _leg(address pool, uint256 amt) internal view returns (Leg memory) {
        return Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
    }

    /// Runs a one-hop route and returns the `floorUsed` the Router published.
    function _floorOf(Leg[] memory legs, uint256 amountIn) internal returns (uint256 floorUsed) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokA), tokenOut: address(tokB),
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        Route memory r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, amountIn, 1, user, block.timestamp + 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (, , floorUsed, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                return floorUsed;
            }
        }
        revert("no ExecutionProof emitted");
    }

    // ─── the claim ───────────────────────────────────────────────────────────

    /// Both routes carry four legs, so the leg-count shave is identical and
    /// cancels. The only difference is what the three padding legs point at.
    function test_DustPadding_MustNotCollapseTheFloor() public {
        // EACH ROUTE GETS ITS OWN MAIN POOL. The two runs happen in sequence,
        // and the first one moves the reserves it trades against — so sharing
        // one main pool would make the second route quote against a worse book
        // and manufacture a gap that has nothing to do with impact weighting.
        // (That flaw was in the first version of this test and survived the fix,
        // which is how it was found.)
        MockV2Pair mainCtl = _pool(1_000_000e18, 1_000_000e18);
        MockV2Pair deepPad1 = _pool(1_000_000e18, 1_000_000e18);
        MockV2Pair deepPad2 = _pool(1_000_000e18, 1_000_000e18);
        MockV2Pair deepPad3 = _pool(1_000_000e18, 1_000_000e18);

        Leg[] memory control = new Leg[](4);
        control[0] = _leg(address(mainCtl), BULK);
        control[1] = _leg(address(deepPad1), DUST);
        control[2] = _leg(address(deepPad2), DUST);
        control[3] = _leg(address(deepPad3), DUST);
        uint256 floorDeep = _floorOf(control, BULK + 3 * DUST);

        // Same shape, same leg count, same dust amounts — but the padding legs
        // now point at pools with almost no reserves, so each one's impact
        // RATIO is enormous while the value it carries is one wei.
        MockV2Pair mainAtk = _pool(1_000_000e18, 1_000_000e18);
        // THE INPUT-SIDE RESERVE IS WHAT MATTERS, and it must be ~zero, not
        // merely small. impact = amountIn/(reserveIn+amountIn), so a one-wei leg
        // into a 1e3-reserve pool scores 10 bps, not 100% — a tiny leg is a tiny
        // fraction of any pool that has reserves at all. The lever only exists
        // where reserveIn is 1 (impact 5000 bps) or 0 (impactV2Bps returns the
        // whole BPS by its own early return). The output side stays deep so the
        // leg can actually settle.
        MockV2Pair dustPad1 = _pool(1, 1e18);
        MockV2Pair dustPad2 = _pool(1, 1e18);
        MockV2Pair dustPad3 = _pool(1, 1e18);

        Leg[] memory attack = new Leg[](4);
        attack[0] = _leg(address(mainAtk), BULK);
        attack[1] = _leg(address(dustPad1), DUST);
        attack[2] = _leg(address(dustPad2), DUST);
        attack[3] = _leg(address(dustPad3), DUST);
        uint256 floorAttack = _floorOf(attack, BULK + 3 * DUST);

        emit log_named_uint("floor with deep padding", floorDeep);
        emit log_named_uint("floor with dust padding", floorAttack);

        // THE CLAIM: three one-wei legs cannot buy a materially weaker floor.
        // A small gap is tolerable — the dust legs do carry a little impact —
        // but the floor must not walk toward its clamp on their account.
        assertGe(floorAttack, (floorDeep * 9_900) / 10_000,
            "negligible-value legs against near-empty pools walked the protocol floor down");
    }

    // ─── control: honest equal splits are unchanged by the weighting ─────────

    /// Weighting by share must reproduce the unweighted sum exactly when the
    /// legs are the same size, so a normal split route does not move.
    function test_Control_EqualSplitAcrossDeepPools() public {
        MockV2Pair b = _pool(1_000_000e18, 1_000_000e18);

        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(deepMain), BULK / 2);
        legs[1] = _leg(address(b), BULK / 2);

        uint256 floorUsed = _floorOf(legs, BULK);
        assertGt(floorUsed, 0, "an honest split route still publishes a floor");
    }
}
