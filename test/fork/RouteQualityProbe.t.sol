// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/console2.sol";
import {BaseChainFixture} from "./TokenSweep.t.sol";
import {MatrixOps} from "./FidelityMatrix.t.sol";
import {RouteQualityRecorder} from "../tools/RouteQualityRecorder.sol";
import {Route, Leg} from "../../src/BlazePhoenixCore.sol";

/// @notice DIAGNOSIS, NOT A GUARD (route quality, USDC->DAI 10k on Base at block 49800000).
///         FidelityMatrixBaseTest.test_Matriz_DaiEPortaExata went red on its USDC->DAI 10k line:
///         the direct hop became one thin, off-market leg. Reading the band's code from the
///         trace's figures does not yield that leg, so this probe replays the same state and
///         logs what the band actually received and did: every probe the Solver ran (15 on the
///         direct hop), and for every `BlazePhoenixMath.select` the rows as they reached it
///         through the ABI (rate, depth, balOut, fe = fee | err << 24), the prices, the votes w
///         and the base of each pass, the kept bits, and the real select's answer beside the
///         tap's (`test/tools/RouteQualityRecorder.sol`). It asserts nothing and must pass.
///         The name carries "BaseForkTest" so the fork lane's --match-contract selects it.
///         Run: forge test --match-path test/fork/RouteQualityProbe.t.sol -vv (DRPC_KEY set).
contract RouteQualityProbeBaseForkTest is BaseChainFixture, MatrixOps, RouteQualityRecorder {
    address constant DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;

    /// The red test's two lines before USDC->DAI 10k, verbatim: they swap through the same
    /// venues and leave the state the trace read.
    function warmUp() external {
        _linha("DAI->USDC 1k", DAI, _dollar(), 1_000e18, true);
        _linhaExata("DAI->USDC 10k", DAI, _dollar(), 10_000e18);
    }

    function test_RouteQuality_UsdcToDai10k_logsTheBand() public {
        if (address(hub) == address(0)) return;
        try this.warmUp() {
            console2.log("RQ warm-up ran: the state below is the red test's");
        } catch (bytes memory err) {
            console2.log("RQ warm-up REVERTED: the state below is the bare fork, not the trace's");
            console2.logBytes(err);
        }
        _rqStart();
        (bool ok, bytes memory ret) =
            address(quoter).call(abi.encodeCall(quoter.previewPlanExact, (_dollar(), DAI, 10_000e6)));
        _rqStopAndReplay("fork USDC->DAI 10k");
        uint256 exactOut;
        if (ok && ret.length >= 64) {
            assembly ("memory-safe") { exactOut := mload(add(ret, 0x40)) }
        }
        console2.log("RQ previewPlanExact ok / return bytes / exactOut word:", ok ? 1 : 0, ret.length, exactOut);
    }

    /// ROUTEQ (2026-11-13) quality: on the trace's state the 10k does not go whole into the
    /// Pancake V3 row 1631 ticks off the market (sqrtP 72985406416730663360560 after the warm-up),
    /// and it pays more than that row alone paid in run 43410379085 (6550182768573569948083 DAI).
    /// Red before the fix (the band's error bound at the probe size): test/RouteQualityOrderSizeError.t.sol.
    function test_RouteQuality_UsdcToDai10k_isNotTheFarRowAlone() public {
        if (address(hub) == address(0)) return;
        try this.warmUp() {} catch {}   // the trace's state when it runs; the bare fork's when not
        Route memory best = solver.findBestRoutePlan(_dollar(), DAI, 10_000e6).best;
        bool farAlone = best.hops.length == 1 && best.hops[0].legs.length == 1
            && _sqrtP(_venue(best.hops[0].legs[0])) == 72985406416730663360560;
        assertFalse(farAlone, "the 10k went whole into the far thin row");
        (, uint256 exactOut) = quoter.previewPlanExact(_dollar(), DAI, 10_000e6);
        assertGt(exactOut, 6550182768573569948083, "the route pays no more than the far row alone");
    }

    /// A leg's venue, Leg's first field.
    function _venue(Leg memory l) internal pure returns (address v) {
        assembly ("memory-safe") { v := mload(l) }
    }

    function _sqrtP(address venue) internal view returns (uint256 s) {
        (bool ok, bytes memory r) = venue.staticcall(abi.encodeWithSignature("slot0()"));
        if (ok && r.length >= 32) s = abi.decode(r, (uint256));
    }
}
