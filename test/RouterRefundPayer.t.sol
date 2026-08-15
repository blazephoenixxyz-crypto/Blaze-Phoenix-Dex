// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  D-09b regression — the residual refund must reach the PAYER, not the Router.
//
//  swapBestExactIn reaches _execute through an external SELF-call
//  (selfExecutePrePulled), where msg.sender is the Router itself. The residual
//  sweeps used to pay msg.sender, which on this path was a self-transfer: the
//  caller's unspent input stayed on the Router, recoverable only through the
//  48h rescue. The fix threads the real payer explicitly down
//  selfExecutePrePulled → _swapPrePulled → _execute.
//
//  The test drives an order far past the ~10%-of-reserve band where the
//  Solver's capacity clamp stays quiet (see SwapBestExactInHardening's parity
//  fuzz bound), so the plan commits LESS than the pull and a residual must
//  exist — then asserts it lands with the user, never with the Router. The
//  setup-produced-a-residual assert keeps this from passing vacuously when
//  nothing was left to refund (blind-constant law).
//
//  forge test --match-contract RouterRefundPayer -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract RouterRefundPayerTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool;

    address user = address(0xBEEF);

    uint112 constant R_A = 1_000_000e18;
    // sqrtPriceX96 for price 1.0 (2**96). Deep PHANTOM liquidity + thin REAL
    // holdings makes the single-tick outV3 over-promise, so the V3/Algebra-only
    // capacity clamp cuts the plan below the pull and a residual exists to refund.
    uint160 constant SQRT_P_1 = 79228162514264337593543950336;
    uint128 constant PHANTOM_LIQ = 1_000_000e18;
    uint256 constant REAL_HELD = 50_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        // Thin over-promising V3 pool: single-tick outV3 quotes far more than the
        // pool physically holds, so the Solver's V3/Algebra capacity clamp fires and
        // commits < amountIn. (A V2 pool could never over-promise — outV2 is
        // reserve-bounded — which is why the old V2 fixture left no residual.)
        pool = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        pool.setState(SQRT_P_1, PHANTOM_LIQ);
        tokenB.mint(address(pool), REAL_HELD);
        hub.seedPool(address(pool), BPC.KIND_V3, 3000, address(0), address(tokenA), address(tokenB));

        tokenA.mint(user, 1_000_000e18);
        vm.prank(user);
        tokenA.approve(address(router), type(uint256).max);
    }

    function test_Refund_BestExactIn_ResidualGoesToPayer_NotRouter() public {
        // Half the input-side reserve: the capacity clamp must cut the plan
        // below the pulled amount, leaving a residual to refund.
        uint256 amountIn = uint256(R_A) / 2;
        uint256 aBefore = tokenA.balanceOf(user);

        vm.prank(user);
        uint256 delivered = router.swapBestExactIn(
            address(tokenA), address(tokenB), amountIn, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "swap must complete");

        // Net spend < amountIn iff the refund came back in the same tx.
        uint256 spent = aBefore - tokenA.balanceOf(user);
        assertLt(spent, amountIn, "setup: the clamp must leave a residual to refund");

        // The regression pin: under the pre-fix code both of these fail —
        // the sweep self-transferred, so the Router kept the residual and
        // the user's net spend equalled the full amountIn.
        assertEq(tokenA.balanceOf(address(router)), 0, "router must hold nothing after the swap");
    }
}
