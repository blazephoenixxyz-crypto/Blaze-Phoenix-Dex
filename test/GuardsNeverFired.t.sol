// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  GuardsNeverFired -- drives twelve refusal guards that an inventory found
//  never fired by any test, each classified REACHABLE with a derived witness.
//  Sequel to RefusalsNeverDriven (same discipline): every fire asserts the
//  EXACT revert bytes, never a bare revert, and every fire is paired with a
//  CONTROL that differs in exactly one respect and settles cleanly (or, where
//  a settling control cannot exist, resolves to a DIFFERENT specific code that
//  pins the fire to its site).
//
//  Guards driven (located by CONDITION, not line):
//    W1  _execV4Amt        `!hub.isHookLive(leg.hooks)`            -> RouterE(9)
//        The Layer-3 codehash pin at EXECUTION time. Its neighbour one line
//        above (`hookAltersDeltas`) shares RouterE(9); the control settling
//        through the SAME hook address proves hookAltersDeltas(h) == false,
//        so the fired 9 can only be the isHookLive site.
//    W2  _swapPrePulled    `block.timestamp > deadline`            -> RouterE(4)
//        The deadline check serving the Permit2 / native / best doors (both
//        existing deadline tests enter through the classic door's _swap).
//    W3  swapBestExactIn   solver fail-closed shape check          -> RouterE(3)
//        `plan.best.hops.length == 0 || hops[0].tokenIn != tokenIn`, BEFORE
//        the pull. Fired with a hostile stub solver wired at construction.
//    W4  _execV4Amt        `tokenOther == address(0)` (auxId == 0) -> RouterE(8)
//        Reachable only where hop.tokenOut == address(0), which makes the
//        leg-homogeneity guard pass by coincidence (0 == 0).
//    W5  BPC.mulDiv        `require(d > prod1)`                    -> "BPC:mulDiv"
//        The 512->256 reduction's only correctness gate.
//    W6  Hub.claimV4       `c0 == c1` (permissionless door)        -> HubE(4)
//    W7  Hub.addFactory    mode-9 `fees.length != spacings.length` -> HubE(5)
//    W8  swapExactInNative `route.hops.length == 0`                -> RouterE(3)
//    W9  queueRescue       `to == address(0)`                      -> RouterE(3)
//    W10 Hub.addV4         `c0 == c1`                              -> HubE(4)
//    W11 Router constructor: each zero arm (hub/solver/admin)      -> RouterE(3)
//    W12 Solver constructor: hub == address(0)                     -> "Solver:hub0"
//
//  V4 note: reuses BubblingV4Manager from RefusalsNeverDriven -- it re-raises
//  the Router's inner revert bytes verbatim, which is the only reason the V4
//  codes are visible at all (the older hostile manager swallowed them and
//  re-reverted with a string).
//
//  forge test --match-contract GuardsNeverFired -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg, RoutePlan
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {BubblingV4Manager} from "./RefusalsNeverDriven.t.sol";

// ─── W8 helper: WETH9-shaped mock (deposit mints 1:1) ────────────────────────
contract MockWETHGNF is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable {
        this.mint(msg.sender, msg.value);
    }
}

// ─── W3 helper: a solver the canonical contract can never be ─────────────────
//
// The canonical Solver cannot produce either bad shape, but `solver` is a
// plain constructor argument of the Router. This stub is that hostile
// constructor argument. Mode 0 is the honest twin (control): a valid one-hop
// V2 plan over the harness pair. Mode 1 returns an all-zero RoutePlan. Mode 2
// returns a VALID-SHAPED plan whose hops[0].tokenIn is a different token --
// the half of the guard that is NOT re-caught downstream: without the check
// the Router would pull token A and then spend a stranded balance of token B.
contract StubSolverGNF {
    uint8   public immutable mode;
    address public immutable pool;
    address public immutable badToken;

    constructor(uint8 mode_, address pool_, address badToken_) {
        mode = mode_;
        pool = pool_;
        badToken = badToken_;
    }

    function findBestRoutePlan(address tIn, address tOut, uint256 amountIn)
        external view returns (RoutePlan memory plan)
    {
        if (mode == 1) return plan; // all-zero: hops.length == 0
        address hopIn = mode == 2 ? badToken : tIn;
        bool zfo = hopIn < tOut;
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: hopIn, tokenOut: tOut,
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        plan.best = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }
}

// ─── W5 helper: external boundary so expectRevert can observe the require ────
contract MulDivHarnessGNF {
    function md(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return BPC.mulDiv(a, b, d);
    }
}

