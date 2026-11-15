// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The encode doors ask the venues' dry-run every refusal the Router measures (G7 base
//  midtail-3:4, 2026-11-14). Red at 3f6f091: on a direct route into a bridge the Router takes
//  the fee off the output, `_fundedOut` answered `type(uint256).max` for it, and `_encode` read
//  that sentinel as "settles" without asking any venue. The planner here reads a deep book
//  (`liquidity`) while the pool pays from a shallow one (`swapLiquidity`): the attestation sits
//  above what the venue pays, as a walk cut by the read budget left it on the G7 draw.
//  The oracle is the Router's execution of the returned bytes, never the Quoter.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract EncodeDoorsAskTheRoutersRefusalsTest is Test {
    uint256 constant AMT = 1e18;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    MockV3Pool pool;
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("treasury1"), makeAddr("treasury2"));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        pool = new MockV3Pool(address(tA), address(tB), 100);
        pool.setState(uint160(BPC.Q96), 1e30);
        // The venue pays about 98 % of what the planner attests: above the iron floor the
        // planner attests on it (FLOOR_BASE_BPS, 96 %) and the per-leg floor (LEG_FLOOR_BPS),
        // under the estimate. So the floor the caller sets is the only question that can refuse.
        pool.setSwapLiquidity(5e19);
        tB.mint(address(pool), 1e30);
        hub.seedPool(address(pool), BPC.KIND_V3, 100, address(0), address(tA), address(tB));
        hub.addBridge(address(tB));
    }

    function _submit(bytes memory data) internal returns (bool ok, bytes memory ret, uint256 out) {
        tA.mint(address(this), AMT);
        tA.approve(address(router), AMT);
        (ok, ret) = address(router).call(data);
        if (ok) out = abi.decode(ret, (uint256));
    }

    function _encodeAt(uint256 userMin) internal returns (BlazePhoenixQuoter.Preview memory pv, bytes memory data) {
        (pv, data) = quoter.previewAndEncodeWithMinOut(
            address(tA), address(tB), AMT, userMin, recipient, block.timestamp + 1);
    }

    /// The venue's delivery as the Router funds it, net of the output fee: the exact door's figure.
    function _paid() internal returns (uint256 exactOut) {
        (, exactOut) = quoter.previewPlanExact(address(tA), address(tB), AMT);
    }

    /// @notice One wei over what the venue pays, net of the fee the Router takes off the output:
    ///         the Router refuses the delivery (RouterE(5)), so the door returns no bytes.
    function test_ADirectRouteIntoABridge_UnderItsFloor_IsNotEncoded() public {
        assertTrue(hub.isBridgeToken(address(tB)), "premise: a direct route into a bridge, fee on the output");
        (BlazePhoenixQuoter.Preview memory est, , ) = quoter.previewPlan(address(tA), address(tB), AMT);
        uint256 paid = _paid();
        assertLt(paid, est.netOut, "premise: the venue pays under the estimate");
        (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encodeAt(paid + 1);
        if (data.length != 0) {
            (bool ok, bytes memory ret, ) = _submit(data);
            assertFalse(ok, "premise of the oracle: the Router settles one wei over what it delivers");
            assertEq(bytes4(ret), BlazePhoenixRouter.RouterE.selector, "refused as RouterE");
            assertEq(abi.decode(_tail(ret), (uint256)), 5, "with code 5");
        }
        assertFalse(pv.canExecute, "a floor the venue misses as funded is not executable");
        assertEq(data.length, 0, "and has no bytes");
    }

    /// @notice Control, the boundary: at exactly what the venue pays, and one wei under it, the
    ///         bytes are encoded and the Router settles them at their floor.
    function test_Control_AtAndUnderWhatTheVenuePays_TheBytesSettle() public {
        uint256 paid = _paid();
        for (uint256 d; d < 2; ++d) {
            uint256 snap = vm.snapshotState();
            (BlazePhoenixQuoter.Preview memory pv, bytes memory data) = _encodeAt(paid - d);
            assertTrue(pv.canExecute, "the venue meets the floor");
            (bool ok, bytes memory ret, uint256 out) = _submit(data);
            assertTrue(ok, string.concat("bytes the Router refuses: ", vm.toString(ret)));
            assertGe(out, pv.effectiveMinOut, "settled at the floor they carry");
            vm.revertToState(snap);
        }
    }

    function _tail(bytes memory ret) private pure returns (bytes memory t) {
        t = new bytes(ret.length - 4);
        for (uint256 i; i < t.length; ++i) t[i] = ret[i + 4];
    }
}
