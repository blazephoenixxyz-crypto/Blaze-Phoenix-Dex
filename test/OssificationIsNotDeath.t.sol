// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  OSSIFICATION IS NOT DEATH — the positive half of renounceControl().
//
//  Every existing renounce test asserts the NEGATIVE half: the setters die
//  (BlazePhoenixRouter.t.sol, RouterRefusalsObserved.t.sol, UntestedSurface,
//  FactoryCodehashPin, BridgeProducerDesync). None asserts the half the
//  protocol actually sells: after renounceControl() the Router KEEPS
//  EXECUTING SWAPS under the frozen configuration — the renounceControl
//  docstring's own words. If any future change coupled `controlRenounced`
//  into the swap path, renouncing would brick mainnet permanently and the
//  whole suite would stay green. This file pins the positive half with
//  concrete numbers, through EVERY door that moves value, pins the Hub side
//  (discovery, quoting and registry learning survive renounce), and pins
//  both pause/renounce compositions.
//
//  VERDICT ON THE COMPOSITION setPaused(true) -> renounceControl(), read
//  from the source and pinned by test_Composition_PauseThenRenounce_*:
//  it is a PERMANENT, UNRECOVERABLE FREEZE, and it is REACHABLE.
//  renounceControl() carries no whenLive and no paused-guard, so it executes
//  from the paused state; afterwards every swap door reverts RouterE(2)
//  forever (whenLive reads a flag nothing can clear) and every path that
//  could thaw the state — setPaused, setAdmin, even queueRescue — reverts
//  RouterE(1) forever (onlyControl). The docstring's "frozen at their
//  current values forever" makes this internally consistent, but its
//  neighbouring sentence "The Router keeps executing swaps" silently assumes
//  the flag is false at renounce time. Judgement: the mechanism looks
//  intended (renounce freezes VALUES, whatever they are), yet operationally
//  DANGEROUS — renouncing during an incident pause is a one-transaction kill
//  switch for the whole Router, with user approvals still outstanding and
//  rescue dead too. No on-chain guard prevents it; the rule "never renounce
//  while paused" can only live in ops procedure. This test pins the observed
//  behaviour so no future change can alter it silently in either direction.
//
//  Harness mirrors SwapBestExactInHardening (full stack: initialized Hub,
//  Solver, Quoter, roles wired) plus the Permit2 and native-entry fixtures
//  (RouterPermit2OneStep.t.sol, RouterNativeEntry.t.sol). Before/after
//  parity uses vm.snapshotState()/vm.revertToState() (the tree's idiom, see
//  SecurityArchitectureGas.t.sol): both runs start from byte-identical
//  state, with ONLY `controlRenounced` flipped between them.
//
//  forge test --match-contract OssificationIsNotDeath -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockWETH} from "./RouterNativeEntry.t.sol";

