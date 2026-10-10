// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A FULLY BLIND LAST HOP STILL ANCHORS THE PROTOCOL FLOOR.
//
//  A leg that spends input with no attestation and no in-frame quote is blind.
//  Off the last hop it is refused; on the last hop the floor is meant to bound
//  it, through the hop's own declared figure. Red at f909422: the anchor was
//  taken only from a hop whose MEASURED delivery `hopGot` was non-zero, and a
//  blind leg is exactly the one `_execScaled` does not measure. On a last hop
//  whose every leg is blind, `hopGot == 0`, `finalHopQuote` stayed 0 and the
//  protocol floor with it: the route settled with any delivery above the
//  caller's minimum (Seavia Resources, bug bounty).
//
//  The quantity under test is `finalHopQuote` (published as
//  ExecutionProof.quoted), and through it `protocolFloorOut` (floorUsed).
//
//  The anchor only ever rises on such a hop: where an earlier hop already
//  anchored the floor in the route's output token, a blind last hop replaces
//  that anchor only with a larger figure, so it can never lower a floor the
//  route carried before. A blind last hop that declares `expectedOut == 0` and
//  follows no anchor has no figure to anchor on; that case is the one
//  test/FeeEscapeViaBridgeResidual.t.sol covers.
//
//  Oracle: the pool's own swap arithmetic (the mock executes BPC.outV3 on its
//  swap liquidity) and the floor's hard minimum, BPS - FLOOR_HARD_MAX_LOSS_BPS;
//  never the Router's floor code.
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract BlindLastHopAnchorsTheFloorTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB; // bridge: the fee lands on the last hop's input
    MockERC20 tokenC; // route output
    MockERC20 tokenD; // second bridge, for the three-hop route

    MockV3Pool pAB;
    MockV3Pool pBC;      // quotable
    MockV3Pool pBCblind; // liquidity() == 0: unpriceable in frame, still swaps
    MockV3Pool pBD;
    MockV3Pool pDCblind;
    MockV3Pool pAC;      // A -> C: an earlier hop that already makes the route's output
    MockV3Pool pCB;

    address user = address(0xBEEF);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = uint128(1e27);
    uint256 constant AMT = 1_000e18;
    /// The floor never falls below this share of its anchor, whatever the shaves.
    uint256 constant HARD_FLOOR_BPS = BPC.BPS - BPC.FLOOR_HARD_MAX_LOSS_BPS;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        tokenD = new MockERC20("D", "D");
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        hub.addBridge(address(tokenB));

        pAB = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pAB.setState(Q96, LIQ);
        pBC = new MockV3Pool(address(tokenB), address(tokenC), 3000);
        pBC.setState(Q96, LIQ);
        pBCblind = new MockV3Pool(address(tokenB), address(tokenC), 3000);
        pBCblind.setState(Q96, 0);
        pBCblind.setSwapLiquidity(LIQ);
        pBD = new MockV3Pool(address(tokenB), address(tokenD), 3000);
        pBD.setState(Q96, LIQ);
        pDCblind = new MockV3Pool(address(tokenD), address(tokenC), 3000);
        pDCblind.setState(Q96, 0);
        pDCblind.setSwapLiquidity(LIQ);

        tokenB.mint(address(pAB), 1_000_000e18);
        tokenC.mint(address(pBC), 1_000_000e18);
        tokenC.mint(address(pBCblind), 1_000_000e18);
        tokenD.mint(address(pBD), 1_000_000e18);
        tokenC.mint(address(pDCblind), 1_000_000e18);

        pAC = new MockV3Pool(address(tokenA), address(tokenC), 3000);
        pAC.setState(Q96, LIQ);
        pCB = new MockV3Pool(address(tokenC), address(tokenB), 3000);
        pCB.setState(Q96, LIQ);
        tokenC.mint(address(pAC), 1_000_000e18);
        tokenB.mint(address(pCB), 1_000_000e18);

        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    // --- builders -------------------------------------------------------------

    function _leg(MockV3Pool p, address tIn, uint256 amt, uint256 exp) private view returns (Leg memory) {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
    }

    function _q(MockV3Pool p, address tIn, uint256 amt) private view returns (uint256) {
        return BPC.outV3(amt, Q96, LIQ, 3000, p.token0() == tIn, 0);
    }

    function _hop(address tIn, address tOut, uint256 amt, uint256 exp, Leg memory l) private pure returns (Hop memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: exp, legs: ls});
    }

    function _route(Hop[] memory hs, uint256 out) private pure returns (Route memory) {
        return Route({hops: hs, totalOut: out, singleOut: out, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// A -> B -> C. `last` carries the last hop; its leg is attested with `legExp`
    /// and the hop declares `hopExp`. Returns the route and what the last hop is
    /// worth at full liquidity (the honest declaration).
    function _twoHop(MockV3Pool last, uint256 legExp, bool declare) private view returns (Route memory r, uint256 honest) {
        uint256 b = _q(pAB, address(tokenA), AMT);
        uint256 bNet = b - BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        honest = _q(pBC, address(tokenB), bNet);
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(address(tokenA), address(tokenB), AMT, b, _leg(pAB, address(tokenA), AMT, b));
        hs[1] = _hop(address(tokenB), address(tokenC), bNet, declare ? honest : 0,
            _leg(last, address(tokenB), bNet, legExp));
        r = _route(hs, honest);
    }

    /// A -> B -> D -> C with a fully blind last hop declaring its honest figure.
    function _threeHop() private view returns (Route memory r, uint256 honest) {
        uint256 b = _q(pAB, address(tokenA), AMT);
        uint256 bNet = b - BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        uint256 d = _q(pBD, address(tokenB), bNet);
        honest = _q(pDCblind, address(tokenD), d); // same geometry at full liquidity
        Hop[] memory hs = new Hop[](3);
        hs[0] = _hop(address(tokenA), address(tokenB), AMT, b, _leg(pAB, address(tokenA), AMT, b));
        hs[1] = _hop(address(tokenB), address(tokenD), bNet, d, _leg(pBD, address(tokenB), bNet, d));
        hs[2] = _hop(address(tokenD), address(tokenC), d, honest, _leg(pDCblind, address(tokenD), d, 0));
        r = _route(hs, honest);
    }

    /// A -> C -> B -> C: hop 0 already makes C and anchors the floor; the last hop is fully
    /// blind and declares `lastExp`. Returns the route and hop 0's figure.
    function _reanchor(uint256 lastExp) private view returns (Route memory r, uint256 c) {
        c = _q(pAC, address(tokenA), AMT);
        uint256 b = _q(pCB, address(tokenC), c);
        uint256 bNet = b - BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        Hop[] memory hs = new Hop[](3);
        hs[0] = _hop(address(tokenA), address(tokenC), AMT, c, _leg(pAC, address(tokenA), AMT, c));
        hs[1] = _hop(address(tokenC), address(tokenB), c, b, _leg(pCB, address(tokenC), c, b));
        hs[2] = _hop(address(tokenB), address(tokenC), bNet, lastExp, _leg(pBCblind, address(tokenB), bNet, 0));
        r = _route(hs, c);
    }

    function _e5() private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5));
    }

    function _proof() private returns (uint256 quoted, uint256 floorUsed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) {
                (quoted,, floorUsed,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
    }

    // --- the property ---------------------------------------------------------

    /// RED at f909422: a fully blind last hop that delivers a sliver of its
    /// declared figure settled with floorUsed == 0.
    function test_FullyBlindLastHop_FinalHopQuote_AnchorsTheFloor_ThinFillRefused() public {
        pBCblind.setSwapLiquidity(uint128(LIQ / 1e7));
        (Route memory r,) = _twoHop(pBCblind, 0, true);
        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// RED at f909422 for thin fills. Whatever the blind pool delivers, a
    /// settlement never lands below the floor's hard minimum of the hop's
    /// declared figure, and the published floor is armed on that figure.
    function testFuzz_FullyBlindLastHop_NeverSettlesBelowTheHardFloorOfItsDeclaredHop(uint256 div) public {
        div = bound(div, 1, 1e9);
        pBCblind.setSwapLiquidity(uint128(LIQ / div));
        (Route memory r, uint256 declared) = _twoHop(pBCblind, 0, true);
        uint256 hard = BPC.mulDiv(declared, HARD_FLOOR_BPS, BPC.BPS);
        vm.recordLogs();
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256 out) {
            (uint256 quoted, uint256 floorUsed) = _proof();
            assertEq(quoted, declared, "the blind last hop must anchor on its declared figure");
            assertGe(floorUsed, hard, "the published floor must be armed on the declared figure");
            assertGe(out, floorUsed, "a settlement must beat the published floor");
        } catch (bytes memory err) {
            assertEq(keccak256(err), keccak256(_e5()), "a refusal must be the floor's");
        }
    }

    /// One hop more: the same blind last hop at the end of a three-hop route.
    function test_ThreeHops_FullyBlindLastHop_ThinFillRefused() public {
        pDCblind.setSwapLiquidity(uint128(LIQ / 1e7));
        (Route memory r,) = _threeHop();
        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// Attacker mode: a fully blind last hop declaring nothing, after a hop that already
    /// anchored the floor in C. Taking the anchor from the blind hop unconditionally would
    /// replace that anchor with zero and disarm the floor; the anchor only rises, so the
    /// thin fill is still refused on hop 0's figure.
    function test_BlindLastHop_DeclaringNothing_CannotDisarmAnEarlierAnchor() public {
        pBCblind.setSwapLiquidity(uint128(LIQ / 1e7));
        (Route memory r,) = _reanchor(0);
        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// Fuzz the declaration below the earlier anchor: the published anchor never falls under it.
    function testFuzz_BlindLastHop_NeverLowersAnEarlierAnchor(uint256 lastExp, uint256 div) public {
        div = bound(div, 1, 1e9);
        pBCblind.setSwapLiquidity(uint128(LIQ / div));
        (, uint256 c) = _reanchor(0);
        lastExp = bound(lastExp, 0, c);
        (Route memory r,) = _reanchor(lastExp);
        vm.recordLogs();
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256 out) {
            (uint256 quoted, uint256 floorUsed) = _proof();
            assertGe(quoted, c, "a blind last hop must never lower the anchor an earlier hop set");
            assertGe(out, floorUsed, "a settlement must beat the published floor");
        } catch (bytes memory err) {
            assertEq(keccak256(err), keccak256(_e5()), "a refusal must be the floor's");
        }
    }

    // --- the neighbouring legitimate paths still settle -----------------------

    /// The same re-anchoring route with an honest fill settles on hop 0's anchor.
    function test_BlindLastHop_AfterAnEarlierAnchor_HonestFill_Settles() public {
        (Route memory r, uint256 c) = _reanchor(0);
        vm.recordLogs();
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        (uint256 quoted, uint256 floorUsed) = _proof();
        assertEq(quoted, c, "the earlier anchor stands");
        assertGe(out, floorUsed, "and the honest fill beats it");
    }

    /// A blind last hop that delivers what it declared settles, with the floor armed.
    function test_FullyBlindLastHop_HonestFill_Settles() public {
        (Route memory r, uint256 declared) = _twoHop(pBCblind, 0, true);
        vm.recordLogs();
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        (uint256 quoted, uint256 floorUsed) = _proof();
        assertEq(quoted, declared, "the honest blind hop anchors on its declaration");
        assertGe(out, floorUsed, "and beats the floor");
        assertGt(floorUsed, 0, "the floor is armed");
    }

    function test_ThreeHops_FullyBlindLastHop_HonestFill_Settles() public {
        (Route memory r,) = _threeHop();
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "the honest three-hop blind route settles");
    }

    /// The same route with the last hop priced in frame settles as before.
    function test_QuotedLastHop_HonestFill_Settles() public {
        (Route memory r, uint256 honest) = _twoHop(pBC, 0, true);
        r.hops[1].legs[0].expectedOut = honest;
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGe(out, BPC.mulDiv(honest, HARD_FLOOR_BPS, BPC.BPS), "the honest quoted route settles");
    }

    function _settles(Route memory r) private returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(user);
        try router.swapExactIn(r, AMT, 1, user, block.timestamp + 1) returns (uint256) {
            ok = true;
        } catch (bytes memory err) {
            assertEq(keccak256(err), keccak256(_e5()), "a refusal must be the floor's");
        }
        vm.revertToState(snap);
    }

    /// Fee-on-transfer neighbour: an output tax treats the blind last hop
    /// exactly as the same hop priced in frame, so the anchor adds no refusal
    /// of its own. Red at f909422 at the heavy tax, where only the blind route
    /// settled.
    function test_TaxedOutput_BlindLastHop_AgreesWithItsQuotedSibling() public {
        uint16[3] memory taxes = [uint16(50), 300, 1_000];
        bool[3] memory got;
        for (uint256 i; i < 3; ++i) {
            tokenC.setFeeOnTransferBps(taxes[i]);
            (Route memory rb,) = _twoHop(pBCblind, 0, true);
            (Route memory rq, uint256 honest) = _twoHop(pBC, 0, true);
            rq.hops[1].legs[0].expectedOut = honest;
            got[i] = _settles(rq);
            assertEq(_settles(rb), got[i], "an output tax must treat the blind last hop as its quoted sibling");
        }
        assertTrue(got[0], "a light tax settles on both");
        assertFalse(got[2], "a heavy tax is refused on both");
    }

    /// A blind last hop that declares nothing, with no earlier anchor, has no figure to
    /// anchor on: the protocol floor is not armed and the caller's minimum governs.
    function test_FullyBlindLastHop_DeclaringNothing_FallsBackToTheCallersMinimum() public {
        pBCblind.setSwapLiquidity(uint128(LIQ / 1e7));
        (Route memory r,) = _twoHop(pBCblind, 0, false);
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        (, uint256 floorUsed) = _proof();
        assertEq(floorUsed, 0, "no declared figure and no earlier anchor: the caller's minimum governs");
    }
}
