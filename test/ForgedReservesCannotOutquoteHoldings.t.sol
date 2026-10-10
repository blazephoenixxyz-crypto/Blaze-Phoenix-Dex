// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Red at 56d0736: a pair that proves its tokens but forges its reserves was quoted on
// those reserves, and the preview promised more than the venue holds. The quote of a
// reserve-shaped leg is now bounded by the venue's own tokenOut balance.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "src/BlazePhoenixQuoter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// A hostile venue: honest token0/token1, honest reserves until it has a seat on the pair
/// (the swap door registers no pair reporting more than it holds), then forged reserves at
/// the honest price ratio. Pays only what it physically holds.
contract FakePair {
    address public immutable token0;
    address public immutable token1;
    uint112 public constant FAKE_R0 = uint112(1e24);
    uint112 public constant FAKE_R1 = uint112(1e24);
    bool public payNothing;
    bool public forged;

    constructor(address a, address b) {
        token0 = a < b ? a : b;
        token1 = a < b ? b : a;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        if (forged) return (FAKE_R0, FAKE_R1, uint32(0));
        return (uint112(IERC20(token0).balanceOf(address(this))), uint112(IERC20(token1).balanceOf(address(this))), 0);
    }

    function forge() external { forged = true; }

    function setPayNothing(bool b) external { payNothing = b; }

    function swap(uint256 a0, uint256 a1, address to, bytes calldata) external {
        uint256 ask = a0 > 0 ? a0 : a1;
        address tokOut = a0 > 0 ? token0 : token1;
        if (payNothing) return; // deliver 0 -> the Router's floor reverts
        uint256 have = IERC20(tokOut).balanceOf(address(this));
        require(ask <= have, "FakePair: empty book");
        IERC20(tokOut).transfer(to, ask);
    }
}

contract ForgedReservesCannotOutquoteHoldings is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 ta;
    MockERC20 tb;
    MockV2Pair honest;
    FakePair fake;
    address t0;
    address t1;
    address attacker = address(0xA77);
    address victim = address(0xBEE);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        ta = new MockERC20("A", "A");
        tb = new MockERC20("B", "B");
        (t0, t1) = address(ta) < address(tb) ? (address(ta), address(tb)) : (address(tb), address(ta));

        honest = new MockV2Pair(t0, t1);
        MockERC20(t0).mint(address(honest), 1e21);
        MockERC20(t1).mint(address(honest), 1e21);
        honest.setReserves(uint112(1e21), uint112(1e21));

        fake = new FakePair(t0, t1);
        MockERC20(t1).mint(address(fake), 1e12); // dust inventory

        MockERC20(t0).mint(attacker, 1e9);
        MockERC20(t0).mint(victim, 10e18);
        vm.startPrank(attacker);
        MockERC20(t0).approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(victim);
        MockERC20(t0).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _leg(address pool, uint256 amt) internal view returns (Leg[] memory legs) {
        legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: true, stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
    }

    function _route(address pool, uint256 amt) internal view returns (Route memory r) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: t0, tokenOut: t1, amountIn: amt, expectedOut: 0,
            legs: _leg(pool, amt)
        });
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function test_ForgedReservesVenue_IsNeverQuotedAboveItsHoldings() public {
        vm.prank(attacker);
        router.swapExactIn(_route(address(honest), 1e6), 1e6, 1, attacker, block.timestamp + 1);
        MockERC20(t0).mint(address(fake), 1e12); // an honest-looking book on both sides
        vm.prank(attacker);
        router.swapExactIn(_route(address(fake), 1e6), 1e6, 1, attacker, block.timestamp + 1);
        assertEq(hub.getActivePools(t0, t1).length, 2, "fixture: both venues reached the registry");
        fake.forge(); // seated while honest, forged from here on

        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(t0, t1, 1e18);
        assertTrue(pv.canExecute, "control: the honest venue still routes the order");
        for (uint256 h; h < pv.route.hops.length; h++) {
            for (uint256 l; l < pv.route.hops[h].legs.length; l++) {
                Leg memory lg = pv.route.hops[h].legs[l];
                assertTrue(lg.pool != address(fake), "a venue quoting above its holdings was routed");
                assertLe(lg.expectedOut, MockERC20(t1).balanceOf(lg.pool), "leg promise exceeds holdings");
            }
        }
        // Oracle independent of the code under test: x*y=k on the honest reserves at 30 bps.
        uint256 ain = 1e18 * 9970;
        uint256 honestOut = ain * 1e21 / (1e21 * 10000 + ain);
        assertLe(pv.netOut, honestOut, "the preview cannot beat the only real venue");
    }
}
