// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  atq-1111, fork lane. Real pools at pinned blocks on Base, Arbitrum, Optimism,
//  BNB Chain and Avalanche; the venue's own swap is the oracle (see the harness,
//  AtqForkVenueOracle.sol, for the laws P1 / P2 / M2 / W).
//
//  Dimensions: chain (5) x family (Uniswap V3 by CREATE2, PancakeSwap V3 by
//  getPool, Algebra 1.9 / Camelot, Uniswap V4 native) x direction (2) x size
//  (dust -> past the whole book, so the top rungs end AT MIN/MAX_SQRT_RATIO).
//  Synthetic books are opened on the REAL PoolManager (its bytecode is still the
//  oracle) where the real chain has no book at the place under attack: bitmap
//  word edges and the two extreme usable ticks.
//
//  Mutants: [ATQ-fork-n] in .github/scripts/mutants.py.
// =============================================================================

import {console2} from "forge-std/Test.sol";
import {AtqForkVenueOracle, AtqPoolKey, IV4ManagerAtq} from "./AtqForkVenueOracle.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../../src/BlazePhoenixCore.sol";

interface IConcViewAtq {
    function token0() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

contract AtqForkToken {
    mapping(address => uint256) public balanceOf;
    constructor() { balanceOf[msg.sender] = type(uint128).max; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

abstract contract AtqForkWalks is AtqForkVenueOracle {
    /// @dev W on a V3-shaped pool: the walk reads the pool's own book at the pool's own fee and spacing.
    function _walkV3(address pool, address a, uint256 unitA, address b, uint256 unitB, uint256 step, uint256 rungs) internal {
        AtqPoolKey memory none;
        bool aIs0 = IConcViewAtq(pool).token0() == a;
        uint24 fee = IConcViewAtq(pool).fee();
        int24 ts = IConcViewAtq(pool).tickSpacing();
        _walkLadder(pool, bytes32(0), none, a, aIs0, fee, ts, unitA, step, rungs);
        _walkLadder(pool, bytes32(0), none, b, !aIs0, fee, ts, unitB, step, rungs);
    }
}

// ─── Base ────────────────────────────────────────────────────────────────────────────────
abstract contract AtqForkBaseStack is AtqForkWalks {
    uint256 internal constant BLK = 49_800_000;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNIV3 = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant UNIV2 = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address internal constant AERO = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address internal constant AEROCL = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant PCK3 = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant V4MGR = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant V3_1PCT = 0x0b1C2DCbBfA744ebD3fC17fF1A96A1E1Eb4B2d69;

    function _base() internal returns (bool) {
        if (!_fork("base", BLK)) return false;
        _stack(WETH, V4MGR);
        hub.addBridge(WETH);
        hub.addBridge(USDC);
        return true;
    }

    function _nativeTier(uint24 fee, int24 ts) internal {
        hub.addV4(address(0), USDC, fee, ts, address(0));
        hub.addFactory(V4MGR, KIND_V4, 9, bytes32(0), _no24(), _noSp());
    }

    // ─── estGas against measured gas ─────────────────────────────────────────────────────

    uint256[7] internal gEst;
    uint256[7] internal gReal;
    uint256 internal gN;

    function _family(uint256 f) internal {
        if (f == 0) hub.addFactory(UNIV2, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _no24(), _noSp());
        if (f == 1) hub.addFactory(AERO, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _no24(), _noSp());
        if (f == 2) hub.addFactory(UNIV3, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _one24(500), _oneSp(10));
        if (f == 3) hub.addFactory(AEROCL, KIND_V3, MODE_CALL_V3CL, bytes32(0), _no24(), _oneSp(100));
        if (f == 4) hub.addFactory(PCK3, KIND_V3, MODE_CALL_V3, bytes32(0), _one24(500), _oneSp(10));
        if (f == 5) _nativeTier(500, 10);
        if (f == 6) {
            hub.addV4(USDC, WETH, 500, 10, address(0));
            hub.addFactory(V4MGR, KIND_V4, 9, bytes32(0), _no24(), _noSp());
        }
    }

    /// @dev One family per stack, the same swap (0.01 WETH -> USDC), one leg. The execution is
    ///      metered from a state the preview never touched (the route survives the revert in
    ///      memory); a second identical run is the control on the meter itself. Router, Hub and
    ///      Solver were created in this transaction and stay warm, and intrinsic gas is not in
    ///      the figure: what is measured is a LOWER bound on what the user pays.
    function _meter(uint256 f) internal {
        uint256 amt = 1e16;
        uint256 est; uint256 real;
        uint256 s0 = vm.snapshotState();
        _family(f);
        deal(WETH, user, amt);
        vm.prank(user);
        IERC20Approve(WETH).approve(address(router), amt);
        uint256 s1 = vm.snapshotState();
        try quoter.previewPlan(WETH, USDC, amt) returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool) {
            if (pv.canExecute && pv.hops == 1 && pv.legs == 1) {
                vm.revertToState(s1);
                s1 = vm.snapshotState();
                uint256 a = _run(pv, amt);
                vm.revertToState(s1);
                uint256 b = _run(pv, amt);
                console2.log(string.concat("family ", vm.toString(f), " kind ", vm.toString(pv.route.hops[0].legs[0].kind),
                    " estGas ", vm.toString(pv.estGas), " measured ", vm.toString(a), " control ", vm.toString(b)));
                est = pv.estGas;
                real = a;
            } else {
                console2.log(string.concat("family ", vm.toString(f), " gave no one-leg executable plan"));
            }
        } catch {
            console2.log(string.concat("family ", vm.toString(f), " preview refused"));
        }
        vm.revertToState(s0); // also rewinds this contract's storage: the pair crossed it in memory
        if (real != 0) { gEst[gN] = est; gReal[gN] = real; ++gN; }
    }

    function _run(BlazePhoenixQuoter.Preview memory pv, uint256 amt) internal returns (uint256 used) {
        vm.prank(user);
        uint256 g = gasleft();
        router.swapExactIn(pv.route, amt, pv.effectiveMinOut, user, block.timestamp + 600);
        used = g - gasleft();
    }

    /// @return n families metered, inv pairs the ladder calls cheaper and the meter reads dearer
    function _estGasOrder() internal returns (uint256 n, uint256 inv) {
        for (uint256 f; f < 7; ++f) _meter(f);
        n = gN;
        for (uint256 i; i < gN; ++i) {
            for (uint256 j; j < gN; ++j) {
                if (gEst[i] < gEst[j] && gReal[i] > gReal[j]) ++inv;
            }
        }
    }
}

contract AtqForkBaseTest is AtqForkBaseStack {
    function test_AtqFork_BaseUniV3Thin_InRangeQuoteNeverAboveThePool_DustPastTheCapacityClamp() public {
        if (!_base()) return;
        hub.addFactory(UNIV3, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _one24(10000), _oneSp(200));
        toCorner = true;
        _ladder(WETH, USDC, 1e9, 1e2, 100, 8);
        _verdict("base univ3 1%", true);
    }

    function test_AtqFork_BaseV4Native500_QuoteNeverAboveTheManager_DustPastTheCapacityClamp() public {
        if (!_base()) return;
        _nativeTier(500, 10);
        toCorner = true;
        _ladder(WETH, USDC, 1e9, 1e2, 100, 8);
        _verdict("base v4 native 0.05%", true);
    }

    function test_AtqFork_BaseV4Native10000_QuoteNeverAboveTheManager_DustPastTheCapacityClamp() public {
        if (!_base()) return;
        _nativeTier(10000, 200);
        toCorner = true;
        _ladder(WETH, USDC, 1e9, 1e2, 100, 8);
        _verdict("base v4 native 1%", true);
    }

    // The real pool left AT a price limit by its own swap, then quoted and executed against.
    function _atLimit(bool lower) internal {
        hub.addFactory(UNIV3, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _one24(10000), _oneSp(200));
        (, uint160 sp) = _swapConc(V3_1PCT, lower ? WETH : USDC, lower, CORNER_IN);
        assertEq(sp, lower ? MIN_P1 : MAX_M1, "setup: the pool is not at its price limit");
        _ladder(WETH, USDC, 1e9, 1e2, 100, 7);
    }

    function test_AtqFork_BaseUniV3Thin_PoolLeftAtMinSqrtRatio_EveryPreviewRefusesTyped() public {
        if (!_base()) return;
        _atLimit(true);
        _verdictRefusedTyped("base univ3 1% at MIN_SQRT_RATIO");
    }

    function test_AtqFork_BaseUniV3Thin_PoolLeftAtMaxSqrtRatio_EveryPreviewRefusesTyped() public {
        if (!_base()) return;
        _atLimit(false);
        _verdictRefusedTyped("base univ3 1% at MAX_SQRT_RATIO");
    }

    // W on the real native ETH/USDC books. Spacing 1 is the dense book (every step is a bitmap
    // word edge candidate) and stays inside it; 60 and 200 run past the book, where the deep
    // walk reaches the clamp at the extreme ticks (+-887272) and must still close on the venue.
    function _walkNative(uint24 fee, int24 ts, uint256 unitE, uint256 unitU, uint256 step, uint256 rungs) internal {
        v4mgr = V4MGR;
        AtqPoolKey memory k = AtqPoolKey(address(0), USDC, fee, ts, address(0));
        bytes32 pid = _v4Id(k);
        (, uint128 liq, uint24 lpF, uint24 pF, ) = BPC.v4SqrtAndLiq(V4MGR, pid);
        assertGt(liq, 0, "the pinned pool holds no liquidity");
        _walkLadder(V4MGR, pid, k, address(0), true, BPC.effV4Fee(fee, lpF, pF, true), ts, unitE, step, rungs);
        _walkLadder(V4MGR, pid, k, USDC, false, BPC.effV4Fee(fee, lpF, pF, false), ts, unitU, step, rungs);
    }

    function test_AtqFork_BaseV4Walk_Spacing1_DenseBookInsideTheBook() public {
        if (!_fork("base", BLK)) return;
        _walkNative(100, 1, 1e9, 1e1, 10, 8);
        _verdictWalk("base v4 walk ts1", false);
    }

    function test_AtqFork_BaseV4Walk_Spacing10_PastTheBook() public {
        if (!_fork("base", BLK)) return;
        toCorner = true;
        _walkNative(500, 10, 1e9, 1e2, 100, 8);
        _verdictWalk("base v4 walk ts10", true);
    }

    function test_AtqFork_BaseV4Walk_Spacing60_ToTheExtremeTicks() public {
        if (!_fork("base", BLK)) return;
        toCorner = true;
        _walkNative(3000, 60, 1e9, 1e2, 100, 8);
        _verdictWalk("base v4 walk ts60", true);
    }

    function test_AtqFork_BaseV4Walk_Spacing200_ToTheExtremeTicks() public {
        if (!_fork("base", BLK)) return;
        toCorner = true;
        _walkNative(10000, 200, 1e9, 1e2, 100, 8);
        _verdictWalk("base v4 walk ts200", true);
    }

    function test_AtqFork_BaseV3Walk_PoolIdZero_ReadsThePoolsOwnBook() public {
        if (!_fork("base", BLK)) return;
        toCorner = true;
        _walkV3(V3_1PCT, WETH, 1e9, USDC, 1e2, 100, 8);
        _verdictWalk("base v3 walk 1%", true);
    }

    // ─── synthetic books on the REAL PoolManager ─────────────────────────────────────────

    function _book(int24 ts, uint160 sp0) internal returns (AtqPoolKey memory k) {
        v4mgr = V4MGR;
        address a = address(new AtqForkToken());
        address b = address(new AtqForkToken());
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = AtqPoolKey(c0, c1, 3000, ts, address(0));
        IV4ManagerAtq(V4MGR).initialize(k, sp0);
    }

    function _add(AtqPoolKey memory k, int24 lo, int24 hi, uint256 liq) internal {
        _v4Do(1, k, false, 0, lo, hi, int256(liq));
    }

    function _walkBook(AtqPoolKey memory k, bool zfo, uint256 unit, uint256 step, uint256 rungs) internal {
        _walkLadder(V4MGR, _v4Id(k), k, zfo ? k.currency0 : k.currency1, zfo, k.fee, k.tickSpacing, unit, step, rungs);
    }

    /// @dev Spacing 1 at tick 0. Initialized ticks sit ON the bitmap word edges (bit 0 and bit
    ///      255 of words -2..2), then one per word with word 4 / -5 left EMPTY, so the walk
    ///      takes both arms of the next-tick search: a tick found in the word, and a word with
    ///      nothing left in it. A walk that skips a word loses that word's tick and its
    ///      liquidityNet, and no longer closes on the manager.
    function test_AtqFork_V4BitmapWordEdges_WalkClosesOnTheManager() public {
        if (!_fork("base", BLK)) return;
        AtqPoolKey memory k = _book(1, 79228162514264337593543950336);
        _add(k, -2000, 2000, 1e18);
        _add(k, -257, 256, 3e18);
        _add(k, -256, 255, 5e18);
        _add(k, -1, 511, 7e18);
        _add(k, -512, 512, 11e18);
        _add(k, -700, 700, 13e18);
        _add(k, -1000, 1000, 17e18);
        _add(k, -1300, 1300, 19e18);
        _add(k, -1600, 1600, 23e18);
        _walkBook(k, true, 11e14, 2, 13);
        _walkBook(k, false, 11e14, 2, 13);
        _verdictWalk("v4 word edges", false);
        assertEq(wOpen, 0, "inside the book every walk finishes: nothing may stay open");
    }

    /// @dev Spacing 200, price initialized AT MIN_SQRT_PRICE. Every input is degenerate here
    ///      (a wei of token1 is worth the whole book), and that is the corner: the walk starts
    ///      on the first tick, crosses the book, runs the empty words to +887272 and stops.
    ///      Then the book is emptied for real and the walk comes back down to -887272, through
    ///      the clamp below the lowest usable tick.
    function test_AtqFork_V4BookAtMinSqrtPrice_WalkClosesOnTheManagerAtBothExtremeTicks() public {
        if (!_fork("base", BLK)) return;
        AtqPoolKey memory k = _book(200, 4295128739);
        _add(k, -887200, -880000, 1e15);
        _add(k, -887200, -886000, 3e15);
        _add(k, -885000, -870000, 2e15);
        _walkBook(k, false, 1, 1000, 4);
        _swapV4(k, false, 5);
        _walkBook(k, true, 1e20, 1e5, 4);
        _verdictWalk("v4 min corner", true);
        assertEq(wOpen, 0, "a walk that reaches the extreme tick has finished");
    }

    function test_AtqFork_V4BookAtMaxSqrtPrice_WalkClosesOnTheManagerAtBothExtremeTicks() public {
        if (!_fork("base", BLK)) return;
        AtqPoolKey memory k = _book(200, MAX_M1);
        _add(k, 880000, 887200, 1e15);
        _add(k, 886000, 887200, 3e15);
        _add(k, 870000, 885000, 2e15);
        _walkBook(k, true, 1, 1000, 4);
        _swapV4(k, true, 5);
        _walkBook(k, false, 1e20, 1e5, 4);
        _verdictWalk("v4 max corner", true);
        assertEq(wOpen, 0, "a walk that reaches the extreme tick has finished");
    }
}

interface IERC20Approve { function approve(address, uint256) external returns (bool); }

// ─── Arbitrum ────────────────────────────────────────────────────────────────────────────
contract AtqForkArbitrumTest is AtqForkWalks {
    uint256 internal constant BLK = 498_000_000;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant V4MGR = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant UNIV3 = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant CAMELOT = 0x1a3c9B1d2F0529D97f2afC5136Cc23e58f1FD35B;
    address internal constant V3_1PCT = 0x42FC852A750BA93D5bf772ecdc857e87a86403a9;

    function _arb() internal returns (bool) {
        if (!_fork(vm.envOr("ARBITRUM_FORK_URL", string("arbitrum")), BLK)) return false;
        _stack(WETH, V4MGR);
        hub.addBridge(WETH);
        hub.addBridge(USDC);
        return true;
    }

    /// @dev Algebra 1.9 as deployed: the live fee is the pool's, read at quote time; here both
    ///      directional fees are equal (measured on 7 of 7 Camelot pools at this block).
    function test_AtqFork_ArbitrumCamelotAlgebra_InRangeQuoteNeverAboveThePool_DustPastTheCapacityClamp() public {
        if (!_arb()) return;
        hub.addFactory(CAMELOT, KIND_ALGEBRA, MODE_CALL_V3, bytes32(0), _one24(0), _oneSp(1));
        toCorner = true;
        _ladder(WETH, USDC, 1e9, 1e2, 100, 8);
        _verdict("arbitrum camelot", true);
    }

    function test_AtqFork_ArbitrumUniV3Thin_InRangeQuoteNeverAboveThePool_DustPastTheCapacityClamp() public {
        if (!_arb()) return;
        hub.addFactory(UNIV3, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _one24(10000), _oneSp(200));
        toCorner = true;
        _ladder(WETH, USDC, 1e9, 1e2, 100, 8);
        _verdict("arbitrum univ3 1%", true);
    }

    function test_AtqFork_ArbitrumV3Walk_PoolIdZero_ReadsThePoolsOwnBook() public {
        if (!_fork(vm.envOr("ARBITRUM_FORK_URL", string("arbitrum")), BLK)) return;
        toCorner = true;
        _walkV3(V3_1PCT, WETH, 1e9, USDC, 1e2, 100, 8);
        _verdictWalk("arbitrum v3 walk 1%", true);
    }
}

// ─── Optimism ────────────────────────────────────────────────────────────────────────────
contract AtqForkOptimismTest is AtqForkWalks {
    uint256 internal constant BLK = 156_000_000;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant UNIV3 = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant V3_1PCT = 0xd4CB5566b5C16eF2f4A08b1438052013171212A2;

    function test_AtqFork_OptimismUniV3Thin_InRangeQuoteNeverAboveThePool_DustPastTheCapacityClamp() public {
        if (!_fork("optimism", BLK)) return;
        _stack(WETH, address(0));
        hub.addBridge(WETH);
        hub.addBridge(USDC);
        hub.addFactory(UNIV3, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _one24(10000), _oneSp(200));
        toCorner = true;
        _ladder(WETH, USDC, 1e9, 1e2, 100, 8);
        _verdict("optimism univ3 1%", true);
    }

    function test_AtqFork_OptimismV3Walk_PoolIdZero_ReadsThePoolsOwnBook() public {
        if (!_fork("optimism", BLK)) return;
        toCorner = true;
        _walkV3(V3_1PCT, WETH, 1e9, USDC, 1e2, 100, 8);
        _verdictWalk("optimism v3 walk 1%", true);
    }
}

// ─── BNB Chain ───────────────────────────────────────────────────────────────────────────
contract AtqForkBscTest is AtqForkWalks {
    uint256 internal constant BLK = 132_700_000;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant PCK3 = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant UNIV3 = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
    address internal constant PCK_1PCT = 0x6805E0E5333c5c3acCF2930Be4734E2b98f4Ce06;
    address internal constant UNI_1PCT = 0x4d170f8714367C44787AE98259CE8Adb72240067;

    function _bsc(bool stack) internal returns (bool) {
        if (!_fork(_drpc("bsc", "BSC_FORK_URL"), BLK)) return false;
        if (stack) {
            _stack(WBNB, address(0));
            hub.addBridge(WBNB);
            hub.addBridge(USDT);
        }
        return true;
    }

    function test_AtqFork_BscPancakeV3Thin_InRangeQuoteNeverAboveThePool_DustPastTheCapacityClamp() public {
        if (!_bsc(true)) return;
        hub.addFactory(PCK3, KIND_V3, MODE_CALL_V3, bytes32(0), _one24(10000), _oneSp(200));
        toCorner = true;
        _ladder(WBNB, USDT, 1e9, 1e9, 100, 8);
        _verdict("bsc pancake v3 1%", true);
    }

    /// @dev The canonical init-code hash derives the real pool on this chain too: the stack is
    ///      registered by CREATE2 and the ladder only measures legs if the derivation lands.
    function test_AtqFork_BscUniV3Thin_Create2Derivation_InRangeQuoteNeverAboveThePool() public {
        if (!_bsc(true)) return;
        hub.addFactory(UNIV3, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _one24(10000), _oneSp(200));
        toCorner = true;
        _ladder(WBNB, USDT, 1e9, 1e9, 100, 8);
        _verdict("bsc univ3 1%", true);
    }

    function test_AtqFork_BscV3Walk_PancakeAndUniswap_PoolIdZero() public {
        if (!_bsc(false)) return;
        toCorner = true;
        _walkV3(PCK_1PCT, WBNB, 1e9, USDT, 1e9, 100, 8);
        _walkV3(UNI_1PCT, WBNB, 1e9, USDT, 1e9, 100, 8);
        _verdictWalk("bsc v3 walk 1%", true);
    }
}

// ─── Avalanche ───────────────────────────────────────────────────────────────────────────
contract AtqForkAvalancheTest is AtqForkWalks {
    uint256 internal constant BLK = 99_900_000;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant UNIV3 = 0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD;
    address internal constant V3_1PCT = 0xd18384F4398BF5415902aD5d87eAA96549Fd4f1E;

    function test_AtqFork_AvalancheUniV3Thin_Create2Derivation_InRangeQuoteNeverAboveThePool() public {
        if (!_fork(_drpc("avalanche", "AVAX_FORK_URL"), BLK)) return;
        _stack(WAVAX, address(0));
        hub.addBridge(WAVAX);
        hub.addBridge(USDC);
        hub.addFactory(UNIV3, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _one24(10000), _oneSp(200));
        toCorner = true;
        _ladder(WAVAX, USDC, 1e9, 1e2, 100, 8);
        _verdict("avalanche univ3 1%", true);
    }

    function test_AtqFork_AvalancheV3Walk_PoolIdZero_ReadsThePoolsOwnBook() public {
        if (!_fork(_drpc("avalanche", "AVAX_FORK_URL"), BLK)) return;
        toCorner = true;
        _walkV3(V3_1PCT, WAVAX, 1e9, USDC, 1e2, 100, 8);
        _verdictWalk("avalanche v3 walk 1%", true);
    }
}