contract GuardsNeverFiredTest is Test {
    // V2 / doors harness
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockPermit2 permit2;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockERC20 tokenBad;
    MockV2Pair pair;

    // native (W8) harness
    MockWETHGNF wethTok;
    MockV2Pair wpair;

    // V4 harness (manager wired)
    BubblingV4Manager mgrV4;
    BlazePhoenixHub hubV4;
    BlazePhoenixRouter routerV4;
    MockERC20 vA;
    MockERC20 vB;

    // best-door harness (W3): one router per stub solver
    StubSolverGNF stubGood;
    StubSolverGNF stubEmpty;
    StubSolverGNF stubMismatch;
    BlazePhoenixRouter routerBestGood;
    BlazePhoenixRouter routerBestEmpty;
    BlazePhoenixRouter routerBestMismatch;

    MulDivHarnessGNF mdh;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);
    address stranger = address(0x51DE);

    uint256 constant RESERVE = 10_000e18;
    address constant V4_PID_ADDR = address(uint160(uint256(keccak256("pid"))));

    // W1: hook address whose low 14 bits are ZERO, so hookAltersDeltas(h) is
    // false by construction and the neighbouring RouterE(9) site is cleared.
    address constant HOOK = address(uint160(0xBEEF) << 14);
    bytes constant RUNTIME_A = hex"fe";
    bytes constant RUNTIME_B = hex"fefe";

    function setUp() public {
        // ── V2 / doors side ──
        hub = new BlazePhoenixHub(address(this));
        tokenIn  = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        tokenBad = new MockERC20("Bad", "BAD");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEE2), address(this), treasury1, treasury2
        );
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));

        tokenIn.mint(address(pair), RESERVE);
        tokenOut.mint(address(pair), RESERVE);
        pair.setReserves(uint112(RESERVE), uint112(RESERVE));

        tokenIn.mint(user, 10_000e18);
        vm.startPrank(user);
        tokenIn.approve(address(router), type(uint256).max);
        tokenIn.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        // ── native (W8) side: weth wired on the main router ──
        wethTok = new MockWETHGNF();
        router.setWeth(address(wethTok));
        wpair = new MockV2Pair(address(wethTok), address(tokenOut));
        wethTok.mint(address(wpair), RESERVE);
        tokenOut.mint(address(wpair), RESERVE);
        wpair.setReserves(uint112(RESERVE), uint112(RESERVE));

        // ── V4 side: hub WITH a working, revert-bubbling manager ──
        mgrV4 = new BubblingV4Manager();
        hubV4 = new BlazePhoenixHub(address(this));
        hubV4.initialize(address(this), address(mgrV4));
        routerV4 = new BlazePhoenixRouter(
            address(hubV4), address(0xBEE2), address(this), treasury1, treasury2
        );
        vA = new MockERC20("V4A", "V4A");
        vB = new MockERC20("V4B", "V4B");
        vA.mint(user, 1_000_000e18);
        vB.mint(address(mgrV4), 1_000_000e18); // output liquidity for take()
        vm.prank(user);
        vA.approve(address(routerV4), type(uint256).max);

        // ── best-door (W3) side ──
        stubGood     = new StubSolverGNF(0, address(pair), address(0));
        stubEmpty    = new StubSolverGNF(1, address(0), address(0));
        stubMismatch = new StubSolverGNF(2, address(pair), address(tokenBad));
        routerBestGood = new BlazePhoenixRouter(
            address(hub), address(stubGood), address(this), treasury1, treasury2
        );
        routerBestEmpty = new BlazePhoenixRouter(
            address(hub), address(stubEmpty), address(this), treasury1, treasury2
        );
        routerBestMismatch = new BlazePhoenixRouter(
            address(hub), address(stubMismatch), address(this), treasury1, treasury2
        );
        // Approval ONLY to the honest-stub router. The two fire arms run with
        // ZERO approval on purpose: the guard under test sits BEFORE the pull,
        // so it must fire without any allowance in place -- if the guard were
        // deleted, the pull would be reached and die on the missing allowance
        // with a completely different error, so RouterE(3) with no approval
        // pins the revert to the fail-closed check itself.
        vm.prank(user);
        tokenIn.approve(address(routerBestGood), type(uint256).max);

        mdh = new MulDivHarnessGNF();
    }

    // ─── Shared builders (house shapes, copied from RefusalsNeverDriven) ─────

    function _v2Route(address pool, address tIn, address tOut, uint256 amountIn, uint256 legAmountIn)
        private pure returns (Route memory route)
    {
        bool zfo = tIn < tOut;
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: legAmountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: tOut, amountIn: amountIn, expectedOut: 0, legs: legs });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// @dev Single-hop V4 leg vA -> vB; `hooksAddr` and `auxId`/`hopOut` are
    ///      the knobs the witnesses turn. The fully-formed shape (auxId = vB,
    ///      hopOut = vB, hooks = 0) is the settling shape RefusalsNeverDriven
    ///      already proved end to end against this same manager.
    function _v4Route(uint256 amountIn, address hooksAddr, bytes32 auxId, address hopOut)
        private view returns (Route memory route)
    {
        bool zfo = address(vA) < address(vB);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: V4_PID_ADDR, hooks: hooksAddr, kind: BPC.KIND_V4, fee: 500,
            tickSpacing: 10, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: auxId
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(vA), tokenOut: hopOut,
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _netOfFee(uint256 amountIn) private pure returns (uint256) {
        return amountIn - BPC.mulDivUp(amountIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    function _hubErr(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, code);
    }

    /// @dev Admit HOOK with RUNTIME_A etched (the pin records keccak(RUNTIME_A))
    ///      and prove the hooked route SETTLES in that state. Every W1 case
    ///      starts here, so each fire differs from this settling state in
    ///      exactly one respect.
    function _admitHookAndSettleOnce() private {
        vm.etch(HOOK, RUNTIME_A);
        hubV4.allowHook(HOOK, true);
        Route memory route = _v4Route(1_000e18, HOOK, bytes32(uint256(uint160(address(vB)))), address(vB));
        vm.prank(user);
        uint256 delivered = routerV4.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
        assertEq(delivered, _netOfFee(1_000e18),
            "setup: the admitted, unmutated hook must route (also proves hookAltersDeltas(HOOK) is false)");
    }

    // =========================================================================
    //  W1 -- _execV4Amt: `!hub.isHookLive(leg.hooks)` (RouterE 9)
    //  The execution-time codehash pin. The only RouterE(9) any prior test
    //  drives is the hookAltersDeltas neighbour one line above -- same code,
    //  different guard. HOOK's low 14 bits are zero, so the neighbour cannot
    //  fire for this address, and the settling preamble proves it end to end.
    // =========================================================================

    /// @notice Control: admitted hook, code unchanged -- the byte-identical
    ///         route settles. This is the state every fire below perturbs.
    function test_W1_Control_AdmittedUnmutatedHook_Settles() public {
        _admitHookAndSettleOnce();
    }

    /// @notice Fire A (revocation): allowHook(h, false), same route.
    ///         Differs from the control ONLY in the allow-list bit.
    function test_W1_FireA_RevokedHook_Reverts9() public {
        _admitHookAndSettleOnce();
        hubV4.allowHook(HOOK, false);
        assertFalse(hubV4.isHookLive(HOOK), "sanity: revocation kills liveness");
        Route memory route = _v4Route(1_000e18, HOOK, bytes32(uint256(uint160(address(vB)))), address(vB));
        vm.prank(user);
        vm.expectRevert(_err(9));
        routerV4.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    /// @notice Fire B (mutation) -- the actual Layer-3 claim: still allowed,
    ///         but the code at the hook address changed after admission. The
    ///         pin recorded keccak(RUNTIME_A); etching RUNTIME_B breaks the
    ///         match and the route must refuse. Differs from the control ONLY
    ///         in the runtime bytes at the hook address.
    function test_W1_FireB_MutatedHookCode_Reverts9() public {
        _admitHookAndSettleOnce();
        vm.etch(HOOK, RUNTIME_B);
        assertFalse(hubV4.isHookLive(HOOK), "sanity: a code change auto-pauses the hook");
        Route memory route = _v4Route(1_000e18, HOOK, bytes32(uint256(uint160(address(vB)))), address(vB));
        vm.prank(user);
        vm.expectRevert(_err(9));
        routerV4.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    // =========================================================================
    //  W2 -- _swapPrePulled: `block.timestamp > deadline` (RouterE 4)
    //  The deadline check serving the pre-pulled doors (Permit2 / native /
    //  best). Both existing deadline tests enter through the classic door's
    //  _swap; this one enters through Permit2. RouterE(4) has exactly one site
    //  on this path, so the code alone pins it; the boundary control proves
    //  the comparison is strict.
    // =========================================================================

    function _permit(uint256 amount) private view returns (IPermit2.PermitTransferFrom memory) {
        return IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(tokenIn), amount: amount }),
            nonce: 0,
            deadline: block.timestamp + 60
        });
    }

    function test_W2_Permit2Door_DeadlinePassed_Reverts4() public {
        vm.warp(1000);
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), 1_000e18, 1_000e18);
        IPermit2.PermitTransferFrom memory p = _permit(1_000e18);
        vm.prank(user);
        vm.expectRevert(_err(4));
        router.swapExactInWithPermit2(route, 1_000e18, 1, user, 999, p, "");
    }

    /// @notice Boundary control: deadline == block.timestamp EXACTLY. The
    ///         comparison is strict (`>`), so the same-second swap executes.
    function test_W2_Permit2Door_DeadlineExactlyNow_BoundaryPasses() public {
        vm.warp(1000);
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), 1_000e18, 1_000e18);
        IPermit2.PermitTransferFrom memory p = _permit(1_000e18);
        vm.prank(user);
        uint256 delivered = router.swapExactInWithPermit2(route, 1_000e18, 1, user, 1000, p, "");
        assertGt(delivered, 0, "deadline == now is the passing boundary of the pre-pulled doors");
    }

    // =========================================================================
    //  W3 -- swapBestExactIn: solver fail-closed shape check (RouterE 3)
    //  `solver` is a constructor argument; a hostile solver can return an
    //  empty plan or a valid-shaped plan starting in a DIFFERENT token. The
    //  second half is not re-caught downstream: without this guard the Router
    //  would pull token A and then spend a stranded balance of token B. Both
    //  fire arms run with ZERO approval to their router, so the observed
    //  RouterE(3) can only come from BEFORE the pull (a reached pull would
    //  die on the missing allowance with a different error).
    // =========================================================================

    function test_W3_FireA_EmptyPlan_Reverts3_BeforeAnyPull() public {
        vm.prank(user);
        vm.expectRevert(_err(3));
        routerBestEmpty.swapBestExactIn(
            address(tokenIn), address(tokenOut), 1e18, 1, user, block.timestamp + 1
        );
    }

    function test_W3_FireB_TokenInMismatchPlan_Reverts3_BeforeAnyPull() public {
        vm.prank(user);
        vm.expectRevert(_err(3));
        routerBestMismatch.swapBestExactIn(
            address(tokenIn), address(tokenOut), 1e18, 1, user, block.timestamp + 1
        );
    }

    /// @notice Control: the honest stub (same shape, hops[0].tokenIn == tokenIn)
    ///         through an identically constructed router settles end to end.
    function test_W3_Control_WellFormedPlan_Settles() public {
        vm.prank(user);
        uint256 delivered = routerBestGood.swapBestExactIn(
            address(tokenIn), address(tokenOut), 1e18, 1, user, block.timestamp + 1
        );
        assertGt(delivered, 0, "a well-shaped plan from the wired solver must execute");
    }

    // =========================================================================
    //  W4 -- _execV4Amt: `tokenOther == address(0)` i.e. auxId == 0 (RouterE 8)
    //  Reachable only where hop.tokenOut == address(0): the leg-homogeneity
    //  guard compares auxId's low 160 bits against hop.tokenOut, and 0 == 0
    //  passes by coincidence. The manager is wired and never touched (the
    //  guard fires before unlock), so the only other RouterE(8) candidate on
    //  the path -- mgr == 0 -- is excluded by the same harness state Control B
    //  proves by settling.
    // =========================================================================

    function test_W4_Fire_V4LegAuxIdZero_Reverts8() public {
        Route memory route = _v4Route(1e18, address(0), bytes32(0), address(0));
        vm.prank(user);
        vm.expectRevert(_err(8));
        routerV4.swapExactIn(route, 1e18, 1, user, block.timestamp + 1);
    }

    /// @notice Control A -- one field changed (auxId 0 -> vB, hop.tokenOut
    ///         still 0): the homogeneity guard now sees vB != 0 and refuses
    ///         with RouterE(3), a DIFFERENT code. This pins the fire's 8 to
    ///         the auxId gate and documents the 0 == 0 coincidence that makes
    ///         it reachable at all.
    function test_W4_ControlA_NonzeroAuxIdZeroTokenOut_Reverts3() public {
        Route memory route = _v4Route(1e18, address(0), bytes32(uint256(uint160(address(vB)))), address(0));
        vm.prank(user);
        vm.expectRevert(_err(3));
        routerV4.swapExactIn(route, 1e18, 1, user, block.timestamp + 1);
    }

    /// @notice Control B -- the fully-formed leg (auxId = vB, hop.tokenOut =
    ///         vB) settles through the same router, proving the manager is
    ///         wired (mgr != 0) and the path is otherwise clean.
    function test_W4_ControlB_FullyFormedV4Leg_Settles() public {
        Route memory route = _v4Route(1_000e18, address(0), bytes32(uint256(uint160(address(vB)))), address(vB));
        vm.prank(user);
        uint256 delivered = routerV4.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
        assertEq(delivered, _netOfFee(1_000e18), "fully-formed V4 leg settles in full");
    }

    // =========================================================================
    //  W5 -- BPC.mulDiv: `require(d > prod1)` ("BPC:mulDiv")
    //  The only correctness gate of the 512->256 reduction. a = b = 2^128
    //  makes the product exactly 2^256 (prod1 = 1, prod0 = 0): with d = 1 the
    //  require is `1 > 1` and refuses; with d = 2 (= prod1 + 1, the smallest
    //  passing divisor) the reduction runs and returns exactly 2^255.
    // =========================================================================

    function test_W5_Fire_MulDivResultOverflows_Reverts() public {
        vm.expectRevert(bytes("BPC:mulDiv"));
        mdh.md(2 ** 128, 2 ** 128, 1);
    }

    /// @notice Boundary control: d == prod1 + 1, one past the refusal, and the
    ///         full 512-bit reduction returns the exact quotient.
    function test_W5_Control_SmallestPassingDivisor_Exact() public {
        assertEq(mdh.md(2 ** 128, 2 ** 128, 2), 2 ** 255,
            "d == prod1 + 1 is the passing boundary and the reduction is exact");
    }

    // =========================================================================
    //  W6 -- Hub.claimV4: `c0 == c1` (HubE 4), permissionless door
    //  Deletion-sensitive: with the guard removed the same call falls through
    //  to the bridge-anchor gate and dies HubE(9) -- Control demonstrates that
    //  exact fall-through code with the equality as the only difference, so
    //  only the specific code tells the guard from its absence.
    // =========================================================================

    function test_W6_Fire_ClaimV4EqualCurrencies_Reverts4() public {
        vm.prank(stranger); // permissionless door: any caller
        vm.expectRevert(_hubErr(4));
        hubV4.claimV4(address(vA), address(vA), 3000, 60);
    }

    /// @notice Control -- equality removed, everything else identical: the
    ///         call falls PAST the c0 == c1 site into the anchor gate and
    ///         refuses HubE(9), which is precisely where a deleted guard
    ///         would send the equal-pair call too.
    function test_W6_Control_DistinctPairFallsThrough_Reverts9() public {
        vm.prank(stranger);
        vm.expectRevert(_hubErr(9));
        hubV4.claimV4(address(vA), address(vB), 3000, 60);
    }

    // =========================================================================
    //  W7 -- Hub.addFactory: mode-9 `fees.length != spacings.length` (HubE 5)
    //  HubE(5) has six earlier sites in the same function; the control clears
    //  every one of them with argument-identical inputs except the spacings
    //  length, which pins the fire to the pairing check.
    // =========================================================================

    function test_W7_Fire_Mode9UnpairedFees_Reverts5() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        int24[] memory spacings = new int24[](0);
        vm.expectRevert(_hubErr(5));
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, 9, bytes32(0), fees, spacings);
    }

    /// @notice Control: same factory, kind, mode and init hash, spacings now
    ///         paired 1:1 with fees -- registers and the count advances.
    function test_W7_Control_Mode9PairedFees_Registers() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        int24[] memory spacings = new int24[](1);
        spacings[0] = 10;
        uint256 before = hub.factoryCount();
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, 9, bytes32(0), fees, spacings);
        assertEq(hub.factoryCount(), before + 1, "paired fees/spacings is the passing shape of mode 9");
    }

    // =========================================================================
    //  W8 -- swapExactInNative: `route.hops.length == 0` (RouterE 3)
    //  weth IS wired in setUp, so the earlier weth == 0 site (same code)
    //  cannot be the one firing -- the settling control through the same door
    //  proves the wiring. Deletion flips this to Panic 0x32 (hops[0] on an
    //  empty array), so the specific code is what watches the guard.
    // =========================================================================

    function test_W8_Fire_NativeDoorEmptyRoute_Reverts3() public {
        Hop[] memory hops = new Hop[](0);
        Route memory route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
        vm.deal(user, 2e18);
        vm.prank(user);
        vm.expectRevert(_err(3));
        router.swapExactInNative{value: 1e18}(route, 1, user, block.timestamp + 1);
    }

    /// @notice Control -- one hop instead of zero, all else identical: the
    ///         same door with the same value wraps and settles WETH -> OUT.
    function test_W8_Control_NativeDoorOneHopWethRoute_Settles() public {
        Route memory route = _v2Route(address(wpair), address(wethTok), address(tokenOut), 1e18, 1e18);
        vm.deal(user, 2e18);
        vm.prank(user);
        uint256 delivered = router.swapExactInNative{value: 1e18}(route, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "the wired native door executes a one-hop WETH route");
    }

    // =========================================================================
    //  W9 -- queueRescue: `to == address(0)` (RouterE 3)
    //  RouterE(3) has exactly one site in this function (the auth path is
    //  RouterE(1) and the caller here IS the admin), so the code pins it.
    // =========================================================================

    function test_W9_Fire_QueueRescueZeroTo_Reverts3() public {
        vm.expectRevert(_err(3));
        router.queueRescue(address(tokenIn), address(0));
    }

    /// @notice Control -- nonzero destination, same token, same caller: the
    ///         rescue queues and the 48h eta is recorded.
    function test_W9_Control_QueueRescueNonzeroTo_Queues() public {
        router.queueRescue(address(tokenIn), address(0xD00D));
        uint256 eta = router.rescueEta(keccak256(abi.encodePacked(address(tokenIn), address(0xD00D))));
        assertEq(eta, block.timestamp + 48 hours, "queued rescue records the timelocked eta");
    }

    // =========================================================================
    //  W10 -- Hub.addV4: `c0 == c1` (HubE 4)
    //  The operator-door twin of W6. _ne0(c1) precedes it (HubE 3), so a
    //  nonzero token isolates the equality site; the control registers.
    // =========================================================================

    function test_W10_Fire_AddV4EqualCurrencies_Reverts4() public {
        vm.expectRevert(_hubErr(4));
        hubV4.addV4(address(vA), address(vA), 500, 10, address(0));
    }

    /// @notice Control -- distinct currencies, all else identical: registers
    ///         and returns a nonzero key.
    function test_W10_Control_AddV4DistinctPair_Registers() public {
        bytes32 key = hubV4.addV4(address(vA), address(vB), 500, 10, address(0));
        assertTrue(key != bytes32(0), "distinct currencies register and key");
    }

    // =========================================================================
    //  W11 -- Router constructor: each zero arm of hub/solver/admin (RouterE 3)
    //  The treasuries are deliberately NOT guarded (zero falls back to the
    //  admin), which is the boundary the control walks.
    // =========================================================================

    function test_W11_FireA_CtorZeroHub_Reverts3() public {
        vm.expectRevert(_err(3));
        new BlazePhoenixRouter(address(0), address(0xBEE2), address(this), treasury1, treasury2);
    }

    function test_W11_FireB_CtorZeroSolver_Reverts3() public {
        vm.expectRevert(_err(3));
        new BlazePhoenixRouter(address(hub), address(0), address(this), treasury1, treasury2);
    }

    function test_W11_FireC_CtorZeroAdmin_Reverts3() public {
        vm.expectRevert(_err(3));
        new BlazePhoenixRouter(address(hub), address(0xBEE2), address(0), treasury1, treasury2);
    }

    /// @notice Control -- zeros moved to the UNguarded arms: the treasuries
    ///         may be zero and default to the admin; construction succeeds.
    function test_W11_Control_ZeroTreasuriesDefaultToAdmin() public {
        BlazePhoenixRouter r = new BlazePhoenixRouter(
            address(hub), address(0xBEE2), address(this), address(0), address(0)
        );
        assertEq(r.treasury1(), address(this), "zero treasury1 falls back to admin");
        assertEq(r.treasury2(), address(this), "zero treasury2 falls back to admin");
    }

    // =========================================================================
    //  W12 -- Solver constructor: hub == address(0) ("Solver:hub0")
    // =========================================================================

    function test_W12_Fire_SolverCtorZeroHub_Reverts() public {
        vm.expectRevert(bytes("Solver:hub0"));
        new BlazePhoenixSolver(address(0));
    }

    /// @notice Control -- a real hub address constructs and is stored.
    function test_W12_Control_SolverCtorNonzeroHub_Deploys() public {
        BlazePhoenixSolver s = new BlazePhoenixSolver(address(hub));
        assertEq(address(s.hub()), address(hub), "the hub reference survives construction");
    }
}
