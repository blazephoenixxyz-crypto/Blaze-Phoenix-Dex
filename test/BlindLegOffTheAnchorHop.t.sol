// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE 2a06c38 TAKEOVER ONLY REACHES THE ANCHOR HOP.
//
//  `Router._execute` (src/BlazePhoenixRouter.sol:1356-1361) now reads
//
//      uint256 hopBase = hopQuote != 0 ? hopQuote : hopAttested;
//      if (hopBlind && route.hops[h].expectedOut > hopBase) {
//          hopBase = route.hops[h].expectedOut;
//      }
//      if (hopGot != 0 && route.hops[h].tokenOut == tokenOut)
//          finalHopQuote = hopBase;
//
//  `hopBase` is a loop-local. It is READ ONLY on the line below it, and that line
//  is gated on `route.hops[h].tokenOut == tokenOut`. On every hop that is not the
//  one producing the route's output token, the corrected base is computed and
//  thrown away in the same iteration.
//
//  So the blindness correction covers exactly one hop of a route. Layer 1
//  (Router:1312-1322) was not changed by the fix: a blind leg is still absent
//  from `hopGot` and from `hopAttested`, so an intermediate hop still compares
//  its surviving legs with themselves.
//
//  A 2-hop route puts the blind leg on hop 0. `hopBlind` is set, hop 0's own
//  `expectedOut` is declared HONESTLY (the whole hop's fair quote, so the
//  sponsor's "the caller can only push it UP" defence is satisfied), the
//  takeover fires — and the result is discarded because hop 0's tokenOut is the
//  bridge, not the route's tokenOut. Hop 1 then quotes IN FRAME against the
//  bridge balance that actually survived hop 0 (Router:776-779), so
//  `finalHopQuote` is an honest quote of the money that is left, the protocol
//  floor is 96% of that, and the swap settles.
//
//  Reported by Seavia Resources through the bug bounty programme; this file is
//  their proof of concept. Since 2026-10-07 the Router refuses a blind leg on
//  every hop but the last, whose hop-level figure the floor reads (RouterE(5)),
//  so the defect tests below are green and the sweep asserts the refusal at every
//  depth. One control changed meaning: off the last hop, a hop whose only leg is
//  unpriceable AND unattested is the blind case at full strength, so it is
//  refused; attested, the same pool still settles.
//
//  forge test --match-path 'test/BlindLegOffTheAnchorHop.t.sol' -vv
// =============================================================================

