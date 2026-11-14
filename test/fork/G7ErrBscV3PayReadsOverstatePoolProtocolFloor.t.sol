// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  G7 draws bsc gate-6-2 idx 5 (block 132,377,036) and bsc midtail-2 idx 2 (block 132,580,903):
//  0xa991...cf7b -> USDT, 2,431,842.937 tokens. G7 lines: 6 + 6, exec `RouterE(5)`.
//
//  The quote is executable (canExecute, effectiveMinOut 2,162.93 USDT). The exec trace
//  (callTracer, gate-6-2 i5) shows one hop on two V3 legs; the unspent input is returned
//  (Router.sol:1517) and nothing reaches the recipient, so the refusal is the protocol floor,
//  Router.sol:1649 (`amountOut < effMin`): the legs paid 8,192.74 USDT, more than three times
//  the user's floor, while the floor's base is the frame's own quote, 12,974.78 USDT.
//
//  The frame quoted each V3 leg with `Core.v3PaysOnBudget` on V3_PAY_READS (12) reads and, when
//  the reads ran out, priced the input left on the liquidity of the last range it read; this
//  pool's book thins past that range, so leg 2 was quoted 12,839.38 USDT and pays 8,057.34
//  (62.8 %). The protocol floor then refused a fill the market honours.
//
//  The fix: one walk, two questions. The frame (`legQuoteImpact`) answers what the walk read,
//  min(walked, f), which is never above what the pool pays from the same state; the Solver's
//  promise keeps the rest (see SHARED_QUANTITIES, V3 pay walk).
//
//  Pinned here:
//    oracle : the venues pay at least the user's floor and the Solver's attested hop
//             figure (leg 1 pays 135,399,751,186,560,792,558, its book ends). Green.
//    cause  : the frame's quote (`Core.legQuoteImpact`, the Router's own call) is at most what
//             the pool pays. Red at 4f729bc: 12,839,378,017,277,891,192,820 >
//             8,057,336,833,845,326,459,693 (g7-erros run 1).
//    cause  : the frame's walk with 200 reads (cut at V4_WALK_MAX_STEPS) is at most the pay. Red
//             with the rest priced (mutant [wc-3]): 10,060,541,200,510,340,269,405.
//  Mutants [wc-1] and [wc-3] in .github/scripts/mutants.py.
//  Run with DRPC_KEY set, this file only (match-path).
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Leg} from "../../src/BlazePhoenixCore.sol";

interface IERC20G7ErrBscPf {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IV3PoolG7ErrBscPf {
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

contract G7ErrBscV3PayReadsOverstatePoolProtocolFloorTest is Test {
    uint256 internal constant BLK = 132_377_036;
    address internal constant TIN = 0xA991F61940095AEA0724ef54077223B048c5CF7b;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant POOL1 = 0x09eD968AbBeE0AAB6Ca0c68E497a61c6B390a355; // V3 0.05 %
    address internal constant POOL2 = 0x005Db8721Ef9dAdCcf8B99F151b1763E8C58ba61; // V3 0.30 %
    // The G7 route's leg inputs (Router calldata, exec trace) and the quote's floors.
    uint256 internal constant IN1 = 1_152_052_535_947_065_522_716;
    uint256 internal constant IN2 = 98_739_197_313_817_030_331_894;
    uint256 internal constant USER_MIN = 2_162_926_600_175_821_826_632;
    uint256 internal constant HOP_ATTESTED = 2_703_658_250_219_777_283_290;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(string.concat("https://lb.drpc.live/bsc/", vm.envString("DRPC_KEY")), BLK);
    }

    /// @dev The frame's walk for a V3 leg (the A_CONC_POOL arm of Core.legQuoteImpact) on `reads` reads.
    function _frame(address pool, uint256 amt, uint256 reads) internal view returns (uint256 q) {
        (uint160 sp, uint24 dynFee, bool dyn) = BPC.v3StateAndDynFee(pool);
        uint128 lq = BPC.getLiquidity(pool);
        uint256 f = BPC.outV3(amt, sp, lq, BPC.quoteV3Fee(pool, 0, dynFee, dyn), false, 0);
        (q, ) = BPC.v3PaysOnBudget(pool, amt, false, f, reads, false);
    }

    /// @dev The Router's own in-frame call for this leg (Router `_hopScaleImpactAndQuote`).
    function _inFrame(address pool, uint256 amt) internal view returns (uint256 q) {
        Leg memory leg;
        leg.pool = pool;
        leg.kind = BPC.KIND_V3;
        leg.amountIn = amt;
        (q, , ) = BPC.legQuoteImpact(leg, TIN, USDT, amt);
    }

    /// @dev What the pool pays: the swap itself, measured as the delta of balanceOf (I2).
    function _pays(address pool, uint256 amt) internal returns (uint256 got) {
        deal(TIN, address(this), amt);
        uint256 b0 = IERC20G7ErrBscPf(USDT).balanceOf(address(this));
        IV3PoolG7ErrBscPf(pool).swap(address(this), false, int256(amt), MAX_SQRT, "");
        got = IERC20G7ErrBscPf(USDT).balanceOf(address(this)) - b0;
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        uint256 owed = a0 > 0 ? uint256(a0) : uint256(a1);
        IERC20G7ErrBscPf(TIN).transfer(msg.sender, owed);
    }

    function test_oracle_venuesPayAboveTheQuotedFloorAndTheAttestedHop() public {
        uint256 paid1 = _pays(POOL1, IN1);
        uint256 paid2 = _pays(POOL2, IN2);
        console2.log("leg1 pays:", paid1);
        console2.log("leg2 pays:", paid2);
        assertGe(paid1 + paid2, USER_MIN, "the market honours the user's floor");
        assertGe(paid1 + paid2, HOP_ATTESTED, "the market honours the Solver's attested hop figure");
    }

    /// @dev With 200 reads the walk still stops (V4_WALK_MAX_STEPS stretches). Priced with the rest
    ///      it answered 10,060,541,200,510,340,269,405 against 8,057,336,833,845,326,459,693 paid
    ///      (g7-erros run 1): the excess was the rest priced on the last range read, not the read count.
    function test_aFrameWalkCutByItsStretchesQuotesAtMostWhatThePoolPays() public {
        uint256 deep = _frame(POOL2, IN2, 200);
        uint256 paid2 = _pays(POOL2, IN2);
        console2.log("leg2 frame walk, 200 reads:", deep);
        console2.log("leg2 pays:", paid2);
        assertLe(deep, paid2, "a frame walk cut short quotes above the pay");
    }

    function test_theInFrameQuoteIsAtMostWhatThePoolPays_soTheProtocolFloorHonoursTheFill() public {
        uint256 q1 = _inFrame(POOL1, IN1);
        uint256 q2 = _inFrame(POOL2, IN2);
        uint256 paid1 = _pays(POOL1, IN1);
        uint256 paid2 = _pays(POOL2, IN2);
        console2.log("leg2 in-frame quote:", q2);
        console2.log("leg2 pays:", paid2);
        assertLe(q2, paid2, "the in-frame quote (protocol floor base) is above what the pool pays");
        // The hop's protocol-floor base is the sum of its legs' frame quotes: under the pay.
        assertLe(q1 + q2, paid1 + paid2, "the protocol floor's base is above what the hop pays");
    }
}
