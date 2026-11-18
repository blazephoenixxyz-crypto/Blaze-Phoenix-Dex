// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title  A leg's fee-on-transfer ratio is the one the leg measured, never one recovered from
///         the route's compound.
/// @notice RED at 2c8cbbe. `_execScaled` recovered a leg's local net ratio by difference from
///         the compounded slot (`after * BPS / prev`), and `_noteFot` kept that slot in whole
///         basis points, never below 1. Two errors follow, in opposite directions:
///           - the compound saturates at 1 and the recovered ratio is larger than the leg's own
///             (714 bps for a leg that kept 100): an honest fill is refused, `RouterE(5)`;
///           - at a slot of 2 or 3 the division is coarse (2 -> 1 reads as 5000 bps for a leg
///             that kept 9999): the leg gate asks 40% of the attestation instead of 80%.
///         The leg's ratio is `took / amt`, both measured by the leg itself. The slot keeps the
///         route's compound in WAD, and a ratio it cannot represent is refused.
///
///         Matrix (range x vector x dimension):
///           range     pull net {999 wei, 1e6 wei, 1 bp, 2 bps, 14 bps, 100 bps, fuzz 1..5000 bps}
///                     x push net {1 bp, 100, 9993, 9999 bps, fuzz 1..10000, none};
///                     the leg gate at its exact wei and one wei under it; the route floor
///                     at its exact wei and one wei under it, with every leg gate cleared
///           vector    pool {honest, pays half, pays an exact amount}; venue {V2, Solidly, V3
///                     partial take}; tax on {pull, push, push to one pool of a split hop,
///                     second hop's push}
///           dimension unit, fuzz, boundary; 1 hop and 2 hops; 1 leg and 2 legs; ERC20.

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {SolidlyPairK} from "./RouterFotSolidly.t.sol";

/// @notice A token taxed per lane: `transferFrom` keeps `pullNetBps` (or exactly `pullWei` when
///         set), `transfer` sent by `taxedSender` (to `taxedTo` only, when set) keeps
///         `pushNetBps`. The rest is burned.
contract LaneTaxToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public pullNetBps = 10_000;
    uint256 public pushNetBps = 10_000;
    uint256 public pullWei;
    address public taxedSender;
    address public taxedTo;

    function set(uint256 pull, uint256 push, uint256 pullWei_, address sender) external {
        (pullNetBps, pushNetBps, pullWei, taxedSender) = (pull, push, pullWei_, sender);
    }
    function setTaxedTo(address to) external { taxedTo = to; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        bool taxed = msg.sender == taxedSender && (taxedTo == address(0) || to == taxedTo);
        balanceOf[to] += taxed ? a * pushNetBps / 10_000 : a;
        return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        allowance[from][msg.sender] -= a;
        balanceOf[from] -= a;
        balanceOf[to] += pullWei != 0 ? pullWei : a * pullNetBps / 10_000;
        return true;
    }
}

interface IERC20Bal {
    function transfer(address to, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @notice A V2-shaped pair that pays `payBps` of what it is asked, or exactly `payWei` when
///         set: the observable effect of a sandwich, to the wei, without staging one.
contract DialV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public payBps = 10_000;
    uint256 public payWei;

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function setPayBps(uint256 b) external { payBps = b; }
    function setPayWei(uint256 w) external { payWei = w; }
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20Bal(token0).transfer(to, payWei != 0 ? payWei : amount0Out * payBps / 10_000);
        if (amount1Out > 0) IERC20Bal(token1).transfer(to, payWei != 0 ? payWei : amount1Out * payBps / 10_000);
        reserve0 = uint112(IERC20Bal(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Bal(token1).balanceOf(address(this)));
    }
}

interface IV3Callback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice A V3-shaped pool that takes `takeBps` of the order and pays `takeBps` of its output:
///         a partial fill, honestly declared.
contract PartialV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    uint128 public liquidity = 1e27;
    uint256 public takeBps = 10_000;

    constructor(address a, address b, uint24 f) { (token0, token1) = a < b ? (a, b) : (b, a); fee = f; }

