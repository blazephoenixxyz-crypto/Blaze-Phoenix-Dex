// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ALGEBRA-QUOTE-PRICES-THE-FEE-THE-SWAP-PAYS
//
//  RED at 6387350. `quoteV3Fee` never asked an Algebra-shaped pool for fee():
//  it priced word 2 of globalState(). On Algebra Integral that word is
//  `lastFee`, which the pool's own source marks "may be obsolete if using
//  dynamic fee plugin": the swap pays what the plugin's beforeSwap returns, and
//  pool.fee() is the view that asks the same plugin.
//
//  MEASURED on Base at block 61_800_517, Hydrex (Algebra Integral, factory
//  0x36077D39...), the four pools of highest TVL: word 2 = 500 on every one,
//  fee() = 3081 / 15000 / 50 / 123. The quote priced 500 on all four.
//
//  The oracle is the pool, not our code: each case swaps on the pool itself and
//  reads the fee off the Swap event (`overrideFee`, `pluginFee`). The fee the
//  quote prices must be that fee, and the quote must not promise more than the
//  swap delivered. No tolerance band: both are identities of one block.
//
//  Two more venues hold the change on both sides. QuickSwap v4 on Base is the
//  same Integral build under another factory (word 2 = 500, fee() = 750): a
//  second vector of the same defect. Camelot V3 on Arbitrum is Algebra 1.9,
//  with no fee() selector: word 2 keeps answering there, as before.
//
//  SCOPE: every case here stays inside one initialized tick range, so the fee is
//  the only term between the quote and the swap.
// =============================================================================

import {Test, console2, Vm} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx} from "../../src/BlazePhoenixCore.sol";

