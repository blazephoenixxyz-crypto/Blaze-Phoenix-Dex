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

/// @notice The oracle: a raw exact-input swap straight on the pool, paid from its own balance in
///         the pool's callback. It shares no code with the Router, the Quoter or the Core.
contract RawV3Oracle {
    address private live;

    function swapIn(address pool, address tokenIn, bool zeroForOne, uint256 amtIn) external returns (uint256 out) {
        live = pool;
        (int256 a0, int256 a1) = IV3PoolA(pool).swap(
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
        require(msg.sender == live && live != address(0), "oracle: not the pool");
        uint256 owed = a0 > 0 ? uint256(a0) : uint256(a1);
        require(IErc20A(abi.decode(data, (address))).transfer(msg.sender, owed), "oracle: pay");
    }
}

/// @notice avax-1103 wave 2 (core-v3): do the core V3 readers serve Uniswap V3 and Pharaoh V3
///         (RamsesV3) on Avalanche, block 99270000? Verification only, no src change: there is
///         no red commit, every test is a pin of current behaviour and each one has its own
///         mutant on a src line it guards (core-v3-mutantes.tsv).
///         Oracle: RawV3Oracle above, on the same pre-state (snapshot), fed the input the pool
///         itself received during the Router's run (the pool's balance delta). The route's use
///         of the pool is proven by that pool's own balance deltas.
contract AvaxCoreV3Fork is AvaxForkBase {
    address internal constant UNI_WU_500  = 0xfAe3f424a0a47706811521E3ee268f00cFb5c45E;
    address internal constant PHX_WU_TS10 = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534;
    address internal constant T1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant T2 = address(0x7e52222222222222222222222222222222222222);

    struct Run {
        uint256 quote;    // Quoter.previewRouteExact exactOut
        uint256 exec;     // what the recipient received from Router.swapExactIn
        uint256 poolIn;   // tokenIn the pool received (balance delta)
        uint256 poolOut;  // tokenOut the pool paid (balance delta)
        uint256 feeIn;    // treasuries' tokenIn delta
        uint256 feeOut;   // treasuries' tokenOut delta
        uint256 kept;     // what the Router kept, both tokens summed (must be 0)
        uint256 oracle;   // RawV3Oracle output for poolIn, same pre-state
        uint256 coreWalk; // BPC.v4WalkOut over the pool's own book, for poolIn
        uint256 coreOne;  // BPC.universalQuote (current range only), for poolIn
        uint128 liq0;
        uint128 liq1;
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IErc20A(t).balanceOf(who);
    }

    function _leg(address pool, uint24 fee, int24 ts, bool zfo, uint256 amt) internal pure returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: KIND_V3, fee: fee, tickSpacing: ts,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: USDC, tokenOut: WAVAX, amountIn: amt, expectedOut: 0, legs: legs});
        r.hops = hops;
    }

    function _find(address pool) internal view returns (bool found, PoolInfo memory info) {
        PoolInfo[] memory hits = hub.discoverFor(USDC, WAVAX);
        for (uint256 i; i < hits.length; ++i) {
            console2.log("  hit", hits[i].pool, hits[i].fee, uint256(int256(hits[i].tickSpacing)));
            if (hits[i].pool == pool) (found, info) = (true, hits[i]);
        }
    }

    /// @dev USDC -> WAVAX through ONE pool: Quoter preview, Router execution with the pool's
    ///      and the treasuries' deltas, then (state reverted) the Core's two readers and the
    ///      raw oracle on the input the pool actually received.
    function _run(address pool, uint24 legFee, int24 legTs, uint256 amt) internal returns (Run memory r) {
        bool zfo = IV3PoolA(pool).token0() == USDC;
        (Route memory route, uint256 q) = quoter.previewRouteExact(_leg(pool, legFee, legTs, zfo, amt), amt);
        r.quote = q;
        assertGt(q, 0, "the Quoter prices the leg");
        address user = makeAddr("avax-user");
        deal(USDC, user, amt);
        vm.prank(user);
        IErc20A(USDC).approve(address(router), amt);

        uint256 snap = vm.snapshotState();
        uint256[7] memory b = [
            _bal(USDC, pool), _bal(WAVAX, pool), _bal(USDC, T1) + _bal(USDC, T2),
            _bal(WAVAX, T1) + _bal(WAVAX, T2), _bal(WAVAX, user), _bal(USDC, address(router)),
            _bal(WAVAX, address(router))
        ];
        r.liq0 = IV3PoolA(pool).liquidity();
        vm.prank(user);
        uint256 got = router.swapExactIn(route, amt, q, user, block.timestamp + 600);
        r.liq1 = IV3PoolA(pool).liquidity();
        r.poolIn = _bal(USDC, pool) - b[0];
        r.poolOut = b[1] - _bal(WAVAX, pool);
        r.feeIn = _bal(USDC, T1) + _bal(USDC, T2) - b[2];
        r.feeOut = _bal(WAVAX, T1) + _bal(WAVAX, T2) - b[3];
        r.exec = _bal(WAVAX, user) - b[4];
        r.kept = (_bal(USDC, address(router)) - b[5]) + (_bal(WAVAX, address(router)) - b[6]);
        assertEq(got, r.exec, "the Router returns what the recipient received");
        assertEq(_bal(USDC, user), 0, "the user spent the whole order");
        vm.revertToState(snap);

        // Pre-state again: the Core's readers first (views), then the oracle's real swap.
        r.coreWalk = BPC.v4WalkOut(pool, bytes32(0), r.poolIn, 0, 0, zfo);
        QuoteCtx memory c;
        (c.kind, c.pool, c.zeroForOne, c.fee, c.tickSpacing) = (KIND_V3, pool, zfo, legFee, legTs);
        (c.tokenIn, c.tokenOther, c.hub) = (USDC, WAVAX, address(hub));
        (r.coreOne, ) = BPC.universalQuote(c, r.poolIn);
        RawV3Oracle o = new RawV3Oracle();
        deal(USDC, address(o), r.poolIn);
        r.oracle = o.swapIn(pool, USDC, zfo, r.poolIn);
        assertEq(_bal(WAVAX, address(o)), r.oracle, "the oracle received what the pool declared");

        console2.log("pool", pool);
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

    /// @dev The equalities every single-pool run must hold, to the wei.
    function _assertRun(Run memory r, uint256 amt) internal pure {
        assertGt(r.poolIn, 0, "the route used this pool (input side)");
        assertGt(r.poolOut, 0, "the route used this pool (output side)");
        assertEq(r.quote, r.exec, "Quoter == Router, to the wei");
        assertEq(r.oracle, r.poolOut, "raw oracle == what the pool paid in the Router's run");
        assertEq(r.poolIn + r.feeIn, amt, "input: pool + fee == order");
        assertEq(r.exec + r.feeOut, r.poolOut, "output: recipient + fee == pool paid");
        assertEq(r.kept, 0, "the Router keeps nothing");
    }

    // ─── Uniswap V3 ───────────────────────────────────────────────────────

    /// @notice The Hub row (mode 5, V3 salt, this factory and init hash) derives the WAVAX/USDC
    ///         500 pool. Three producers agree: the CREATE2 formula written here, the Core's
    ///         deriveAddress, and the Hub's discovery; the pool itself names the factory.
    function test_UniV3_HubDerivesPool500ByCreate2() public {
        _addUniV3Row();
        bytes32 salt = keccak256(abi.encode(WAVAX, USDC, uint24(500)));
        address want = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), UNIV3_FACTORY, salt, UNIV3_INIT)))));
        assertEq(want, UNI_WU_500, "CREATE2(factory, salt, init) reproduces the pool");
        assertEq(BPC.deriveAddress(UNIV3_FACTORY, USDC, WAVAX, 500, false, 0, MODE_CREATE2_V3, UNIV3_INIT), UNI_WU_500, "Core derive");
        assertEq(IV3PoolA(UNI_WU_500).factory(), UNIV3_FACTORY, "the pool names the factory");
        assertEq(IV3PoolA(UNI_WU_500).fee(), 500, "fee tier");
        (bool found, PoolInfo memory info) = _find(UNI_WU_500);
        assertTrue(found, "the Hub row lists the pool");
        assertEq(info.kind, KIND_V3, "kind V3");
        assertEq(info.fee, 500, "listed at its tier");
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
    ///         only after the pool proves its pair (token0/token1).
    function test_PharaohV3_Mode3Row_AsksTheFactory() public {
        _addPharaohV3Row(MODE_CALL_V3CL);
        (bool found, PoolInfo memory info) = _find(PHX_WU_TS10);
        assertTrue(found, "the mode-3 row lists the ts10 pool");
        assertEq(info.kind, KIND_V3, "kind V3");
        assertEq(int256(info.tickSpacing), int256(10), "listed at its spacing");
        assertEq(IV3PoolA(PHX_WU_TS10).factory(), PHARAOH_V3_FACTORY, "the pool names the factory");
    }

    /// @notice Mode 7 derives create2(deployer, keccak(abi.encode(t0, t1, ts)), init): the
    ///         origin is the separate pool deployer, not the factory.
    function test_PharaohV3_Mode7Row_DerivesFromDeployer() public {
        _addPharaohV3Row(MODE_CREATE2_V3CL);
        bytes32 salt = keccak256(abi.encode(WAVAX, USDC, int24(10)));
        address want = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), PHARAOH_V3_DEPLOYER, salt, PHARAOH_V3_INIT)))));
        assertEq(want, PHX_WU_TS10, "CREATE2(deployer, salt, init) reproduces the pool");
        (bool found, PoolInfo memory info) = _find(PHX_WU_TS10);
        assertTrue(found, "the mode-7 row lists the ts10 pool");
        assertEq(int256(info.tickSpacing), int256(10), "listed at its spacing");
    }

    function test_PharaohV3_1000Usdc_QuoteExecOracleCore() public {
        _addPharaohV3Row(MODE_CALL_V3CL);
        (, PoolInfo memory info) = _find(PHX_WU_TS10);
        uint256 amt = 1_000e6;
        Run memory r = _run(PHX_WU_TS10, info.fee, info.tickSpacing, amt);
        _assertRun(r, amt);
        assertEq(r.coreWalk, r.oracle, "Core walk == oracle");
        // Measured on both venues at this block (Uni V3 500 and this pool, 1 000 USDC, no tick
        // crossed): the one-range closed form (universalQuote -> outV3) lands a few hundred
        // thousand wei UNDER the pool, never over it. Pinned as measured, not as exactness.
        assertEq(uint256(r.liq1), uint256(r.liq0), "1 000 USDC stays inside the current range");
        assertLe(r.coreOne, r.oracle, "the one-range closed form does not over-promise");
    }

    function test_PharaohV3_100kUsdc_CrossesTicks_QuoteExecOracleCore() public {
        _addPharaohV3Row(MODE_CALL_V3CL);
        (, PoolInfo memory info) = _find(PHX_WU_TS10);
        uint256 amt = 100_000e6;
        Run memory r = _run(PHX_WU_TS10, info.fee, info.tickSpacing, amt);
        assertTrue(r.liq1 != r.liq0, "the swap crossed an initialized tick");
        _assertRun(r, amt);
        assertEq(r.coreWalk, r.oracle, "Core walk == oracle across ticks");
    }

    /// @notice The automatic door on the mode-3 row alone: the Solver plans over the pools the
    ///         row lists, the Quoter prices the plan, the Router fills it to the wei, and every
    ///         leg's pool pays exactly its share (pool deltas).
    function test_PharaohV3_AutoRoute_1000Usdc_QuoteEqualsExec() public {
        _addPharaohV3Row(MODE_CALL_V3CL);
        uint256 amt = 1_000e6;
        (Route memory route, uint256 q) = quoter.previewPlanExact(USDC, WAVAX, amt);
        assertGt(q, 0, "the plan prices");
        assertEq(route.hops.length, 1, "direct route");
        Leg[] memory legs = route.hops[0].legs;
        uint256[] memory out0 = new uint256[](legs.length);
        for (uint256 i; i < legs.length; ++i) {
            out0[i] = _bal(WAVAX, legs[i].pool);
            console2.log("  leg", legs[i].pool, legs[i].amountIn, legs[i].expectedOut);
        }
        address user = makeAddr("avax-user");
        deal(USDC, user, amt);
        vm.prank(user);
        IErc20A(USDC).approve(address(router), amt);
        uint256 fee0 = _bal(WAVAX, T1) + _bal(WAVAX, T2);
        vm.prank(user);
        uint256 got = router.swapExactIn(route, amt, q, user, block.timestamp + 600);
        uint256 paid;
        for (uint256 i; i < legs.length; ++i) paid += out0[i] - _bal(WAVAX, legs[i].pool);
        console2.log("  auto quote_wei", q);
        console2.log("  auto exec_wei ", got);
        console2.log("  auto pools_out", paid);
        assertEq(got, q, "Quoter == Router, to the wei");
        assertEq(_bal(WAVAX, user), got, "the recipient received what the Router returned");
        assertEq(got + (_bal(WAVAX, T1) + _bal(WAVAX, T2) - fee0), paid, "the legs' pools paid recipient + fee");
    }
}
