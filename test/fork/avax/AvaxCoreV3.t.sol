// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo, QuoteCtx} from "../../../src/BlazePhoenixCore.sol";
import {AvaxForkBase} from "./AvaxForkBase.sol";

interface IErc20A {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IV3FactoryA {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

interface IV3PoolA {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);
    function factory() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256, int256);
}

/// @notice The oracle: a raw exact-input swap straight on the V3 contract, paid from its own
///         balance in the venue's callback. It shares no code with the Router, the Quoter or the Core.
contract RawV3Oracle {
    address private live;

    function swapIn(address amm, address tokenIn, bool zeroForOne, uint256 amtIn) external returns (uint256 out) {
        live = amm;
        (int256 a0, int256 a1) = IV3PoolA(amm).swap(
            address(this), zeroForOne, int256(amtIn),
            zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341),
            abi.encode(tokenIn)
        );
        live = address(0);
        int256 o = zeroForOne ? a1 : a0;
        require(o < 0, "oracle: no output");
        out = uint256(-o);
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        require(msg.sender == live && live != address(0), "oracle: not the venue");
        uint256 owed = a0 > 0 ? uint256(a0) : uint256(a1);
        require(IErc20A(abi.decode(data, (address))).transfer(msg.sender, owed), "oracle: pay");
    }
}