interface IAlgebraPoolLike {
    function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160 limitSqrtPrice, bytes calldata data)
        external returns (int256, int256);
    function fee() external view returns (uint16);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IErc20Like {
    function transfer(address to, uint256 v) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract AlgebraQuotePricesTheFeeTheSwapPaysFork is Test {
    address constant HYDX_USDC  = 0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2;
    address constant USDC_TGN   = 0x38564DDf10fE9941139f92D6CCDdE2e094B83603;
    address constant CBETH_WETH = 0xB1383DC47D9971Fc999C3A9088F79E744b376e97;
    address constant WETH_CBBTC = 0x3f9b863EF4B295d6Ba370215bcCa3785FCC44f44;
    address constant VENUE_QUOTER_V2 = 0x08b46265643a5389529D6f6616FA4a0d66F13Fdb;
    // QuickSwap v4, factory 0xC5396866754799B9720125B104AE01d935Ab9C7b: not a Hydrex pool.
    address constant QUICK_WETH_USDC = 0x5a9Ad2BB92B0B3E5C571FDD5125114E04E02be1a;

    /// @dev Hydrex's quoter by default. A case on another venue zeroes it: that quoter would
    ///      answer for a Hydrex pool of the same pair, which is not the pool measured.
    address internal venueQuoter = VENUE_QUOTER_V2;

    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    bytes32 constant SWAP_TOPIC =
        keccak256("Swap(address,address,int256,int256,uint160,uint128,int24,uint24,uint24)");

    struct M {
        uint24 word2;    // globalState().lastFee
        uint24 feeNow;   // pool.fee()
        uint24 priced;   // what quoteV3Fee hands the curve
        uint24 charged;  // what the Swap event says the swap paid
        uint256 ours;
        uint256 theirs;
        uint256 exec;
    }

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base", 61_800_517);
    }

    function algebraSwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address tIn = abi.decode(data, (address));
        IErc20Like(tIn).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }

    /// @dev The venue's own QuoterV2, by low-level call: Integral 1.2 takes a `deployer` field,
    ///      earlier builds do not. 0 means "did not answer", and is logged, never asserted on.
    function _venueQuote(address tIn, address tOut, uint256 amountIn) internal returns (uint256 out) {
        if (venueQuoter == address(0)) return 0;
        (bool ok, bytes memory r) = venueQuoter.call(
            abi.encodeWithSignature(
                "quoteExactInputSingle((address,address,address,uint256,uint160))", tIn, tOut, address(0), amountIn, uint160(0)
            )
        );
        if (!ok || r.length < 32) {
            (ok, r) = venueQuoter.call(
                abi.encodeWithSignature(
                    "quoteExactInputSingle((address,address,uint256,uint160))", tIn, tOut, amountIn, uint160(0)
                )
            );
        }
        if (ok && r.length >= 32) out = abi.decode(r, (uint256));
    }

    function _measure(address pool, bool zeroForOne, uint256 amountIn) internal returns (M memory m) {
        address t0 = IAlgebraPoolLike(pool).token0();
        address t1 = IAlgebraPoolLike(pool).token1();
        (address tIn, address tOut) = zeroForOne ? (t0, t1) : (t1, t0);

        bool dyn;
        (, m.word2, dyn) = BPC.v3StateAndDynFee(pool);
        assertTrue(dyn, "precondition: the pool answers globalState() with the fee word");
        m.feeNow = IAlgebraPoolLike(pool).fee();
        m.priced = BPC.quoteV3Fee(pool, 0, m.word2, dyn);

        QuoteCtx memory c;
        c.kind = BPC.KIND_ALGEBRA;
        c.pool = pool;
        c.zeroForOne = zeroForOne;
        c.tokenIn = tIn;
        c.tokenOther = tOut;
        (m.ours,,,) = BPC.universalQuoteRank(c, amountIn, type(uint256).max, false);
        m.theirs = _venueQuote(tIn, tOut, amountIn);

        deal(tIn, address(this), amountIn);
        uint256 b = IErc20Like(tOut).balanceOf(address(this));
        vm.recordLogs();
        IAlgebraPoolLike(pool).swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1, abi.encode(tIn)
        );
        m.exec = IErc20Like(tOut).balanceOf(address(this)) - b;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            // OUR swap only, and the first of them: a plugin's afterSwap may swap on the same
            // pool again (measured: a later Swap with overrideFee 1 on the beacon-proxy
            // plugins), and that event is somebody else's fee.
            if (
                !seen && logs[i].emitter == pool && logs[i].topics[0] == SWAP_TOPIC
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(this))))
            ) {
                (,,,,, uint24 overrideFee, uint24 pluginFee) =
                    abi.decode(logs[i].data, (int256, int256, uint160, uint128, int24, uint24, uint24));
                // SwapCalculation: the override replaces lastFee, the plugin fee adds to either.
                m.charged = (overrideFee != 0 ? overrideFee : m.word2) + pluginFee;
                seen = true;
            }
        }
        assertTrue(seen, "precondition: the pool emitted its Swap event");

        console2.log("word2 / fee() / priced / charged:", m.word2, m.feeNow);
        console2.log("  ", m.priced, m.charged);
        console2.log("ours / venue quoter / executed:", m.ours, m.theirs);
        console2.log("  ", m.exec);
        // Signed error of our quote against execution, in 1/100 bps. Positive = over-quote.
        console2.log("ours vs exec, bps x100:", (int256(m.ours) - int256(m.exec)) * 1_000_000 / int256(m.exec));
        if (m.theirs != 0) {
            console2.log("venue quoter vs exec, bps x100:", (int256(m.theirs) - int256(m.exec)) * 1_000_000 / int256(m.exec));
        }
    }

    function _assertPricedAsCharged(M memory m) internal pure {
        assertGt(m.exec, 0, "precondition: the swap delivered");
        assertEq(m.priced, m.charged, "the fee the quote prices is the fee the swap paid");
        assertLe(m.ours, m.exec, "the quote never promises more than the pool delivered in the same block");
    }

    // HYDX/USDC, beacon-proxy plugin: word 2 = 500, fee() = 3081.
    function test_HydxUsdc_UsdcIn() public { _assertPricedAsCharged(_measure(HYDX_USDC, false, 100e6)); }
    function test_HydxUsdc_HydxIn() public { _assertPricedAsCharged(_measure(HYDX_USDC, true, 10_000e18)); }
    function test_HydxUsdc_Dust() public { _assertPricedAsCharged(_measure(HYDX_USDC, false, 1e4)); }

    // USDC/TGN, direct plugin with no published source: word 2 = 500, fee() = 15000.
    function test_UsdcTgn_UsdcIn() public { _assertPricedAsCharged(_measure(USDC_TGN, true, 100e6)); }
    // 10 TGN stays inside one tick range (tick 308726, spacing 60), so the fee is all there is.
    function test_UsdcTgn_TgnIn() public { _assertPricedAsCharged(_measure(USDC_TGN, false, 10e18)); }

    // QuickSwap v4 WETH/USDC, another factory, the same Integral build: word 2 = 500,
    // fee() = 750. Tick spacing 1, so the amounts are small enough to stay in one range.
    function test_QuickSwap_WethIn() public {
        venueQuoter = address(0);
        _assertPricedAsCharged(_measure(QUICK_WETH_USDC, true, 2e14));
    }

    function test_QuickSwap_UsdcIn() public {
        venueQuoter = address(0);
        _assertPricedAsCharged(_measure(QUICK_WETH_USDC, false, 5e5));
    }

    // The other direction of the same defect: the pool charges LESS than word 2.
    function test_CbethWeth_CbethIn() public { _assertPricedAsCharged(_measure(CBETH_WETH, true, 1e17)); }
    function test_WethCbbtc_WethIn() public { _assertPricedAsCharged(_measure(WETH_CBBTC, true, 1e16)); }

    /// The read the fix adds fits the budget `getV3Fee` already has: the Core's own reader
    /// returns the pool's answer on all four, cold. Outside the budget it would return 0.
    function test_FeeReadAnswersInsideItsBudget() public {
        address[4] memory pools = [HYDX_USDC, USDC_TGN, CBETH_WETH, WETH_CBBTC];
        for (uint256 i; i < pools.length; ++i) {
            uint256 g = gasleft();
            uint24 f = BPC.getV3Fee(pools[i]);
            g -= gasleft();
            console2.log("getV3Fee cold gas / answer:", g, f);
            assertEq(f, IAlgebraPoolLike(pools[i]).fee(), "the Core's reader takes the pool's answer");
            assertGt(f, 0, "precondition: a live fee");
        }
    }
}

