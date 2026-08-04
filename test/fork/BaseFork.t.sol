// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

interface IERC20Fork {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Fork test against REAL Base mainnet liquidity — the gap TESTING.md
///         flagged as entirely missing ("Fork tests against real liquidity —
///         none exist"). Requires network access to the `base` RPC configured
///         in foundry.toml. Run with:
///           forge test --match-contract BaseForkTest -vvv
///         (uses vm.createSelectFork, which is the same underlying forking
///         engine a standalone `anvil --fork-url` process uses — no separate
///         anvil process needs to be kept alive for this to be a real test
///         against live chain state).
contract BaseForkTest is Test {
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    function setUp() public {
        vm.createSelectFork("base");
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
    }

    /// @notice The deployed Hub must actually be wired with Base's real
    ///         factories/bridges — a smoke check that the wiring helper ran
    ///         and didn't silently no-op.
    function test_Deployment_WiresRealBaseFactoriesAndBridges() public view {
        assertGt(hub.factoryCount(), 0);
        assertTrue(hub.isBridgeToken(BASE_WETH));
        assertTrue(hub.isBridgeToken(BASE_USDC));
    }

    /// @notice Quoting USDC -> WETH against LIVE Base liquidity must return a
    ///         plausible, nonzero route. This is a real end-to-end exercise
    ///         of Hub.discoverFor (CREATE2 + factory-call derivation against
    ///         real deployed factories), the Solver's median filter/capital
    ///         anchor/depth-weighted split over REAL pools, and the Quoter's
    ///         packing math — none of which any mock-based test can reach.
    function test_Preview_USDCtoWETH_AgainstRealLiquidity() public {
        uint256 amountIn = 1_000e6; // 1,000 USDC (6 decimals)
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(BASE_USDC, BASE_WETH, amountIn);

        console2.log("grossOut (wei WETH):", pv.grossOut);
        console2.log("netOut   (wei WETH):", pv.netOut);
        console2.log("legs used          :", pv.legs);
        console2.log("hops used          :", pv.hops);

        assertGt(pv.grossOut, 0, "must find a real route for USDC/WETH on Base");
        // Base WETH sits well above ~0.0001 ETH per 1000 USDC and well below
        // 10 ETH per 1000 USDC across any plausible price regime — a loose
        // sanity band against a decimal/unit-mixing bug, not a price oracle.
        assertGt(pv.grossOut, 0.0001 ether);
        assertLt(pv.grossOut, 10 ether);
        assertTrue(pv.canExecute);
    }

    /// @notice Full execution against real Base liquidity: deal real USDC to
    ///         a test user (via forge-std's deal, which locates the ERC20
    ///         balance storage slot automatically), run the Solver-suggested
    ///         route through the real Router, and confirm WETH is actually
    ///         delivered net of the protocol fee.
    function test_Execute_USDCtoWETH_AgainstRealLiquidity() public {
        address user = address(0xBEEF);
        uint256 amountIn = 1_000e6;
        deal(BASE_USDC, user, amountIn);
        // 0xBEEF is a well-known example/test address that may carry real
        // pre-existing dust on forked mainnet state — measure the DELTA the
        // swap produces, not an absolute post-swap balance (the same
        // discipline the Router itself uses internally, never assuming a
        // zero baseline).
        uint256 wethBefore = IERC20Fork(BASE_WETH).balanceOf(user);

        vm.prank(user);
        IERC20Fork(BASE_USDC).approve(address(router), amountIn);

        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlan(BASE_USDC, BASE_WETH, amountIn);
        assertGt(pv.grossOut, 0, "precondition: a route must exist to execute");

        vm.prank(user);
        uint256 delivered = router.swapExactIn(pv.route, amountIn, 0, user, block.timestamp + 60);

        console2.log("delivered (wei WETH):", delivered);
        assertEq(IERC20Fork(BASE_WETH).balanceOf(user) - wethBefore, delivered);
        assertGt(delivered, 0);
        // Router must hold nothing afterward (the same holds-nothing
        // invariant checked by the mock-based invariant suite, now verified
        // against a real multi-venue execution path).
        assertEq(IERC20Fork(BASE_USDC).balanceOf(address(router)), 0);
        assertEq(IERC20Fork(BASE_WETH).balanceOf(address(router)), 0);
    }
}
