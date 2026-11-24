// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE PROMISE OF AN ALGEBRA INTEGRAL LEG, AGAINST THE POOL ITSELF (Base fork).
//
//  `Core.v3PaysOnBudget` is the one producer of a concentrated leg's promise and
//  of the Router's in-frame quote (`legQuoteImpact`). It read the book through
//  `slot0()` and `tickBitmap(int16)`, which an Algebra Integral pool does not
//  answer, so the promise of such a leg was `f`, the single-range figure: an
//  order that crossed initialized ticks into thinner liquidity was promised the
//  depth of the range it started in.
//
//  MEASURED on Base at block 61_800_517, Hydrex USDC/TGN
//  (0x38564DDf10fE9941139f92D6CCDdE2e094B83603), 2 000 TGN in, with the fee
//  priced as charged (15000), so the gap is depth and not fee:
//      single-range figure 68578926, the pool delivered 63924843 (+728 bps).
//  The walk now follows the pool's own list (prevTickGlobal / nextTickGlobal,
//  then prevTick / nextTick in ticks(int24)) and the promise is the pool's
//  figure. After the change, same block, same fee: 2 000 TGN are promised
//  63924843, the pool delivers 63924843 (to the wei; 8 of the 12 reads, two
//  ticks crossed; walk 73969 gas cold); 10 TGN, inside one range, 385483 =
//  the single-range figure = what the pool delivers (6 reads; 44845 gas).
//
//  The oracle is the pool: the swap runs on the pool itself, in the same block.
//
//  forge test --match-path test/fork/AlgebraListPromiseIsWhatThePoolPays.t.sol -vv
// =============================================================================

import {Test, console2, Vm} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Leg} from "../../src/BlazePhoenixCore.sol";

interface IAlgebraPoolList {
    function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160 limitSqrtPrice, bytes calldata data)
        external returns (int256, int256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IErc20List {
    function transfer(address to, uint256 v) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract AlgebraListPromiseIsWhatThePoolPaysFork is Test {
    address constant USDC_TGN = 0x38564DDf10fE9941139f92D6CCDdE2e094B83603;
    bytes32 constant SWAP_TOPIC =
        keccak256("Swap(address,address,int256,int256,uint160,uint128,int24,uint24,uint24)");

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base", 61_800_517);
    }

    function algebraSwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address tIn = abi.decode(data, (address));
        IErc20List(tIn).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }

    /// 2 000 TGN in crosses initialized ticks into thinner liquidity: the promise is not above
    /// what the pool delivers, and it is the figure the Router's frame quotes.
    function test_AnOrderAcrossTicks_IsPromisedNoMoreThanThePoolDelivers() public {
        (uint256 f, uint256 q, uint256 left, uint256 exec) = _promiseAndSwap(2_000e18);
        assertGt(f, exec, "premise: the order crosses ticks, the single-range figure is above the pool");
        assertLe(q, exec, "the promise is above what the pool delivered in the same block");
        assertEq(q, exec, "the promise is not the pool's figure to the wei");
        assertLt(left, BPC.V3_PAY_READS - 6, "premise: the walk crossed at least one tick");
    }

    /// 10 TGN in ends inside the range it starts in: the walk reads no tick and the promise is
    /// still the pool's figure (the list shape costs this order nothing in price). A control:
    /// before the change this order was already promised the pool's figure; only its reads move.
    function test_AnOrderInsideOneRange_IsPromisedWhatThePoolDelivers() public {
        (uint256 f, uint256 q, uint256 left, uint256 exec) = _promiseAndSwap(10e18);
        assertEq(left, BPC.V3_PAY_READS - 6, "premise: no tick is crossed, six reads");
        assertLe(q, exec, "the promise is above what the pool delivered in the same block");
        assertEq(q, exec, "the promise is not the pool's figure to the wei");
        assertEq(q, f, "an order inside one range is promised other than the single-range figure");
    }

    function _promiseAndSwap(uint256 amountIn) internal returns (uint256 f, uint256 q, uint256 left, uint256 exec) {
        uint24 priced;
        uint24 word2;
        (f, priced, word2) = _singleRange(amountIn);
        uint256 g;
        (q, left, g) = _promise(amountIn, f);
        assertEq(_frame(amountIn), q, "the frame quotes a figure the promise is not");
        exec = _swap(amountIn);
        assertEq(priced, _charged(word2), "premise: the fee the promise prices is the fee the swap paid");
        console2.log("amountIn / walk gas (cold):", amountIn, g);
        console2.log("single-range f / promise:", f, q);
        console2.log("pool delivered / reads left:", exec, left);
    }

    /// `f`: the single-range figure at the fee the walk prices.
    function _singleRange(uint256 amountIn) internal view returns (uint256 f, uint24 priced, uint24 word2) {
        uint160 sp;
        bool dyn;
        (sp, word2, dyn) = BPC.v3StateAndDynFee(USDC_TGN);
        priced = BPC.getV3Fee(USDC_TGN);
        assertEq(priced, BPC.quoteV3Fee(USDC_TGN, 0, word2, dyn), "premise: the walk and the single-range figure price one fee");
        f = BPC.outV3(amountIn, sp, BPC.getLiquidity(USDC_TGN), priced, false, 0);
    }

    function _promise(uint256 amountIn, uint256 f) internal view returns (uint256 q, uint256 left, uint256 g) {
        g = gasleft();
        (q, left) = BPC.v3PaysOnBudget(USDC_TGN, amountIn, false, f, BPC.V3_PAY_READS);
        g -= gasleft();
    }

    /// The Router's in-frame quote: the same producer on the same reads.
    function _frame(uint256 amountIn) internal view returns (uint256 frame) {
        Leg memory leg = Leg({
            pool: USDC_TGN, hooks: address(0), kind: BPC.KIND_ALGEBRA, fee: 0, tickSpacing: 0,
            zeroForOne: false, stable: false, amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        bool held;
        (frame, , held) = BPC.legQuoteImpact(
            leg, IAlgebraPoolList(USDC_TGN).token1(), IAlgebraPoolList(USDC_TGN).token0(), amountIn
        );
        assertTrue(held, "premise: the frame holds the leg");
    }

    function _swap(uint256 amountIn) internal returns (uint256 exec) {
        address tOut = IAlgebraPoolList(USDC_TGN).token0();
        address tIn = IAlgebraPoolList(USDC_TGN).token1();
        deal(tIn, address(this), amountIn);
        uint256 b = IErc20List(tOut).balanceOf(address(this));
        vm.recordLogs();
        IAlgebraPoolList(USDC_TGN).swap(address(this), false, int256(amountIn), BPC.MAX_SQRT_PRICE_MINUS_ONE, abi.encode(tIn));
        exec = IErc20List(tOut).balanceOf(address(this)) - b;
    }

    /// The fee the pool charged this contract's swap, from its Swap event.
    function _charged(uint24 word2) internal returns (uint24 charged) {
        bool seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                !seen && logs[i].emitter == USDC_TGN && logs[i].topics[0] == SWAP_TOPIC
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(this))))
            ) {
                (,,,,, uint24 overrideFee, uint24 pluginFee) =
                    abi.decode(logs[i].data, (int256, int256, uint160, uint128, int24, uint24, uint24));
                charged = (overrideFee != 0 ? overrideFee : word2) + pluginFee;
                seen = true;
            }
        }
        assertTrue(seen, "premise: the pool emitted its Swap event");
    }
}
