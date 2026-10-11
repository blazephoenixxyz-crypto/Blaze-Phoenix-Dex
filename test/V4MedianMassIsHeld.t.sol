// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Leg} from "src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "src/BlazePhoenixSolver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

/// @notice A singleton book votes in the depth-weighted median with the share of its depth
///         it holds, not with the virtual reserves of its current liquidity. Red at 2b5d79c
///         (both regime tests): an 8-tick range holding ~2e-4 of the mass it declared set the
///         band base and the wide book quoting the pair's price was filtered out of the route.
/// @dev    Oracle, independent of the Solver: the real reserves of a range (Uniswap v3
///         whitepaper, 6.2), y = L * (sqrtP - sqrtPa), against the virtual y = L * sqrtP,
///         read from the mock's own price table.
contract V4MedianMassIsHeldTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    address t0;
    address t1;

    uint24 constant FEE_W = 3000;
    int24  constant TS_W  = 60;
    uint24 constant FEE_N = 100;
    int24  constant TS_N  = 1;
    uint128 constant L_W = 1e24;
    int24 constant N_LO = 580;
    int24 constant N_AT = 584; // ~6% above the wide book: outside the 5% band of either rate
    int24 constant N_HI = 588;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub));
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        MockERC20(t0).mint(address(mgr), 1e30);
        MockERC20(t1).mint(address(mgr), 1e30);
    }

    function _wide() internal returns (address) {
        return _wideAt(0);
    }

    function _wideAt(int24 tick) internal returns (address) {
        bytes32 pid = BPC.computeV4PoolId(t0, t1, FEE_W, TS_W, address(0));
        mgr.initialize(pid, mgr.sqrtAt(tick), tick, FEE_W);
        mgr.addPosition(pid, -887220, 887220, TS_W, L_W);
        hub.seedPool(address(uint160(uint256(pid))), BPC.KIND_V4, FEE_W, address(0), t0, t1);
        return address(uint160(uint256(pid)));
    }

    function _narrow(uint128 liq) internal returns (address) {
        return _narrowAt(0, liq);
    }

    function _narrowAt(int24 base, uint128 liq) internal returns (address) {
        bytes32 pid = BPC.computeV4PoolId(t0, t1, FEE_N, TS_N, address(0));
        mgr.initialize(pid, mgr.sqrtAt(base + N_AT), base + N_AT, FEE_N);
        mgr.addPosition(pid, base + N_LO, base + N_HI, TS_N, liq);
        hub.seedPool(address(uint160(uint256(pid))), BPC.KIND_V4, FEE_N, address(0), t0, t1);
        return address(uint160(uint256(pid)));
    }

    /// token1 the narrow range holds below its price: L * (sqrtP - sqrtPa) / 2^96.
    function _heldBelow(uint128 liq) internal view returns (uint256) {
        return _heldBelowAt(0, liq);
    }

    function _heldBelowAt(int24 base, uint128 liq) internal view returns (uint256) {
        return BPC.mulDiv(liq, uint256(mgr.sqrtAt(base + N_AT)) - uint256(mgr.sqrtAt(base + N_LO)), 1 << 96);
    }

    function _split(address wide, address narrow) internal view returns (uint256 wIn, uint256 nIn) {
        return _splitFrom(t0, t1, wide, narrow);
    }

    function _splitFrom(address tIn, address tOut, address wide, address narrow)
        internal view returns (uint256 wIn, uint256 nIn)
    {
        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, 1e21);
        assertGt(plan.best.hops.length, 0, "a route must exist");
        for (uint256 h; h < plan.best.hops.length; h++) {
            for (uint256 l; l < plan.best.hops[h].legs.length; l++) {
                Leg memory lg = plan.best.hops[h].legs[l];
                if (lg.pool == wide) wIn += lg.amountIn;
                if (lg.pool == narrow) nIn += lg.amountIn;
            }
        }
    }

    function test_aNarrowRangeVotesWithTheOutputItHolds_notWithItsVirtualDepth() public {
        address wide = _wide();
        uint128 lN = 3 * L_W;
        address narrow = _narrow(lN);
        // The regime: the range declares more virtual depth than the wide book, but holds
        // far less than the wide book's mass on the output side.
        assertGt(BPC.depthFromL18(lN, mgr.sqrtAt(N_AT), 18, 18), BPC.depthFromL18(L_W, mgr.sqrtAt(0), 18, 18));
        assertLt(_heldBelow(lN) * 1000, L_W, "fixture: the range holds < 0.1% of the wide mass");
        (uint256 wIn, uint256 nIn) = _split(wide, narrow);
        assertEq(wIn, 1e21, "the wide book sets the base and takes the whole order");
        assertEq(nIn, 0, "the narrow range is outside the band");
    }

    function test_control_aNarrowRangeHoldingMoreThanTheWideMassStillSetsTheBase() public {
        address wide = _wide();
        uint128 lN = 2e28;
        address narrow = _narrow(lN);
        // Capital, not shape: once the range holds more output than the wide book's mass,
        // it carries the vote, exactly as a pair holding that much would.
        assertGt(_heldBelow(lN), 2 * uint256(L_W), "fixture: the range holds > 2x the wide mass");
        (uint256 wIn, uint256 nIn) = _split(wide, narrow);
        assertEq(wIn, 0, "the wide book is outside the band of the funded range");
        assertEq(nIn, 1e21, "the funded range takes the whole order");
    }

    /// Away from a price of one the two sides of a book are different numbers: at ~2,980
    /// token1 per token0 the range below holds ~56 token1 for every token0 of its virtual
    /// depth. Its vote must stay in the unit of the depth it scales - the share of the
    /// virtual output side it holds - or a range holding a fraction of the wide book's
    /// value outvotes it by the price.
    function test_aNarrowRangeVoteKeepsTheDepthUnit_awayFromAPriceOfOne() public {
        int24 base = 80_000;
        address wide = _wideAt(base);
        uint128 lN = 300 * L_W;
        address narrow = _narrowAt(base, lN);
        uint256 wideDepth = BPC.depthFromL18(L_W, mgr.sqrtAt(base), 18, 18);
        uint160 spN = mgr.sqrtAt(base + N_AT);
        uint256 held = _heldBelowAt(base, lN);
        // The regime: counted in token1 the range holds more than the wide book's depth
        // (a token0 number), while the share of its depth it holds is far below it.
        assertGt(held, wideDepth, "fixture: token1 held exceeds the wide depth as a number");
        uint256 share = BPC.mulDiv(BPC.depthFromL18(lN, spN, 18, 18), held, BPC.mulDiv(lN, spN, 1 << 96));
        assertLt(share * 10, wideDepth, "fixture: the depth the range holds is < 10% of the wide one");
        (uint256 wIn, uint256 nIn) = _split(wide, narrow);
        assertEq(wIn, 1e21, "the wide book sets the base and takes the whole order");
        assertEq(nIn, 0, "the narrow range is outside the band");
    }

    /// The mirror, token1 in: the range above its price holds token0,
    /// L * (1/sqrtP - 1/sqrtPb), against the virtual L / sqrtP. At ~1/2,980 token1 per token0
    /// the token0 it holds is again a far larger number than the depth it scales.
    function test_aNarrowRangeVoteKeepsTheDepthUnit_tokenOneIn() public {
        int24 base = -80_000;
        address wide = _wideAt(base);
        uint128 lN = 300 * L_W;
        // Range [base - 588, base - 580] priced at base - 584: ~6% cheaper token0 than the wide book.
        address narrow = _narrowAt(base - 1168, lN);
        uint256 wideDepth = BPC.depthFromL18(L_W, mgr.sqrtAt(base), 18, 18);
        uint256 s = mgr.sqrtAt(base - 584);
        uint256 sb = mgr.sqrtAt(base - 580);
        uint256 held = BPC.mulDiv(BPC.mulDiv(lN, 1 << 96, s), sb - s, sb);
        assertGt(held, wideDepth, "fixture: token0 held exceeds the wide depth as a number");
        uint256 share = BPC.mulDiv(BPC.depthFromL18(lN, uint160(s), 18, 18), held, BPC.mulDiv(lN, 1 << 96, s));
        assertLt(share * 10, wideDepth, "fixture: the depth the range holds is < 10% of the wide one");
        (uint256 wIn, uint256 nIn) = _splitFrom(t1, t0, wide, narrow);
        assertEq(wIn, 1e21, "the wide book sets the base and takes the whole order");
        assertEq(nIn, 0, "the narrow range is outside the band");
    }
}
