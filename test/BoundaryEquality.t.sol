// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// EXACT BOUNDARIES -- the two `<` comparisons no existing test told apart from `<=`.
//
// A `<` -> `<=` flip diverges from the original on EXACTLY one input: the
// boundary value. The existing hop-budget tests live at ~82%/85% of the bound
// and the minOut boundary test controls `delivered`, not `amountOut` -- none of
// them lands on equality. These two land on it, to the wei, and therefore:
//   - against the original code, both PASS (equality is not "less than");
//   - against the `<=` mutant, the matching test REVERTS RouterE(5) and goes red.
//
// An off-by-one only shows on the one input nobody thinks to type.
//
// The exactness key is the SAME in both: amountIn = sum(leg.amountIn) + fee,
// with the protocol fee prepaid ON TOP, so that after _chargeHopFee exactly
// sum(leg.amountIn) remains -> scaleNum == scaleDen -> every scaling mulDiv is
// an identity and the calldata expectedOut reaches hopBound UNCHANGED
// (case 1), while the measured outV2 reaches amountOut unchanged (case 2).
//
// Case 1 (hopGot + slack < hopBound): with 2 legs, slack = floor(floor(S/2)/5)
// = floor(S/10). The boundary 2G + floor(S/10) == S is solvable for ANY 2G:
// S = 10*floor(2G/9) + (2G mod 9), because S |-> S - floor(S/10) = 9q + t
// sweeps every integer (t in 0..8 covers 2G mod 9). The mutant is NOT
// equivalent -- it is stubborn, and this is the input the suite lacked.
//
// Case 2 (amountOut < effMin): effMin is fed by route.singleOutFloor (free
// calldata, no rounding anywhere on that path when there is no FoT).
// singleOutFloor = G = amountOut lands on equality; userMinOut stays at 1 so
// the delivered/userMinOut comparison keeps STRICT headroom -- this test kills
// only the effMin flip, not the delivered one (which already has a watcher).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixMath, IHubMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract BoundaryEqualityTest is Test {
    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router;
    MockERC20 tokenA; MockERC20 tokenB;
    MockV2Pair pool1; MockV2Pair pool2;
    address user = address(0xBEEF);
    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    uint256 constant A = 100e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A"); tokenB = new MockERC20("B", "B");
        pool1 = new MockV2Pair(address(tokenA), address(tokenB));
        pool2 = new MockV2Pair(address(tokenA), address(tokenB));
        _seed(pool1, 100_000e18, 100_000e18);
        _seed(pool2, 100_000e18, 100_000e18);

        hub.seedPool(address(pool1), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        hub.seedPool(address(pool2), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user); tokenA.approve(address(router), type(uint256).max);
    }

    function _seed(MockV2Pair p, uint256 a, uint256 b) internal {
        if (p.token0() == address(tokenA)) p.setReserves(uint112(a), uint112(b));
        else p.setReserves(uint112(b), uint112(a));
        tokenA.mint(address(p), a); tokenB.mint(address(p), b);
    }

    /// What execution will both measure AND request from the pool: the same
    /// outV2, from the same reserves, with the same effective fee -- so
    /// got == legQuote == this number, exactly.
    function _trueOut(MockV2Pair p) internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = p.getReserves();
        bool zfo = p.token0() == address(tokenA);
        return BPC.outV2(A, zfo ? r0 : r1, zfo ? r1 : r0, 30);
    }

    function _leg(MockV2Pair p, uint256 expectedOut) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2,
            fee: 30, tickSpacing: 0, zeroForOne: p.token0() == address(tokenA),
            stable: false, amountIn: A, expectedOut: expectedOut, auxId: bytes32(0)
        });
    }

    function _route(Leg[] memory legs, uint256 totalIn) internal view returns (Route memory r) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
                       amountIn: totalIn, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// The amountIn that leaves exactly sum(leg.amountIn) after the hop-0 fee
    /// (no-bridge route -> fee charged at the entry, baseH = sum(leg.amountIn)).
    function _inWithFee(uint256 sumLegs) internal pure returns (uint256) {
        return sumLegs + BPC.mulDivUp(sumLegs, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// CASE 1 -- the per-hop budget boundary, to the wei.
    /// Two honest legs (each delivers G), attestations inflated until
    /// hopGot + slack == hopBound EXACTLY. Each leg passes its own 80%
    /// floor (e_i ~ 1.11*G < 1.25*G) -- only the aggregate equality is at stake.
    function test_HopBudget_ExactBoundaryDelivers() public {
        uint256 G = _trueOut(pool1);            // == _trueOut(pool2), equal seeds
        uint256 q = (2 * G) / 9;
        uint256 S = 10 * q + (2 * G - 9 * q);   // S - floor(S/10) == 2G, always solvable

        // Self-check: the Router's OWN expression must land on equality.
        uint256 slack = BPC.mulDiv(S / 2, BPC.BPS - BPC.LEG_FLOOR_BPS, BPC.BPS);
        assertEq(2 * G + slack, S, "constructed off the boundary");

        uint256 e1 = S / 2; uint256 e2 = S - e1;
        // The per-leg floor must not fire: ceil(0.8 * e_i) <= G.
        assertLe(BPC.mulDivUp(e2 > e1 ? e2 : e1, BPC.LEG_FLOOR_BPS, BPC.BPS), G,
                 "per-leg floor would fire before the boundary");

        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(pool1, e1);
        legs[1] = _leg(pool2, e2);
        uint256 amountIn = _inWithFee(2 * A);
        vm.prank(user);
        uint256 got = router.swapExactIn(_route(legs, amountIn), amountIn, 1, user, block.timestamp + 1);
        assertEq(got, 2 * G, "at the exact boundary the hop MUST deliver");
    }

    /// CASE 2 -- the aggregate output floor boundary (amountOut == effMin), to
    /// the wei. effMin is driven by singleOutFloor = G (a calldata identity,
    /// zero rounding); userMinOut = 1 keeps the delivered comparison slack,
    /// and protocolFloorOut (<= ceil(0.96*G)) stays strictly below.
    function test_AggregateFloor_ExactBoundaryDelivers() public {
        uint256 G = _trueOut(pool1);
        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(pool1, G);               // honest attestation
        uint256 amountIn = _inWithFee(A);
        Route memory r = _route(legs, amountIn);
        r.singleOutFloor = G;                   // effMin lands EXACTLY on amountOut
        vm.prank(user);
        uint256 got = router.swapExactIn(r, amountIn, 1, user, block.timestamp + 1);
        assertEq(got, G, "at the exact floor the swap MUST deliver");
    }
}

// THE BAND's vote at a fee of exactly 1e6 pips (BlazePhoenixMath._mutedVotes, `>= PIPS`).
//
// A Solidly pair whose factory() answers a word that is not an address reads a fee of BPS
// (`BPC.readDynamicFee`), and its probe states BPS * 100 = 1e6 pips (`BPC._solidlyAsk`): that
// venue's "fee nobody knows" lands ON the boundary, where a Gate's (0xFFFFFF) lands past it. A
// fee of 1e6 is unknown, so while a stated row votes, that row's mass does not choose the base.
// Read at the library (`BlazePhoenixMath.select`) on rows built by hand, every row vouched
// (`active`: no Hub read); the band's own edges are test/MedianBandMath.t.sol.
//
// RED at 1c33f29 with mutant "Math:492" applied (`>= PIPS` -> `> PIPS`: the 1e6 row
// votes, takes the base, and a base whose fee is the whole keeps every live row); GREEN at HEAD.
contract BoundaryEqualityBandVoteTest is Test {
    uint256 constant PIPS = 1_000_000;

    /// The rows `select` keeps (bit i = row i): two pairs at 0.997 behind 0.3 %, one at half
    /// that price, and a Solidly row of fee `fee3` paying 0.95e-6 per unit with most of the mass.
    function _keptBeside(uint256 fee3) internal view returns (uint256 set) {
        uint256[4] memory rate = [uint256(997e15), 997e15, 4985e14, 95e10];
        uint256[4] memory fee = [uint256(3000), 3000, 3000, fee3];
        uint256[4] memory mass = [uint256(1e18), 1e18, 1e17, 3e18];
        uint256[] memory rates = new uint256[](4);
        uint256[] memory depths = new uint256[](4);
        uint256[] memory bals = new uint256[](4);
        uint256[] memory fe = new uint256[](4);
        PoolInfo[] memory c = new PoolInfo[](4);
        for (uint256 i; i < 4; ++i) {
            rates[i] = rate[i];
            depths[i] = mass[i];
            bals[i] = mass[i];
            fe[i] = fee[i];   // error bounds 0
            c[i] = PoolInfo({
                active: true, stable: false, kind: i == 3 ? BPC.KIND_SOLIDLY : BPC.KIND_V2,
                fee: 0, tickSpacing: 0, token0: address(0xA), token1: address(0xB),
                pool: address(uint160(0x1000 + i)), hooks: address(0)
            });
        }
        (uint256 nBand, , , uint256[] memory map, ) =
            BlazePhoenixMath.select(rates, depths, bals, fe, c, address(0xA), IHubMath(address(0)), 8);
        for (uint256 j; j < nBand; ++j) set |= 1 << map[j];
    }

    function test_AFeeOfExactlyOneMillionPipsDoesNotVote() public view {
        // one pip under the whole: stated, so it votes; its price is 0.95e-6 / 1e-6 = 0.95, it
        // holds 3 of the 5.1 units of mass and takes the base, and a base nearly all fee keeps
        // every live row, the one at 0.5 too
        assertEq(_keptBeside(PIPS - 1), 1 | 2 | 4 | 8, "a fee one pip under the whole is stated and votes");
        // exactly the whole: unknown, it does not vote; the base is a pair at 0.997 behind 0.3 %,
        // the row at 0.5 falls out, and the 1e6 row is judged from above only and stays
        assertEq(_keptBeside(PIPS), 1 | 2 | 8, "a fee of exactly 1e6 pips voted as if it were stated");
        // past the whole, a Gate's mark: unknown as well
        assertEq(_keptBeside(0xFFFFFF), 1 | 2 | 8, "a fee past the whole voted");
    }
}
