// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// DEX-17 (revisao-total K5; opencode dx/it0020). A concentrated pool whose fee moves after its
// registry row was written. `provenShape` writes the pool's `fee()` into the row when the pool
// is registered, and the quote side read it back as "the static key is truth"
// (`Core.quoteV3Fee`, cfgFee first): the Solver's leg and the preview priced the fee of the
// registration block. The Router never reads the row for a CL leg - the pool charges its own
// fee, and the in-frame floor asks the pool (`quoteV3Fee(leg.pool, 0, ...)`). Two producers of
// "what fee does this pool charge?", one of them stale.
//
// Measured on Base (reports onda1/1c.md §1): the Slipstream WETH/USDC pool at tick spacing 100
// answers `fee()` 549 and 564 in two consecutive blocks and 150..937 pips across 35 samples.
// Fee up since registration: the preview promises more than the pool pays, and a userMinOut
// taken from it is refused (RouterE(5)). Fee down: the venue is priced worse than it is.
//
// The fixture is one V3 pool, a direct route into a bridge (the protocol fee off the output, so
// the preview is the plain deduction), one leg (no safety buffer): the preview and the fill are
// the same figure when the quote charges the fee the pool charges. Red at 2a384f0 (Core as at
// c516601): the two tests whose fee moved; the control, whose fee did not, is green there too.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

/// @dev A V3-shaped pool whose fee the test moves, as a dynamic-fee CL pool moves it per block.
contract MovingFeeV3Pool is MockV3Pool {
    constructor(address a, address b, uint24 f) MockV3Pool(a, b, f) {}

    function setFee(uint24 f) external { fee = f; }
}

contract QuoteChargesTheClFeeThePoolChargesNowTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    MovingFeeV3Pool pool;
    address recipient = makeAddr("recipient");

    uint256 constant AMOUNT_IN = 1e18;
    uint24 constant LOW = 150;   // the lowest fee() sampled on the Base pool
    uint24 constant HIGH = 937;  // the highest

    function _fixture(uint24 feeAtRegistration) internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2")
        );
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        pool = new MovingFeeV3Pool(address(tA), address(tB), feeAtRegistration);
        pool.setState(uint160(BPC.Q96), 1e30);
        tA.mint(address(pool), 1e30);
        tB.mint(address(pool), 1e30);
        Origin.wire(hub, address(pool), address(tA), address(tB), BPC.KIND_V3, feeAtRegistration);
        hub.seedPool(address(pool), BPC.KIND_V3, feeAtRegistration, address(0), address(tA), address(tB));
        hub.addBridge(address(tB));
    }

    /// The preview's netOut for tA -> tB, and what the Router delivers for its route in the same
    /// block, after the pool's fee moved from `feeAtRegistration` to `feeNow`.
    function _previewAndFill(uint24 feeAtRegistration, uint24 feeNow)
        internal
        returns (uint256 netOut, uint256 delivered)
    {
        _fixture(feeAtRegistration);
        vm.roll(block.number + 1);
        pool.setFee(feeNow);
        (BlazePhoenixQuoter.Preview memory pv, ) =
            quoter.previewAndEncode(address(tA), address(tB), AMOUNT_IN, recipient, block.timestamp);
        assertEq(pv.route.hops.length, 1, "premise: a direct route");
        assertEq(pv.route.hops[0].legs.length, 1, "premise: one leg, no safety buffer");
        assertEq(pv.route.hops[0].legs[0].pool, address(pool), "premise: the leg is the pool");
        assertEq(pv.route.hops[0].legs[0].fee, feeAtRegistration,
            "premise: the row and the leg carry the fee of the registration block");
        netOut = pv.netOut;
        tA.mint(address(this), AMOUNT_IN);
        tA.approve(address(router), AMOUNT_IN);
        delivered = router.swapExactIn(pv.route, AMOUNT_IN, 1, recipient, block.timestamp);
    }

    /// @notice The fee rose since the row was written: the preview may not promise the old fee.
    function test_AFeeThatRoseIsPromisedAsThePoolChargesIt() public {
        (uint256 netOut, uint256 delivered) = _previewAndFill(LOW, HIGH);
        assertLe(netOut, delivered, "the preview never promises more than the pool pays now");
        assertEq(netOut, delivered, "the preview charges the fee the pool charges now");
    }

    /// @notice The fee fell since the row was written: the venue is priced as it is now.
    function test_AFeeThatFellIsPromisedAsThePoolChargesIt() public {
        (uint256 netOut, uint256 delivered) = _previewAndFill(HIGH, LOW);
        assertEq(netOut, delivered, "the preview charges the fee the pool charges now");
    }

    /// @notice Control: a fee that did not move - the preview and the fill are one figure.
    function test_Control_AFeeThatDidNotMoveIsPromisedAsCharged() public {
        (uint256 netOut, uint256 delivered) = _previewAndFill(HIGH, HIGH);
        assertEq(netOut, delivered, "preview == fill when the fee did not move");
    }
}
