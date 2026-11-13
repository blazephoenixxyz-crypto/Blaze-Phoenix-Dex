// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Two Router guards that held with nothing watching them (PR #123 guard review).
//
//  (a) The last leg of a hop never pushes more than the Router holds
//      (`if (remaining < scaledAmt) scaledAmt = remaining;` in _execute).
//      The legs are scaled by floor-mulDiv, so their sum never exceeds the hop
//      input on paper; the clamp is what holds when the input token's balance
//      moves under the Router between two legs (a rebase fired by the first
//      leg's delivery). Without it the last leg asks for its whole scaled share
//      and the token refuses the transfer, so an honest fill is lost.
//
//  (b) The Permit2 door pulls exactly `amountIn`, never the permit's ceiling
//      (`requestedAmount: amountIn` in swapExactInWithPermit2). A signer who
//      grants headroom (permit.amount > amountIn) pays amountIn and nothing more.
//
//  Both guards exist at ab0bc56, so these tests are green there; they are pins.
//  Each is red under its mutant in .github/scripts/mutants.py (names below).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";

interface IERC20Pull {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Permit2 stand-in that records what the Router asked for. The oracle is
///         the recorded request and the payer's balance, not the Router's return.
contract RecordingPermit2 {
    uint256 public lastRequested;
    uint256 public calls;

    function permitTransferFrom(
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata details,
        address owner,
        bytes calldata
    ) external {
        require(details.requestedAmount <= permit.permitted.amount, "RecordingPermit2: over-request");
        lastRequested = details.requestedAmount;
        ++calls;
        require(
            IERC20Pull(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount),
            "RecordingPermit2: transferFrom failed"
        );
    }
}

contract Guards123Test is Test {
    uint256 constant R = 10_000e18;
    uint256 constant LEG = 500e18;

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), treasury1, treasury2);
    }

    function _pair(address a, address b) private returns (MockV2Pair p) {
        p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), R);
        MockERC20(b).mint(address(p), R);
        p.setReserves(uint112(R), uint112(R));
    }

    function _leg(address pool, address tIn, address tOut, uint256 amt) private pure returns (Leg memory) {
        return Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: tIn < tOut, stable: false,
            amountIn: amt, expectedOut: BPC.outV2(amt, R, R, 30), auxId: bytes32(0)
        });
    }

    function _route(address tIn, address tOut, Leg[] memory legs, uint256 amountIn)
        private pure returns (Route memory route)
    {
        uint256 exp;
        for (uint256 i; i < legs.length; ++i) exp += legs[i].expectedOut;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: tOut, amountIn: amountIn, expectedOut: exp, legs: legs });
        route = Route({
            hops: hops, totalOut: exp, singleOut: exp,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    // -------------------------------------------------------------------------
    // (a) last-leg clamp
    // -------------------------------------------------------------------------

    /// @notice Two legs of 500 on two pools of the same pair. The input token
    ///         rebases down by 1/10000 when leg 0 lands on pool A, so the Router
    ///         holds 499.95 when leg 1 is scaled to 500. The clamp spends what the
    ///         Router holds and the fill settles; the Router keeps no input.
    ///         Mutant 'last leg: the clamp to the Router's holdings is gone' -> the
    ///         last transfer asks for 500 against 499.95 and the token reverts.
    function test_LastLegSpendsWhatTheRouterHolds_WhenTheInputShrinksBetweenLegs() public {
        PathologicalERC20 tIn = new PathologicalERC20("In", "IN", 18);
        MockERC20 tOut = new MockERC20("Out", "OUT");
        MockV2Pair pA = _pair(address(tIn), address(tOut));
        MockV2Pair pB = _pair(address(tIn), address(tOut));

        uint256 amountIn = 2 * LEG;
        tIn.mint(user, amountIn);
        vm.prank(user);
        tIn.approve(address(router), type(uint256).max);

        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(pA), address(tIn), address(tOut), LEG);
        legs[1] = _leg(address(pB), address(tIn), address(tOut), LEG);
        Route memory route = _route(address(tIn), address(tOut), legs, amountIn);

        // Fires once, after leg 0's delivery to pool A has moved the balances.
        tIn.setRebaseOnTransferTo(address(pA), 9_999, 10_000);

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);

        // Precondition the clamp exists for: the rebase did fire, so the Router
        // held less than leg 1's scaled share when leg 1 ran.
        assertEq(tIn.rebaseNum(), 9_999, "the rebase fired mid-swap");
        assertLt((amountIn - LEG) * 9_999 / 10_000, LEG, "leg 1 was scaled past the Router's holdings");

        assertGt(delivered, 0, "the fill settles");
        assertEq(tOut.balanceOf(user), delivered, "the recipient got what the Router returned");
        assertEq(tIn.balanceOf(address(router)), 0, "the Router keeps no input");
    }

    /// @notice Control: no rebase, the same route spends exactly its legs and
    ///         the clamp is a no-op (the last leg is not trimmed).
    function test_LastLegClampIsANoOpWhenTheBalanceHolds() public {
        PathologicalERC20 tIn = new PathologicalERC20("In", "IN", 18);
        MockERC20 tOut = new MockERC20("Out", "OUT");
        MockV2Pair pA = _pair(address(tIn), address(tOut));
        MockV2Pair pB = _pair(address(tIn), address(tOut));

        uint256 amountIn = 2 * LEG;
        tIn.mint(user, amountIn);
        vm.prank(user);
        tIn.approve(address(router), type(uint256).max);

        Leg[] memory legs = new Leg[](2);
        legs[0] = _leg(address(pA), address(tIn), address(tOut), LEG);
        legs[1] = _leg(address(pB), address(tIn), address(tOut), LEG);

        vm.prank(user);
        router.swapExactIn(_route(address(tIn), address(tOut), legs, amountIn), amountIn, 1, user, block.timestamp + 1);

        assertEq(tIn.balanceOf(address(pA)), R + LEG, "pool A got its whole leg");
        assertEq(tIn.balanceOf(address(pB)), R + LEG, "pool B got its whole leg");
        assertEq(tIn.balanceOf(address(router)), 0, "the Router keeps no input");
    }

    // -------------------------------------------------------------------------
    // (b) Permit2 pulls amountIn, not the permit ceiling
    // -------------------------------------------------------------------------

    /// @notice The signer grants twice the input. The Router asks Permit2 for
    ///         exactly amountIn and the signer pays exactly amountIn.
    ///         Mutant 'permit2 door: the pull asks for the permit ceiling instead of
    ///         amountIn' -> Permit2 records 2x and the signer pays 2x.
    function test_Permit2PullsAmountInNotThePermitCeiling() public {
        MockERC20 tIn = new MockERC20("In", "IN");
        MockERC20 tOut = new MockERC20("Out", "OUT");
        MockV2Pair p = _pair(address(tIn), address(tOut));
        RecordingPermit2 permit2 = new RecordingPermit2();
        router.setPermit2(address(permit2));

        uint256 amountIn = 1_000e18;
        uint256 start = 3 * amountIn;
        tIn.mint(user, start);
        vm.prank(user);
        tIn.approve(address(permit2), type(uint256).max);

        Leg[] memory legs = new Leg[](1);
        legs[0] = _leg(address(p), address(tIn), address(tOut), amountIn);
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(tIn), amount: 2 * amountIn }),
            nonce: 0,
            deadline: block.timestamp + 60
        });

        vm.prank(user);
        router.swapExactInWithPermit2(
            _route(address(tIn), address(tOut), legs, amountIn), amountIn, 1, user, block.timestamp + 1, permit, ""
        );

        assertEq(permit2.calls(), 1, "one pull");
        assertEq(permit2.lastRequested(), amountIn, "the Router asked for amountIn, not the ceiling");
        assertEq(tIn.balanceOf(user), start - amountIn, "the signer paid exactly amountIn");
        assertEq(tIn.balanceOf(address(router)), 0, "the Router keeps no input");
    }
}
