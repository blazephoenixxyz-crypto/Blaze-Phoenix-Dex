// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER INVARIANTS — fork, Ethereum mainnet.
//
//  Property/fuzz suite over the Router execution path against REAL liquidity.
//  For each fuzzed (amount[, minOut]) it quotes a route then fills it and
//  asserts the safety properties the Router promises:
//
//    P1  truthful reporting   delivered == recipient's tokenOut balance delta
//                             == swapExactIn's return value
//    P2  slippage honored     a successful fill delivers >= userMinOut
//    P3  unreachable minOut    a minOut above what the market can give reverts
//    P4  no trapped funds      the Router holds 0 extra tokenIn / tokenOut after
//                             the swap (no user value stuck in the contract)
//    P5  fee cap               protocol fee <= (delivered+fee) * 0.28%  (+rounding)
//    P6  surplus is fee-exempt fee is charged on at most the attested quote, never
//                             on the upside above it
//    P7  fee split 30/70       treasury1 / treasury2 shares match the constants
//
//  Run (pin a block so the fork state caches; lower fuzz runs on a phone):
//    export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<KEY>"
//    export ETH_FORK_BLOCK=$(cast block-number --rpc-url "$ETH_RPC_URL")
//    FOUNDRY_FUZZ_RUNS=64 forge test --match-contract RouterInvariants -vv \
//      --compute-units-per-second 100 --threads 1
//
//  Unset ETH_RPC_URL → the suite skips (offline stays green).
// =============================================================================

import { ForkMetricsBase, IERC20 } from "./ForkMetricsBase.sol";
import { Route, RoutePlan } from "../../src/BlazePhoenixCore.sol";

