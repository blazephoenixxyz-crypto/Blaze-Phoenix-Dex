// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Fuzz and boundary coverage for the Quoter's public entry points, driven from the outside
// against the real Hub, Solver and Router:
//
//   - the bytes previewAndEncode returns are executable AS-IS by the Router and settle at or
//     above the floor they carry;
//   - a preview that says it cannot execute encodes NOTHING;
//   - the user floor can only tighten, never weaken;
//   - boundaries (1 wei, uint128 max, a pool that cannot pay 1 wei): the plan entry points
//     refuse with the Solver's named "no route" error, never a panic, and batchQuote answers
//     the same tuple with a zero-initialised entry instead of reverting;
//   - previewRoute publishes the same numbers as the plan path for the same route;
//   - batchQuote: length == entries, cap reverts with QuoterE(4), failed entries zero.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter, IRouterExec} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract QuoterRoundTripAndBoundariesTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool;

    address recipient = makeAddr("recipient");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2
        );
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));

        pool = new MockV3Pool(address(tokenA), address(tokenB), 100);
        pool.setState(uint160(BPC.Q96), 1e30);
        tokenB.mint(address(pool), 1e30);
        hub.seedPool(address(pool), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));
    }

    /// @dev Named _clamp, not _bound: forge-std's StdUtils._bound is virtual and would
    ///      demand an override; the helper here is deliberately local to the test.
    /// Below this the 1e30-liquidity pool rounds every output to zero and the Solver has no
    /// route; the boundary tests below own that region.
    uint256 constant MIN_ROUTABLE = 1000;

    bytes NO_ROUTE = abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(5));

    function _clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    /// @dev The encoded bytes must be executable by the Router exactly as returned,
    ///      and deliver no less than the floor they carry.
    function testFuzz_EncodedCallIsExecutableAtItsFloor(uint256 amtSeed, uint256 minSeed) public {
        uint256 amt = _clamp(amtSeed, MIN_ROUTABLE, 1e21);
        uint256 userMin = _clamp(minSeed, 0, 1e21);
        uint256 deadline = block.timestamp + 1;

        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = quoter.previewAndEncodeWithMinOut(
            address(tokenA), address(tokenB), amt, userMin, recipient, deadline
        );

        if (!pv.canExecute) {
            assertEq(data.length, 0, "non-executable preview must encode nothing");
            return;
        }

        bytes4 sel;
        assembly { sel := mload(add(data, 32)) }
        assertEq(sel, IRouterExec.swapExactIn.selector, "wrong selector");

        tokenA.mint(address(this), amt);
        tokenA.approve(address(router), amt);
        (bool ok, bytes memory ret) = address(router).call(data);
        assertTrue(ok, "encoded call reverted");
        uint256 out = abi.decode(ret, (uint256));
        assertGe(out, pv.effectiveMinOut, "execution below the effective floor");
    }

    function testFuzz_UserFloorCanOnlyTighten(uint256 amtSeed, uint256 minSeed) public view {
        uint256 amt = _clamp(amtSeed, MIN_ROUTABLE, 1e21);
        uint256 userMin = _clamp(minSeed, 0, 1e21);

        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlanWithMinOut(address(tokenA), address(tokenB), amt, userMin);

        assertGe(pv.effectiveMinOut, pv.ironFloor, "floor weakened below the iron floor");
        assertGe(pv.effectiveMinOut, pv.userMinOut, "floor weakened below the user's");
        if (pv.effectiveMinOut != pv.userMinOut) {
            assertEq(pv.effectiveMinOut, pv.ironFloor, "neither max() arm explains the floor");
        }
    }

    /// @dev previewRoute is the second entry point; it must publish the same numbers
    ///      as the plan path for the same route (single producer of the packer).
    function test_PreviewRouteMatchesPlanForTheSameRoute() public {
        uint256 amt = 1e18;
        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlanWithMinOut(address(tokenA), address(tokenB), amt, 0);
        BlazePhoenixQuoter.Preview memory pv2 = quoter.previewRoute(pv.route, 0);

        assertEq(pv2.grossOut, pv.grossOut);
        assertEq(pv2.protocolFee, pv.protocolFee);
        assertEq(pv2.safetyBuffer, pv.safetyBuffer);
        assertEq(pv2.netOut, pv.netOut);
        assertEq(pv2.ironFloor, pv.ironFloor);
        assertEq(pv2.effectiveMinOut, pv.effectiveMinOut);
        assertEq(pv2.estGas, pv.estGas);
        assertEq(pv2.hops, pv.hops);
        assertEq(pv2.legs, pv.legs);
        assertEq(pv2.topology, pv.topology);
        assertEq(pv2.bridgeUsed, pv.bridgeUsed);
        assertEq(pv2.canExecute, pv.canExecute);
        assertEq(
            keccak256(abi.encode(pv2.route)), keccak256(abi.encode(pv.route)),
            "route drifted between the two entry points"
        );
    }

    /// @dev The plan entry points refuse an unroutable order with the Solver's named error;
    ///      batchQuote answers the same tuple with a zero entry and does not revert.
    function _assertRefusedEverywhere(uint256 amt) internal {
        vm.expectRevert(NO_ROUTE);
        quoter.previewPlanWithMinOut(address(tokenA), address(tokenB), amt, 0);
        vm.expectRevert(NO_ROUTE);
        quoter.previewAndEncode(address(tokenA), address(tokenB), amt, recipient, block.timestamp + 1);
        vm.expectRevert(NO_ROUTE);
        quoter.previewPlanExact(address(tokenA), address(tokenB), amt);

        BlazePhoenixQuoter.BatchEntry[] memory one = new BlazePhoenixQuoter.BatchEntry[](1);
        one[0] = BlazePhoenixQuoter.BatchEntry(address(tokenA), address(tokenB), amt, 0);
        BlazePhoenixQuoter.Preview[] memory pv = quoter.batchQuote(one);
        assertEq(pv.length, 1, "batch length");
        assertEq(pv[0].grossOut, 0, "refused entry must be zero-initialised");
        assertEq(pv[0].netOut, 0, "refused entry must be zero-initialised");
        assertFalse(pv[0].canExecute, "refused entry must not be executable");
    }

    /// @dev 1 wei is the smallest possible order: the pool pays nothing for it.
    function test_Boundary_OneWeiIsRefusedByName() public {
        _assertRefusedEverywhere(1);
    }

    /// @dev uint128 max: refused by name, never an arithmetic panic.
    function test_Boundary_Uint128MaxIsRefusedByName() public {
        _assertRefusedEverywhere(type(uint128).max);
    }

    /// @dev A pool that cannot return 1 wei: refused by name, nothing encoded.
    function test_Boundary_GrossOutZeroIsRefusedByName() public {
        pool.setState(uint160(BPC.Q96), 1); // liquidity 1 wei: out rounds to zero
        _assertRefusedEverywhere(1e18);
    }

    function test_Batch_LengthMatchesEntriesAndCapReverts() public {
        BlazePhoenixQuoter.BatchEntry[] memory entries = new BlazePhoenixQuoter.BatchEntry[](3);
        entries[0] = BlazePhoenixQuoter.BatchEntry(address(tokenA), address(tokenB), 1e18, 0);
        entries[1] = BlazePhoenixQuoter.BatchEntry(address(tokenA), address(tokenB), 1e20, 5e19);
        entries[2] = BlazePhoenixQuoter.BatchEntry(address(tokenA), address(0xC0FFEE), 1e18, 0);

        BlazePhoenixQuoter.Preview[] memory previews = quoter.batchQuote(entries);
        assertEq(previews.length, 3, "batch length != entries");

        for (uint256 i; i < 2; ++i) {
            (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlanWithMinOut(
                entries[i].tIn, entries[i].tOut, entries[i].amountIn, entries[i].userMinOut
            );
            assertEq(previews[i].grossOut, pv.grossOut, "batch grossOut drift");
            assertEq(previews[i].netOut, pv.netOut, "batch netOut drift");
            assertEq(previews[i].effectiveMinOut, pv.effectiveMinOut, "batch floor drift");
            assertEq(previews[i].canExecute, pv.canExecute, "batch canExecute drift");
        }

        assertEq(previews[2].grossOut, 0, "failed entry must be zero-initialised");
        assertEq(previews[2].netOut, 0, "failed entry must be zero-initialised");
        assertFalse(previews[2].canExecute, "failed entry must not be executable");

        BlazePhoenixQuoter.BatchEntry[] memory over = new BlazePhoenixQuoter.BatchEntry[](33);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixQuoter.QuoterE.selector, uint16(4)));
        quoter.batchQuote(over);
    }
}
