// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, MAX_HOPS, MAX_LEGS_PER_HOP} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @notice FLOOR-01 and FLOOR-02 — two ways the caller could relax a floor the code promised
///         they could not, both found by a census of quantities with two producers rather than
///         by hand, and both measured before they were fixed.
///
///         `Router._execute` writes, eleven lines above the floor it computes: "The caller's
///         singleOutFloor and userMinOut may TIGHTEN the floor ... but can never RELAX the
///         protocol floor", and called the anchor "unforgeable by calldata". Both sentences were
///         false, and the shape is this repository's standing law: a DECLARED count decided the
///         floor while the MEASURED count sat unread three hundred lines above.
///
///         Measured against the pre-fix code:
///           FLOOR-01  a trailing hop declaring amountIn = 0 -> quoted 0, floorUsed 0. The whole
///                     protocol floor gone, the swap settling normally, only userMinOut left.
///           FLOOR-02  four padded legs -> the floor fell 9501 -> 8702 bps of the quote, exactly
///                     4 x FLOOR_PER_LEG_BPS. At the structural maximum of MAX_HOPS x
///                     MAX_LEGS_PER_HOP legs it reaches the 8000 hard clamp: 96% -> 80%.
///                     History: measured at 15 legs (3 x 5). Since 2026-11-06 the maximum is
///                     2 x 5 = 10 legs, where the count shaved 9 x 200 bps (9600 - 1800 = 7800,
///                     below the clamp), so the clamp still bites. Post-fix, two hops of five
///                     equal legs earn 2 x 4 x 200 = 1600 bps honestly: 9600 - 1600 lands on it.
contract FloorAnchorAndLegCountTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tIn;
    MockERC20 tOut;
    MockV2Pair pair;
    address user = address(0xBEEF);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tIn = new MockERC20("In", "IN");
        tOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tIn), address(tOut));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(0xBEEF));
        tIn.mint(address(pair), 10_000e18);
        tOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);
        tIn.mint(user, 10_000e18);
        vm.prank(user);
        tIn.approve(address(router), type(uint256).max);
    }

    function _leg(uint256 amountIn) private view returns (Leg memory) {
        return Leg({pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                    tickSpacing: 0, zeroForOne: address(tIn) < address(tOut), stable: false,
                    amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)});
    }

    /// @dev A V2 leg on `p` from `from` to `to`; the pair sorts its tokens, so the direction is
    ///      the order of the two addresses.
    function _legOn(MockV2Pair p, address from, address to, uint256 amountIn)
        private pure returns (Leg memory)
    {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                    tickSpacing: 0, zeroForOne: from < to, stable: false,
                    amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)});
    }

    function _pairOf(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        x.mint(address(p), 10_000e18);
        y.mint(address(p), 10_000e18);
        p.setReserves(10_000e18, 10_000e18);
    }

    /// @dev A concentrated-single leg that moves nothing (amountIn 0, so no pool is touched),
    ///      with a key that holds together: poolId derived from (currencies, fee, tickSpacing,
    ///      hooks), direction from the tokens, counter token in auxId. A preview of a route
    ///      made of such legs can only refuse it on its shape.
    function _idleSingleLeg(address from, address to) private pure returns (Leg memory) {
        (address c0, address c1) = from < to ? (from, to) : (to, from);
        return Leg({pool: address(uint160(uint256(BPC.computeV4PoolId(c0, c1, 500, 10, address(0))))),
                    hooks: address(0), kind: BPC.KIND_V4, fee: 500, tickSpacing: 10,
                    zeroForOne: from == c0, stable: false, amountIn: 0, expectedOut: 0,
                    auxId: bytes32(uint256(uint160(to)))});
    }

    function _route(uint256 amountIn, uint256 pads) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1 + pads);
        legs[0] = _leg(amountIn);
        // Same pair, same direction, ZERO input: satisfies the leg/hop token equality gate and
        // is returned from before any pool is touched, so it executes nothing at all.
        for (uint256 i; i < pads; ++i) legs[1 + i] = _leg(0);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut),
                       amountIn: amountIn, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                   hasSurplus: false, isV4Bundle: false});
    }

    /// @dev The floor as a rate of the quote, read from the ExecutionProof the swap emits.
    ///      Rates, not absolutes: each swap moves the pool, so two runs never quote the same.
    function _floorBpsOfQuote(Route memory r, uint256 amountIn) private returns (uint256) {
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, amountIn, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (uint256 q, , uint256 f, ) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertGt(q, 0, "premise: the swap must produce a real in-frame quote");
                return (f * 10_000) / q;
            }
        }
        revert("no ExecutionProof emitted");
    }

    /// @notice FLOOR-02. Legs that carry no share of the hop buy no loosening. The shave is
    ///         computed from the CONCENTRATION of the trade across legs - `(Σa)² / Σa²` per
    ///         hop, the effective number of legs - so the loosening a split earns is
    ///         proportional to how genuinely it is split. Before this, four zero-amount legs
    ///         moved the floor 9501 -> 8702 bps of the quote: exactly 4 x FLOOR_PER_LEG_BPS.
    function test_PaddedZeroAmountLegsCannotLowerTheProtocolFloor() public {
        uint256 amt = 100e18;
        uint256 clean  = _floorBpsOfQuote(_route(amt, 0), amt);
        uint256 padded = _floorBpsOfQuote(_route(amt, MAX_LEGS_PER_HOP - 1), amt);   // 4 pads
        emit log_named_uint("floor bps of quote, one leg      ", clean);
        emit log_named_uint("floor bps of quote, four padded  ", padded);
        assertGt(clean, 9_000, "premise: the honest route carries a floor near the 9600 base");
        // What remains is the impact term drifting because the first swap moved the reserves.
        uint256 gap = clean > padded ? clean - padded : 0;
        assertLt(gap, 50, "PADDING: zero-amount legs must not walk the protocol floor down");
    }

    /// @notice And the one-wei variant, which a count of EXECUTED legs would still have paid
    ///         for: a leg carrying a vanishing share of the hop earns a vanishing shave, whether
    ///         it declares zero or one wei. Concentration is what closes both.
    function test_OneWeiPaddedLegsCannotLowerTheProtocolFloorEither() public {
        uint256 amt = 100e18;
        uint256 clean = _floorBpsOfQuote(_route(amt, 0), amt);
        Leg[] memory legs = new Leg[](5);
        legs[0] = _leg(amt);
        for (uint256 i = 1; i < 5; ++i) legs[i] = _leg(1);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut),
                       amountIn: amt + 4, expectedOut: 0, legs: legs});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                                expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                                hasSurplus: false, isV4Bundle: false});
        uint256 padded = _floorBpsOfQuote(r, amt + 4);
        emit log_named_uint("floor bps of quote, one leg       ", clean);
        emit log_named_uint("floor bps of quote, four x 1 wei  ", padded);
        uint256 gap = clean > padded ? clean - padded : 0;
        assertLt(gap, 50, "PADDING: one-wei legs must not walk the protocol floor down");
    }

    /// @notice The positive control, without which the two above would pass on a shave that
    ///         had simply been deleted: an HONEST equal split still earns its full loosening.
    ///         Five equal legs have an effective count of exactly five, so the shave is exactly
    ///         4 x FLOOR_PER_LEG_BPS - the same 800 bps the padding used to steal.
    function test_AnHonestEqualSplitStillEarnsItsFullShave() public {
        uint256 amt = 100e18;
        uint256 clean = _floorBpsOfQuote(_route(amt, 0), amt);
        Leg[] memory legs = new Leg[](5);
        for (uint256 i; i < 5; ++i) legs[i] = _leg(amt / 5);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut),
                       amountIn: amt, expectedOut: 0, legs: legs});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                                expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                                hasSurplus: false, isV4Bundle: false});
        uint256 split = _floorBpsOfQuote(r, amt);
        emit log_named_uint("floor bps of quote, one leg           ", clean);
        emit log_named_uint("floor bps of quote, five equal legs   ", split);
        uint256 gap = clean > split ? clean - split : 0;
        // 800 from the shave, LESS what the split gives back through the impact term: five legs
        // each carrying a fifth of the order have a fifth of the price impact, and `ironFloorBps`
        // subtracts impact, so the floor rises by roughly four fifths of the single-leg impact
        // (~99 bps here -> ~79 back). Measured: 721. The bound is the shave minus that, with
        // room for the reserve drift between the two swaps - and it must stay well above the
        // ~0 a padded route earns, which is the whole distinction this file exists to pin.
        assertGt(gap, 600, "an honest five-way split must earn most of 4 x 200 bps");
        assertLt(gap, 850, "and not more than the shave itself");
    }

    /// @notice FLOOR-01's original shape, one hop past the ceiling. A no-op tail that goes out
    ///         through `mid` and back into tOut was the shape that let a hop which moved nothing
    ///         end the route; it takes three hops, and since 2026-11-06 a route has at most
    ///         MAX_HOPS = 2. Both doors refuse it on its length alone. The preview: every leg here
    ///         holds together (the V2 pair trades the hop's tokens, the idle legs' poolIds derive)
    ///         and the claim is positive, so nothing but the shape can make it non-executable.
    ///         The Router: RouterE(3), before any hop runs.
    ///
    ///         History: until 2026-11-06 this route settled and
    ///         test_TrailingHopThatMovesNothingCannotZeroTheProtocolFloor asserted that its floor
    ///         stayed above 9000 bps of the quote. The two-hop analogue is the next test.
    function test_ThreeHops_TrailingNoOpTail_IsRefusedBeforeAnyHopRuns() public {
        uint256 amt = 100e18;
        MockERC20 mid = new MockERC20("Mid", "MID");
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _leg(amt);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _idleSingleLeg(address(tOut), address(mid));
        Leg[] memory l2 = new Leg[](1);
        l2[0] = _idleSingleLeg(address(mid), address(tOut));
        Hop[] memory hops = new Hop[](3);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(tOut),
                       amountIn: amt, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(tOut), tokenOut: address(mid),
                       amountIn: 0, expectedOut: 0, legs: l1});
        hops[2] = Hop({tokenIn: address(mid), tokenOut: address(tOut),
                       amountIn: 0, expectedOut: 0, legs: l2});
        Route memory r = Route({hops: hops, totalOut: amt, singleOut: 0, singleOutFloor: 0,
                                expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                                hasSurplus: false, isV4Bundle: false});
        assertEq(r.hops.length, MAX_HOPS + 1, "premise: the route is one hop past the ceiling");
        assertFalse(quoter.previewRoute(r, 1).canExecute,
            "CEILING: the preview must refuse a route of MAX_HOPS + 1 hops");

        r.totalOut = 0; // the calldata the pre-2026-11-06 test sent, which settled then
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    /// @notice FLOOR-01 at two hops. A trailing hop that moves nothing can no longer sit behind a
    ///         hop that already made tOut: at two hops the last hop is the only one that makes
    ///         it (hop 1 starts where hop 0 ends and is no self-hop). So a last hop that moves
    ///         nothing delivers nothing, and the Router refuses the empty delivery (RouterE(8))
    ///         before any floor is computed. The positive arm runs the same two pairs with a real
    ///         last leg and keeps a floor near the 9600 base: the refusal is the empty delivery,
    ///         not a malformed construction.
    ///
    ///         History: replaces test_TrailingHopThatMovesNothingCannotZeroTheProtocolFloor (the
    ///         three-hop route of the test above, which settled until 2026-11-06). With two hops
    ///         and honest tokens the FLOOR-01 anchor condition no longer decides on its own; this
    ///         is the executable witness of that.
    function test_TwoHops_TrailingHopThatMovesNothing_DeliversNothingAndIsRefused() public {
        uint256 amt = 100e18;
        MockERC20 mid = new MockERC20("Mid", "MID");
        MockV2Pair pIM = _pairOf(tIn, mid);
        MockV2Pair pMO = _pairOf(mid, tOut);
        Leg[] memory l0 = new Leg[](1);
        l0[0] = _legOn(pIM, address(tIn), address(mid), amt);
        Leg[] memory l1 = new Leg[](1);
        l1[0] = _idleSingleLeg(address(mid), address(tOut));
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({tokenIn: address(tIn), tokenOut: address(mid),
                       amountIn: amt, expectedOut: 0, legs: l0});
        hops[1] = Hop({tokenIn: address(mid), tokenOut: address(tOut),
                       amountIn: 0, expectedOut: 0, legs: l1});
        Route memory r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                                expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
                                hasSurplus: false, isV4Bundle: false});
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);

        // The same route with a last leg that trades: the Router scales it to the measured
        // `mid` balance, so its declared amount only has to be non-zero.
        l1[0] = _legOn(pMO, address(mid), address(tOut), amt);
        hops[1].amountIn = amt;
        uint256 twoHops = _floorBpsOfQuote(r, amt);
        emit log_named_uint("floor bps of quote, two honest hops", twoHops);
        assertGt(twoHops, 9_000, "the honest two-hop route carries a floor near the 9600 base");
    }
}