    function setTakeBps(uint256 b) external { takeBps = b; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external returns (int256 amount0, int256 amount1)
    {
        uint256 amtIn = uint256(amountSpecified) * takeBps / 10_000;
        uint256 amtOut = BPC.outV3(uint256(amountSpecified), sqrtPriceX96, liquidity, fee, zeroForOne, 0) * takeBps / 10_000;
        (amount0, amount1) = zeroForOne
            ? (int256(amtIn), -int256(amtOut)) : (-int256(amtOut), int256(amtIn));
        IV3Callback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        IERC20Bal(zeroForOne ? token1 : token0).transfer(recipient, amtOut);
    }
}

contract FotLegRatioIsMeasuredTest is Test {
    BlazePhoenixRouter router;
    LaneTaxToken tokenIn;
    MockERC20 tokenOut;
    DialV2Pair pair;
    address user = address(0x5E4);

    uint256 constant AMOUNT_IN = 1_000e18;
    uint112 constant R_IN = 100_000e18;
    uint112 constant R_OUT = 100_000e18;

    function setUp() public {
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this));
        tokenIn = new LaneTaxToken();
        tokenOut = new MockERC20("Out", "OUT");
        pair = new DialV2Pair(address(tokenIn), address(tokenOut));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0x7451), address(0x7452));
        tokenIn.mint(user, AMOUNT_IN);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _seed(uint112 rIn, uint112 rOut) private {
        tokenIn.mint(address(pair), rIn);
        tokenOut.mint(address(pair), rOut);
        bool inIs0 = address(tokenIn) < address(tokenOut);
        pair.setReserves(inIs0 ? rIn : rOut, inIs0 ? rOut : rIn);
    }

    function _outV2(uint256 a, uint256 rIn, uint256 rOut) private pure returns (uint256) {
        return (a * 9970 * rOut) / (rIn * 10_000 + a * 9970);
    }

    /// @dev One V2 leg attested at the honest quote of the nominal input.
    function _route(uint256 q) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tokenIn) < address(tokenOut), stable: false,
            amountIn: AMOUNT_IN, expectedOut: q, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenIn), tokenOut: address(tokenOut), amountIn: AMOUNT_IN, expectedOut: q, legs: legs});
        r = Route({hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _swap() private returns (uint256) {
        vm.prank(user);
        return router.swapExactIn(_route(_outV2(AMOUNT_IN, R_IN, R_OUT)), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    /// @notice The pull keeps 14 bps and the push 100 bps: the compound is 0.14 bps. The leg kept
    ///         1% and the honest pool pays the constant-product output of that 1%.
    function test_HonestFill_CompoundBelowOneBp_Settles() public {
        _seed(R_IN, R_OUT);
        tokenIn.set(14, 100, 0, address(router));
        uint256 out = _swap();
        assertGt(out, 0, "an honest fill of a heavily taxed leg settles");
        assertEq(tokenOut.balanceOf(user), out, "the user holds what was reported");
    }

    /// @notice The pull keeps 2 bps, the push 9999 bps, and the pool pays half of what it owes.
    ///         The leg kept 99.99% of its input: half the attestation is under the 80% leg floor.
    function test_HalfPaidLeg_AfterAHeavyPull_IsRefusedByTheLegFloor() public {
        _seed(R_IN, R_OUT);
        tokenIn.set(2, 9_999, 0, address(router));
        pair.setPayBps(5_000);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        _swap();
    }

    /// @notice Control: the same route with the pool paying in full settles, before and after.
    function test_Control_HeavyPull_HonestPool_Settles() public {
        _seed(R_IN, R_OUT);
        tokenIn.set(2, 9_999, 0, address(router));
        assertGt(_swap(), 0, "the honest fill settles");
    }

    /// @notice 999 wei out of 1000e18 arrive: under one part in 1e18 the ratio has no
    ///         representation, and zero means "no tax seen". The swap is refused; no figure is
    ///         written in its place. (At 2c8cbbe the slot was set to 1 bp and this settled.)
    function test_RatioWithNoRepresentation_IsRefused() public {
        _seed(1e18, 1e24);
        tokenIn.set(0, 10_000, 999, address(router));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(_route(_outV2(AMOUNT_IN, 1e18, 1e24)), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    /// @notice The same refusal on the compound: 1e6 wei of 1000e18 is 1000 parts in 1e18, and a
    ///         push that keeps 1 bp of it takes the product under one part.
    function test_CompoundWithNoRepresentation_IsRefused() public {
        _seed(1e18, 1e24);
        tokenIn.set(0, 1, 1e6, address(router));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(_route(_outV2(AMOUNT_IN, 1e18, 1e24)), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    /// @dev What the door sends to the leg: the measured pull less the protocol fee, which is
    ///      charged on the input here (no bridge token on the route) and rounds up.
    function _legIn(uint256 received) private pure returns (uint256) {
        return received - BPC.mulDivUp(received, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// @dev The leg gate, to the wei: 80% (rounded up) of the attestation scaled to the amount
    ///      sent, then to the share of it the pool received (rounded up).
    function _gate(uint256 q, uint256 amt, uint256 took) private pure returns (uint256) {
        uint256 b = BPC.mulDiv(q, amt, AMOUNT_IN);
        if (took < amt) b = BPC.mulDivUp(b, took, amt);
        return BPC.mulDivUp(b, BPC.LEG_FLOOR_BPS, BPC.BPS);
    }

    /// @notice The gate sits where the measurement puts it, to the wei. The pull keeps 1% (the
    ///         route floor is then far below), the push 9993 bps; the parameters are chosen so
    ///         that the scaled bound has a remainder and rounding it down moves the gate by one.
    function test_LegGate_ToTheWei_AndOneWeiUnder() public {
        uint256 q = _outV2(AMOUNT_IN, R_IN, R_OUT);
        uint256 amt = _legIn(AMOUNT_IN * 100 / 10_000);
        uint256 took = amt * 9_993 / 10_000;
        uint256 b = BPC.mulDiv(q, amt, AMOUNT_IN);
        assertTrue(mulmod(b, took, amt) != 0, "the scaled bound has a remainder");
        assertEq(BPC.mulDiv(b, took, amt) % 5, 0, "rounding it down would move the gate");
        uint256 gate = _gate(q, amt, took);
        assertEq(gate, BPC.mulDiv(BPC.mulDiv(b, took, amt), 8_000, 10_000) + 1, "the gate rounds up twice");

        _seed(R_IN, R_OUT);
        tokenIn.set(100, 9_993, 0, address(router));
        uint256 snap = vm.snapshotState();
        pair.setPayWei(gate - 1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        _swap();
        vm.revertToState(snap);
        pair.setPayWei(gate);
        assertEq(_swap(), gate, "the gate itself settles");
    }

    /// @notice Across pull and push taxes and across what the pool pays: the swap settles exactly
    ///         when the leg delivered its gate, and an honest pool always does. The pull keeps at
    ///         most half so that the leg gate, not the route floor, is the bound that binds.
    function testFuzz_LegGateFollowsTheMeasuredRatio(uint256 pull, uint256 push, uint256 pay) public {
        pull = bound(pull, 1, 5_000);
        push = bound(push, 1, 10_000);
        pay = bound(pay, 5_000, 10_000);
        uint256 amt = _legIn(AMOUNT_IN * pull / 10_000);
        uint256 took = amt * push / 10_000;
        uint256 owed = BPC.outV2(took, R_IN, R_OUT, BPC.effV2Fee(30));
        uint256 gate = _gate(_outV2(AMOUNT_IN, R_IN, R_OUT), amt, took);
        assertGe(owed, gate, "an honest pool always clears the gate");

        _seed(R_IN, R_OUT);
        tokenIn.set(pull, push, 0, address(router));
        pair.setPayBps(pay);
        uint256 paid = owed * pay / 10_000;
        if (paid < gate) {
            vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
            _swap();
        } else {
            assertEq(_swap(), paid, "at or above the gate the swap settles");
        }
    }

    /// @dev The protocol floor and the quote the swap just used, read off its `ExecutionProof`.
    function _proof() private returns (uint256 quoted, uint256 floorUsed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != BlazePhoenixRouter.ExecutionProof.selector) continue;
            (quoted,, floorUsed,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            return (quoted, floorUsed);
        }
        revert("no ExecutionProof");
    }

    /// @notice The route floor is re-priced by the compound in WAD, to the wei, and here it is the
    ///         only bound that refuses. Only the push is taxed (it keeps 99%): the leg is quoted
    ///         before the push, so the untaxed run prices the same leg and gives the floor `p0`
    ///         before re-pricing. The taxed floor is `ceil(p0 * compound / WAD)` with
    ///         `compound = took * WAD / amt`; one wei under it is refused, the floor itself
    ///         settles, and the leg gate sits far below both. Reading the slot at any other unit
    ///         (a belt that caps it at `BPS`) drops this floor to about nothing and the wei under
    ///         it settles.
    function test_RouteFloor_ToTheWei_IsTheOnlyRefuser() public {
        _seed(R_IN, R_OUT);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _swap();
        (uint256 q0, uint256 p0) = _proof();
        vm.revertToState(snap);

        uint256 amt = _legIn(AMOUNT_IN);
        uint256 took = amt * 9_900 / 10_000;
        uint256 compound = BPC.mulDiv(took, BPC.WAD, amt);
        assertEq(compound, 99e16, "the compound is the push's 99%");
        assertTrue(mulmod(p0, compound, BPC.WAD) != 0, "the re-priced floor has a remainder");
        uint256 floor = BPC.mulDivUp(p0, compound, BPC.WAD);
        assertLt(_gate(_outV2(AMOUNT_IN, R_IN, R_OUT), amt, took), floor - 1, "the leg gate is not the bound");
        assertLt(floor, BPC.outV2(took, R_IN, R_OUT, BPC.effV2Fee(30)), "an honest pool clears the floor");

        tokenIn.set(10_000, 9_900, 0, address(router));
        snap = vm.snapshotState();
        pair.setPayWei(floor - 1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        _swap();
        vm.revertToState(snap);
        pair.setPayWei(floor);
        vm.recordLogs();
        assertEq(_swap(), floor, "the floor itself settles");
        (uint256 q1, uint256 p1) = _proof();
        assertEq(q1, q0, "the push tax does not move the quote");
        assertEq(p1, floor, "the floor used is the re-priced one");
    }

    // ── split hop: two legs of one hop, the second one's ratio is not the first one's ──

    function _splitRoute(DialV2Pair b, uint256 q) private view returns (Route memory r) {
        r = _route(q);
        Leg[] memory legs = new Leg[](2);
        legs[0] = r.hops[0].legs[0];
        legs[0].amountIn = AMOUNT_IN / 2;
        legs[0].expectedOut = q / 2;
        // a second struct, not a second reference to the first
        legs[1] = Leg({
            pool: address(b), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: legs[0].zeroForOne, stable: false,
            amountIn: AMOUNT_IN / 2, expectedOut: q / 2, auxId: bytes32(0)
        });
        r.hops[0].legs = legs;
    }

    function _splitSetUp() private returns (DialV2Pair b, uint256 q) {
        _seed(R_IN, R_OUT);
        b = new DialV2Pair(address(tokenIn), address(tokenOut));
        tokenIn.mint(address(b), R_IN);
        tokenOut.mint(address(b), R_OUT);
        b.setReserves(R_IN, R_OUT);
        q = 2 * _outV2(AMOUNT_IN / 2, R_IN, R_OUT);
    }

    /// @notice Only the push to the second pool is taxed (it keeps 1%), after a pull that keeps
    ///         1 bp. At 2c8cbbe the slot read 1 before that leg and 1 after it, "no tax on this
    ///         leg", and the honest fill was refused.
    function test_SplitHop_SecondLegTaxedAlone_HonestFillSettles() public {
        (DialV2Pair b, uint256 q) = _splitSetUp();
        tokenIn.set(1, 100, 0, address(router));
        tokenIn.setTaxedTo(address(b));
        vm.prank(user);
        uint256 out = router.swapExactIn(_splitRoute(b, q), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertEq(tokenOut.balanceOf(user), out, "both legs settled");
    }

    /// @notice Both pushes keep 9999 bps after a pull that keeps 2 bps, and the first pool pays
    ///         half. Each leg answers for its own ratio: the first is refused.
    function test_SplitHop_FirstLegHalfPaid_IsRefused() public {
        (DialV2Pair b, uint256 q) = _splitSetUp();
        tokenIn.set(2, 9_999, 0, address(router));
        pair.setPayBps(5_000);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(_splitRoute(b, q), AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    // ── two hops: the tax of the second hop's push, after the first hop's pull ──

    function _twoHops(uint256 payBps2) private returns (Route memory r) {
        LaneTaxToken bridge = new LaneTaxToken();
        MockERC20 last = new MockERC20("Last", "LAST");
        // hop 1 pays in `bridge`: the first pair is built on (tokenIn, bridge)
        pair = new DialV2Pair(address(tokenIn), address(bridge));
        tokenIn.mint(address(pair), R_IN);
        bridge.mint(address(pair), R_OUT);
        pair.setReserves(R_IN, R_OUT);
        DialV2Pair p2 = new DialV2Pair(address(bridge), address(last));
        bridge.mint(address(p2), R_IN);
        last.mint(address(p2), R_OUT);
        p2.setReserves(R_IN, R_OUT);
        p2.setPayBps(payBps2);
        bridge.set(10_000, _hop2PushBps, 0, address(router));

        uint256 q1 = _outV2(AMOUNT_IN, R_IN, R_OUT);
        uint256 q2 = _outV2(q1, R_IN, R_OUT);
        Hop[] memory hops = new Hop[](2);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = Leg({pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tokenIn) < address(bridge), stable: false, amountIn: AMOUNT_IN, expectedOut: q1, auxId: bytes32(0)});
        Leg[] memory l2 = new Leg[](1);
        l2[0] = Leg({pool: address(p2), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(bridge) < address(last), stable: false, amountIn: q1, expectedOut: q2, auxId: bytes32(0)});
        hops[0] = Hop({tokenIn: address(tokenIn), tokenOut: address(bridge), amountIn: AMOUNT_IN, expectedOut: q1, legs: l1});
        hops[1] = Hop({tokenIn: address(bridge), tokenOut: address(last), amountIn: q1, expectedOut: q2, legs: l2});
        r = Route({hops: hops, totalOut: q2, singleOut: q2, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    uint256 private _hop2PushBps;

    /// @notice Two hops: the pull keeps 14 bps and the second hop's push 1%. The second leg's
    ///         ratio is its own 1%, not the 7% the saturated compound gave back at 2c8cbbe.
    function test_TwoHops_SecondHopTaxed_HonestFillSettles() public {
        tokenIn.set(14, 10_000, 0, address(router));
        _hop2PushBps = 100;
        Route memory r = _twoHops(10_000);
        vm.prank(user);
        assertGt(router.swapExactIn(r, AMOUNT_IN, 1, user, block.timestamp + 1), 0, "the honest fill settles");
    }

    /// @notice Two hops: the pull keeps 2 bps, the second hop's push 9999 bps, and the second
    ///         pool pays half of what it owes. Refused by that leg's floor.
    function test_TwoHops_SecondHopHalfPaid_IsRefused() public {
        tokenIn.set(2, 10_000, 0, address(router));
        _hop2PushBps = 9_999;
        Route memory r = _twoHops(5_000);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        router.swapExactIn(r, AMOUNT_IN, 1, user, block.timestamp + 1);
    }

    // ── the Solidly arm shares the producer ──

    /// @notice The same honest fill through a Solidly leg (volatile, K-checked pool): pull 14 bps,
    ///         push 1%.
    function test_SolidlyArm_HonestFill_CompoundBelowOneBp_Settles() public {
        SolidlyPairK sp = new SolidlyPairK(address(tokenIn), address(tokenOut));
        tokenIn.mint(address(sp), R_IN);
        tokenOut.mint(address(sp), R_OUT);
        sp.setReserves(R_IN, R_OUT);
        uint256 q = BPC.outSolidly(AMOUNT_IN, R_IN, R_OUT, 30, false);
        Route memory r = _route(q);
        r.hops[0].legs[0].pool = address(sp);
        r.hops[0].legs[0].kind = BPC.KIND_SOLIDLY;
        tokenIn.set(14, 100, 0, address(router));
        vm.prank(user);
        assertGt(router.swapExactIn(r, AMOUNT_IN, 1, user, block.timestamp + 1), 0, "the honest fill settles");
    }
}

/// @notice A partial take on a concentrated venue is not a transfer tax: the pool chose to
///         consume less, and its bound is not discounted for it. Only the pair arms measure a
///         taxed push, so only there does `took / amt` cut the bound.
contract PartialTakeIsNotATaxTest is Test {
    uint24 constant FEE = 3000;
    uint256 constant ASK = 1e18;
    BlazePhoenixRouter router;
    BlazePhoenixHub hub;
    PartialV3Pool pool;
    address t0;
    address t1;
    address user = address(0x5E4);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0x44));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        pool = new PartialV3Pool(t0, t1, FEE);
        MockERC20(t1).mint(address(pool), 1e24);
        hub.seedPool(address(pool), BPC.KIND_V3, FEE, address(0), t0, t1);
        MockERC20(t0).mint(user, ASK);
        vm.prank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
    }

    function _swap() private returns (uint256) {
        uint256 q = BPC.outV3(ASK, uint160(1 << 96), 1e27, FEE, true, 0);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: FEE, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: ASK, expectedOut: q, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: t0, tokenOut: t1, amountIn: ASK, expectedOut: q, legs: legs});
        Route memory r = Route({hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        vm.prank(user);
        return router.swapExactIn(r, ASK, 1, user, block.timestamp + 1);
    }

    /// @notice The pool takes half the order and pays half the output. Half the attestation is
    ///         under the 80% leg floor, and the unspent half does not lower that floor.
    function test_HalfTakenHalfPaid_OnAConcentratedLeg_IsRefused() public {
        pool.setTakeBps(5_000);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        _swap();
    }

    /// @notice Control: the same pool taking and paying in full settles.
    function test_Control_FullTake_Settles() public {
        assertGt(_swap(), 0, "the full fill settles");
    }

    /// @notice A split hop: a 1% leg on a pool that takes half and pays half, beside a 99% leg
    ///         filled in full. The hop as a whole delivers ~99.5% of its quote, above the hop
    ///         floor and the protocol floor (~96% here), so only the small leg's own floor can
    ///         refuse it, and a partial take must not discount that floor.
    function test_SplitHop_PartialTakeOnAConcentratedLeg_IsRefusedByItsLegFloor() public {
        pool.setTakeBps(5_000);
        Route memory r = _splitRoute();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5)));
        vm.prank(user);
        router.swapExactIn(r, ASK, 1, user, block.timestamp + 1);
    }

    /// @notice Control: the same split, both pools taking and paying in full, settles.
    function test_Control_SplitHop_FullTakes_Settles() public {
        assertGt(_swapSplit(), 0, "the full split settles");
    }

    function _swapSplit() private returns (uint256) {
        Route memory r = _splitRoute();
        vm.prank(user);
        return router.swapExactIn(r, ASK, 1, user, block.timestamp + 1);
    }

    /// @dev Deploys and seeds the second pool, so it runs BEFORE `vm.expectRevert` is armed.
    function _splitRoute() private returns (Route memory r) {
        PartialV3Pool big = new PartialV3Pool(t0, t1, 500);
        MockERC20(t1).mint(address(big), 1e24);
        hub.seedPool(address(big), BPC.KIND_V3, 500, address(0), t0, t1);
        uint256 a0 = ASK / 100;
        uint256 a1 = ASK - a0;
        uint256 q0 = BPC.outV3(a0, uint160(1 << 96), 1e27, FEE, true, 0);
        uint256 q1 = BPC.outV3(a1, uint160(1 << 96), 1e27, 500, true, 0);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg({pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: FEE, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: a0, expectedOut: q0, auxId: bytes32(0)});
        legs[1] = Leg({pool: address(big), hooks: address(0), kind: BPC.KIND_V3, fee: 500, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: a1, expectedOut: q1, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: t0, tokenOut: t1, amountIn: ASK, expectedOut: q0 + q1, legs: legs});
        r = Route({hops: hops, totalOut: q0 + q1, singleOut: q0 + q1, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }
}
