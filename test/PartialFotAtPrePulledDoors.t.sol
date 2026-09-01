// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Partial fee-on-transfer at the two PRE-PULLED doors — the untested cell.
//
//  swapExactInWithPermit2 (Router:371) and swapBestExactIn (Router:472) each
//  carry their own copy of the measured-pull reprice block (Router:395-408 and
//  Router:485-498): measure what actually arrived, and if it differs from the
//  nominal amountIn, _noteFot(received * BPS / amountIn) so the floor block
//  (Router:1295-1305) drops the nominal-priced singleOutFloor and re-prices
//  protocolFloorOut off the MEASURED net ratio. Until this file, the only FoT
//  test at these doors used a 100% tax, which short-circuits at RouterE(8)
//  (Router:394 / Router:483) BEFORE the reprice runs
//  (test/RouterRefusalsObserved.t.sol:324-334, :361-366). Every partial-rate
//  FoT test in the tree (test/FotFloorReprice.t.sol, 1%/5%/15%/25%) enters
//  through the CLASSIC door only. Duplicated logic with a test on only one
//  copy is this codebase's documented defect signature — so both copies get
//  executed here with a NONZERO receive, at 1%, 5% and 25%.
//
//  Two token shapes, because they exercise different sub-branches:
//
//    · MockERC20 with feeOnTransferBps (taxes EVERY transfer): the pull-side
//      note AND the leg-side note (Router:1619) both fire and compound in
//      TSLOT_FOT (Router:1578-1583). The delivered amount reflects the token
//      taxing each transfer it actually makes — pull and pool-push — and the
//      Router must add NOTHING on top.
//
//    · TransferFromTaxERC20 (in-file): taxes transferFrom, exempts transfer —
//      the exact asymmetric subclass the reprice comment names (Router:397-399
//      / :487-489). Here the leg loop sees NO discrepancy, so TSLOT_FOT is
//      written ONLY by the door's own pull-side block. Delete either door's
//      block and its asym test below dies in RouterE(5) on a floor priced for
//      the nominal amountIn: these are the two discriminating tests.
//
//  Door parity (requirement 5): all three doors — classic swapExactIn
//  (Router:352, pull measured at Router:526-540), Permit2, and best — run the
//  same downstream _execute on the measured receive. The pull tax, the hop-0
//  protocol fee (Router:589-620, charged on hop 0 because no bridge token is
//  registered: Router:976-981, :1044-1045) and the leg push are identical
//  transfers in all three, so delivered must agree to the EXACT wei. The
//  parity tests assert strict equality; if a divergence ever appears, the
//  failing assert names the diverging door — that divergence is the defect
//  this file exists to find. As analysed at head revision, no divergence is
//  expected: neither pre-pulled door is believed wrong.
//
//  Harness mirrors test/SwapBestExactInHardening.t.sol (real Hub + Solver,
//  seedPool) plus test/RouterPermit2OneStep.t.sol (MockPermit2 wiring).
//
//  forge test --match-contract PartialFotAtPrePulledDoors -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

/// @notice The asymmetric FoT subclass named by the reprice blocks themselves
///         (Router:397-399): taxes transferFrom, exempts transfer. The pull
///         (classic safeTransferFrom, Permit2's transferFrom, best-door
///         safeTransferFrom) is taxed; the Router->pool push (safeTransfer ->
///         transfer) arrives whole, so the leg loop's own FoT note
///         (Router:1614-1620) never fires and TSLOT_FOT can only be written
///         by the door's pull-side block. Tax arithmetic mirrors
///         test/mocks/MockERC20.sol:71-75 exactly: fee = (amt * bps) / 10_000,
///         delivered = amt - fee, debit is the FULL amt.
contract TransferFromTaxERC20 {
    string public name;
    string public symbol;
    uint8  public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint16 public taxBps;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function setTaxBps(uint16 bps) external { taxBps = bps; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    /// @dev Plain transfer is EXEMPT — this is what makes the token
    ///      asymmetric and the door's pull-side note the only producer.
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "AsymFoT: balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    /// @dev transferFrom is TAXED, same integer arithmetic as
    ///      MockERC20._transfer (test/mocks/MockERC20.sol:71-75).
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (from != msg.sender) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) {
                require(a >= amt, "AsymFoT: allowance");
                allowance[from][msg.sender] = a - amt;
            }
        }
        require(balanceOf[from] >= amt, "AsymFoT: balance");
        balanceOf[from] -= amt;
        uint256 delivered = amt - (amt * taxBps) / 10_000;
        balanceOf[to] += delivered;
        return true;
    }
}

contract PartialFotAtPrePulledDoorsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockPermit2 permit2;

    MockERC20 fotIn;              // taxes EVERY transfer (pull AND leg push)
    TransferFromTaxERC20 asymIn;  // taxes transferFrom only (pull, not push)
    MockERC20 tokenOut;           // always clean, so output-side is exact
    MockV2Pair pairFot;
    MockV2Pair pairAsym;

    address user = address(0xBEEF);
    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);

    uint256 constant RESERVE = 1_000_000e18; // deep on both sides: 0.1% trade,
                                             // Solver capacity clamp stays away
    uint256 constant N = 1_000e18;           // nominal amountIn at every door

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0)); // Hub:387
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2
        );
        hub.setRoles(address(router), address(solver), address(this)); // Hub:428
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2)); // Router:290

        fotIn = new MockERC20("FoT In", "FIN");
        asymIn = new TransferFromTaxERC20("Asym In", "AIN");
        tokenOut = new MockERC20("Out", "OUT");

        pairFot = _seedV2(address(fotIn), address(tokenOut));
        pairAsym = _seedV2(address(asymIn), address(tokenOut));

        fotIn.mint(user, 100_000e18);
        asymIn.mint(user, 100_000e18);
        vm.startPrank(user);
        fotIn.approve(address(router), type(uint256).max);
        fotIn.approve(address(permit2), type(uint256).max);
        asymIn.approve(address(router), type(uint256).max);
        asymIn.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function _seedV2(address tX, address tY) internal returns (MockV2Pair p) {
        p = new MockV2Pair(tX, tY);
        // Mint == setReserves, so _execPairAmt's FoT branch (Router:1612-1619)
        // computes realIn = balAfter - storedReserve = exactly what arrived.
        if (tX == address(fotIn) || tX == address(tokenOut)) {
            MockERC20(tX).mint(address(p), RESERVE);
        } else {
            TransferFromTaxERC20(tX).mint(address(p), RESERVE);
        }
        MockERC20(tY).mint(address(p), RESERVE);
        p.setReserves(uint112(RESERVE), uint112(RESERVE));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), tX, tY); // Hub:1729
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Expected-value arithmetic — every step is one line of source.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The mocks' tax, verbatim (test/mocks/MockERC20.sol:71-75 and
    ///      TransferFromTaxERC20.transferFrom above): floor division on the fee.
    function _taxedOut(uint256 amt, uint256 t) private pure returns (uint256) {
        return amt - (amt * t) / 10_000;
    }

    /// @dev Delivered amount, derived from the MEASURED pull:
    ///        received = _taxedOut(N, t)                — the pull, measured at
    ///                    Router:392/447-style balance delta (Router:388-392 for
    ///                    Permit2, Router:481-482 for best, Router:526-528 classic);
    ///        feeH     = mulDivUp(received, 28, 10_000) — hop-0 protocol fee on
    ///                    the measured base (Router:593-597 min(received, sum
    ///                    leg.amountIn) = received under tax; Router:612;
    ///                    PROTOCOL_FEE_BPS Core:323, mulDivUp Core:381);
    ///        spend    = received - feeH                — Router:619-620;
    ///        legAmt   = mulDiv(leg.amountIn, spend, leg.amountIn) = spend
    ///                    (single leg: scaleNum = spend, scaleDen = N,
    ///                     Router:1148, cap at Router:1150-1153 inert);
    ///        poolIn   = legTaxed ? _taxedOut(spend, t) : spend
    ///                    — the Router->pool push (Router:1600); askIn is the
    ///                    measured arrival (Router:1612-1618);
    ///        out      = outV2(poolIn, RESERVE, RESERVE, 30)
    ///                    — Router:1622 with effV2Fee(30) = 30 (Core:993-995),
    ///                    outV2 at Core:1050-1057; MockV2Pair pays it exactly
    ///                    and tokenOut is clean, so delivered == out
    ///                    (Router:1332-1335 measures the recipient delta).
    ///      The tax appears in this chain exactly as many times as the token
    ///      actually taxes a transfer — once for the asym token, twice for the
    ///      tax-all token. Any EXTRA discount by the Router breaks assertEq.
    function _expectedDelivered(uint256 t, bool legTaxed) private pure returns (uint256) {
        uint256 received = _taxedOut(N, t);
        uint256 feeH = BPC.mulDivUp(received, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 spend = received - feeH;
        uint256 poolIn = legTaxed ? _taxedOut(spend, t) : spend;
        return BPC.outV2(poolIn, RESERVE, RESERVE, 30);
    }

    /// @dev Hand-built one-leg route, the same shape the Solver emits: gross
    ///      attestation priced at the NOMINAL amountIn (a Solver quotes the
    ///      nominal — it cannot see the tax), optional Solver-style floor.
    function _route(address tIn, MockV2Pair p, uint256 floorOut)
        private view returns (Route memory r)
    {
        uint256 q = BPC.outV2(N, RESERVE, RESERVE, 30); // gross, nominal-priced
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: p.token0() == tIn, stable: false,
            amountIn: N, expectedOut: q, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: tIn, tokenOut: address(tokenOut),
            amountIn: N, expectedOut: q, legs: legs
        });
        r = Route({
            hops: hops, totalOut: q, singleOut: q, singleOutFloor: floorOut,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _permitFor(address token, uint256 amount)
        private view returns (IPermit2.PermitTransferFrom memory p)
    {
        // Struct shape: Router:78-85.
        p = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: token, amount: amount }),
            nonce: 0,
            deadline: block.timestamp + 60
        });
    }

    // Door runners — one swap each, from whatever state the caller prepared.

    // NOTE: the Route is built BEFORE vm.prank — _route makes an external
    // staticcall (p.token0()), which would otherwise consume the prank.

    function _swapClassic(address tIn, MockV2Pair p) private returns (uint256 d) {
        Route memory r = _route(tIn, p, 0);
        vm.prank(user);
        d = router.swapExactIn(r, N, 1, user, block.timestamp + 1); // Router:352
    }

    function _swapPermit2(address tIn, MockV2Pair p, uint256 floorOut) private returns (uint256 d) {
        Route memory r = _route(tIn, p, floorOut);
        IPermit2.PermitTransferFrom memory permit = _permitFor(tIn, N);
        vm.prank(user);
        d = router.swapExactInWithPermit2( // Router:371-375
            r, N, 1, user, block.timestamp + 1, permit, ""
        );
    }

    function _swapBest(address tIn) private returns (uint256 d) {
        vm.prank(user);
        d = router.swapBestExactIn( // Router:472-475
            tIn, address(tokenOut), N, 1, user, block.timestamp + 1
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  1+2. The grid: each pre-pulled door settles a partially-taxed token,
    //       and delivers EXACTLY the amount the measured pull predicts —
    //       the tax charged once per transfer the token makes, never more.
    // ─────────────────────────────────────────────────────────────────────────

    function _permit2DoorExact(uint16 t) private {
        fotIn.setFeeOnTransferBps(t);
        uint256 balBefore = fotIn.balanceOf(user);
        uint256 delivered = _swapPermit2(address(fotIn), pairFot, 0);

        assertGt(delivered, 0, "taxed token must not be locked out of the Permit2 door");
        assertEq(delivered, _expectedDelivered(t, true),
            "Permit2 door: delivered must equal the measured-pull derivation to the wei");
        assertEq(tokenOut.balanceOf(user), delivered,
            "recipient got exactly the returned amount");
        // The user is debited the NOMINAL amount exactly once (Router:389-393
        // pulls amountIn; the tax burns in transit, it is not re-pulled).
        assertEq(fotIn.balanceOf(user), balBefore - N, "user debited exactly the nominal N");
        assertEq(fotIn.balanceOf(address(router)), 0, "router holds no tokenIn");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router holds no tokenOut");
    }

    function _bestDoorExact(uint16 t) private {
        fotIn.setFeeOnTransferBps(t);
        uint256 balBefore = fotIn.balanceOf(user);
        uint256 delivered = _swapBest(address(fotIn));

        assertGt(delivered, 0, "taxed token must not be locked out of the best door");
        assertEq(delivered, _expectedDelivered(t, true),
            "best door: delivered must equal the measured-pull derivation to the wei");
        assertEq(tokenOut.balanceOf(user), delivered,
            "recipient got exactly the returned amount");
        assertEq(fotIn.balanceOf(user), balBefore - N, "user debited exactly the nominal N");
        assertEq(fotIn.balanceOf(address(router)), 0, "router holds no tokenIn");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router holds no tokenOut");
    }

    /// @notice 1% tax through swapExactInWithPermit2 — the first partial-rate
    ///         FoT ever to execute the Router:395-408 reprice with a nonzero
    ///         receive.
    function test_Permit2Door_Tax1pct_SettlesTaxChargedOnce() public {
        _permit2DoorExact(100);
    }

    function test_Permit2Door_Tax5pct_SettlesTaxChargedOnce() public {
        _permit2DoorExact(500);
    }

    function test_Permit2Door_Tax25pct_SettlesTaxChargedOnce() public {
        _permit2DoorExact(2_500);
    }

    /// @notice 1% tax through swapBestExactIn — first partial-rate FoT through
    ///         the Router:485-498 reprice with a nonzero receive.
    function test_BestDoor_Tax1pct_SettlesTaxChargedOnce() public {
        _bestDoorExact(100);
    }

    function test_BestDoor_Tax5pct_SettlesTaxChargedOnce() public {
        _bestDoorExact(500);
    }

    function test_BestDoor_Tax25pct_SettlesTaxChargedOnce() public {
        _bestDoorExact(2_500);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  4. Controls: untaxed token, same fixture, same doors. If these fail,
    //     the fixture is broken and every failure above is unattributable.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Untaxed control at the Permit2 door: received == N, only the
    ///         28 bps hop-0 fee and the pool curve stand between N and out.
    function test_Control_Permit2Door_NoTax_ExactDelivery() public {
        // fotIn.feeOnTransferBps defaults to 0 — same token, tax off.
        uint256 delivered = _swapPermit2(address(fotIn), pairFot, 0);
        assertEq(delivered, _expectedDelivered(0, true),
            "control: untaxed Permit2 delivery must be exact");
        assertEq(tokenOut.balanceOf(user), delivered, "control: recipient credited");
    }

    /// @notice Untaxed control at the best door.
    function test_Control_BestDoor_NoTax_ExactDelivery() public {
        uint256 delivered = _swapBest(address(fotIn));
        assertEq(delivered, _expectedDelivered(0, true),
            "control: untaxed best-door delivery must be exact");
        assertEq(tokenOut.balanceOf(user), delivered, "control: recipient credited");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  3. The discriminators: a floor priced on the NOMINAL amountIn would
    //     refuse; the measured reprice must settle. The asymmetric token
    //     (transferFrom taxed, transfer exempt) makes the door's own pull-side
    //     block the ONLY writer of TSLOT_FOT: the leg push arrives whole
    //     (Router:1612 `balAfter - balBefore != amt` is false), so deleting
    //     the block under test reverts these in RouterE(5) at Router:1307 —
    //     no other note can mask it.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Permit2 door, 25% pull tax, route carrying the Solver-style
    ///         floor priced on the NOMINAL amountIn (Solver:1450-1456:
    ///         floorOut = mulDiv(expectedOut, ironFloorBps(impact, 1, 0), BPS),
    ///         impact per Solver:1396-1400 impactV2Bps(amountIn, reserveIn)).
    ///         amountOut ~ 74.5% of the gross quote; the un-repriced floor sits
    ///         at ~95.9% of it. Without the Router:395-408 note, fotSeen == 0,
    ///         route.singleOutFloor applies (Router:1297-1298) and the honest
    ///         swap dies in RouterE(5). With it, fotSeen == 7500, the nominal
    ///         floor is dropped and protocolFloorOut is re-priced
    ///         (Router:1300-1304) — the swap MUST settle.
    function test_Permit2Door_AsymTax25_NominalFloorWouldRefuse_MeasuredRepriceSettles() public {
        asymIn.setTaxBps(2_500);
        uint256 gross = BPC.outV2(N, RESERVE, RESERVE, 30);
        uint256 floorOut = BPC.mulDiv(
            gross, BPC.ironFloorBps(BPC.impactV2Bps(N, RESERVE), 1, 0), BPC.BPS
        );

        uint256 delivered = _swapPermit2(address(asymIn), pairAsym, floorOut);

        assertGt(delivered, 0, "asym-taxed token must settle at the Permit2 door");
        // Exactly ONE tax event in the whole path (the pull): poolIn == spend.
        assertEq(delivered, _expectedDelivered(2_500, false),
            "Permit2 door: tax charged once, at the measured pull, and only once");
        // The counterfactual, concrete: the nominal-priced floor exceeds what
        // actually arrived, so a floor NOT re-priced off the measured pull
        // would have refused this settlement (amountOut < effMin, Router:1307).
        assertGt(floorOut, delivered,
            "sanity: the nominal floor really is above the honest FoT delivery");
    }

    /// @notice Best door, 25% pull tax. No hand-built route here: the Solver
    ///         itself publishes singleOutFloor priced on the nominal amountIn
    ///         (Solver:1450-1456) — this IS the scenario the Router:485-498
    ///         comment describes. The plan is fetched first (view, same state
    ///         the in-tx solve will read) to pin the floor the Router will see.
    function test_BestDoor_AsymTax25_SolverFloorOnNominal_MeasuredRepriceSettles() public {
        asymIn.setTaxBps(2_500);
        RoutePlan memory plan =
            solver.findBestRoutePlan(address(asymIn), address(tokenOut), N); // Solver:258
        assertGt(plan.best.singleOutFloor, 0, "sanity: Solver published a nominal-priced floor");

        uint256 delivered = _swapBest(address(asymIn));

        assertGt(delivered, 0, "asym-taxed token must settle at the best door");
        assertEq(delivered, _expectedDelivered(2_500, false),
            "best door: tax charged once, at the measured pull, and only once");
        // Counterfactual: the Solver's own floor (nominal-priced) is above the
        // honest delivery — without the pull-side reprice this swap was dead.
        assertGt(plan.best.singleOutFloor, delivered,
            "sanity: the Solver floor really is above the honest FoT delivery");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  5. Door parity: classic vs Permit2 vs best, same tax, same state
    //     (snapshot/revert), delivered must agree to the EXACT wei — every
    //     fee in the path (pull tax, 28 bps hop-0, leg-push tax) is identical
    //     across the three. A divergence here IS the duplicated-block defect
    //     this file hunts; the failing assert names the diverging door.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Tax-all token at 0%, 1%, 5%, 25% — the 0% row doubles as a
    ///         cross-door fixture control.
    function test_ThreeDoors_TaxGrid_DeliveredExactlyEqual() public {
        uint16[4] memory rates = [uint16(0), 100, 500, 2_500];
        for (uint256 i; i < rates.length; ++i) {
            fotIn.setFeeOnTransferBps(rates[i]);

            uint256 s1 = vm.snapshotState();
            uint256 dClassic = _swapClassic(address(fotIn), pairFot);
            vm.revertToState(s1);

            uint256 s2 = vm.snapshotState();
            uint256 dPermit2 = _swapPermit2(address(fotIn), pairFot, 0);
            vm.revertToState(s2);

            uint256 s3 = vm.snapshotState();
            uint256 dBest = _swapBest(address(fotIn));
            vm.revertToState(s3);

            assertGt(dClassic, 0, "classic door must settle (fixture baseline)");
            assertEq(dPermit2, dClassic,
                "PERMIT2 door diverges from the classic door at the same tax");
            assertEq(dBest, dClassic,
                "BEST door diverges from the classic door at the same tax");
            assertEq(dClassic, _expectedDelivered(rates[i], true),
                "all three doors: delivered matches the measured-pull derivation");
        }
    }

    /// @notice Asymmetric token at 25% — the same parity, on the subclass
    ///         where only the pull-side blocks write TSLOT_FOT. The classic
    ///         door's copy of the note (Router:540) is the reference; each
    ///         pre-pulled door's copy must reproduce it exactly.
    function test_ThreeDoors_AsymTax25_DeliveredExactlyEqual() public {
        asymIn.setTaxBps(2_500);

        uint256 s1 = vm.snapshotState();
        uint256 dClassic = _swapClassic(address(asymIn), pairAsym);
        vm.revertToState(s1);

        uint256 s2 = vm.snapshotState();
        uint256 dPermit2 = _swapPermit2(address(asymIn), pairAsym, 0);
        vm.revertToState(s2);

        uint256 s3 = vm.snapshotState();
        uint256 dBest = _swapBest(address(asymIn));
        vm.revertToState(s3);

        assertGt(dClassic, 0, "classic door must settle the asym token");
        assertEq(dPermit2, dClassic,
            "PERMIT2 door diverges from classic on the asym-FoT subclass");
        assertEq(dBest, dClassic,
            "BEST door diverges from classic on the asym-FoT subclass");
        assertEq(dClassic, _expectedDelivered(2_500, false),
            "all three doors: asym delivery matches the single-tax derivation");
    }
}
