// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The hostile-venue matrix — one pathology per venue, two doors, one rule.
//
//  Token pathologies (fee-on-transfer, rebasing, blocklists, pausing, odd
//  decimals) have long had their tests. Venue pathologies did not have a
//  matrix: a pair that takes the input and pays nothing, one that pays half,
//  reserves that come back as a returndata bomb, reads and swaps that burn
//  every unit of gas, a token whose decimals() never returns, a V3 pool that
//  fires its payment callback twice, one that re-enters the Router mid-swap,
//  one whose slot0() reverts, and a factory whose getPair() answers with a
//  pool on other tokens.
//
//  Every cell is judged by the same rule as the regime covering array: the
//  swap settles with the delivered amount equal to the recipient's balance
//  delta and nothing left on the Router, or it is refused with a selector of
//  ours. Two cells add a sharper oracle - a pool that pays nothing or half
//  must be REFUSED, and the re-entering pool records whether the Router ever
//  let its nested swap run. A swap that burns all forwarded gas is the one
//  case no caller can decide for the callee; that cell passes only if the
//  transaction reverted whole and the user's balance is untouched.
//
//  Outcomes print as `CELL <venue> <door> <outcome>` for matrix_summary.py.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {MockV2Factory} from "../mocks/MockV2Factory.sol";
import {Outcomes} from "./Outcomes.sol";
import {
    LyingV2Pair, HalfPayV2Pair, ReturnBombV2Pair, GasBombReadV2Pair, GasBombSwapV2Pair,
    GasBombDecimalsToken, DoubleCallbackV3Pool, ReentrantV3Pool, SlotRevertV3Pool
} from "./HostileVenues.sol";

interface IERC20X {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function mint(address, uint256) external;
}

