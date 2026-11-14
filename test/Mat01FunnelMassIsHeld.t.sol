// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// MAT-01 (audit 2026-11-06): the funnel's dust rule adds one token.
//
// WHAT WAS WRONG. `Solver._dropDust` weighed every row of a pair by the registry's depth
// (`Core.registryDepth18Dec`) and dropped row j when
//     d_j * 1e6 < MIN_SPLIT_IMPROVEMENT_PPM * (D - d_j),   D = sum over the rows.
// The registry's depth has no direction, and for a singleton book it is the virtual depth with
// no cap by what the book holds. A one-tick V4 position at an absurd price projected a depth
// ~2e4 times the capital it held, took D, and dropped every honest row of its pair before it
// was quoted.
//
// THE FIXTURE. WETH (18) = token0, USDC (6) = token1. Honest V2 pair: 1,000 WETH + 3,000,000
// USDC. A hookless V4 pool (fee 101, tickSpacing 1) priced ~1 USDC per WETH (tick -276324) with
// a one-tick position holding ~2,499.94 USDC and ~0 WETH, liquidity L = 5e19, claimed through
// `Hub.claimV4` (no privilege: one bridge side, a hookless live pool, a quotable fee).
//
// WHAT IS MEASURED NOW. A row's mass is the tokenOut it can pay (`Core.hopMass18`), and what a
// singleton book adds to the other rows' D is capped by the tokenOut its walk holds
// (`Solver._heldBooks`). The honest row is quoted and routed, and 1 WETH previews at >= 99 % of
// the honest pair's own quote. Observed through `Solver.findBestRoutePlan`.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, RoutePlan, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

contract MAT01DustV4VirtualDepthTest is Test {
    MockV4TickManager mgr;
    BlazePhoenixHub   hub;
    BlazePhoenixSolver solver;

    PathologicalERC20 weth; // token0, 18 decimals
    PathologicalERC20 usdc; // token1,  6 decimals
    MockV2Pair honest;

    address constant ATK = address(0xA77AC);

    // Attacker V4 pool (hookless). Static fee 101, tickSpacing 1.
    uint24 constant FEE = 101;
    int24  constant TS  = 1;
    int24  constant TLO = -276324;                            // raw price ~1e-12 == ~1 USDC/WETH
    uint160 constant SP  = 79232228561461197483621;           // sqrtAt(TLO+1) - 1 (price at tick top)
    uint128 constant L   = 50000000000000000000;              // 5e19
    uint256 constant HELD_USDC = 2499940807;                  // ~2499.94 USDC (the position's capital)
    uint256 constant HELD_WETH = 632;                         // ~0 WETH

    uint256 constant GAMMA_PPM = 25;                          // Solver.MIN_SPLIT_IMPROVEMENT_PPM

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));          // this = admin + operator; mgr = v4 manager
        solver = new BlazePhoenixSolver(address(hub), address(0));

        // token0 must be the 18-dec WETH side, so raw price = USDC(6)/WETH(18); loop until sorted.
        weth = new PathologicalERC20("WETH", "WETH", 18);
        usdc = new PathologicalERC20("USDC", "USDC", 6);
        while (address(usdc) < address(weth)) usdc = new PathologicalERC20("USDC", "USDC", 6);
        assertTrue(address(weth) < address(usdc), "fixture: WETH is token0");

        // Honest curated V2 venue: 1000 WETH + 3,000,000 USDC, reserves == balances.
        honest = new MockV2Pair(address(weth), address(usdc));
        weth.mint(address(honest), 1000e18);
        usdc.mint(address(honest), 3_000_000e6);
        honest.setReserves(uint112(1000e18), uint112(3_000_000e6));
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), address(weth), address(usdc));
    }

    function _pid() internal view returns (bytes32) {
        return BPC.computeV4PoolId(address(weth), address(usdc), FEE, TS, address(0));
    }

    function _atkPool() internal view returns (address) {
        return address(uint160(uint256(_pid())));
    }

    /// Build the attacker's one-tick V4 pool and register it through the permissionless door.
    function _mountAttackerV4() internal {
        bytes32 pid = _pid();
        mgr.initialize(pid, SP, TLO, FEE);          // slot0: price at the tick's top, current tick = TLO
        mgr.addPosition(pid, TLO, TLO + 1, TS, L);  // one-tick position, active (TLO in [TLO, TLO+1))
        // The tokens the singleton actually holds for this position: ~2500 USDC, ~0 WETH.
        usdc.mint(address(mgr), HELD_USDC);
        weth.mint(address(mgr), HELD_WETH);

        hub.addBridge(address(usdc));               // honest config: USDC is a routable bridge
        vm.prank(ATK);                              // no privilege: anyone may claim
        hub.claimV4(address(weth), address(usdc), FEE, TS);
    }

    function _routes(Route memory r, address pool) internal pure returns (bool) {
        for (uint256 x; x < r.hops.length; ++x)
            for (uint256 y; y < r.hops[x].legs.length; ++y)
                if (r.hops[x].legs[y].pool == pool) return true;
        return false;
    }

    // ---- a one-tick singleton book at an absurd price ----------------------------------------

    function test_MAT01_AOneTickSingletonBookDoesNotDropTheHonestVenue() public {
        // Control: with only the honest pool, 1 WETH is routed through it and pays ~2988 USDC.
        RoutePlan memory base = solver.findBestRoutePlan(address(weth), address(usdc), 1e18);
        uint256 honestAlone = base.best.totalOut;
        assertTrue(_routes(base.best, address(honest)), "control: honest venue is routed on its own");
        assertGt(honestAlone, 2900e6, "control: honest pays ~2988 USDC for 1 WETH");

        // The attacker mounts a one-tick V4 dust pool and claims it (permissionless).
        _mountAttackerV4();

        // MECHANISM: the registry reads the attacker's VIRTUAL depth, ~2e4x the capital it holds,
        // and ~5e4x the honest pool's depth - enough to cross the 25-ppm dust gate against honest.
        uint256 atkDepth    = BPC.registryDepth18(_atkPool(), BPC.KIND_V4, address(weth), address(usdc), address(mgr), _pid());
        uint256 honestDepth = BPC.registryDepth18(address(honest), BPC.KIND_V2, address(weth), address(usdc), address(0), bytes32(0));
        uint256 heldUsdc18  = usdc.balanceOf(address(mgr)) * 1e12;     // 6 -> 18 decimals
        assertEq(honestDepth, 1e21, "fixture: honest depth 1e21");
        assertGt(atkDepth, 1e4 * heldUsdc18, "fixture: registry depth >1e4x the mass the pool holds");
        assertLt(honestDepth * 1e6, GAMMA_PPM * atkDepth, "fixture: the honest row is below the dust gate vs the attacker");

        // The honest pool is quoted, and the preview the user signs minOut against keeps its price.
        RoutePlan memory plan = solver.findBestRoutePlan(address(weth), address(usdc), 1e18);
        assertTrue(_routes(plan.best, address(honest)),
            "honest venue dropped from the route by a one-tick V4 book's virtual depth");
        assertGe(plan.best.totalOut, honestAlone * 99 / 100,
            "1 WETH previews far below the honest venue's quote (the dust book took the route)");
    }
}
