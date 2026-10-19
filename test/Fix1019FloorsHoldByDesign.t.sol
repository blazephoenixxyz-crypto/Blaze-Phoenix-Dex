// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  fix-1019 (oc-1018 H2, H4a, H4b): the per-leg and declared floors a caller
//  can switch off in a crafted route are DEFENCE IN DEPTH; the floor the user
//  asked for, `userMinOut`, still binds. These tests pin that by design.
//
//  Written at 57a4bab (origin/main). Every test here is GREEN on the unfixed
//  tree: none of these points is a defect (verdicts veredictos-1019/A). Each
//  one is paired with a mutant that turns it red, so the green watches the arm
//  that answers, not another guard with the same error code:
//    - userMinOut forwarded by the classic door (`_swap` -> `_execute`);
//    - the delivered-balance check (`delivered < userMinOut`), which is the
//      ONLY arm that sees an output-token tax (H4b);
//    - the FOT drop of `route.singleOutFloor` (pinned as the design, H4a);
//    - the blind last hop's declared figure anchoring the protocol floor (H2).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

interface IF19Erc20 {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// Fee-on-transfer token: every transfer delivers `amt - amt * feeBps / 1e4`.
contract F19FotToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint16 public feeBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; }

    function mint(address to, uint256 amt) external { totalSupply += amt; balanceOf[to] += amt; }
    function setFeeBps(uint16 bps) external { feeBps = bps; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) { return _move(msg.sender, to, amt); }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "allowance");
            allowance[from][msg.sender] = a - amt;
        }
        return _move(from, to, amt);
    }

    function _move(address from, address to, uint256 amt) private returns (bool) {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        uint256 delivered = feeBps > 0 ? amt - (amt * feeBps) / 10_000 : amt;
        balanceOf[to] += delivered;
        return true;
    }
}

/// V2-shaped pair that pays `payBps` of what it is asked (10_000 = honest).
contract F19Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public payBps = 10_000;

    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function setPayBps(uint256 b) external { payBps = b; }
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IF19Erc20(token0).transfer(to, (amount0Out * payBps) / 10_000);
        if (amount1Out > 0) IF19Erc20(token1).transfer(to, (amount1Out * payBps) / 10_000);
        reserve0 = uint112(IF19Erc20(token0).balanceOf(address(this)));
        reserve1 = uint112(IF19Erc20(token1).balanceOf(address(this)));
    }
}

