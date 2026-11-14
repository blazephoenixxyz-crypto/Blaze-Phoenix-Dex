// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route, Leg, PoolInfo} from "../../../src/BlazePhoenixCore.sol";
import {BscForkBase} from "./BscForkBase.sol";

interface IErc20B {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IV2PairB {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

/// @notice bsc-infinity-1106 phase B: do the venues the current Core already reaches by config
///         (Pancake V3, Uniswap V3, Pancake V2, Uniswap V4) serve WBNB -> USDT on BSC at block
///         131960000, quote equal to execution to the wei? Verification only, no src change:
///         every test pins current behaviour and has its own mutant on a src line it guards
///         (~/reports/adapters-1106/bsc/mutantes.tsv).
///         Each test wires a clean stack with ONE row, lets the Solver plan, the Quoter price
///         the plan and the Router fill it. The venues' own balance deltas prove what they paid.
contract BscCoveredVenuesFork is BscForkBase {
    // Pools the factories answered at FORK_BLOCK for (USDT, WBNB), by eth_call.
    address internal constant PCS_V3_100  = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address internal constant PCS_V3_500  = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
    address internal constant PCS_V3_2500 = 0x1401ff943D08a7E098328C1d3a9d388923B115D2;
    address internal constant UNI_V3_100  = 0x47a90A2d92A8367A91EfA1906bFc8c1E05bf10c4;
    address internal constant UNI_V3_500  = 0x6fe9E9de56356F7eDBfcBB29FAB7cd69471a4869;
    address internal constant UNI_V3_3000 = 0x7862D9B4bE2156B15d54F41ee4EDE2d5b0b455e4;
    address internal constant PCS_V2_PAIR = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;

    uint256 internal constant AMT = 5e18; // 5 WBNB

    struct Auto {
        uint256 quote; // Quoter.previewPlanExact
        uint256 exec;  // what the recipient received
        uint256 paid;  // USDT the listed venues paid, summed
        uint256 poolIn; // WBNB the listed venues received, summed
        uint256 feeIn;
        uint256 feeOut;
        uint256 kept;  // what the Router kept, both tokens summed
        uint8 kind0;   // kind of the first leg
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IErc20B(t).balanceOf(who);
    }

    /// @dev Whether the Hub's discovery for WBNB/USDT lists `venue` under `kind`.
    function _listed(address venue, uint8 kind) internal view returns (bool found) {
        PoolInfo[] memory hits = hub.discoverFor(WBNB, USDT);
        for (uint256 i; i < hits.length; ++i) {
            if (hits[i].pool == venue && hits[i].kind == kind && hits[i].active) found = true;
        }
    }

    /// @dev WBNB -> USDT through the automatic door: plan, price, fill. `venues` is the whole
    ///      candidate set of the one row; a leg outside it would leave `paid` short.
    function _autoRun(address[] memory venues) internal returns (Auto memory r) {
        (Route memory route, uint256 q) = quoter.previewPlanExact(WBNB, USDT, AMT);
        assertGt(q, 0, "the plan prices");
        assertEq(route.hops.length, 1, "direct route");
        Leg[] memory legs = route.hops[0].legs;
        r.kind0 = legs[0].kind;
        for (uint256 i; i < legs.length; ++i) console2.log("  leg", legs[i].pool, legs[i].amountIn, legs[i].expectedOut);
        r.quote = q;
        address user = makeAddr("bsc-user");
        deal(WBNB, user, AMT);
        vm.prank(user);
        IErc20B(WBNB).approve(address(router), AMT);
        uint256[] memory in0 = new uint256[](venues.length);
        uint256[] memory out0 = new uint256[](venues.length);
        for (uint256 i; i < venues.length; ++i) (in0[i], out0[i]) = (_bal(WBNB, venues[i]), _bal(USDT, venues[i]));
        uint256 fi0 = _bal(WBNB, TEST_TREASURY_1) + _bal(WBNB, TEST_TREASURY_2);
        uint256 fo0 = _bal(USDT, TEST_TREASURY_1) + _bal(USDT, TEST_TREASURY_2);
        uint256 k0 = _bal(WBNB, address(router)) + _bal(USDT, address(router));
        vm.prank(user);
        uint256 got = router.swapExactIn(route, AMT, q, user, block.timestamp + 600);
        for (uint256 i; i < venues.length; ++i) {
            r.paid += out0[i] - _bal(USDT, venues[i]);
            uint256 b = _bal(WBNB, venues[i]);
            if (b > in0[i]) r.poolIn += b - in0[i];
        }
        r.exec = _bal(USDT, user);
        r.feeIn = _bal(WBNB, TEST_TREASURY_1) + _bal(WBNB, TEST_TREASURY_2) - fi0;
        r.feeOut = _bal(USDT, TEST_TREASURY_1) + _bal(USDT, TEST_TREASURY_2) - fo0;
        r.kept = _bal(WBNB, address(router)) + _bal(USDT, address(router)) - k0;
        assertEq(got, r.exec, "the Router returns what the recipient received");
        assertEq(_bal(WBNB, user), 0, "the user spent the whole order");
        console2.log("  quote_wei", r.quote);
        console2.log("  exec_wei ", r.exec);
        console2.log("  paid     ", r.paid);
        console2.log("  pool_in  ", r.poolIn);
        console2.log("  fee_in   ", r.feeIn);
        console2.log("  fee_out  ", r.feeOut);
    }

    function _assertAuto(Auto memory r) internal pure {
        assertEq(r.quote, r.exec, "Quoter == Router, to the wei");
        assertEq(r.exec + r.feeOut, r.paid, "the row's venues paid recipient + fee");
        assertEq(r.kept, 0, "the Router keeps nothing");
    }

    // ─── Pancake V3 ───────────────────────────────────────────────────────

    /// @notice Mode 1 asks the Pancake V3 factory getPool(t0, t1, fee) at 100/500/2500/10000;
    ///         the Router answers pancakeV3SwapCallback through its universal V3 fallback.
    function test_PancakeV3_Mode1Row_AutoRoute_QuoteEqualsExec() public {
        _addV3CallRow(PANCAKE_V3_FACTORY, [uint24(100), 500, 2500, 10000], [int24(1), 10, 50, 200]);
        assertTrue(_listed(PCS_V3_100, KIND_V3), "lists the fee-100 pool");
        assertTrue(_listed(PCS_V3_500, KIND_V3), "lists the fee-500 pool");
        assertTrue(_listed(PCS_V3_2500, KIND_V3), "lists the fee-2500 pool");
        address[] memory v = new address[](3);
        (v[0], v[1], v[2]) = (PCS_V3_100, PCS_V3_500, PCS_V3_2500);
        Auto memory r = _autoRun(v);
        _assertAuto(r);
        assertEq(r.poolIn + r.feeIn, AMT, "input: venues + fee == order");
    }

    // ─── Uniswap V3 ───────────────────────────────────────────────────────

    function test_UniV3_Mode1Row_AutoRoute_QuoteEqualsExec() public {
        _addV3CallRow(UNI_V3_FACTORY, [uint24(100), 500, 3000, 10000], [int24(1), 10, 60, 200]);
        assertTrue(_listed(UNI_V3_100, KIND_V3), "lists the fee-100 pool");
        assertTrue(_listed(UNI_V3_500, KIND_V3), "lists the fee-500 pool");
        assertTrue(_listed(UNI_V3_3000, KIND_V3), "lists the fee-3000 pool");
        address[] memory v = new address[](3);
        (v[0], v[1], v[2]) = (UNI_V3_100, UNI_V3_500, UNI_V3_3000);
        Auto memory r = _autoRun(v);
        _assertAuto(r);
        assertEq(r.poolIn + r.feeIn, AMT, "input: venues + fee == order");
    }

    // ─── Pancake V2 ───────────────────────────────────────────────────────

    /// @notice Mode 0 asks getPair. The row declares no fee, so the Core prices the pair at the
    ///         house V2 fee (Core.effV2Fee: 30 bps); the pair itself charges 25 bps. The fill is
    ///         pinned to the 30-bps constant-product output on the input the pair received.
    function test_PancakeV2_Mode0Row_AutoRoute_QuoteEqualsExec_At30Bps() public {
        _addV2CallRow(PANCAKE_V2_FACTORY);
        assertTrue(_listed(PCS_V2_PAIR, KIND_V2), "lists the pair");
        (uint112 r0, uint112 r1, ) = IV2PairB(PCS_V2_PAIR).getReserves();
        bool wbnb0 = IV2PairB(PCS_V2_PAIR).token0() == WBNB;
        (uint256 rin, uint256 rout) = wbnb0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        address[] memory v = new address[](1);
        v[0] = PCS_V2_PAIR;
        Auto memory r = _autoRun(v);
        _assertAuto(r);
        assertEq(r.poolIn + r.feeIn, AMT, "input: venue + fee == order");
        uint256 out30 = (r.poolIn * 9970 * rout) / (rin * 10000 + r.poolIn * 9970);
        uint256 out25 = (r.poolIn * 9975 * rout) / (rin * 10000 + r.poolIn * 9975);
        console2.log("  pair max at 25 bps", out25);
        assertEq(r.paid, out30, "the pair paid the 30-bps constant-product output");
        assertLt(r.paid, out25, "below the pair's own 25-bps maximum (house fee, by design)");
    }

    // ─── Uniswap V4 ───────────────────────────────────────────────────────

    /// @notice The native BNB/USDT 500/10 no-hook pool on the BSC V4 PoolManager, admitted by
    ///         addV4(address(0), ...): the route speaks WBNB, the execution settles native BNB.
    function test_UniV4_NativeBnbUsdt500_AutoRoute_QuoteEqualsExec() public {
        hub.addV4(address(0), USDT, 500, 10, address(0));
        address[] memory v = new address[](1);
        v[0] = UNI_V4_PM;
        Auto memory r = _autoRun(v);
        assertEq(r.kind0, BPC.KIND_V4_NATIVE, "the leg is the native V4 kind");
        _assertAuto(r);
    }
}
