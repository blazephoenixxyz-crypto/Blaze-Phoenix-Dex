// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "src/BlazePhoenixSolver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

/// @notice A one-spacing position stacked on an honest singleton book does not buy that book
///         the band: the book votes with the share of its virtual output side it holds
///         (`v4HeldShare`), so a position with 100x the honest liquidity and almost nothing
///         held moves the vote by what it holds, not by what it declares. Measurement, not a
///         fix: green at 66b499b; the held-share guard's mutant (`124-L3 B13-M1`) turns the
///         band test red.
/// @dev    The book shape this file adds to V4MedianMassIsHeld (a separate narrow pool) is the
///         SAME pool: honest full-range liquidity plus the attacker's range around the price.
///         Oracles, independent of the Solver: the band is read from the plan's own legs; what
///         a leg pays is the mock's `specSwap`, the walk its `swap` settles.
///         Ledger lines (`ledger\t...`) feed docs/assurance/v4-narrow.tsv: the narrow book's
///         allocation share and held share, in ppm, with and without the position. The owner
///         decides any number on allocation scaling from those two figures.
contract V4NarrowPositionDoesNotBuyTheBandTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    address t0;
    address t1;

    uint24 constant FEE_W = 3000;
    int24 constant TS_W = 60;
    uint24 constant FEE_B = 500;
    int24 constant TS_B = 10;
    uint128 constant L_W = 1e24;
    uint128 constant L_H = 5e23; // the honest book: half the wide one
    uint256 constant AMT = 1e21;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        MockERC20(t0).mint(address(mgr), 1e30);
        MockERC20(t1).mint(address(mgr), 1e30);
    }

    function _wide() internal returns (address) {
        bytes32 pid = BPC.computeV4PoolId(t0, t1, FEE_W, TS_W, address(0));
        mgr.initialize(pid, mgr.sqrtAt(0), 0, FEE_W);
        mgr.addPosition(pid, -887220, 887220, TS_W, L_W);
        hub.seedPool(address(uint160(uint256(pid))), BPC.KIND_V4, FEE_W, address(0), t0, t1);
        return address(uint160(uint256(pid)));
    }

    /// The honest book at `tick`, full range, L_H.
    function _honest(int24 tick) internal returns (address) {
        bytes32 pid = BPC.computeV4PoolId(t0, t1, FEE_B, TS_B, address(0));
        mgr.initialize(pid, mgr.sqrtAt(tick), tick, FEE_B);
        mgr.addPosition(pid, -887270, 887270, TS_B, L_H);
        hub.seedPool(address(uint160(uint256(pid))), BPC.KIND_V4, FEE_B, address(0), t0, t1);
        return address(uint160(uint256(pid)));
    }

    /// The attacker: one spacing around the price, 100x the honest liquidity.
    function _stack(int24 lower) internal {
        bytes32 pid = BPC.computeV4PoolId(t0, t1, FEE_B, TS_B, address(0));
        mgr.addPosition(pid, lower, lower + TS_B, TS_B, 100 * L_H);
    }

    function _pid() internal view returns (bytes32) {
        return BPC.computeV4PoolId(t0, t1, FEE_B, TS_B, address(0));
    }

    function _plan() internal view returns (RoutePlan memory plan) {
        plan = solver.findBestRoutePlan(t0, t1, AMT);
        assertGt(plan.best.hops.length, 0, "a route must exist");
    }

    function _split(RoutePlan memory plan, address wide, address book)
        internal view returns (uint256 wIn, uint256 bIn)
    {
        for (uint256 h; h < plan.best.hops.length; h++) {
            for (uint256 l; l < plan.best.hops[h].legs.length; l++) {
                Leg memory lg = plan.best.hops[h].legs[l];
                if (lg.pool == wide) wIn += lg.amountIn;
                if (lg.pool == book) bIn += lg.amountIn;
            }
        }
    }

    /// (iii) every leg on the stacked book pays at least what it promised, by the mock's swap.
    function _legsPay(RoutePlan memory plan, address book) internal view {
        for (uint256 h; h < plan.best.hops.length; h++) {
            for (uint256 l; l < plan.best.hops[h].legs.length; l++) {
                Leg memory lg = plan.best.hops[h].legs[l];
                if (lg.pool != book || lg.amountIn == 0) continue;
                (, uint256 paid, , , ) = mgr.specSwap(_pid(), lg.amountIn, FEE_B, TS_B, lg.zeroForOne);
                assertLe(lg.expectedOut, paid, "the leg promises no more than the book pays");
            }
        }
    }

    function _ledger(string memory cell, RoutePlan memory plan, address wide, address book) internal view {
        (uint256 wIn, uint256 bIn) = _split(plan, wide, book);
        (uint160 sp, ) = mgr.slot0(_pid());
        uint128 liq = mgr.liquidity(_pid());
        uint256 d = BPC.depthFromL18(liq, sp, 18, 18);
        uint256 held = BPC.v4HeldShare(address(mgr), _pid(), TS_B, true, d, type(uint256).max);
        console2.log(string.concat(
            "ledger\t", cell, "\t", vm.toString(uint256(liq)), "\t", vm.toString(d), "\t", vm.toString(held), "\t",
            vm.toString(BPC.mulDiv(held, 1e6, d)), "\t", vm.toString(BPC.mulDiv(bIn, 1e6, AMT)), "\t",
            vm.toString(wIn), "\t", vm.toString(bIn), "\t", vm.toString(plan.best.totalOut)
        ));
    }

    /// (i) Out of band: the honest book sits ~6% above the wide one and holds less of its
    /// mass. Stacking the narrow position on it declares 50x the wide book's depth; the set
    /// the band keeps is unchanged.
    function test_aStackedNarrowPositionDoesNotBuyTheBand() public {
        address wide = _wide();
        address book = _honest(584);
        console2.log("ledger\tcell\tliq\tdepth\theld_share\theld_share_narrow_ppm\tpsi_share_narrow_ppm\twide_in\tbook_in\ttotal_out");
        RoutePlan memory p0 = _plan();
        (uint256 w0, uint256 b0) = _split(p0, wide, book);
        assertEq(w0, AMT, "control: the wide book sets the base and takes the whole order");
        assertEq(b0, 0, "control: the honest book is outside the band");
        _ledger("out_without", p0, wide, book);

        _stack(580);
        (uint160 sp, ) = mgr.slot0(_pid());
        assertGt(
            BPC.depthFromL18(mgr.liquidity(_pid()), sp, 18, 18),
            10 * BPC.depthFromL18(L_W, mgr.sqrtAt(0), 18, 18),
            "fixture: the stacked book declares > 10x the wide depth"
        );
        RoutePlan memory p1 = _plan();
        (uint256 w1, uint256 b1) = _split(p1, wide, book);
        assertEq(w1, AMT, "the stacked position does not move the base");
        assertEq(b1, 0, "the stacked book stays outside the band");
        _ledger("out_with", p1, wide, book);
    }

    /// (iii)+(iv) In band: the honest book at the wide book's price. The stacked position is
    /// real liquidity at the price, so the user is paid at least as much as without it, and
    /// every leg on the book pays what it promised.
    function test_aStackedNarrowPositionInBandPaysWhatItPromises() public {
        address wide = _wide();
        address book = _honest(4);
        console2.log("ledger\tcell\tliq\tdepth\theld_share\theld_share_narrow_ppm\tpsi_share_narrow_ppm\twide_in\tbook_in\ttotal_out");
        RoutePlan memory p0 = _plan();
        _legsPay(p0, book);
        _ledger("in_without", p0, wide, book);

        _stack(0);
        RoutePlan memory p1 = _plan();
        _legsPay(p1, book);
        assertGe(p1.best.totalOut, p0.best.totalOut, "real liquidity at the price never pays the user less");
        _ledger("in_with", p1, wide, book);
    }
}