contract Fix1019FotFloorsHoldTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    F19FotToken tokenA;
    F19FotToken tokenB;
    F19FotToken tokenC;
    F19FotToken tokenD;
    F19Pair pAB;
    F19Pair pBC;
    F19Pair pCD;

    address user = address(0xBEEF);
    address recip = address(0xCAFE);
    uint256 constant R = 100_000e18;
    uint256 constant AMT = 1_000e18;
    /// The declared floor the caller writes: 96 % of an independent x*y=k quote.
    uint256 constant DECLARED_FLOOR_BPS = 9_600;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        tokenA = new F19FotToken("A", "A");
        tokenB = new F19FotToken("B", "B");
        tokenC = new F19FotToken("C", "C");
        tokenD = new F19FotToken("D", "D");
        hub.addBridge(address(tokenB));
        pAB = new F19Pair(address(tokenA), address(tokenB));
        pBC = new F19Pair(address(tokenB), address(tokenC));
        pCD = new F19Pair(address(tokenC), address(tokenD));
        tokenA.mint(address(pAB), R);
        tokenB.mint(address(pAB), R);
        tokenB.mint(address(pBC), R);
        tokenC.mint(address(pBC), R);
        tokenC.mint(address(pCD), R);
        tokenD.mint(address(pCD), R);
        pAB.setReserves(uint112(R), uint112(R));
        pBC.setReserves(uint112(R), uint112(R));
        pCD.setReserves(uint112(R), uint112(R));
        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    // Oracle: the x*y=k formula with the 30 bps V2 fee, written here, not read from the Core.
    function _outV2(uint256 amtIn) private pure returns (uint256) {
        uint256 inAfterFee = amtIn * 9970;
        return (inAfterFee * R) / (R * 10_000 + inAfterFee);
    }

    function _declaredFloor(uint256 q) private pure returns (uint256) { return q * DECLARED_FLOOR_BPS / 10_000; }

    function _e5() private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5));
    }

    function _leg(F19Pair p, address tIn, uint256 amtIn, uint256 exp) private view returns (Leg memory) {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: p.token0() == tIn, stable: false, amountIn: amtIn, expectedOut: exp, auxId: bytes32(0)});
    }

    function _hop(address tIn, address tOut, uint256 amtIn, uint256 exp, Leg memory l)
        private pure returns (Hop memory)
    {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amtIn, expectedOut: exp, legs: ls});
    }

    function _route(Hop[] memory hs, uint256 out, uint256 floor) private pure returns (Route memory) {
        return Route({hops: hs, totalOut: out, singleOut: out, singleOutFloor: floor,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _twoHop(uint256 floor) private view returns (Route memory) {
        uint256 q0 = _outV2(AMT);
        uint256 q1 = _outV2(q0);
        Hop[] memory hs = new Hop[](2);
        hs[0] = _hop(address(tokenA), address(tokenB), AMT, q0, _leg(pAB, address(tokenA), AMT, q0));
        hs[1] = _hop(address(tokenB), address(tokenC), q0, q1, _leg(pBC, address(tokenB), q0, q1));
        return _route(hs, q1, floor);
    }

    function _threeHop(uint256 floor) private view returns (Route memory) {
        uint256 q0 = _outV2(AMT);
        uint256 q1 = _outV2(q0);
        uint256 q2 = _outV2(q1);
        Hop[] memory hs = new Hop[](3);
        hs[0] = _hop(address(tokenA), address(tokenB), AMT, q0, _leg(pAB, address(tokenA), AMT, q0));
        hs[1] = _hop(address(tokenB), address(tokenC), q0, q1, _leg(pBC, address(tokenB), q0, q1));
        hs[2] = _hop(address(tokenC), address(tokenD), q1, q2, _leg(pCD, address(tokenC), q1, q2));
        return _route(hs, q2, floor);
    }

    /// H4a, first hop FOT: the input tax drops `singleOutFloor` (documented,
    /// Router `fotSeen != 0` branch), the 82 % pool slips under it, and the
    /// caller's own userMinOut at that same floor refuses the swap.
    function test_H4a_FirstHopFot_HonestUserMinOut_RevertsRouterE5() public {
        tokenA.setFeeBps(500);
        pAB.setPayBps(8_200);
        uint256 floor = _declaredFloor(_outV2(_outV2(AMT)));
        Route memory r = _twoHop(floor);
        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, floor, recip, block.timestamp + 1);
    }

    /// H4a, FOT in the middle of three hops: same refusal by userMinOut.
    function test_H4a_MiddleHopFot_HonestUserMinOut_RevertsRouterE5() public {
        tokenB.setFeeBps(500);
        pBC.setPayBps(8_200);
        uint256 floor = _declaredFloor(_outV2(_outV2(_outV2(AMT))));
        Route memory r = _threeHop(floor);
        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, floor, recip, block.timestamp + 1);
    }

    /// H4a pinned as the design: with an FOT input the declared singleOutFloor
    /// is DROPPED for this swap (Router comment "Drop it for this swap only;
    /// the user stays protected by userMinOut"). The same route that the
    /// floor would refuse settles below it when userMinOut is loose. A change
    /// that re-applies the floor under FOT turns this red on purpose: it must
    /// be a decision, not an accident.
    function test_H4a_FirstHopFot_DeclaredFloorIsDropped_OnlyUserMinOutBinds() public {
        tokenA.setFeeBps(500);
        pAB.setPayBps(8_200);
        uint256 floor = _declaredFloor(_outV2(_outV2(AMT)));
        Route memory r = _twoHop(floor);
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, recip, block.timestamp + 1);
        assertLt(out, floor, "FOT input: the declared floor is dropped, the swap settles under it");
        assertEq(tokenC.balanceOf(recip), out, "untaxed output: delivered == returned");
    }

    /// H4b: an output-token tax is invisible to the Router-side floor
    /// (`amountOut` is measured before the push) and visible only to the
    /// delivered-balance check. userMinOut at the declared floor refuses at
    /// delivery. This is the one test here that only `delivered < userMinOut`
    /// can turn red: the pre-push amount clears the same number (pinned next).
    function test_H4b_LastHopOutputTax_HonestUserMinOut_RevertsAtDelivery() public {
        tokenC.setFeeBps(300);
        uint256 q0 = _outV2(AMT);
        uint256 paid1 = _outV2(q0 - BPC.mulDivUp(q0, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
        uint256 floor = _declaredFloor(paid1);
        Route memory r = _twoHop(floor);
        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, floor, recip, block.timestamp + 1);
    }

    /// H4b pinned: same route, loose userMinOut. The Router-side amount clears
    /// the declared floor (swap quality), the recipient lands under it (the
    /// output token's own tax). Together with the test above this shows WHICH
    /// arm refuses: not the pre-push floor, the delivered check.
    function test_H4b_LastHopOutputTax_FloorIsPrePush_DeliveredIsTaxed() public {
        tokenC.setFeeBps(300);
        uint256 q0 = _outV2(AMT);
        uint256 paid1 = _outV2(q0 - BPC.mulDivUp(q0, BPC.PROTOCOL_FEE_BPS, BPC.BPS));
        uint256 floor = _declaredFloor(paid1);
        Route memory r = _twoHop(floor);
        uint256 poolC0 = tokenC.balanceOf(address(pBC));
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, recip, block.timestamp + 1);
        // Measured outside the Router: the pool's C outflow, taxed once on the
        // way in (pool -> Router: the Router-side amount) and once on the push.
        uint256 paidByPool = poolC0 - tokenC.balanceOf(address(pBC));
        uint256 routerSide = paidByPool - (paidByPool * 300) / 10_000;
        uint256 got = tokenC.balanceOf(recip);
        assertEq(got, routerSide - (routerSide * 300) / 10_000, "delivered = Router-side amount minus the push tax");
        assertEq(out, got, "the door returns what was delivered");
        assertLt(got, floor, "the recipient lands under the declared floor");
        assertGe(routerSide, floor, "the pre-push amount clears the declared floor");
    }
}

contract Fix1019BlindLegFloorsHoldTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pAB;

    address user = address(0xBEEF);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = uint128(1e27);
    uint128 constant THIN = uint128(1e19);
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        router = new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        hub.addBridge(address(tokenB));
        pAB = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pAB.setState(Q96, LIQ);
        tokenB.mint(address(pAB), 1_000_000e18);
        tokenA.mint(user, 10_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _e5() private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(5));
    }

    /// Fair output at full liquidity: the V3 swap-step formula on the pool's
    /// published state, computed BEFORE the pool is starved.
    function _fair() private view returns (uint256) {
        return BPC.outV3(AMT, Q96, LIQ, 3000, pAB.token0() == address(tokenA), 0);
    }

    /// One unattested leg, one hop, no declared figures: the caller's crafted
    /// blind route of H2.
    function _blindRoute() private view returns (Route memory r) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = Leg({pool: address(pAB), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: pAB.token0() == address(tokenA), stable: false, amountIn: AMT, expectedOut: 0,
            auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB), amountIn: AMT, expectedOut: 0, legs: ls});
        r = Route({hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 1, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// H2: unquotable last leg (liquidity() == 0) with a thin fill. The per-leg
    /// guard and the protocol floor have no basis; userMinOut at 80 % of the
    /// fair quote refuses the fill.
    function test_H2_BlindLastLeg_HonestUserMinOut_RevertsRouterE5() public {
        uint256 minOut = BPC.mulDivUp(_fair(), BPC.LEG_FLOOR_BPS, BPC.BPS);
        Route memory r = _blindRoute();
        pAB.setState(Q96, 0);
        pAB.setSwapLiquidity(THIN);
        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, minOut, user, block.timestamp + 1);
    }

    /// H2: the same blind hop with a declared hop figure. With no in-frame
    /// quote, the declared `hop.expectedOut` becomes the protocol floor's base
    /// (blind-hop anchor), so the thin fill is refused with userMinOut = 1.
    function test_H2_BlindLastHop_DeclaredHopFigure_AnchorsProtocolFloor() public {
        Route memory r = _blindRoute();
        r.hops[0].expectedOut = _fair();
        pAB.setState(Q96, 0);
        pAB.setSwapLiquidity(THIN);
        vm.prank(user);
        vm.expectRevert(_e5());
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }
}