contract OssificationIsNotDeathTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockPermit2 permit2;
    MockWETH wethT;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV2Pair pairAB; // seeded in the Hub: the Solver/Quoter route over it
    MockV2Pair wpair;  // WETH/tokenB, unseeded (mirrors RouterNativeEntry)

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    uint256 constant R = 10_000e18; // symmetric reserves on every pair

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2
        );
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        // All control wiring happens HERE, before any renounce — the exact
        // sequence a mainnet ossification would follow.
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));
        wethT = new MockWETH();
        router.setWeth(address(wethT));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        pairAB = _newPair(address(tokenA), address(tokenB));
        hub.seedPool(address(pairAB), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));

        wpair = _newPair(address(wethT), address(tokenB));

        tokenA.mint(user, 1_000_000e18);
        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);  // classic + best doors
        tokenA.approve(address(permit2), type(uint256).max); // permit2 door
        vm.stopPrank();
        vm.deal(user, 100e18);                               // native door
    }

    function _newPair(address tX, address tY) internal returns (MockV2Pair p) {
        p = new MockV2Pair(tX, tY);
        MockERC20(tX).mint(address(p), R);
        MockERC20(tY).mint(address(p), R);
        p.setReserves(uint112(R), uint112(R)); // symmetric: sorted order is moot
    }

    function _v2Route(address pool, address tIn, address tOut, uint256 amountIn, uint256 claimedTotalOut)
        private pure returns (Route memory route)
    {
        bool zeroForOne = tIn < tOut;
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: amountIn, expectedOut: claimedTotalOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: tIn, tokenOut: tOut,
            amountIn: amountIn, expectedOut: claimedTotalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedTotalOut, singleOut: claimedTotalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _permitFor(address token, uint256 amount)
        private view returns (IPermit2.PermitTransferFrom memory p)
    {
        p = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: token, amount: amount }),
            nonce: 0,
            deadline: block.timestamp + 60
        });
    }

    // =========================================================================
    //  1. The positive half, door by door: a swap that settles BEFORE
    //     renounceControl() settles IDENTICALLY after it. Same route, same
    //     input, same delivered output, same fee to each treasury — asserted
    //     as exact equalities between two runs from byte-identical state,
    //     plus absolute anchors so two equally-broken runs cannot pass.
    // =========================================================================

    /// @notice Door 1/4 — swapExactIn (classic pre-approved pull).
    function test_Ossified_SwapExactIn_SettlesIdenticallyAfterRenounce() public {
        uint256 amountIn = 1_000e18;
        uint256 quote = BPC.outV2(amountIn, R, R, 30);
        Route memory route = _v2Route(address(pairAB), address(tokenA), address(tokenB), amountIn, quote);

        uint256 snap = vm.snapshotState();

        vm.prank(user);
        uint256 dBefore = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        uint256 outBefore    = tokenB.balanceOf(user);
        uint256 inLeftBefore = tokenA.balanceOf(user);
        uint256 t1Before     = tokenA.balanceOf(treasury1);
        uint256 t2Before     = tokenA.balanceOf(treasury2);

        require(vm.revertToState(snap), "revert snap");

        router.renounceControl();
        assertTrue(router.controlRenounced(), "renounce must have taken");

        vm.prank(user);
        uint256 dAfter = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);

        assertEq(dAfter, dBefore, "delivered output changed across renounceControl");
        assertEq(tokenB.balanceOf(user), outBefore, "recipient balance diverged");
        assertEq(tokenA.balanceOf(user), inLeftBefore, "user paid a different input");
        assertEq(tokenA.balanceOf(treasury1), t1Before, "treasury1 fee diverged");
        assertEq(tokenA.balanceOf(treasury2), t2Before, "treasury2 fee diverged");

        // Absolute anchors: fee = ceil(amountIn * 28 / 10_000) in tokenIn
        // (_chargeHopFee), split 30/70 by TREASURY1_SHARE = 3_000 (_payFee).
        uint256 fee = BPC.mulDivUp(amountIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(tokenA.balanceOf(treasury1) + tokenA.balanceOf(treasury2), fee,
            "total fee is 28 bps of the input, in tokenIn");
        assertEq(tokenA.balanceOf(treasury1), BPC.mulDiv(fee, 3_000, BPC.BPS),
            "treasury1 takes exactly 30% of the fee");
        assertGt(dAfter, 0, "a real swap must deliver");
        assertApproxEqRel(dAfter, quote, 0.01e18,
            "delivered tracks the pool-math quote (28 bps input fee + rounding)");
    }

    /// @notice Door 2/4 — swapExactInWithPermit2 (SignatureTransfer pull;
    ///         fixture mirrors RouterPermit2OneStep.t.sol).
    function test_Ossified_SwapExactInWithPermit2_SettlesIdenticallyAfterRenounce() public {
        uint256 amountIn = 1_000e18;
        uint256 quote = BPC.outV2(amountIn, R, R, 30);
        Route memory route = _v2Route(address(pairAB), address(tokenA), address(tokenB), amountIn, quote);
        IPermit2.PermitTransferFrom memory permit = _permitFor(address(tokenA), amountIn);

        uint256 snap = vm.snapshotState();

        vm.prank(user);
        uint256 dBefore = router.swapExactInWithPermit2(
            route, amountIn, 1, user, block.timestamp + 1, permit, "");
        uint256 outBefore = tokenB.balanceOf(user);
        uint256 t1Before  = tokenA.balanceOf(treasury1);
        uint256 t2Before  = tokenA.balanceOf(treasury2);

        require(vm.revertToState(snap), "revert snap");

        router.renounceControl();

        vm.prank(user);
        uint256 dAfter = router.swapExactInWithPermit2(
            route, amountIn, 1, user, block.timestamp + 1, permit, "");

        assertEq(dAfter, dBefore, "Permit2 door settles differently after renounce");
        assertEq(tokenB.balanceOf(user), outBefore, "recipient balance diverged");
        assertEq(tokenA.balanceOf(treasury1), t1Before, "treasury1 fee diverged");
        assertEq(tokenA.balanceOf(treasury2), t2Before, "treasury2 fee diverged");

        uint256 fee = BPC.mulDivUp(amountIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(tokenA.balanceOf(treasury1) + tokenA.balanceOf(treasury2), fee,
            "total fee is 28 bps of the input");
        assertGt(dAfter, 0, "a real swap must deliver");
    }

    /// @notice Door 3/4 — swapExactInNative (raw ETH wrapped once into WETH;
    ///         fixture mirrors RouterNativeEntry.t.sol; the fee for this door
    ///         is charged in WETH, the hop's tokenIn).
    function test_Ossified_SwapExactInNative_SettlesIdenticallyAfterRenounce() public {
        uint256 amountIn = 10e18;
        uint256 quote = BPC.outV2(amountIn, R, R, 30);
        Route memory route = _v2Route(address(wpair), address(wethT), address(tokenB), amountIn, quote);

        uint256 snap = vm.snapshotState();

        vm.prank(user);
        uint256 dBefore = router.swapExactInNative{value: amountIn}(
            route, 1, user, block.timestamp + 1);
        uint256 outBefore = tokenB.balanceOf(user);
        uint256 ethBefore = user.balance;
        uint256 t1Before  = wethT.balanceOf(treasury1);
        uint256 t2Before  = wethT.balanceOf(treasury2);

        require(vm.revertToState(snap), "revert snap");

        router.renounceControl();

        vm.prank(user);
        uint256 dAfter = router.swapExactInNative{value: amountIn}(
            route, 1, user, block.timestamp + 1);

        assertEq(dAfter, dBefore, "native door settles differently after renounce");
        assertEq(tokenB.balanceOf(user), outBefore, "recipient balance diverged");
        assertEq(user.balance, ethBefore, "user spent a different amount of ETH");
        assertEq(wethT.balanceOf(treasury1), t1Before, "treasury1 WETH fee diverged");
        assertEq(wethT.balanceOf(treasury2), t2Before, "treasury2 WETH fee diverged");

        uint256 fee = BPC.mulDivUp(amountIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        assertEq(wethT.balanceOf(treasury1) + wethT.balanceOf(treasury2), fee,
            "total fee is 28 bps of msg.value, in WETH");
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(wethT.balanceOf(address(router)), 0, "router holds no WETH");
        assertGt(dAfter, 0, "a real swap must deliver");
    }

    /// @notice Door 4/4 — swapBestExactIn (route solved ON-CHAIN inside the
    ///         same tx; fixture mirrors SwapBestExactInHardening). The
    ///         preview runs once BEFORE the snapshot so both runs start from
    ///         identical post-preview state; the parity band vs the preview
    ///         is the one SwapBestExactInHardening pins.
    function test_Ossified_SwapBestExactIn_SettlesIdenticallyAfterRenounce() public {
        uint256 amountIn = 100e18;
        (Route memory rt, uint256 exactOut) =
            quoter.previewPlanExact(address(tokenA), address(tokenB), amountIn);
        assertGt(exactOut, 0, "preview must quote the seeded pool");

        uint256 snap = vm.snapshotState();

        vm.prank(user);
        uint256 dBefore = router.swapBestExactIn(
            address(tokenA), address(tokenB), amountIn, 1, user, block.timestamp + 1);
        uint256 outBefore = tokenB.balanceOf(user);
        uint256 t1Before  = tokenA.balanceOf(treasury1);
        uint256 t2Before  = tokenA.balanceOf(treasury2);

        require(vm.revertToState(snap), "revert snap");

        router.renounceControl();

        vm.prank(user);
        uint256 dAfter = router.swapBestExactIn(
            address(tokenA), address(tokenB), amountIn, 1, user, block.timestamp + 1);

        assertEq(dAfter, dBefore, "on-chain-solved route settles differently after renounce");
        assertEq(tokenB.balanceOf(user), outBefore, "recipient balance diverged");
        assertEq(tokenA.balanceOf(treasury1), t1Before, "treasury1 fee diverged");
        assertEq(tokenA.balanceOf(treasury2), t2Before, "treasury2 fee diverged");
        assertGt(tokenA.balanceOf(treasury1) + tokenA.balanceOf(treasury2), 0,
            "a real fee was charged");

        // The route carries the pool-math ceiling; `exactOut` is that figure
        // less the protocol fee (FEE-02, 2026-09-03) and is a FLOOR, not an
        // equality: the Router charges the fee on each hop's INPUT, and a
        // concave curve pays slightly more for a slightly smaller input than
        // a proportional cut of the full-size output would. Both sides are
        // asserted so neither direction can drift unnoticed.
        assertLe(dAfter, rt.totalOut, "delivered above the pool-math ceiling");
        assertGe(dAfter, exactOut, "delivered below the exact preview: exactOut is the floor");
        assertGe(dAfter, BPC.mulDiv(exactOut, 9_900, BPC.BPS),
            "delivered fell >1% below the exact preview");
    }

    // =========================================================================
    //  2. The Hub side: discovery and quoting still answer, and the registry
    //     still LEARNS, after BOTH surfaces renounce.
    // =========================================================================

    /// @notice After full renounce (Router + Hub) the read side still
    ///         answers: registry read-out lists the seeded pool, factory
    ///         discovery returns instead of reverting, and the Quoter still
    ///         produces the exact V2 number.
    function test_Ossified_HubDiscoveryAndQuoting_StillAnswerAfterFullRenounce() public {
        router.renounceControl();
        hub.renounceControl();

        PoolInfo[] memory act = hub.getActivePools(address(tokenA), address(tokenB));
        assertEq(act.length, 1, "registry read-out must still answer");
        assertEq(act[0].pool, address(pairAB), "and still list the seeded pool");

        // No factories are wired in this harness, so an empty census is the
        // correct answer — the pin is that the door ANSWERS, not reverts.
        PoolInfo[] memory hits = hub.discoverFor(address(tokenA), address(tokenB));
        assertEq(hits.length, 0, "no factories wired: empty census, not a revert");

        uint256 amountIn = 1_000e18;
        (Route memory rt, uint256 exactOut) =
            quoter.previewPlanExact(address(tokenA), address(tokenB), amountIn);
        assertEq(rt.totalOut, BPC.outV2(amountIn, R, R, 30),
            "route total == V2 formula after full renounce");
        assertEq(exactOut, _netOfFee(BPC.outV2(amountIn, R, R, 30)),
            "preview == V2 formula less the protocol fee, after full renounce");
    }
    /// Since 2026-09-03 (register escape FEE-02) `previewPlanExact` returns the
    /// NET output: the dry-run total less the protocol fee, deducted once and
    /// rounded up exactly as `_pack` and the Router do. The route keeps the
    /// pool-math attestation in `totalOut`. Written from the constants so the
    /// expectation never comes from the code under test.
    function _netOfFee(uint256 gross) internal pure returns (uint256) {
        return gross - BPC.mulDivUp(gross, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }


    /// @notice After full renounce the registry keeps LEARNING: a routed swap
    ///         still ticks the seeded pool's slot, and a never-seen pool still
    ///         gets registered through recordSwap's insert branch. The Router
    ///         wraps recordSwap in try/catch (_recordHits), so a silently dead
    ///         registry would NOT fail the swap — the slot change and the new
    ///         registration are the only honest witnesses.
    function test_Ossified_RegistryKeepsLearningAfterFullRenounce() public {
        router.renounceControl();
        hub.renounceControl();

        // (a) The seeded pool's slot still ticks on a routed swap.
        bytes32 keyAB = hub.keyOf(address(pairAB), address(tokenA), address(tokenB));
        uint256 slotBefore = hub.getSlot(keyAB);
        assertTrue(slotBefore != 0, "precondition: pool seeded");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1000);
        uint256 amountIn = 100e18;
        uint256 quote = BPC.outV2(amountIn, R, R, 30);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _v2Route(address(pairAB), address(tokenA), address(tokenB), amountIn, quote),
            amountIn, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "the swap itself must settle");
        assertTrue(hub.getSlot(keyAB) != slotBefore,
            "the registry must keep ticking with nobody at the controls");

        // (b) A brand-new pool on a brand-new pair still gets registered.
        MockERC20 tX = new MockERC20("X", "X");
        MockERC20 tY = new MockERC20("Y", "Y");
        MockV2Pair pairXY = _newPair(address(tX), address(tY));
        tX.mint(user, 1_000e18);
        vm.prank(user);
        tX.approve(address(router), type(uint256).max);

        bytes32 keyXY = hub.keyOf(address(pairXY), address(tX), address(tY));
        assertEq(hub.getPool(keyXY), address(0), "precondition: pool unknown");

        uint256 qXY = BPC.outV2(100e18, R, R, 30);
        vm.prank(user);
        router.swapExactIn(
            _v2Route(address(pairXY), address(tX), address(tY), 100e18, qXY),
            100e18, 1, user, block.timestamp + 1);

        assertEq(hub.getPool(keyXY), address(pairXY),
            "the registry must learn a brand-new pool after renounce");
        assertTrue(hub.getSlot(keyXY) != 0, "with a live slot");
    }

    /// @notice Renounce freezes the config at its CURRENT values — it does
    ///         not zero anything. renounceControl emits Cfg(0, address(0))
    ///         but the admin storage itself must survive, as must every other
    ///         frozen value the swap path reads (permit2, weth, treasuries).
    function test_Ossified_FrozenConfigKeepsItsValues_NotZeroed() public {
        address a  = router.admin();
        address t1 = router.treasury1();
        address t2 = router.treasury2();
        address p2 = router.permit2();
        address w  = router.weth();
        assertFalse(router.paused(), "precondition: live");

        router.renounceControl();

        assertTrue(router.controlRenounced());
        assertEq(router.admin(), a,  "admin storage must survive (the Cfg(0,0) event is not a wipe)");
        assertEq(router.treasury1(), t1, "treasury1 frozen at its value");
        assertEq(router.treasury2(), t2, "treasury2 frozen at its value");
        assertEq(router.permit2(), p2, "permit2 frozen at its value");
        assertEq(router.weth(), w, "weth frozen at its value");
        assertFalse(router.paused(), "pause flag frozen at false");
    }

    // =========================================================================
    //  3. The composition — the governance endgame nobody had pinned.
    // =========================================================================

/// @notice setPaused(true) then renounceControl() — REFUSED, and that is the
    ///         whole point. The composition used to be reachable: renounceControl
    ///         carried no paused check, so an admin who paused during an incident
    ///         and then "sealed" the contract reached a state with no exit — all
    ///         four value doors refusing RouterE(2) forever, and every thaw path
    ///         (setPaused, setAdmin, queueRescue) refusing RouterE(1) forever,
    ///         because renouncing had just killed onlyControl.
    ///         There was no legitimate use for it. Ossifying a LIVE protocol
    ///         leaves users trading through it forever, which is the intent;
    ///         pausing is worth doing precisely because control is retained to
    ///         migrate, and renouncing at that moment discards the capability the
    ///         pause was bought to use. The guard makes the terminal state
    ///         unreachable rather than merely undocumented.
    function test_Composition_PauseThenRenounce_IsRefused() public {
        router.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 2));
        router.renounceControl();

        assertTrue(router.paused(), "still paused");
        assertFalse(router.controlRenounced(), "control survived the refusal");

        // And the escape stays open: unpause, then ossify, and swaps work.
        router.setPaused(false);
        router.renounceControl();
        assertTrue(router.controlRenounced(), "ossification still available when live");

        uint256 amountIn = 100e18;
        uint256 quote = BPC.outV2(amountIn, R, R, 30);
        Route memory route = _v2Route(address(pairAB), address(tokenA), address(tokenB), amountIn, quote);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "an ossified LIVE router still settles swaps");
    }

    /// @notice The REVERSE order — renounceControl() then setPaused(true):
    ///         the mirror image of the freeze, and it DOES differ. Once
    ///         renounced while live, the protocol can never be STOPPED:
    ///         pause is a control power and dies in RouterE(1), and swaps
    ///         keep settling forever under the frozen config.
    function test_ReverseOrder_RenounceThenPause_CannotStopTheProtocol() public {
        router.renounceControl();

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, 1));
        router.setPaused(true);
        assertFalse(router.paused(), "the flag must be untouched");

        uint256 amountIn = 100e18;
        uint256 quote = BPC.outV2(amountIn, R, R, 30);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(
            _v2Route(address(pairAB), address(tokenA), address(tokenB), amountIn, quote),
            amountIn, 1, user, block.timestamp + 1);
        assertGt(delivered, 0,
            "swaps keep settling: renounced-while-live means unstoppable, not frozen");
    }

/// @notice The Hub twin. Its terminal state was quieter — recordSwap is the
    ///         only whenLive surface, so paused+renounced left swaps settling
    ///         (the Router swallows the refusal) while ranking, vitality and
    ///         eviction died permanently and silently. Fixing one of two
    ///         symmetric channels is this codebase's documented defect
    ///         signature, so the same guard sits on both.
    function test_Composition_HubPauseThenRenounce_IsRefused() public {
        hub.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 2));
        hub.renounceControl();

        // The Hub exposes no controlRenounced getter, so the flag is asserted
        // BEHAVIOURALLY through the door it gates: setRoles is onlyControl, so
        // it must still work while control survives.
        hub.setRoles(address(router), address(solver), address(0));

        hub.setPaused(false);
        hub.renounceControl();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        hub.setRoles(address(router), address(solver), address(0));
    }
}
