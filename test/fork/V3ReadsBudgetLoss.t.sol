// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WHAT TWELVE READS LOSE, MEASURED ON THE POOL OF 3331 (B10).
//
//  `Core.v3PaysOnBudget` walks a V3 book on at most V3_PAY_READS reads; a walk that runs
//  out of reads prices the rest on the last range it read. That is a model, and a model
//  has a sign: on a book that thins past the last range read it promises more than the
//  pool pays (the Router refuses with RouterE(5), no funds move); on one that thickens,
//  less. This file does not assert a threshold on that error. It measures it, per size and
//  direction, against what the pool itself pays (a real swap on the fork, rolled back),
//  and asserts only the bounds that are theorems of the walk:
//    promised <= f                      the band is a ceiling (Core: `out < f ? out : f`);
//    walk16  <= paid                   the full walk (`v4WalkOut`, sixteen stretches) never
//                                      prices a range it did not read;
//    left > 0 => promised <= paid       a walk that finished inside its reads answers the
//                                      book, and the book pays what it says.
//  Each cell is printed as a ledger line (docs/assurance/v3-reads.tsv): the signed error
//  (promised - paid) / paid in ppm, and the venue's own QuoterV2 answer. A QuoterV2 that
//  reverts is `n/a`, never zero: an absent answer is a fact about the source.
//
//  Base, block 52,900,000; pool 0xC18F50d6A832f12F6DcAaeEe8D0c87A65B96787E (the WETH/DAI
//  pool of reports/plano-1026/pocs/3331.log). Sizes 1k, 10k, 100k, 1M DAI, and the same
//  notional in WETH at the pool's own price, both directions.
//
//  Mutant: Core `return (out < f ? out : f, left);` -> `return (f, left);` (the promised
//  stays the single-range figure even when the walk finished): red on the third bound.
//  Src 0: a measurement, not a fix.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IV3PoolL3 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

interface IQuoterV2L3 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory)
        external returns (uint256, uint160, uint32, uint256);
}

interface IERC20L3 {
    function transfer(address, uint256) external returns (bool);
}

/// Pays the pool from its own balance in the callback; the test funds it with `deal`.
contract V3PayerL3 {
    function swapExact(address pool, bool zfo, uint256 amountIn) external returns (uint256 paid) {
        (int256 d0, int256 d1) = IV3PoolL3(pool).swap(
            address(this), zfo, int256(amountIn),
            zfo ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341), ""
        );
        paid = uint256(-(zfo ? d1 : d0));
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        IV3PoolL3 p = IV3PoolL3(msg.sender);
        if (d0 > 0) IERC20L3(p.token0()).transfer(msg.sender, uint256(d0));
        if (d1 > 0) IERC20L3(p.token1()).transfer(msg.sender, uint256(d1));
    }
}

contract V3ReadsBudgetLoss is Test {
    uint256 internal constant BLK = 52_900_000;
    address internal constant POOL = 0xC18F50d6A832f12F6DcAaeEe8D0c87A65B96787E;
    address internal constant DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address internal constant QUOTER_V2 = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    uint256 internal constant READS = 12; // V3_PAY_READS, the frame's budget

    V3PayerL3 payer;

    function setUp() public {
        vm.createSelectFork("base", BLK);
        payer = new V3PayerL3();
    }

    function test_V3ReadsBudget_LossIsMeasuredOnThe3331Pool() public {
        IV3PoolL3 p = IV3PoolL3(POOL);
        address t0 = p.token0();
        address t1 = p.token1();
        (uint160 sp, , , , , , ) = p.slot0();
        console2.log("ledger\tpool\tblock\tdir\tsize_usd\tamount_in\tf\tpromise\tleft\twalk16\tpaid\terr_ppm\tquoterV2\tframe12");
        uint256[4] memory usd = [uint256(1_000), 10_000, 100_000, 1_000_000];
        for (uint256 k; k < 4; ++k) {
            for (uint256 d; d < 2; ++d) {
                bool zfo = d == 0;
                address tIn = zfo ? t0 : t1;
                uint256 notional = usd[k] * 1e18; // DAI raw units
                // the same notional on the other side at the pool's own price (sp^2 / 2^192)
                uint256 amt = tIn == DAI ? notional
                    : (t0 == DAI ? notional * (uint256(sp) >> 48) / (uint256(1) << 48) * (uint256(sp) >> 48) / (uint256(1) << 48)
                                 : notional * (uint256(1) << 48) / (uint256(sp) >> 48) * (uint256(1) << 48) / (uint256(sp) >> 48));
                _cell(p, zfo, tIn, zfo ? t1 : t0, usd[k], amt);
            }
        }
    }

    function _cell(IV3PoolL3 p, bool zfo, address tIn, address tOut, uint256 usd, uint256 amt) private {
        (uint160 sp, , , , , , ) = p.slot0();
        uint256 f = BPC.outV3(amt, sp, p.liquidity(), p.fee(), zfo, 0);
        (uint256 promised, uint256 left) = BPC.v3PaysOnBudget(address(p), amt, zfo, f, READS, true);
        // The frame (`rest` false) on the same reads: what the stretches it read pay, no rest.
        (uint256 frame12, ) = BPC.v3PaysOnBudget(address(p), amt, zfo, f, READS, false);
        uint256 walk16 = BPC.v4WalkOut(address(p), bytes32(0), amt, 0, 0, zfo);
        string memory q = _quoterV2(tIn, tOut, amt, p.fee());

        uint256 snap = vm.snapshotState();
        deal(tIn, address(payer), amt);
        uint256 paid = payer.swapExact(address(p), zfo, amt);
        vm.revertToState(snap);

        int256 errPpm = paid == 0 ? int256(0) : (int256(promised) - int256(paid)) * 1e6 / int256(paid);
        console2.log(string.concat(
            "ledger\t", vm.toString(address(p)), "\t", vm.toString(BLK), "\t", zfo ? "zfo" : "ofz", "\t",
            vm.toString(usd), "\t", vm.toString(amt), "\t", vm.toString(f), "\t", vm.toString(promised), "\t",
            vm.toString(left), "\t", vm.toString(walk16), "\t", vm.toString(paid), "\t",
            vm.toString(errPpm), "\t", q, "\t", vm.toString(frame12)
        ));

        assertGt(paid, 0, "the pool pays something for the cell");
        assertLe(promised, f, "the band is a ceiling on the promised");
        assertLe(walk16, paid, "the sixteen-stretch walk never prices a range it did not read");
        assertLe(frame12, paid, "the frame never quotes above what the pool pays from the same state");
        assertLe(frame12, promised, "the frame is the promise without the rest");
        if (left > 0) assertLe(promised, paid, "a walk that finished inside its reads promises what the book pays");
    }

    /// The venue's own quoter; a revert is `n/a`, never zero (an absent answer is about the source).
    function _quoterV2(address tIn, address tOut, uint256 amt, uint24 fee) private returns (string memory) {
        try IQuoterV2L3(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2L3.QuoteExactInputSingleParams(tIn, tOut, amt, fee, 0)
        ) returns (uint256 out, uint160, uint32, uint256) {
            return vm.toString(out);
        } catch {
            return "n/a";
        }
    }
}
