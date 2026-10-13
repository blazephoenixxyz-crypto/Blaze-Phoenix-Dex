// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Invariant campaign for the Quoter. Its promise is a CROSS-CHANNEL one, so a handler drives
// quote -> settle through the real Hub, Solver and Router and counts any drift between what
// was published and what execution does:
//
//   INV1 accounting   netOut + safetyBuffer + protocolFee == grossOut (exactly, when
//                     netOut > 0; at most, when the buffer swallows the whole output)
//   INV2 floor        a canExecute preview whose effectiveMinOut is no tighter than exactOut
//                     SETTLES through the Router at that floor and delivers at least it
//   INV3 exact floor  the route previewPlanExact returns settles with userMinOut = exactOut
//                     and delivers at least exactOut (its docstring: derive userMinOut from it)
//   INV4 encoding     previewAndEncodeWithMinOut emits calldata iff canExecute, and the
//                     emitted selector is swapExactIn
//
// Vacuity guard: afterInvariant asserts the campaign quoted AND settled both ways.

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter, IRouterExec} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract QuoterPreviewHandler {
    BlazePhoenixRouter immutable router;
    BlazePhoenixQuoter immutable quoter;
    MockERC20 immutable tokenA;
    MockERC20 immutable tokenB;
    address immutable recipient;

    uint256 public quotes;
    uint256 public settled;
    uint256 public badAccounting;
    uint256 public badEncoded;
    uint256 public badSettle;
    uint256 public settledExact;
    uint256 public badExact;

    constructor(
        BlazePhoenixRouter _router,
        BlazePhoenixQuoter _quoter,
        MockERC20 _a,
        MockERC20 _b,
        address _recipient
    ) {
        router = _router;
        quoter = _quoter;
        tokenA = _a;
        tokenB = _b;
        recipient = _recipient;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function quoteAndMaybeSettle(uint256 amtSeed, uint256 minSeed) external {
        // Below 1000 the 1e30-liquidity pool pays zero and the Solver has no route; the
        // boundary suite owns that region (QuoterRoundTripAndBoundaries).
        uint256 amt = _bound(amtSeed, 1000, 1e21);
        uint256 userMin = _bound(minSeed, 0, 1e21);
        uint256 deadline = block.timestamp + 1;

        (BlazePhoenixQuoter.Preview memory pv, , ) =
            quoter.previewPlanWithMinOut(address(tokenA), address(tokenB), amt, userMin);
        unchecked { ++quotes; }

        // INV1 — the published split of grossOut is arithmetically closed.
        if (pv.netOut > 0) {
            if (pv.netOut + pv.safetyBuffer + pv.protocolFee != pv.grossOut) {
                unchecked { ++badAccounting; }
            }
        } else if (pv.safetyBuffer + pv.protocolFee < pv.grossOut) {
            // netOut clipped to zero is allowed only when the buffer swallowed everything.
            unchecked { ++badAccounting; }
        }

        // INV4 — the encoded round-trip agrees with the preview, by construction.
        (BlazePhoenixQuoter.Preview memory pvEnc, bytes memory data) = quoter.previewAndEncodeWithMinOut(
            address(tokenA), address(tokenB), amt, userMin, recipient, deadline
        );
        if (pvEnc.canExecute != (data.length != 0)) {
            unchecked { ++badEncoded; }
        } else if (data.length != 0) {
            bytes4 sel;
            assembly { sel := mload(add(data, 32)) }
            if (sel != IRouterExec.swapExactIn.selector) { unchecked { ++badEncoded; } }
        }

        // INV2 — a route the preview calls executable must settle at its own floor, for any
        // floor no tighter than exactOut. netOut is an estimate (see ASSUMED_FEE_SAFETY in the
        // Quoter); the floor the Quoter stands behind is exactOut, so a userMinOut between the
        // two is the caller's own bet and is not part of this property.
        (, uint256 exactNow) = quoter.previewPlanExact(address(tokenA), address(tokenB), amt);
        if (pv.canExecute && pv.effectiveMinOut <= exactNow) {
            tokenA.mint(address(this), amt);
            tokenA.approve(address(router), amt);
            try router.swapExactIn(pv.route, amt, pv.effectiveMinOut, recipient, deadline) returns (
                uint256 out
            ) {
                unchecked { ++settled; }
                if (out < pv.effectiveMinOut) { unchecked { ++badSettle; } }
            } catch {
                unchecked { ++badSettle; }
            }
        }

        // INV3 — a fresh exact preview, settled with userMinOut = exactOut.
        (Route memory xr, uint256 exactOut) =
            quoter.previewPlanExact(address(tokenA), address(tokenB), amt);
        if (exactOut != 0) {
            tokenA.mint(address(this), amt);
            tokenA.approve(address(router), amt);
            try router.swapExactIn(xr, amt, exactOut, recipient, deadline) returns (uint256 out) {
                unchecked { ++settledExact; }
                if (out < exactOut) { unchecked { ++badExact; } }
            } catch {
                unchecked { ++badExact; }
            }
        }
    }
}

contract QuoterPreviewDeliveryTest is StdInvariant, Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockV3Pool pool;
    QuoterPreviewHandler handler;

    address recipient = makeAddr("recipient");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");

    uint256 constant POOL_LIQ = 1e30;

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
        tokenB.mint(address(pool), POOL_LIQ);
        hub.seedPool(address(pool), BPC.KIND_V3, 100, address(0), address(tokenA), address(tokenB));

        handler = new QuoterPreviewHandler(router, quoter, tokenA, tokenB, recipient);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_accountingNeverDrifts() public view {
        assertEq(handler.badAccounting(), 0, "netOut + safetyBuffer + protocolFee != grossOut");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_encodeAgreesWithPreview() public view {
        assertEq(handler.badEncoded(), 0, "encoded calldata disagrees with the preview");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_canExecuteSettlesAtItsFloor() public view {
        assertEq(handler.badSettle(), 0, "a canExecute preview did not settle at its floor");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_exactOutIsAFloorTheRouterHonours() public view {
        assertEq(handler.badExact(), 0, "the exact route did not settle at userMinOut = exactOut");
    }

    function afterInvariant() public view {
        assertGt(handler.quotes(), 0, "vacuous: nothing was quoted");
        assertGt(handler.settled(), 0, "vacuous: a canExecute preview never settled");
        assertGt(handler.settledExact(), 0, "vacuous: an exact preview never settled");
    }
}