/// @notice avax-1103 wave 2 (core-v3): do the core V3 readers serve Uniswap V3 and Pharaoh V3
///         (RamsesV3) on Avalanche, block 99270000? Verification only, no src change: there is
///         no red commit, every test is a pin of current behaviour and each one has its own
///         mutant on a src line it guards (core-v3-mutantes.tsv).
///         Oracle: RawV3Oracle above, on the same pre-state (snapshot), fed the input the venue
///         itself received during the Router's run (its balance delta). The route's use of the
///         venue is proven by that venue's own balance deltas.
contract AvaxCoreV3Fork is AvaxForkBase {
    address internal constant UNI_WU_500  = 0xfAe3f424a0a47706811521E3ee268f00cFb5c45E;
    address internal constant PHX_WU_TS10 = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534;
    address internal constant T1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant T2 = address(0x7e52222222222222222222222222222222222222);

    struct Run {
        uint256 quote;    // Quoter.previewRouteExact exactOut
        uint256 exec;     // what the recipient received from Router.swapExactIn
        uint256 poolIn;   // tokenIn the venue received (balance delta)
        uint256 poolOut;  // tokenOut the venue paid (balance delta)
        uint256 feeIn;    // treasuries' tokenIn delta
        uint256 feeOut;   // treasuries' tokenOut delta
        uint256 kept;     // what the Router kept, both tokens summed (must be 0)
        uint256 oracle;   // RawV3Oracle output for poolIn, same pre-state
        uint256 coreWalk; // BPC.v4WalkOut over the venue's own book, for poolIn
        uint256 coreOne;  // BPC.universalQuote (current range only), for poolIn
        uint128 liq0;
        uint128 liq1;
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IErc20A(t).balanceOf(who);
    }

    function _leg(address amm, uint24 fee, int24 ts, bool zfo, uint256 amt) internal pure returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        // Positional, in the order of src/BlazePhoenixCore.sol `Leg`: venue, hooks, kind, fee,
        // tickSpacing, zeroForOne, stable, amountIn, expectedOut, auxId.
        legs[0] = Leg(amm, address(0), KIND_V3, fee, ts, zfo, false, amt, 0, bytes32(0));
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: USDC, tokenOut: WAVAX, amountIn: amt, expectedOut: 0, legs: legs});
        r.hops = hops;
    }

    /// @dev The record the Hub must list for a V3 venue on USDC/WAVAX, every field fixed:
    ///      positional, in the order of src/BlazePhoenixCore.sol `PoolInfo` (active, stable,
    ///      kind, fee, tickSpacing, token0, token1, venue, hooks). WAVAX sorts below USDC.
    ///      fee and tickSpacing are the row's grid cells the Hub probed (Hub._probe), not the
    ///      venue's: an axis the mode never reads is its first cell (Hub._axes), so the Uni V3
    ///      row (mode 5, spacings 1/10/60/200) lists spacing 1, and the Pharaoh rows (no fee
    ///      tier) list fee 0, the fee the Core reads live at the leg.
    function _v3Record(address amm, uint24 fee, int24 ts) internal pure returns (PoolInfo memory) {
        return PoolInfo(true, false, KIND_V3, fee, ts, WAVAX, USDC, amm, address(0));
    }

    /// @dev Whether the Hub's discovery for USDC/WAVAX lists exactly `want`, field by field.
    function _lists(PoolInfo memory want) internal view returns (bool found) {
        PoolInfo[] memory hits = hub.discoverFor(USDC, WAVAX);
        bytes32 w = keccak256(abi.encode(want));
        for (uint256 i; i < hits.length; ++i) {
            console2.logBytes(abi.encode(hits[i]));
            if (keccak256(abi.encode(hits[i])) == w) found = true;
        }
    }

    /// @dev USDC -> WAVAX through ONE venue: Quoter preview, Router execution with the venue's
    ///      and the treasuries' deltas, then (state reverted) the Core's two readers and the
    ///      raw oracle on the input the venue actually received.
    function _run(address amm, uint24 legFee, int24 legTs, uint256 amt) internal returns (Run memory r) {
        bool zfo = IV3PoolA(amm).token0() == USDC;
        (Route memory route, uint256 q) = quoter.previewRouteExact(_leg(amm, legFee, legTs, zfo, amt), amt);
        r.quote = q;
        assertGt(q, 0, "the Quoter prices the leg");
        address user = makeAddr("avax-user");
        deal(USDC, user, amt);
        vm.prank(user);
        IErc20A(USDC).approve(address(router), amt);

        uint256 snap = vm.snapshotState();
        uint256[7] memory b = [
            _bal(USDC, amm), _bal(WAVAX, amm), _bal(USDC, T1) + _bal(USDC, T2),
            _bal(WAVAX, T1) + _bal(WAVAX, T2), _bal(WAVAX, user), _bal(USDC, address(router)),
            _bal(WAVAX, address(router))
        ];
        r.liq0 = IV3PoolA(amm).liquidity();
        vm.prank(user);
        uint256 got = router.swapExactIn(route, amt, q, user, block.timestamp + 600);
        r.liq1 = IV3PoolA(amm).liquidity();
        r.poolIn = _bal(USDC, amm) - b[0];
        r.poolOut = b[1] - _bal(WAVAX, amm);
        r.feeIn = _bal(USDC, T1) + _bal(USDC, T2) - b[2];
        r.feeOut = _bal(WAVAX, T1) + _bal(WAVAX, T2) - b[3];
        r.exec = _bal(WAVAX, user) - b[4];
        r.kept = (_bal(USDC, address(router)) - b[5]) + (_bal(WAVAX, address(router)) - b[6]);
        assertEq(got, r.exec, "the Router returns what the recipient received");
        assertEq(_bal(USDC, user), 0, "the user spent the whole order");
        vm.revertToState(snap);

        // Pre-state again: the Core's readers first (views), then the oracle's real swap.
        r.coreWalk = BPC.v4WalkOut(amm, bytes32(0), r.poolIn, 0, 0, zfo);
        // Positional, in the order of src/BlazePhoenixCore.sol `QuoteCtx`: kind, venue,
        // zeroForOne, fee, tickSpacing, stable, tokenIn, tokenOther, hooks, v4Manager, hub,
        // decIn1, decOther1 (0 = not filled in, the Core reads the decimals itself).
        QuoteCtx memory c = QuoteCtx(
            KIND_V3, amm, zfo, legFee, legTs, false, USDC, WAVAX, address(0), address(0), address(hub), 0, 0
        );
        (r.coreOne, , , ) = BPC.universalQuoteRank(c, r.poolIn, type(uint256).max, false);
        RawV3Oracle o = new RawV3Oracle();
        deal(USDC, address(o), r.poolIn);
        r.oracle = o.swapIn(amm, USDC, zfo, r.poolIn);
        assertEq(_bal(WAVAX, address(o)), r.oracle, "the oracle received what the venue declared");

        console2.log("venue", amm);
        console2.log("  amountIn  ", amt);
        console2.log("  quote_wei ", r.quote);
        console2.log("  exec_wei  ", r.exec);
        console2.log("  pool_in   ", r.poolIn);
        console2.log("  pool_out  ", r.poolOut);
        console2.log("  oracle_wei", r.oracle);
        console2.log("  fee_in    ", r.feeIn);
        console2.log("  fee_out   ", r.feeOut);
        console2.log("  kept      ", r.kept);
        console2.log("  core_walk ", r.coreWalk);
        console2.log("  core_one  ", r.coreOne);
        console2.log("  liq_before", uint256(r.liq0));
        console2.log("  liq_after ", uint256(r.liq1));
    }

    /// @dev The equalities every single-venue run must hold, to the wei.
    function _assertRun(Run memory r, uint256 amt) internal pure {
        assertGt(r.poolIn, 0, "the route used this venue (input side)");
        assertGt(r.poolOut, 0, "the route used this venue (output side)");
        assertEq(r.quote, r.exec, "Quoter == Router, to the wei");
        assertEq(r.oracle, r.poolOut, "raw oracle == what the venue paid in the Router's run");
        assertEq(r.poolIn + r.feeIn, amt, "input: venue + fee == order");
        assertEq(r.exec + r.feeOut, r.poolOut, "output: recipient + fee == venue paid");
        assertEq(r.kept, 0, "the Router keeps nothing");
    }

    // ─── Uniswap V3 ───────────────────────────────────────────────────────

    /// @notice The Hub row (mode 5, V3 salt, this factory and init hash) derives the WAVAX/USDC
    ///         500 venue. Three producers agree: the CREATE2 formula written here, the Core's
    ///         deriveAddress, and the Hub's discovery; the venue itself names the factory.
    function test_UniV3_HubDerivesPool500ByCreate2() public {
        _addUniV3Row();
        bytes32 salt = keccak256(abi.encode(WAVAX, USDC, uint24(500)));
        address want = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), UNIV3_FACTORY, salt, UNIV3_INIT)))));
        assertEq(want, UNI_WU_500, "CREATE2(factory, salt, init) reproduces the venue");
        assertEq(BPC.deriveAddress(UNIV3_FACTORY, USDC, WAVAX, 500, false, 0, MODE_CREATE2_V3, UNIV3_INIT), UNI_WU_500, "Core derive");
        assertEq(IV3PoolA(UNI_WU_500).factory(), UNIV3_FACTORY, "the venue names the factory");
        assertEq(IV3PoolA(UNI_WU_500).fee(), 500, "fee tier");
        assertTrue(_lists(_v3Record(UNI_WU_500, 500, 1)), "the Hub row lists the venue: kind V3, at its tier, spacing cell 1");
    }

    function test_UniV3_1000Usdc_QuoteEqualsExecEqualsOracle() public {
        _addUniV3Row();
        uint256 amt = 1_000e6;
        Run memory r = _run(UNI_WU_500, 500, 10, amt);
        _assertRun(r, amt);
        assertEq(r.coreWalk, r.oracle, "Core walk == oracle");
    }

    // ─── Pharaoh V3 (RamsesV3) ────────────────────────────────────────────

    /// @notice Mode 3 asks the factory getPool(t0, t1, tickSpacing); the Hub keeps the answer
    ///         only after the venue proves its pair (token0/token1).
    function test_PharaohV3_Mode3Row_AsksTheFactory() public {
        _addPharaohV3Row(MODE_CALL_V3CL);
        assertTrue(_lists(_v3Record(PHX_WU_TS10, 0, 10)), "the mode-3 row lists the ts10 venue: kind V3, at its spacing, fee 0");
        assertEq(IV3PoolA(PHX_WU_TS10).factory(), PHARAOH_V3_FACTORY, "the venue names the factory");
    }

    /// @notice Mode 7 derives create2(deployer, keccak(abi.encode(t0, t1, ts)), init): the
    ///         origin is the separate deployer contract, not the factory.
    function test_PharaohV3_Mode7Row_DerivesFromDeployer() public {
        _addPharaohV3Row(MODE_CREATE2_V3CL);
        bytes32 salt = keccak256(abi.encode(WAVAX, USDC, int24(10)));
        address want = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), PHARAOH_V3_DEPLOYER, salt, PHARAOH_V3_INIT)))));
        assertEq(want, PHX_WU_TS10, "CREATE2(deployer, salt, init) reproduces the venue");
        assertTrue(_lists(_v3Record(PHX_WU_TS10, 0, 10)), "the mode-7 row lists the ts10 venue at its spacing");
    }

    function test_PharaohV3_1000Usdc_QuoteExecOracleCore() public {
        _addPharaohV3Row(MODE_CALL_V3CL);
        assertTrue(_lists(_v3Record(PHX_WU_TS10, 0, 10)), "listed");
        uint256 amt = 1_000e6;
        Run memory r = _run(PHX_WU_TS10, 0, 10, amt);
        _assertRun(r, amt);
        assertEq(r.coreWalk, r.oracle, "Core walk == oracle");
        // Measured on both venues at this block (Uni V3 500 and this one, 1 000 USDC, no tick
        // crossed): the one-range closed form (universalQuote -> outV3) lands a few hundred
        // thousand wei UNDER the venue, never over it. Pinned as measured, not as exactness.
        assertEq(uint256(r.liq1), uint256(r.liq0), "1 000 USDC stays inside the current range");
        assertLe(r.coreOne, r.oracle, "the one-range closed form does not over-promise");
    }

    function test_PharaohV3_100kUsdc_CrossesTicks_QuoteExecOracleCore() public {
        _addPharaohV3Row(MODE_CALL_V3CL);
        assertTrue(_lists(_v3Record(PHX_WU_TS10, 0, 10)), "listed");
        uint256 amt = 100_000e6;
        Run memory r = _run(PHX_WU_TS10, 0, 10, amt);
        assertTrue(r.liq1 != r.liq0, "the swap crossed an initialized tick");
        _assertRun(r, amt);
        assertEq(r.coreWalk, r.oracle, "Core walk == oracle across ticks");
    }

    /// @notice The automatic door on the mode-3 row alone: the Solver plans over the venues the
    ///         row lists, the Quoter prices the plan, the Router fills it to the wei, and the
    ///         row's venues together pay exactly recipient + fee (their own balance deltas).
    function test_PharaohV3_AutoRoute_1000Usdc_QuoteEqualsExec() public {
        _addPharaohV3Row(MODE_CALL_V3CL);
        uint256 amt = 1_000e6;
        (Route memory route, uint256 q) = quoter.previewPlanExact(USDC, WAVAX, amt);
        assertGt(q, 0, "the plan prices");
        assertEq(route.hops.length, 1, "direct route");
        Leg[] memory legs = route.hops[0].legs;
        for (uint256 i; i < legs.length; ++i) console2.log("  leg", legs[i].amountIn, legs[i].expectedOut);
        // The candidate set: every venue the mode-3 row can list, the factory's answer at each
        // of the row's spacings (AvaxForkBase._addPharaohV3Row). A leg outside it would leave
        // the sum below recipient + fee.
        int24[6] memory sp = [int24(1), 5, 10, 50, 100, 200];
        address[] memory venues = new address[](6);
        uint256[] memory out0 = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            venues[i] = IV3FactoryA(PHARAOH_V3_FACTORY).getPool(WAVAX, USDC, sp[i]);
            out0[i] = _bal(WAVAX, venues[i]);
        }
        address user = makeAddr("avax-user");
        deal(USDC, user, amt);
        vm.prank(user);
        IErc20A(USDC).approve(address(router), amt);
        uint256 fee0 = _bal(WAVAX, T1) + _bal(WAVAX, T2);
        vm.prank(user);
        uint256 got = router.swapExactIn(route, amt, q, user, block.timestamp + 600);
        uint256 paid;
        for (uint256 i; i < 6; ++i) paid += out0[i] - _bal(WAVAX, venues[i]);
        console2.log("  auto quote_wei ", q);
        console2.log("  auto exec_wei  ", got);
        console2.log("  auto venues_out", paid);
        assertEq(got, q, "Quoter == Router, to the wei");
        assertEq(_bal(WAVAX, user), got, "the recipient received what the Router returned");
        assertEq(got + (_bal(WAVAX, T1) + _bal(WAVAX, T2) - fee0), paid, "the row's venues paid recipient + fee");
    }
}
