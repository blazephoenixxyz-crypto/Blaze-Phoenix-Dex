// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MaliciousReentrantERC20} from "./mocks/MaliciousReentrantERC20.sol";

contract BlazePhoenixRouterTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );

        tokenIn.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);

        tokenIn.mint(user, 3_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _buildRoute(uint256 amountIn, uint256 claimedTotalOut) private view returns (Route memory route) {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: amountIn, expectedOut: claimedTotalOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: claimedTotalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedTotalOut, singleOut: claimedTotalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @notice Regression for the fee-base leak: a caller who lies about
    ///         route.totalOut (understating it far below the real quote)
    ///         must no longer shrink the protocol fee down to a mere
    ///         floor-fraction of the real proceeds — the fee base must track
    ///         the ON-CHAIN quote of the legs as actually executed.
    function test_FeeBase_IgnoresLiedAboutTotalOut() public {
        uint256 amountIn = 3_000e18;
        // Saldo para DOIS swaps: o teste compara a rota mentirosa com a honesta.
        deal(address(tokenIn), user, amountIn * 4);

        uint256 realQuote = BPC.outV2(amountIn, 10_000e18, 10_000e18, 30);
        assertGt(realQuote, 0);

        // Attacker declares a near-zero totalOut/expectedOut in the Route.
        Route memory route = _buildRoute(amountIn, 1);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);

        assertApproxEqRel(delivered, realQuote, 0.01e18);

        // A FEE MUDOU DE LADO (2026-08-21). Este teste defendia contra um `totalOut` mentido
        // encolher a base da fee. Essa classe inteira desapareceu: a fee e 28 bps da ENTRADA,
        // cobrada em tokenIn ANTES de a rota correr, portanto nada que o atacante escreva na
        // Route lhe pode tocar. A defesa deixou de ser uma comparacao contra o que o bug teria
        // cobrado e passou a ser uma IGUALDADE.
        uint256 feeMentida = tokenIn.balanceOf(treasury1) + tokenIn.balanceOf(treasury2);
        assertGt(feeMentida, 0, "uma fee real tem de ter sido cobrada");
        assertEq(tokenOut.balanceOf(treasury1) + tokenOut.balanceOf(treasury2), 0,
            "e nada e cobrado do lado da saida");

        // A PROVA, e e uma IGUALDADE em vez de uma comparacao contra o que o bug teria cobrado:
        // a fee e exatamente 28 bps do que entrou. O `totalOut` mentido nao aparece em NENHUM
        // termo deste calculo — nasce antes de a Route ser lida para o que quer que seja.
        assertEq(feeMentida, (amountIn * 28) / 10_000,
            "a fee e 28 bps da entrada, e a mentira no totalOut nao lhe toca");

    }

    function test_Receive_RejectsPlainEthTransfer() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok, ) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "plain ETH transfers must revert, not be silently trapped");
    }

    // =========================================================================
    //  Input validation
    // =========================================================================

    function test_SwapExactIn_RevertsOnExpiredDeadline() public {
        vm.warp(1000);
        Route memory route = _buildRoute(1_000e18, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 4));
        router.swapExactIn(route, 1_000e18, 1, user, 999);
    }

    function test_SwapExactIn_RevertsOnZeroAmountIn() public {
        Route memory route = _buildRoute(0, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3));
        router.swapExactIn(route, 0, 0, user, block.timestamp + 1);
    }

    function test_SwapExactIn_RevertsOnEmptyHops() public {
        Route memory route;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3));
        router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    function test_SwapExactIn_RevertsWhenBelowUserMinOut() public {
        uint256 amountIn = 1_000e18;
        uint256 realQuote = BPC.outV2(amountIn, 10_000e18, 10_000e18, 30);
        Route memory route = _buildRoute(amountIn, realQuote);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 5));
        router.swapExactIn(route, amountIn, realQuote + 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  Pause
    // =========================================================================

    function test_SetPaused_BlocksSwaps() public {
        router.setPaused(true);
        Route memory route = _buildRoute(1_000e18, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 2));
        router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  Admin / control access
    // =========================================================================

    function test_SetAdmin_OnlyControl() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.setAdmin(address(0xCAFE));
    }

    function test_SetAdmin_RevertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3));
        router.setAdmin(address(0));
    }

    function test_SetAdmin_UpdatesAdmin() public {
        router.setAdmin(address(0xCAFE));
        assertEq(router.admin(), address(0xCAFE));
    }

    function test_SetTreasuries_RevertsOnEitherZero() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3));
        router.setTreasuries(address(0), treasury2);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 3));
        router.setTreasuries(treasury1, address(0));
    }

    function test_SetTreasuries_UpdatesBoth() public {
        router.setTreasuries(address(0x1111), address(0x2222));
        assertEq(router.treasury1(), address(0x1111));
        assertEq(router.treasury2(), address(0x2222));
    }

    function test_SetPermit2_OnlyControl() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.setPermit2(address(0x3333));
    }

    function test_RenounceControl_DisablesAllControlPowersPermanently() public {
        router.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.setAdmin(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.setTreasuries(address(0x1111), address(0x2222));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.setPermit2(address(0x3333));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.setPaused(true);
        // Even the (former) admin itself is locked out, not just other callers.
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.renounceControl();
    }

    // =========================================================================
    //  Universal V3-shaped callback — direct-invocation auth
    // =========================================================================

    function test_Fallback_RevertsWhenNoExpectedPoolIsSet() public {
        (bool ok, bytes memory ret) = address(router).call(
            abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", int256(1), int256(0), bytes(""))
        );
        assertFalse(ok);
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector);
    }

    function test_UnlockCallback_RevertsWhenNotV4Manager() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 6));
        router.unlockCallback("");
    }

    // =========================================================================
    //  V3 leg dispatch (previously zero coverage in this file)
    // =========================================================================

    function test_V3Leg_ExecutesAndPaysOutMatchingPoolMath() public {
        bool zfo = address(tokenIn) < address(tokenOut);
        MockV3Pool v3pool = new MockV3Pool(address(tokenIn), address(tokenOut), 3000);
        uint160 sqrtP = uint160(BPC.Q96);
        uint128 liq = 1_000_000e18;
        v3pool.setState(sqrtP, liq);
        tokenOut.mint(address(v3pool), 1_000_000e18);

        uint256 amountIn = 1_000e18;
        uint256 expectedOut = BPC.outV3(amountIn, sqrtP, liq, 3000, zfo, 0);
        assertGt(expectedOut, 0);

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(v3pool), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: expectedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: expectedOut, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: expectedOut, singleOut: expectedOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertApproxEqRel(delivered, expectedOut, 0.01e18);
    }

    function test_V3Leg_RevertsWhenPoolDemandsMoreThanCommittedInput() public {
        bool zfo = address(tokenIn) < address(tokenOut);
        MockV3Pool v3pool = new MockV3Pool(address(tokenIn), address(tokenOut), 3000);
        v3pool.setState(uint160(BPC.Q96), 1_000_000e18);
        tokenOut.mint(address(v3pool), 1_000_000e18);
        v3pool.setOverDemand(true);

        uint256 amountIn = 1_000e18;
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(v3pool), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 1, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: 1, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: 1, singleOut: 1, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 8));
        router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  Reentrancy guard — the realistic vector: token pull mid-transferFrom
    // =========================================================================

    function test_ReentrancyGuard_BlocksNestedSwapExactInDuringTokenPull() public {
        MaliciousReentrantERC20 evil = new MaliciousReentrantERC20();
        MockV2Pair evilPair = new MockV2Pair(address(evil), address(tokenOut));
        evil.mint(address(evilPair), 10_000e18);
        tokenOut.mint(address(evilPair), 10_000e18);
        evilPair.setReserves(10_000e18, 10_000e18);

        evil.mint(user, 1_000e18);
        vm.prank(user);
        evil.approve(address(router), type(uint256).max);

        bool zfo = address(evil) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(evilPair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: 100e18, expectedOut: 1, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(evil), tokenOut: address(tokenOut),
            amountIn: 100e18, expectedOut: 1, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: 1, singleOut: 1, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        bytes memory nestedCalldata = abi.encodeWithSelector(
            router.swapExactIn.selector, route, uint256(100e18), uint256(1), user, block.timestamp + 1
        );
        evil.setAttack(address(router), nestedCalldata);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, 100e18, 1, user, block.timestamp + 1);

        assertGt(delivered, 0, "the OUTER (legitimate) swap must still complete");
        assertTrue(evil.lastReentryAttempted(), "the token's transferFrom must have attempted the nested call");
        assertTrue(evil.lastReentryReverted(),
            "nrEntrant must block the nested swapExactIn call made mid-transferFrom");
        // AND IT MUST BE THE LOCK THAT REFUSED. A nested call made mid-pull
        // reverts for several reasons that have nothing to do with reentrancy,
        // so asserting only that it reverted leaves the lock unwatched: a
        // Router that never arms the lock passes the assertion above. Pin the
        // exact code.
        bytes memory ret = evil.lastReentryReturndata();
        assertEq(ret.length, 36, "nested revert must carry RouterE(uint16)");
        assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, "must be a RouterE");
        uint256 code;
        assembly { code := mload(add(ret, 36)) }
        assertEq(code, 7, "the refusal must be the reentrancy lock, RouterE(7)");
    }
}