import {Test, Vm, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract BlindLegOffTheAnchorHop is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;

    MockERC20 tokenA;   // route input
    MockERC20 tokenB;   // bridge
    MockERC20 tokenC;   // route output

    MockV3Pool pGood;   // A/B, quotable, honest      — carries 5% of hop 0
    MockV3Pool pBlind;  // A/B, reports no liquidity  — carries 95% of hop 0
    MockV3Pool pHon2;   // A/B, quotable, honest      — the baseline stand-in for pBlind
    MockV3Pool pOut;    // B/C, quotable, honest      — hop 1

    address user = address(0xBEEF);

    uint160 constant Q96 = uint160(uint256(1) << 96);   // price 1.0
    uint128 constant LIQ = uint128(1e27);
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        router = new BlazePhoenixRouter(
            address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.addBridge(address(tokenB));   // the fee lands on hop 1's input

        pGood = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pGood.setState(Q96, LIQ);
        pHon2 = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pHon2.setState(Q96, LIQ);

        // The pool the frame cannot price: liquidity() answers 0, so
        // Router:828's `lq != 0` is false and legQuotes[l] stays 0. It still
        // swaps, with `swapLiquidity`.
        pBlind = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pBlind.setState(Q96, 0);

        pOut = new MockV3Pool(address(tokenB), address(tokenC), 3000);
        pOut.setState(Q96, LIQ);

        tokenB.mint(address(pGood), 1_000_000e18);
        tokenB.mint(address(pHon2), 1_000_000e18);
        tokenB.mint(address(pBlind), 1_000_000e18);
        tokenC.mint(address(pOut), 1_000_000e18);

        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _zfoAB() private view returns (bool) { return address(tokenA) < address(tokenB); }
    function _zfoBC() private view returns (bool) { return address(tokenB) < address(tokenC); }

    function _e5() private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5));
    }

    function _legAB(address pool, uint256 amt, uint256 exp) private view returns (Leg memory) {
        return Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 0, zeroForOne: _zfoAB(), stable: false,
            amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
    }

    /// Two hops, A -> B -> C. Hop 0 splits `aIn` through `p0` and `bIn` through
    /// `p1`; hop 0's own `expectedOut` is `hop0Exp` — the HONEST whole-hop quote.
    function _route(address p0, uint256 aIn, uint256 aExp, address p1, uint256 bIn, uint256 bExp, uint256 hop0Exp)
        private view returns (Route memory r)
    {
        Leg[] memory l0 = new Leg[](2);
        l0[0] = _legAB(p0, aIn, aExp);
        l0[1] = _legAB(p1, bIn, bExp);

        Leg[] memory l1 = new Leg[](1);
        uint256 outExp = BPC.outV3(hop0Exp, Q96, LIQ, 3000, _zfoBC(), 0);
        l1[0] = Leg({pool: address(pOut), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 0, zeroForOne: _zfoBC(), stable: false,
            amountIn: hop0Exp, expectedOut: outExp, auxId: bytes32(0)});

        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
            amountIn: aIn + bIn, expectedOut: hop0Exp, legs: l0});
        hops[1] = Hop({tokenIn: address(tokenB), tokenOut: address(tokenC),
            amountIn: hop0Exp, expectedOut: outExp, legs: l1});

        r = Route({hops: hops, totalOut: outExp, singleOut: outExp, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// What an honest A -> B -> C route of `AMT` is worth, net of the one
    /// protocol fee charged on the bridge coin.
    function _fairOut() private view returns (uint256) {
        uint256 b = BPC.outV3(AMT, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 fee = BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        return BPC.outV3(b - fee, Q96, LIQ, 3000, _zfoBC(), 0);
    }

    // ── THE DEFECT ────────────────────────────────────────────────────────────

    /// RED at d96c32b: the route settles and hands the user a small fraction of
    /// what the same input is worth. GREEN once the hop that went blind is
    /// bounded wherever it sits in the route.
    function test_BlindLegOnHopZeroIsRefused() public {
        pBlind.setSwapLiquidity(uint128(LIQ / 1e7));
        uint256 aIn  = AMT / 20;          // 5% priced
        uint256 bIn  = AMT - aIn;         // 95% blind
        uint256 aExp = BPC.outV3(aIn, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 hop0Exp = BPC.outV3(AMT, Q96, LIQ, 3000, _zfoAB(), 0);   // honest, whole hop

        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(
            _route(address(pGood), aIn, aExp, address(pBlind), bIn, 0, hop0Exp),
            AMT, 1, user, block.timestamp + 1
        );
    }

    /// The measurement. RED at the pin (records how little settles), GREEN with
    /// the fix (RouterE(5)).
    function test_HopZeroBleedsAndTheAnchorNeverSeesIt() public {
        pBlind.setSwapLiquidity(uint128(LIQ / 1e7));
        uint256 aIn  = AMT / 20;
        uint256 bIn  = AMT - aIn;
        uint256 aExp = BPC.outV3(aIn, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 hop0Exp = BPC.outV3(AMT, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 fair = _fairOut();

        vm.recordLogs();
        vm.prank(user);
        try router.swapExactIn(
            _route(address(pGood), aIn, aExp, address(pBlind), bIn, 0, hop0Exp),
            AMT, 1, user, block.timestamp + 1
        ) returns (uint256 out) {
            (uint256 quoted, uint256 floorUsed) = _proof();
            console2.log("hop 0 expectedOut, declared HONESTLY", hop0Exp);
            console2.log("fair output of the whole route      ", fair);
            console2.log("delivered                           ", out);
            console2.log("delivered / fair, bps               ", (out * 10_000) / fair);
            console2.log("ExecutionProof.quoted (anchor)      ", quoted);
            console2.log("ExecutionProof.floorUsed            ", floorUsed);
            console2.log("tokenA the blind pool kept          ", tokenA.balanceOf(address(pBlind)));
            console2.log("tokenA swept back to the user       ", tokenA.balanceOf(address(router)));
            assertEq(tokenA.balanceOf(address(pBlind)), bIn, "the blind pool kept its 95%");
            assertEq(tokenA.balanceOf(address(router)), 0, "nothing was swept back");
            assertGt(floorUsed, 0, "the published proof reports an ARMED floor");
            assertGt(out, 0, "and the user was paid the remainder");
            revert("PIN: hop 0 bled and every floor passed");
        } catch (bytes memory err) {
            assertEq(keccak256(err), keccak256(_e5()), "expected RouterE(5) once the fix is in");
        }
    }

    /// The same shape, swept over how thin the blind pool fills. Records where
    /// the protocol stops it — if it does.
    function test_SweepHowMuchHopZeroMayBleed() public {
        uint256[4] memory div = [uint256(1e2), 1e3, 1e5, 1e7];
        uint256 fair = _fairOut();
        for (uint256 i; i < div.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint128 l = uint128(LIQ / div[i]);
            if (l == 0) l = 1;
            pBlind.setSwapLiquidity(l);

            uint256 aIn  = AMT / 20;
            uint256 bIn  = AMT - aIn;
            uint256 aExp = BPC.outV3(aIn, Q96, LIQ, 3000, _zfoAB(), 0);
            uint256 hop0Exp = BPC.outV3(AMT, Q96, LIQ, 3000, _zfoAB(), 0);

            vm.prank(user);
            try router.swapExactIn(
                _route(address(pGood), aIn, aExp, address(pBlind), bIn, 0, hop0Exp),
                AMT, 1, user, block.timestamp + 1
            ) returns (uint256 out) {
                console2.log("SETTLED  divisor", div[i]);
                console2.log("   lost, bps    ", ((fair - out) * 10_000) / fair);
                fail("a blind leg on hop 0 settled at this depth");
            } catch (bytes memory e) {
                assertEq(keccak256(e), keccak256(_e5()), "refused, but not by the blind-leg guard");
            }
            vm.revertToState(snap);
        }
    }

    // ── THE MEASURED BASELINE ────────────────────────────────────────────────

    /// The same 95/5 split, the same thin fill, but the thin leg ATTESTED. The
    /// per-leg floor sees it and the swap is already refused at the pin, so the
    /// shortfall is not what the defect buys — the blindness is.
    function test_Control_TheSameFillAttestedIsAlreadyRefused() public {
        pBlind.setSwapLiquidity(uint128(LIQ / 1e7));
        uint256 aIn  = AMT / 20;
        uint256 bIn  = AMT - aIn;
        uint256 aExp = BPC.outV3(aIn, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 bExp = BPC.outV3(bIn, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 hop0Exp = BPC.outV3(AMT, Q96, LIQ, 3000, _zfoAB(), 0);

        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(
            _route(address(pGood), aIn, aExp, address(pBlind), bIn, bExp, hop0Exp),
            AMT, 1, user, block.timestamp + 1
        );
    }

    /// And the same route with the SINGLE-hop shape the 2a06c38 fix does cover,
    /// to show the fix is live in this build and the difference is the hop
    /// index and nothing else. Already refused at the pin.
    function test_Control_TheSameBlindLegOnTheANCHORHopIsRefused() public {
        pBlind.setSwapLiquidity(uint128(LIQ / 1e7));
        uint256 aIn  = AMT / 20;
        uint256 bIn  = AMT - aIn;
        uint256 aExp = BPC.outV3(aIn, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 hop0Exp = BPC.outV3(AMT, Q96, LIQ, 3000, _zfoAB(), 0);

        Leg[] memory l0 = new Leg[](2);
        l0[0] = _legAB(address(pGood), aIn, aExp);
        l0[1] = _legAB(address(pBlind), bIn, 0);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
            amountIn: AMT, expectedOut: hop0Exp, legs: l0});
        Route memory r = Route({hops: hops, totalOut: hop0Exp, singleOut: hop0Exp,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false});

        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    // ── THE FIX MUST NOT CLOSE A LEGITIMATE ROUTE ────────────────────────────

    /// An honest 2-hop route with a split hop 0 — both legs priceable and
    /// attested. GREEN at the pin and with the fix.
    function test_Control_AnHonestTwoHopSplitStillSettles() public {
        uint256 aIn  = AMT / 2;
        uint256 bIn  = AMT - aIn;
        uint256 aExp = BPC.outV3(aIn, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 hop0Exp = aExp * 2;
        uint256 fair = _fairOut();

        vm.prank(user);
        uint256 out = router.swapExactIn(
            _route(address(pGood), aIn, aExp, address(pHon2), bIn, aExp, hop0Exp),
            AMT, 1, user, block.timestamp + 1
        );
        console2.log("honest two-hop split delivered", out);
        console2.log("fair                          ", fair);
        assertGt(out * 10_000 / fair, 9_900, "an honest split route delivers its quote");
    }

    /// A hop whose ONLY leg is the unpriceable pool, ATTESTED, on hop 0 of a
    /// 2-hop route, still settles: NM-002 names such pools legitimately
    /// executable, and an attested leg is measured against its attestation.
    function test_Control_AnUnpriceableLegAloneOnHopZeroSettlesWhenAttested() public {
        _unpriceableAloneOnHopZero(true);
    }

    /// The same hop with no attestation is blind from end to end: nothing in
    /// the frame measured it and nothing was declared for it. Refused.
    function test_AnUnpriceableUnattestedHopZeroIsRefused() public {
        vm.expectRevert(_e5());
        this.unpriceableAloneOnHopZeroExternal(false);
    }

    function unpriceableAloneOnHopZeroExternal(bool attested) external {
        _unpriceableAloneOnHopZero(attested);
    }

    function _unpriceableAloneOnHopZero(bool attested) private {
        pBlind.setSwapLiquidity(LIQ);          // honest fill, just unpriceable
        uint256 hop0Exp = BPC.outV3(AMT, Q96, LIQ, 3000, _zfoAB(), 0);
        uint256 outExp  = BPC.outV3(hop0Exp, Q96, LIQ, 3000, _zfoBC(), 0);

        Leg[] memory l0 = new Leg[](1);
        l0[0] = _legAB(address(pBlind), AMT, attested ? hop0Exp : 0);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({pool: address(pOut), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 0, zeroForOne: _zfoBC(), stable: false,
            amountIn: hop0Exp, expectedOut: outExp, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB),
            amountIn: AMT, expectedOut: attested ? hop0Exp : 0, legs: l0});
        hops[1] = Hop({tokenIn: address(tokenB), tokenOut: address(tokenC),
            amountIn: hop0Exp, expectedOut: outExp, legs: l1});
        Route memory r = Route({hops: hops, totalOut: outExp, singleOut: outExp,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false});

        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "a hop with no priceable leg at all is still executable");
        console2.log("unpriceable-only hop 0 delivered", out);
    }

    function _proof() private returns (uint256 quoted, uint256 floorUsed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) {
                (quoted, , floorUsed, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
    }
}