contract HostileVenueMatrixTest is Test {
    enum Venue {
        LYING_V2, HALFPAY_V2, RETURNBOMB_V2, GASBOMB_READ_V2, GASBOMB_SWAP_V2,
        GASBOMB_DECIMALS, DOUBLE_CALLBACK_V3, REENTRANT_V3, SLOT_REVERT_V3, WRONG_PAIR_FACTORY
    }
    enum Door { EXACT_IN, BEST }

    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    address user = address(0xBEEF);

    uint256 constant DEPTH = 1_000_000e18;
    uint256 constant AMT   = 1_000e18;
    uint256 constant GAS   = 6_000_000;   // generous for an honest swap; a bomb burns it all

    address tIn; address tOut;
    address venue; uint8 kind; uint24 fee;
    address reentrant;   // the ReentrantV3Pool, when the cell has one

    function _name(Venue v) private pure returns (string memory) {
        string[10] memory n = ["LYING_V2", "HALFPAY_V2", "RETURNBOMB_V2", "GASBOMB_READ_V2", "GASBOMB_SWAP_V2",
                               "GASBOMB_DECIMALS", "DOUBLE_CALLBACK_V3", "REENTRANT_V3", "SLOT_REVERT_V3", "WRONG_PAIR_FACTORY"];
        return n[uint256(v)];
    }
    function _door(Door d) private pure returns (string memory) { return d == Door.EXACT_IN ? "EXACT_IN" : "BEST"; }

    function _stack() private {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tIn = address(new MockERC20("In", "IN"));
        tOut = address(new MockERC20("Out", "OUT"));
        reentrant = address(0);
    }

    function _fund(address pool) private {
        IERC20X(tIn).mint(pool, DEPTH);
        IERC20X(tOut).mint(pool, DEPTH);
    }

    /// Builds the cell's venue on (tIn, tOut). Returns false when the venue is admitted through a
    /// factory rather than seeded (the factory cell), so the door call goes to whatever discovery
    /// admitted.
    function _venue(Venue v) private returns (bool seeded) {
        if (v == Venue.GASBOMB_DECIMALS) {
            tIn = address(new GasBombDecimalsToken());
            MockV2Pair p = new MockV2Pair(tIn, tOut);
            p.setReserves(uint112(DEPTH), uint112(DEPTH));
            venue = address(p); kind = BPC.KIND_V2; fee = 30;
        } else if (v == Venue.WRONG_PAIR_FACTORY) {
            address c = address(new MockERC20("C", "C"));
            address d = address(new MockERC20("D", "D"));
            MockV2Pair impostor = new MockV2Pair(c, d);
            impostor.setReserves(uint112(DEPTH), uint112(DEPTH));
            IERC20X(c).mint(address(impostor), DEPTH); IERC20X(d).mint(address(impostor), DEPTH);
            MockV2Factory f = new MockV2Factory();
            f.setPair(tIn, tOut, address(impostor));
            hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
            venue = address(impostor); kind = BPC.KIND_V2; fee = 30;
            return false;
        } else if (v == Venue.LYING_V2 || v == Venue.HALFPAY_V2 || v == Venue.RETURNBOMB_V2 || v == Venue.GASBOMB_READ_V2 || v == Venue.GASBOMB_SWAP_V2) {
            if (v == Venue.LYING_V2)        venue = address(new LyingV2Pair(tIn, tOut));
            if (v == Venue.HALFPAY_V2)      venue = address(new HalfPayV2Pair(tIn, tOut));
            if (v == Venue.RETURNBOMB_V2)   venue = address(new ReturnBombV2Pair(tIn, tOut));
            if (v == Venue.GASBOMB_READ_V2) venue = address(new GasBombReadV2Pair(tIn, tOut));
            if (v == Venue.GASBOMB_SWAP_V2) venue = address(new GasBombSwapV2Pair(tIn, tOut));
            LyingV2Pair(venue).setReserves(uint112(DEPTH), uint112(DEPTH));   // same base ABI
            kind = BPC.KIND_V2; fee = 30;
        } else {
            if (v == Venue.DOUBLE_CALLBACK_V3) venue = address(new DoubleCallbackV3Pool(tIn, tOut, 3000));
            if (v == Venue.REENTRANT_V3)     { venue = address(new ReentrantV3Pool(tIn, tOut, 3000, address(router))); reentrant = venue; }
            if (v == Venue.SLOT_REVERT_V3)     venue = address(new SlotRevertV3Pool(tIn, tOut, 3000));
            SlotRevertV3Pool(venue).setState(uint160(BPC.Q96), uint128(DEPTH));   // same base ABI
            kind = BPC.KIND_V3; fee = 3000;
        }
        _fund(venue);
        return true;
    }

    function _handRoute() private view returns (Route memory route) {
        (address t0,) = tIn < tOut ? (tIn, tOut) : (tOut, tIn);
        bool zfo = tIn == t0;
        uint256 out = kind == BPC.KIND_V2
            ? BPC.outV2(AMT, DEPTH, DEPTH, 30)
            : BPC.outV3(AMT, uint160(BPC.Q96), uint128(DEPTH), 3000, zfo, 0);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: venue, hooks: address(0), kind: kind, fee: fee, tickSpacing: kind == BPC.KIND_V3 ? int24(60) : int24(0),
                       zeroForOne: zfo, stable: false, amountIn: AMT, expectedOut: out, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: AMT, expectedOut: out, legs: legs});
        route = Route({hops: hops, totalOut: out, singleOut: out, singleOutFloor: 0, expectedImpactBps: 0,
                       confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _cell(Venue v, Door d) private {
        _stack();
        bool seeded = _venue(v);
        string memory name = _name(v);
        string memory door = _door(d);
        if (seeded) {
            (address t0, address t1) = tIn < tOut ? (tIn, tOut) : (tOut, tIn);
            try hub.seedPool(venue, kind, fee, address(0), t0, t1) {} catch (bytes memory err) {
                (bool ours, string memory what) = Outcomes.classify(err);
                assertTrue(ours, string.concat("admission refused without a selector of ours: ", what));
                console2.log("CELL", name, door, string.concat("ADMISSION_REFUSED ", what));
                return;
            }
        } else {
            // the factory cell: whatever discovery lists, nothing may SETTLE through a pool on
            // other tokens - the guarantee is at the seam that pays, and the cell records
            // whether discovery listed the impostor so the two layers are told apart.
            // RED on main 0752733: discovery listed the impostor and the Solver planned it; the
            // executor refused it (LEG-01), so funds were never at risk, and the pair was refused
            // for as long as the impostor won the split. Discovery now proves an asked pool's
            // pair before listing it.
            PoolInfo[] memory hits = hub.discoverFor(tIn, tOut);
            for (uint256 i; i < hits.length; ++i) assertTrue(hits[i].pool != venue, "discovery listed a pool on other tokens");
        }
        IERC20X(tIn).mint(user, AMT * 4);
        vm.prank(user);
        IERC20X(tIn).approve(address(router), type(uint256).max);
        uint256 inBefore = IERC20X(tIn).balanceOf(user);
        uint256 outBefore = IERC20X(tOut).balanceOf(user);
        uint256 dl = block.timestamp + 1;

        bytes memory call = d == Door.EXACT_IN
            ? abi.encodeCall(router.swapExactIn, (_handRoute(), AMT, 1, user, dl))
            : abi.encodeCall(router.swapBestExactIn, (tIn, tOut, AMT, 1, user, dl));
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call{gas: GAS}(call);

        if (reentrant != address(0)) {
            assertFalse(ReentrantV3Pool(reentrant).reentered(), "the Router let a pool re-enter it mid-swap");
        }
        if (ok) {
            uint256 got = abi.decode(ret, (uint256));
            uint256 delta = IERC20X(tOut).balanceOf(user) - outBefore;
            assertEq(got, delta, "delivered must equal the recipient's balance delta");
            assertGt(got, 0, "a settled swap delivers something");
            assertEq(IERC20X(tIn).balanceOf(address(router)), 0, "the Router holds no input after a swap");
            assertEq(IERC20X(tOut).balanceOf(address(router)), 0, "the Router holds no output after a swap");
            assertLe(inBefore - IERC20X(tIn).balanceOf(user), AMT, "the user never pays more than the amount they sent");
            assertTrue(v != Venue.LYING_V2 && v != Venue.HALFPAY_V2, "a venue that under-pays must be refused, not settled");
            assertTrue(v != Venue.WRONG_PAIR_FACTORY, "a swap must never settle through a pool on other tokens");
            console2.log("CELL", name, door, string.concat("SETTLED ", vm.toString(got)));
            return;
        }
        if (ret.length == 0 && v == Venue.GASBOMB_SWAP_V2) {
            // the one case no caller can decide for its callee: the whole transaction reverts
            assertEq(IERC20X(tIn).balanceOf(user), inBefore, "a gas-exhausted swap leaves the user's balance untouched");
            console2.log("CELL", name, door, "GAS_EXHAUSTED (whole transaction reverted, balance untouched)");
            return;
        }
        (bool ours, string memory what) = Outcomes.classify(ret);
        assertTrue(ours, string.concat("refused without a selector of ours: ", what));
        assertEq(IERC20X(tIn).balanceOf(user), inBefore, "a refusal leaves the user's balance untouched");
        console2.log("CELL", name, door, string.concat("REFUSED ", what));
    }

    function test_Matrix_LyingV2_ExactIn()          public { _cell(Venue.LYING_V2, Door.EXACT_IN); }
    function test_Matrix_LyingV2_Best()             public { _cell(Venue.LYING_V2, Door.BEST); }
    function test_Matrix_HalfPayV2_ExactIn()        public { _cell(Venue.HALFPAY_V2, Door.EXACT_IN); }
    function test_Matrix_HalfPayV2_Best()           public { _cell(Venue.HALFPAY_V2, Door.BEST); }
    function test_Matrix_ReturnBombV2_ExactIn()     public { _cell(Venue.RETURNBOMB_V2, Door.EXACT_IN); }
    function test_Matrix_ReturnBombV2_Best()        public { _cell(Venue.RETURNBOMB_V2, Door.BEST); }
    function test_Matrix_GasBombReadV2_ExactIn()    public { _cell(Venue.GASBOMB_READ_V2, Door.EXACT_IN); }
    function test_Matrix_GasBombReadV2_Best()       public { _cell(Venue.GASBOMB_READ_V2, Door.BEST); }
    function test_Matrix_GasBombSwapV2_ExactIn()    public { _cell(Venue.GASBOMB_SWAP_V2, Door.EXACT_IN); }
    function test_Matrix_GasBombSwapV2_Best()       public { _cell(Venue.GASBOMB_SWAP_V2, Door.BEST); }
    function test_Matrix_GasBombDecimals_ExactIn()  public { _cell(Venue.GASBOMB_DECIMALS, Door.EXACT_IN); }
    function test_Matrix_GasBombDecimals_Best()     public { _cell(Venue.GASBOMB_DECIMALS, Door.BEST); }
    function test_Matrix_DoubleCallbackV3_ExactIn() public { _cell(Venue.DOUBLE_CALLBACK_V3, Door.EXACT_IN); }
    function test_Matrix_DoubleCallbackV3_Best()    public { _cell(Venue.DOUBLE_CALLBACK_V3, Door.BEST); }
    function test_Matrix_ReentrantV3_ExactIn()      public { _cell(Venue.REENTRANT_V3, Door.EXACT_IN); }
    function test_Matrix_ReentrantV3_Best()         public { _cell(Venue.REENTRANT_V3, Door.BEST); }
    function test_Matrix_SlotRevertV3_ExactIn()     public { _cell(Venue.SLOT_REVERT_V3, Door.EXACT_IN); }
    function test_Matrix_SlotRevertV3_Best()        public { _cell(Venue.SLOT_REVERT_V3, Door.BEST); }
    function test_Matrix_WrongPairFactory_ExactIn() public { _cell(Venue.WRONG_PAIR_FACTORY, Door.EXACT_IN); }
    function test_Matrix_WrongPairFactory_Best()    public { _cell(Venue.WRONG_PAIR_FACTORY, Door.BEST); }
}
