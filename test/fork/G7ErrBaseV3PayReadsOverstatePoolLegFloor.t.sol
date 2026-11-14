// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  G7 draw base midtail-3 idx 4 (block 53,653,191): 0x532f...42e4 -> WETH, 8,806,943.08 tokens.
//  G7 lines: 8, exec `RouterE(5)`.
//
//  The quote is executable (canExecute, netOut 14.5838 WETH, effectiveMinOut 13.1649 WETH):
//  one hop on four legs. The exec trace (callTracer) stops right after leg 4's balanceOf,
//  before the residual read of Router.sol:1517, so the refusal is the per-leg floor,
//  Router.sol:1936 (`got < bound * LEG_FLOOR_BPS`). Leg 4 is the V3 1 % pool 0xba3f...46f7 on
//  5,735,927.50 tokens: the Solver attested 9.5173 WETH (calldata `expectedOut`), the frame
//  quotes 7.5120 WETH, the pool pays 6.3692 WETH, under 80 % of the attestation (7.6138).
//
//  Both figures came from `Core.v3PaysOnBudget`: when the reads ran out (the Solver shares
//  V3_PAY_READS across the route, the frame spends them per leg) the walk priced the input
//  left on the last range it read, and this book thins past it. The fix: the frame answers what
//  the walk read, min(walked, f), never above what the pool pays from the same state.
//
//  Pinned here:
//    cause  : the frame's quote (`Core.legQuoteImpact`, the Router's own call) is at most what the
//             pool pays. Red at 4f729bc: 7,511,996,354,983,061,990 > 6,369,190,246,769,622,121.
//    guard  : the frame's walk on 200 reads finishes (32 reads) and is at most the pay.
//  NOT pinned here: the :1936 refusal itself. The Solver's leg-4 attestation equals the
//  single-range band to the wei (the route's 12 reads were spent before leg 4, so the leg was
//  never walked); that is a separate cause (unwalked legs) and its test ships with its own fix.
//  Mutant [wc-1] in .github/scripts/mutants.py.
//  Run with DRPC_KEY set, this file only (match-path).
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Leg} from "../../src/BlazePhoenixCore.sol";

interface IERC20G7ErrBaseLf {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IV3PoolG7ErrBaseLf {
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

contract G7ErrBaseV3PayReadsOverstatePoolLegFloorTest is Test {
    uint256 internal constant BLK = 53_653_191;
    address internal constant TIN = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant POOL4 = 0xBA3F945812a83471d709BCe9C3CA699A19FB46f7; // V3 1 %
    uint256 internal constant IN4 = 5_735_927_499_098_017_995_765_998;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(string.concat("https://lb.drpc.live/base/", vm.envString("DRPC_KEY")), BLK);
    }

    function _frame(uint256 reads) internal view returns (uint256 q) {
        (uint160 sp, uint24 dynFee, bool dyn) = BPC.v3StateAndDynFee(POOL4);
        uint128 lq = BPC.getLiquidity(POOL4);
        uint256 f = BPC.outV3(IN4, sp, lq, BPC.quoteV3Fee(POOL4, 0, dynFee, dyn), false, 0);
        (q, ) = BPC.v3PaysOnBudget(POOL4, IN4, false, f, reads, false);
    }

    /// @dev The Router's own in-frame call for this leg (Router `_hopScaleImpactAndQuote`).
    function _inFrame() internal view returns (uint256 q) {
        Leg memory leg;
        leg.pool = POOL4;
        leg.kind = BPC.KIND_V3;
        leg.amountIn = IN4;
        (q, , ) = BPC.legQuoteImpact(leg, TIN, WETH, IN4);
    }

    function _pays() internal returns (uint256 got) {
        deal(TIN, address(this), IN4);
        uint256 b0 = IERC20G7ErrBaseLf(WETH).balanceOf(address(this));
        IV3PoolG7ErrBaseLf(POOL4).swap(address(this), false, int256(IN4), MAX_SQRT, "");
        got = IERC20G7ErrBaseLf(WETH).balanceOf(address(this)) - b0;
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        uint256 owed = a0 > 0 ? uint256(a0) : uint256(a1);
        IERC20G7ErrBaseLf(TIN).transfer(msg.sender, owed);
    }

    function test_aFrameWalkThatFinishesQuotesAtMostWhatThePoolPays() public {
        uint256 deep = _frame(200);
        uint256 paid = _pays();
        console2.log("leg4 frame walk, 200 reads:", deep);
        console2.log("leg4 pays:", paid);
        assertLe(deep, paid, "a finished frame walk quotes above the pay");
    }

    function test_theInFrameQuoteIsAtMostWhatThePoolPays() public {
        uint256 q = _inFrame();
        uint256 paid = _pays();
        console2.log("leg4 in-frame quote:", q);
        console2.log("leg4 pays:", paid);
        assertLe(q, paid, "the in-frame quote is above what the pool pays");
    }
}