/// Non-regression on the other side: Algebra 1.9 (Camelot V3, Arbitrum, factory
/// 0x1a3c9B1d2F0529D97f2afC5136Cc23e58f1FD35B) has no fee() selector. The read the fix adds
/// fails there, word 2 keeps answering, and the quote stays at or under execution. Its Swap
/// event carries no fee, so the oracle is the delivery alone.
contract AlgebraWithNoFeeGetterKeepsItsWordFork is Test {
    address constant CAMELOT_WETH_USDC = 0xB1026b8e7276e7AC75410F1fcbbe21796e8f7526;
    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("arbitrum", 527_219_000);
    }

    function algebraSwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address tIn = abi.decode(data, (address));
        IErc20Like(tIn).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }

    function _quotedAndDelivered(bool zeroForOne, uint256 amountIn) internal returns (uint256 ours, uint256 exec) {
        address pool = CAMELOT_WETH_USDC;
        address t0 = IAlgebraPoolLike(pool).token0();
        address t1 = IAlgebraPoolLike(pool).token1();
        (address tIn, address tOut) = zeroForOne ? (t0, t1) : (t1, t0);

        (bool answers,) = pool.staticcall(abi.encodeWithSelector(IAlgebraPoolLike.fee.selector));
        assertFalse(answers, "precondition: this pool has no fee()");
        (, uint24 word2, bool dyn) = BPC.v3StateAndDynFee(pool);
        assertTrue(dyn, "precondition: the pool answers globalState() with the fee word");
        assertEq(BPC.quoteV3Fee(pool, 0, word2, dyn), word2, "word 2 is still the fee priced");

        QuoteCtx memory c;
        c.kind = BPC.KIND_ALGEBRA;
        c.pool = pool;
        c.zeroForOne = zeroForOne;
        c.tokenIn = tIn;
        c.tokenOther = tOut;
        (ours,,,) = BPC.universalQuoteRank(c, amountIn, type(uint256).max, false);

        deal(tIn, address(this), amountIn);
        uint256 b = IErc20Like(tOut).balanceOf(address(this));
        IAlgebraPoolLike(pool).swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1, abi.encode(tIn)
        );
        exec = IErc20Like(tOut).balanceOf(address(this)) - b;
        console2.log("word2 / ours / executed:", word2, ours, exec);
        console2.log("ours vs exec, bps x100:", (int256(ours) - int256(exec)) * 1_000_000 / int256(exec));
    }

    function test_Camelot_WethIn() public {
        (uint256 ours, uint256 exec) = _quotedAndDelivered(true, 1e14);
        assertGt(ours, 0, "precondition: the pool quotes");
        assertLe(ours, exec, "the quote never promises more than the pool delivered in the same block");
    }

    function test_Camelot_UsdcIn() public {
        (uint256 ours, uint256 exec) = _quotedAndDelivered(false, 5e5);
        assertGt(ours, 0, "precondition: the pool quotes");
        assertLe(ours, exec, "the quote never promises more than the pool delivered in the same block");
    }

    /// What the fix costs a pool with no fee(): one failed staticcall, the pool already warm
    /// from the globalState() read that precedes it in every quote.
    function test_TheFailedFeeReadIsCheap() public {
        BPC.v3StateAndDynFee(CAMELOT_WETH_USDC);
        uint256 g = gasleft();
        uint24 f = BPC.getV3Fee(CAMELOT_WETH_USDC);
        g -= gasleft();
        console2.log("getV3Fee on a pool with no fee(), warm, gas:", g);
        assertEq(f, 0, "no answer is taken from a pool with no fee()");
        assertLt(g, 5_000, "the failed read stays a small constant");
    }
}
