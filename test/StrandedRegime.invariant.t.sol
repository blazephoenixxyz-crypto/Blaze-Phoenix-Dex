// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  META-TEST OF THE INVARIANT LAYER — THE REGIME NO CAMPAIGN EVER ENTERS.
//
//  Measured on this tree: 10 unit-test sites deliberately seed the Router with
//  a pre-existing ("stranded" / rescue-territory) balance, and ZERO of the nine
//  stateful invariant campaigns do. Every campaign starts the Router at zero,
//  so in every stateful run:
//
//      baseIn      == 0        (Router:981)
//      bridgeBase  == 0        (Router:~1000)
//      toutStart   == 0
//      foreignBase == 0
//
//  Those four baselines exist for exactly one purpose: to stop a crafted route
//  from sweeping money the Router already held. Under base == 0 every one of
//  them is dead code, so `invariant_RouterHoldsNothing` (six copies across the
//  suite) has never distinguished "the sweep subtracted the baseline correctly"
//  from "there was no baseline to subtract". It certifies that the Router ends
//  at zero over a universe where it also started at zero.
//
//  This campaign runs the same swaps with the Router holding money at rest, and
//  adds an adversarial action that aims a leg at a pool the hop never declared
//  (the LegDivergentStrandedDrain shape) so the search actually pushes on the
//  drain, instead of asserting it once by hand.
//
//  forge test --match-contract MetaStrandedRegime -vv
// =============================================================================

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract StrandedRegimeHandler {
    BlazePhoenixRouter immutable router;
    MockERC20 immutable A;
    MockERC20 immutable B;
    MockERC20 immutable T;
    MockV2Pair immutable poolAB;
    MockV2Pair immutable poolTB;
    address immutable recipient;

    uint256 public swaps;
    uint256 public divergentAttempts;
    uint256 public divergentSettled;
    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public mintedT;

    // ─── THE COMPOSITION AXIS ───
    // Measured on this tree: the action alphabet of ALL NINE existing invariant
    // campaigns is ten handler functions, and every one of them is a swap or a
    // recordSwap. Not one campaign can call setPaused, setTreasuries, setAdmin,
    // addFactory, addBridge or allowHook WHILE swaps are in flight. Every
    // configuration transition in this repository is tested only as an isolated
    // unit case from a quiescent state, so no search has ever interleaved one
    // with a route. These two actions add that axis.
    address[4] public tcands;
    uint256 public treasuryRotations;
    uint256 public pauseToggles;
    uint256 public attemptsWhilePaused;
    uint256 private pauseTick;
    uint256 public settledWhilePaused;

    constructor(
        BlazePhoenixRouter _router, MockERC20 _a, MockERC20 _b, MockERC20 _t,
        MockV2Pair _poolAB, MockV2Pair _poolTB, address _recipient, address[4] memory _tcands
    ) {
        router = _router; A = _a; B = _b; T = _t;
        poolAB = _poolAB; poolTB = _poolTB; recipient = _recipient;
        tcands = _tcands;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    /// The ordinary, honest swap — the same shape every existing campaign fuzzes,
    /// but executed against a Router that is holding money at rest.
    function swap(uint256 dirSeed, uint256 amtSeed) external {
        bool aIn = dirSeed % 2 == 0;
        MockERC20 tin = aIn ? A : B;
        MockERC20 tout = aIn ? B : A;
        uint256 amt = _bound(amtSeed, 1e15, 1e21);

        tin.mint(address(this), amt);
        tout.mint(address(poolAB), 1e27);
        if (aIn) { mintedA += amt; mintedB += 1e27; } else { mintedB += amt; mintedA += 1e27; }
        tin.approve(address(router), amt);

        (uint112 r0, uint112 r1,) = poolAB.getReserves();
        address t0 = poolAB.token0();
        uint256 rIn  = address(tin) == t0 ? r0 : r1;
        uint256 rOut = address(tin) == t0 ? r1 : r0;
        uint256 quoted = BPC.outV2(amt, rIn, rOut, 30);
        if (quoted == 0) return;

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(poolAB), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tin) == t0, stable: false,
            amountIn: amt, expectedOut: quoted, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tin), tokenOut: address(tout),
                       amountIn: amt, expectedOut: quoted, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: quoted, singleOut: quoted, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        bool wasPaused = router.paused();
        if (wasPaused) { unchecked { ++attemptsWhilePaused; } }
        try router.swapExactIn(r, amt, 1, recipient, block.timestamp + 1) returns (uint256) {
            unchecked { ++swaps; if (wasPaused) ++settledWhilePaused; }
        } catch {}
    }

    /// THE ADVERSARIAL ACTION. A hop that DECLARES A->B while its only leg names
    /// the T/B pool. `_legTokens` derives the leg's tokens from the calldata pool,
    /// so legIn resolves to T -- a token this swap never received and which the
    /// Router is holding only because someone mis-sent it. Router:1216 must refuse.
    function swapDivergent(uint256 amtSeed) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        A.mint(address(this), amt); mintedA += amt;
        B.mint(address(poolTB), 1e27); mintedB += 1e27;
        A.approve(address(router), amt);

        address t0 = poolTB.token0();
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(poolTB), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(T) == t0, stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B),
                       amountIn: amt, expectedOut: 0, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });

        unchecked { ++divergentAttempts; }
        try router.swapExactIn(r, amt, 1, recipient, block.timestamp + 1) returns (uint256) {
            unchecked { ++divergentSettled; }
        } catch {}
    }

    /// ADMIN ACTION 1 - the treasuries move while routes are in flight.
    function adminRotateTreasuries(uint256 seed) external {
        address t1 = tcands[seed % 4];
        address t2 = tcands[(seed / 4) % 4];
        if (t1 == t2) t2 = tcands[(seed / 4 + 1) % 4];
        try router.setTreasuries(t1, t2) { unchecked { ++treasuryRotations; } } catch {}
    }

    /// ADMIN ACTION 2 - the pause flag moves while routes are in flight.
    /// THE ALTERNATION IS STRUCTURAL, AND THAT WAS MEASURED, NOT CHOSEN.
    /// Two earlier drafts derived the flag from the fuzz word -- `seed % 8 == 0`,
    /// then `seed % 2 == 0` -- and BOTH went red on this file's own anti-vacuity
    /// gates, in opposite directions: one window settled no swap at all, another
    /// attempted no swap while paused. Foundry's fuzz DICTIONARY is harvested from
    /// the compiled project and is dominated by round constants, so the low bit of
    /// a drawn word is not a fair coin and `% 2` is not a 50/50 split. The V4
    /// adversary in this repository records the same trap for its minOut draw.
    /// An internal tick cannot be biased by the dictionary: the composition is then
    /// a property of the campaign, not of which literals happen to be in scope.
    function adminPause(uint256 seed) external {
        seed;
        bool p;
        unchecked { p = (++pauseTick % 2 == 0); }
        try router.setPaused(p) { unchecked { ++pauseToggles; } } catch {}
    }
}

