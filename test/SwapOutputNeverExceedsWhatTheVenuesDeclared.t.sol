// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// 3310 (BUG-03) — what the swap's output delta may count.
//
// _execute pays the recipient the change of the Router's tokenOut balance between the entry
// baseline (toutStart) and the end of the hop loop. Between those two reads other code runs: every
// leg of every hop, the fee pushes, the sweeps. A positive restatement of the Router's tokenOut
// balance in that span (a rebase, a reflection) also grows the STRANDED tokenOut, the balance the
// 48h rescue exists to return to its owner, and the delta handed that growth to the swapper. The
// input side has carried its cap since #45 (`if (received > amountIn) received = amountIn`). The
// output's mirror: the delta may not exceed what the legs' venues declared they paid in tokenOut,
// less what later legs and fee charges took back out of the Router (`outCap`: a leg that makes
// tokenOut adds the `declared` it returns, the per-leg quantity DEX-11 reads; a leg that spends
// tokenOut takes off its input, and a fee charged in tokenOut is taken off too). Less is fine (a
// fee-on-transfer tokenOut); the excess stays with the stranded balance.
//
// DEX-11 (G1, c516601) already refuses the reported shape, a restatement inside a measured leg
// window (RouterE 20). It does not see a restatement outside the windows that measure tokenOut, nor
// one inside a blind leg's window (no attestation and no in-frame quote: nothing is measured).
//
// Red at 59ecf3f: test_ARestatementInsideTheLegWindowIsRefused settled and paid the stranded growth.
// Red at c516601: the three restatements G1 does not see paid the stranded growth. The controls are
// watchers: an honest swap, a fee-on-transfer output, a two-leg hop and a cyclic route are paid
// what they made.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";

/// The route's input: a plain token whose first transfer to `hookTo` makes one call
/// (`target.call(payload)`) after the balances moved. Here the call restates tokenOut.
contract CallingIn {
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hookTo;
    address public target;
    bytes public payload;

    function arm(address to, address t, bytes calldata p) external {
        hookTo = to;
        target = t;
        payload = p;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
        return true;
    }

    function _move(address from, address to, uint256 amt) private {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        if (to == hookTo && target != address(0)) {
            address t = target;
            target = address(0);
            (bool ok,) = t.call(payload);
            require(ok, "CallingIn: call");
        }
    }
}