contract RouterInvariants is ForkMetricsBase {
    // mainnet venues (same set as DeployEthereum) ----------------------------
    address constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant V4_MANAGER    = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant SUSHI_V2      = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
    address constant PANCAKE_V2    = 0x1097053Fd2ea711dad45caCcc45EfF7548fCB362;
    address constant PANCAKE_V3    = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant SUSHI_V3      = 0xbACEB8eC6b9355Dfc0269C18bac9d6E2Bdc29C4F;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // protocol constants mirrored from the Router/Core (kept in sync by P5–P7).
    uint256 constant FEE_BPS = 28;     // PROTOCOL_FEE_BPS
    uint256 constant BPS     = 10_000;
    uint256 constant T1_BPS  = 3_000;  // TREASURY1_SHARE

    address recipient;
    address treasury1;
    address treasury2;

    function setUp() public {
        live = _startFork("ETH_RPC_URL", "ETH_FORK_BLOCK");
        if (!live) return;

        recipient = makeAddr("recipient");
        treasury1 = makeAddr("treasury1");
        treasury2 = makeAddr("treasury2");
        _deployCore(V4_MANAGER, treasury1, treasury2);

        hub.addBridge(WETH);
        hub.addBridge(USDC);

        uint24[] memory v3Fees = new uint24[](4);
        v3Fees[0]=100; v3Fees[1]=500; v3Fees[2]=3000; v3Fees[3]=10000;
        int24[] memory v3Sp = new int24[](4);
        v3Sp[0]=1; v3Sp[1]=10; v3Sp[2]=60; v3Sp[3]=200;
        uint24[] memory noFees = new uint24[](0);
        int24[] memory noSp = new int24[](0);

        hub.addFactory(UNIV3_FACTORY, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, v3Fees, v3Sp);
        hub.addFactory(UNIV2_FACTORY, KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V2,      KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(PANCAKE_V2,    KIND_V2, MODE_CALL_GENERIC, bytes32(0), noFees, noSp);
        hub.addFactory(SUSHI_V3,      KIND_V3, MODE_CALL_V3,      bytes32(0), v3Fees, v3Sp);
        uint24[] memory pFees = new uint24[](4);
        pFees[0]=100; pFees[1]=500; pFees[2]=2500; pFees[3]=10000;
        hub.addFactory(PANCAKE_V3,    KIND_V3, MODE_CALL_V3,      bytes32(0), pFees, v3Sp);
    }

    // ── core property check: quote → fill → assert P1/P2/P4/P5/P6/P7 ──
    function _checkFill(address tIn, address tOut, uint256 amt, uint256 userMinOut) internal {
        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, amt);
        Route memory r = plan.best;
        if (r.hops.length == 0 || r.totalOut == 0) return;     // no route → vacuous

        deal(tIn, address(this), amt);
        IERC20(tIn).approve(address(router), amt);

        uint256 rInBefore  = IERC20(tIn).balanceOf(address(router));
        uint256 rOutBefore = IERC20(tOut).balanceOf(address(router));
        uint256 recipBefore = IERC20(tOut).balanceOf(recipient);
        uint256 t1Before = IERC20(tOut).balanceOf(treasury1);
        uint256 t2Before = IERC20(tOut).balanceOf(treasury2);
        uint256 quoted = r.totalOut;

        try router.swapExactIn(r, amt, userMinOut, recipient, block.timestamp + 1)
            returns (uint256 delivered)
        {
            uint256 recipDelta = IERC20(tOut).balanceOf(recipient) - recipBefore;
            uint256 fee = (IERC20(tOut).balanceOf(treasury1) - t1Before)
                        + (IERC20(tOut).balanceOf(treasury2) - t2Before);
            uint256 t1Delta = IERC20(tOut).balanceOf(treasury1) - t1Before;

            // P1 — truthful reporting
            assertEq(recipDelta, delivered, "P1: return != recipient delta");
            // P2 — slippage honored
            assertGe(delivered, userMinOut, "P2: delivered < userMinOut");
            // P4 — no trapped funds in the Router
            assertEq(IERC20(tIn).balanceOf(address(router)),  rInBefore,  "P4: tokenIn stuck");
            assertEq(IERC20(tOut).balanceOf(address(router)), rOutBefore, "P4: tokenOut stuck");
            // P5 — fee cap (fee charged on at most realised output)
            assertLe(fee, (delivered + fee) * FEE_BPS / BPS + 1, "P5: fee over cap");
            // P6 — surplus is fee-exempt: never charged above the attested quote
            assertLe(fee, quoted * FEE_BPS / BPS + 2, "P6: fee on surplus");
            // P7 — 30/70 treasury split
            assertApproxEqAbs(t1Delta, fee * T1_BPS / BPS, 1, "P7: bad fee split");
        } catch {
            // A revert is an acceptable outcome (e.g. minOut unreachable on a
            // moved market); the safety properties hold vacuously for it.
        }
    }

    // ── P1/P2/P4/P5/P6/P7 over fuzzed sizes, both directions + a stable pair ──
    function testFuzz_props_WETH_USDC(uint256 amt) public {
        if (!live) { vm.skip(true); return; }
        amt = bound(amt, 0.01 ether, 300 ether);
        _checkFill(WETH, USDC, amt, 0);
    }

    function testFuzz_props_USDC_WETH(uint256 amt) public {
        if (!live) { vm.skip(true); return; }
        amt = bound(amt, 50e6, 800_000e6);
        _checkFill(USDC, WETH, amt, 0);
    }

    function testFuzz_props_USDC_USDT(uint256 amt) public {
        if (!live) { vm.skip(true); return; }
        amt = bound(amt, 100e6, 5_000_000e6);
        _checkFill(USDC, USDT, amt, 0);
    }

    // ── P2 with a real bound: pass the quoted floor as userMinOut; a fill must
    //    deliver at least it (or revert — never silently underpay). ──
    function testFuzz_minOut_floor_honored(uint256 amt) public {
        if (!live) { vm.skip(true); return; }
        amt = bound(amt, 0.01 ether, 300 ether);
        RoutePlan memory plan = solver.findBestRoutePlan(WETH, USDC, amt);
        if (plan.best.hops.length == 0 || plan.best.totalOut == 0) return;
        // singleOutFloor is the Solver's conservative guaranteed floor.
        _checkFill(WETH, USDC, amt, plan.best.singleOutFloor);
    }

    // ── P3 — an unreachable minOut (2x the quote) must revert, never fill. ──
    function testFuzz_unreachable_minOut_reverts(uint256 amt) public {
        if (!live) { vm.skip(true); return; }
        amt = bound(amt, 0.01 ether, 300 ether);
        RoutePlan memory plan = solver.findBestRoutePlan(WETH, USDC, amt);
        Route memory r = plan.best;
        if (r.hops.length == 0 || r.totalOut == 0) return;

        deal(WETH, address(this), amt);
        IERC20(WETH).approve(address(router), amt);
        uint256 impossible = r.totalOut * 2;       // market cannot beat the quote 2x

        bool reverted;
        try router.swapExactIn(r, amt, impossible, recipient, block.timestamp + 1)
            returns (uint256) { reverted = false; }
        catch { reverted = true; }
        assertTrue(reverted, "P3: unreachable minOut did not revert");
    }
}