contract MetaStrandedRegimeInvariantTest is StdInvariant, Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A; MockERC20 B; MockERC20 T;
    MockV2Pair poolAB; MockV2Pair poolTB;
    StrandedRegimeHandler handler;

    address recipient = makeAddr("recipient");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");
    address treasury3 = makeAddr("treasury3");
    address treasury4 = makeAddr("treasury4");

    /// Money the Router is holding AT REST before any swap: mis-sent funds
    /// awaiting the rescue path. No campaign in this repository has ever put
    /// the Router in this state.
    uint256 constant SEED_A = 100e18;
    uint256 constant SEED_B = 250e18;
    uint256 constant SEED_T = 777e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        T = new MockERC20("T", "T");
        poolAB = new MockV2Pair(address(A), address(B));
        poolTB = new MockV2Pair(address(T), address(B));
        poolAB.setReserves(1e27, 1e27);
        poolTB.setReserves(1e27, 1e27);

        A.mint(address(router), SEED_A);
        B.mint(address(router), SEED_B);
        T.mint(address(router), SEED_T);

        address[4] memory tc = [treasury1, treasury2, treasury3, treasury4];
        handler = new StrandedRegimeHandler(router, A, B, T, poolAB, poolTB, recipient, tc);
        // The handler becomes the control surface, so the fuzzer can move the
        // configuration DURING the campaign instead of only before it.
        router.setAdmin(address(handler));
        targetContract(address(handler));
    }

    // ─── THE PROPERTY THE BASELINES EXIST FOR ────────────────────────────────

    /// No sequence of routes may pay out money the Router held BEFORE the swap.
    /// This is the only assertion in the suite that can tell a correct baseline
    /// subtraction from no baseline at all.
    function invariant_StrandedMoneyIsNeverSwept() public view {
        assertGe(A.balanceOf(address(router)), SEED_A, "a route swept the Router's pre-existing A");
        assertGe(B.balanceOf(address(router)), SEED_B, "a route swept the Router's pre-existing B");
        assertGe(T.balanceOf(address(router)), SEED_T, "a route reached a token it never traded");
    }

    /// Holds-nothing in its NON-TRIVIAL form: the Router ends every call holding
    /// exactly what it held at rest -- no more (residual stranded) and no less
    /// (rescue money paid out).
    function invariant_HoldsNothingBeyondTheSeed() public view {
        assertEq(A.balanceOf(address(router)), SEED_A, "Router's A moved away from the at-rest seed");
        assertEq(B.balanceOf(address(router)), SEED_B, "Router's B moved away from the at-rest seed");
        assertEq(T.balanceOf(address(router)), SEED_T, "Router's T moved away from the at-rest seed");
    }

    /// A leg may never trade a pair the hop did not declare.
    function invariant_DivergentLegNeverSettles() public view {
        assertEq(handler.divergentSettled(), 0,
            "a hop declaring A->B settled through a T/B pool: the leg-pair guard admitted a divergent leg");
    }

    /// THE COMPOSITION PROPERTY. A Router that is paused must refuse, no matter
    /// what sequence of routes and configuration changes preceded the call. No
    /// existing campaign can express this: none of them can pause.
    function invariant_PausedRouterNeverSettles() public view {
        assertEq(handler.settledWhilePaused(), 0,
            "a swap settled through a PAUSED Router");
    }

    function invariant_LedgerConservationA() public view {
        uint256 sum = A.balanceOf(address(handler)) + A.balanceOf(address(poolAB)) + A.balanceOf(address(poolTB))
            + A.balanceOf(address(router)) + A.balanceOf(recipient)
            + A.balanceOf(treasury1) + A.balanceOf(treasury2)
            + A.balanceOf(treasury3) + A.balanceOf(treasury4);
        assertEq(sum, handler.mintedA() + SEED_A, "token A not conserved");
    }

    function invariant_LedgerConservationT() public view {
        uint256 sum = T.balanceOf(address(handler)) + T.balanceOf(address(poolAB)) + T.balanceOf(address(poolTB))
            + T.balanceOf(address(router)) + T.balanceOf(recipient)
            + T.balanceOf(treasury1) + T.balanceOf(treasury2)
            + T.balanceOf(treasury3) + T.balanceOf(treasury4);
        assertEq(sum, handler.mintedT() + SEED_T, "token T not conserved");
    }

    /// ANTI-VACUITY, and one rung deeper than the campaigns it is modelled on.
    /// Settling swaps is not enough here: the adversarial action must also have
    /// been ATTEMPTED, or `invariant_DivergentLegNeverSettles` is certifying a
    /// counter nothing ever tried to move.
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no swap ever settled - vacuous pass");
        assertGt(handler.divergentAttempts(), 0,
            "the divergent-leg action was never called - the drain guard was never pushed on");
        // NON-VACUITY FOR THE NEW AXIS. A composition campaign whose configuration
        // never actually moved is a swap campaign with extra code: these two gates
        // are what make the interleaving a measured fact rather than an intention.
        assertGt(handler.treasuryRotations(), 0,
            "the treasuries never moved during the campaign - nothing was composed");
        assertGt(handler.pauseToggles(), 0,
            "the pause flag never moved during the campaign - nothing was composed");
        assertGt(handler.attemptsWhilePaused(), 0,
            "no route was ever attempted while the Router was paused - invariant_PausedRouterNeverSettles is certifying a counter nothing tried to move");
    }
}