contract SwapOutputNeverExceedsWhatTheVenuesDeclaredTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    CallingIn tokenA;
    MockERC20 tokenB;
    PathologicalERC20 pC;
    address user = address(0xBEEF);
    uint256 constant R = 10_000e18;
    uint256 constant STRANDED = 1_000e18;
    uint256 constant AMT = 100e18;
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = 1e27;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(
            address(hub), address(0x5017E), address(this), address(0xFEE1), address(0xFEE2)
        );
        tokenA = new CallingIn();
        tokenB = new MockERC20("B", "B");
        // tokenOut: shares, display = shares * num / den (1:1 until a restatement).
        pC = new PathologicalERC20("PC", "PC", 18);
        // Mis-sent tokenOut waiting for the rescue: its owner's shares, not the next swapper's.
        pC.mint(address(router), STRANDED);
        tokenA.mint(user, 1_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _mintTo(address t, address to) internal {
        if (t == address(tokenA)) tokenA.mint(to, R);
        else if (t == address(tokenB)) tokenB.mint(to, R);
        else pC.mint(to, R);
    }

    function _pair(address a, address b) internal returns (MockV2Pair p) {
        p = new MockV2Pair(a, b);
        _mintTo(a, address(p));
        _mintTo(b, address(p));
        p.setReserves(uint112(R), uint112(R));
    }

    function _pool(address a, address b, uint128 reported) internal returns (MockV3Pool p) {
        p = new MockV3Pool(a, b, 3000);
        p.setState(Q96, reported);
        p.setSwapLiquidity(LIQ);
        _mintTo(a, address(p));
        _mintTo(b, address(p));
    }

    function _v2(MockV2Pair p, address tIn, uint256 amtIn) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: tIn == p.token0(), stable: false, amountIn: amtIn,
            expectedOut: BPC.outV2(amtIn, R, R, 30), auxId: bytes32(0)
        });
    }

    function _v3(MockV3Pool p, address tIn, uint256 amtIn, uint256 attested) internal view returns (Leg memory) {
        return Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: tIn == p.token0(), stable: false, amountIn: amtIn,
            expectedOut: attested, auxId: bytes32(0)
        });
    }

    function _hop(address tIn, address tOut, Leg memory leg) internal pure returns (Hop memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = leg;
        return Hop({tokenIn: tIn, tokenOut: tOut, amountIn: leg.amountIn, expectedOut: leg.expectedOut, legs: legs});
    }

    function _route(Hop[] memory hops) internal pure returns (Route memory) {
        uint256 q = hops[hops.length - 1].expectedOut;
        return Route({
            hops: hops, totalOut: q, singleOut: q, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _one(Hop memory h) internal pure returns (Route memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = h;
        return _route(hops);
    }

    function _swap(Route memory r) internal returns (uint256) {
        vm.prank(user);
        return router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    function _err(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// The reported shape (RX-H1): tokenOut doubles when the pool's payment lands on the Router,
    /// inside the leg's measured window. The leg's delta then holds the stranded balance's growth
    /// and exceeds what the pool declared: DEX-11 refuses it.
    function test_ARestatementInsideTheLegWindowIsRefused() public {
        MockV2Pair p = _pair(address(tokenA), address(pC));
        pC.setRebaseOnTransferTo(address(router), 2, 1);
        Route memory r = _one(_hop(address(tokenA), address(pC), _v2(p, address(tokenA), AMT)));
        vm.prank(user);
        vm.expectRevert(_err(20));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// The restatement fires in hop 0, whose window measures B: no window that measures tokenOut
    /// contains it. The swapper is paid what the last pool paid; the stranded balance keeps every
    /// share it had.
    function test_ARestatementBeforeTheLastHopStaysWithTheStrandedBalance() public {
        MockV2Pair ab = _pair(address(tokenA), address(tokenB));
        MockV2Pair bc = _pair(address(tokenB), address(pC));
        tokenA.arm(address(ab), address(pC), abi.encodeCall(PathologicalERC20.setRebase, (2, 1)));
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(tokenA), address(tokenB), _v2(ab, address(tokenA), AMT));
        hops[1] = _hop(address(tokenB), address(pC), _v2(bc, address(tokenB), BPC.outV2(AMT, R, R, 30)));
        _swap(_route(hops));
        assertEq(pC.rebaseNum(), 2, "the restatement fired");
        assertEq(pC.sharesOf(address(router)), STRANDED, "the stranded balance keeps every share");
        assertEq(pC.sharesOf(user), R - pC.sharesOf(address(bc)), "the swapper is paid what the last pool paid");
    }

    /// A blind leg (no attestation, a pool that reports no liquidity to the frame) is never
    /// measured, so DEX-11 does not run on it. The restatement fires inside its window (the input
    /// payment in the pool's callback). The swapper is paid no more than the pool declared.
    function test_ABlindLegIsPaidNoMoreThanItsVenueDeclared() public {
        MockV3Pool v3 = _pool(address(tokenA), address(pC), 0);
        tokenA.arm(address(v3), address(pC), abi.encodeCall(PathologicalERC20.setRebase, (2, 1)));
        _swap(_one(_hop(address(tokenA), address(pC), _v3(v3, address(tokenA), AMT, 0))));
        assertEq(pC.rebaseNum(), 2, "the restatement fired");
        assertEq(pC.sharesOf(address(router)), STRANDED, "the stranded balance keeps every share");
        assertEq(pC.sharesOf(user), R - pC.sharesOf(address(v3)), "the swapper is paid what the pool paid");
    }

    /// The loose shape A -> pC -> B -> pC: hop 0 also makes tokenOut and hop 1 hands it back out,
    /// to its venue and, in its own token, to the fee (no bridge coin here: every hop pays), so
    /// what is left is the last hop's declaration. The restatement fires when hop 1 pays pC into
    /// its venue, inside a window that measures B.
    function test_TheLooseShapeIsPaidWhatTheLastHopDeclared() public {
        MockV2Pair ac = _pair(address(tokenA), address(pC));
        MockV3Pool cb = _pool(address(pC), address(tokenB), LIQ);
        MockV2Pair bc = _pair(address(tokenB), address(pC));
        pC.setRebaseOnTransferTo(address(cb), 2, 1);
        uint256 x1 = BPC.outV2(AMT, R, R, 30);
        uint256 q1 = BPC.outV3(x1, Q96, LIQ, 3000, cb.token0() == address(pC), 0);
        Hop[] memory hops = new Hop[](3);
        hops[0] = _hop(address(tokenA), address(pC), _v2(ac, address(tokenA), AMT));
        hops[1] = _hop(address(pC), address(tokenB), _v3(cb, address(pC), x1, q1));
        hops[2] = _hop(address(tokenB), address(pC), _v2(bc, address(tokenB), q1));
        _swap(_route(hops));
        assertEq(pC.rebaseNum(), 2, "the restatement fired");
        assertEq(pC.sharesOf(address(router)), STRANDED, "the stranded balance keeps every share");
        assertEq(pC.sharesOf(user), R - pC.sharesOf(address(bc)), "the swapper is paid what the last pool paid");
    }

    /// Control: no restatement. The swap is paid what its pool paid and the stranded balance stays.
    function test_AnHonestSwapBesideAStrandedBalanceIsPaidWhatThePoolPaid() public {
        MockV2Pair p = _pair(address(tokenA), address(pC));
        uint256 out = _swap(_one(_hop(address(tokenA), address(pC), _v2(p, address(tokenA), AMT))));
        assertEq(out, R - pC.sharesOf(address(p)), "amountOut is what the pool paid");
        assertEq(pC.sharesOf(user), out, "the swapper holds it");
        assertEq(pC.sharesOf(address(router)), STRANDED, "the stranded balance keeps every share");
    }

    /// Control: a fee-on-transfer tokenOut delivers less than the pool declared. The cap does not
    /// bite: the swap is paid what arrived, not the declaration.
    function test_AFeeOnTransferOutputIsPaidWhatArrived() public {
        MockV2Pair p = _pair(address(tokenA), address(pC));
        pC.setFeeOnTransferBps(100);
        _swap(_one(_hop(address(tokenA), address(pC), _v2(p, address(tokenA), AMT))));
        uint256 declared = R - pC.sharesOf(address(p));
        uint256 arrived = declared - declared * 100 / 10_000;
        assertEq(pC.sharesOf(user), arrived - arrived * 100 / 10_000, "the swapper is paid what arrived");
        assertEq(pC.sharesOf(address(router)), STRANDED, "the stranded balance keeps every share");
    }

    /// Control: the last hop's two legs both make tokenOut; the cap is their sum.
    function test_TheCapIsTheSumOfTheLastHopsLegs() public {
        MockV2Pair p1 = _pair(address(tokenA), address(pC));
        MockV2Pair p2 = _pair(address(tokenA), address(pC));
        Leg[] memory legs = new Leg[](2);
        legs[0] = _v2(p1, address(tokenA), AMT / 2);
        legs[1] = _v2(p2, address(tokenA), AMT / 2);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenA), tokenOut: address(pC), amountIn: AMT,
            expectedOut: legs[0].expectedOut + legs[1].expectedOut, legs: legs
        });
        uint256 out = _swap(_route(hops));
        assertEq(out, (R - pC.sharesOf(address(p1))) + (R - pC.sharesOf(address(p2))), "both legs' payments");
        assertEq(pC.sharesOf(address(router)), STRANDED, "the stranded balance keeps every share");
    }

    /// Control: a cyclic route pC -> B -> pC spends its own input, measured against baseIn and made
    /// by no leg, and with no bridge coin hop 0 also pays its fee in pC. The cap floors at zero
    /// there instead of reverting; the swap is paid what its last pool paid.
    function test_ACyclicRouteSpendsItsOwnInputAndIsPaidWhatItsLastPoolPaid() public {
        MockV2Pair cb = _pair(address(pC), address(tokenB));
        MockV2Pair bc = _pair(address(tokenB), address(pC));
        pC.mint(user, AMT);
        vm.prank(user);
        pC.approve(address(router), type(uint256).max);
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(pC), address(tokenB), _v2(cb, address(pC), AMT));
        hops[1] = _hop(address(tokenB), address(pC), _v2(bc, address(tokenB), BPC.outV2(AMT, R, R, 30)));
        uint256 out = _swap(_route(hops));
        assertEq(out, R - pC.sharesOf(address(bc)), "amountOut is what the last pool paid");
        assertEq(pC.sharesOf(address(router)), STRANDED, "the stranded balance keeps every share");
    }
}
