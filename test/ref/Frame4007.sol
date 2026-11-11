// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../../src/BlazePhoenixCore.sol";

/// @notice The same-answer meta-guards (G52, D10) compare the Solver's returndata with a frozen
///         Solver to the byte. 4007 (2026-11-11) moves one figure by design: the Solver attests
///         `singleOutFloor` on the output net of the input fees, where the frozen Solvers attested
///         it on the gross output. This carries the reference's floor (and `hasSurplus`, which
///         reads it) into the 4007 frame, and only where the new floor IS the reference's floor
///         rate on the net output: `floorBps` is read back off the reference (`ceil(T * fb / BPS)`
///         pins `fb` uniquely once `T > BPS`), the net output is the one producer
///         `BPC.netOfInputFees` on the calendar of `Core.feeCalendar`, and the floor rounds up as
///         every Solver rounds. Where the new floor is anything else the reference comes back
///         untouched and the byte comparison reports the disagreement. Every other field must
///         still agree to the byte.
library Frame4007 {
    function carry(BlazePhoenixHub hub, bytes memory rN, bytes memory rR) internal view returns (bytes memory) {
        RoutePlan memory pN = abi.decode(rN, (RoutePlan));
        RoutePlan memory pR = abi.decode(rR, (RoutePlan));
        _carry(hub, pN.best, pR.best);
        if (pR.hasFallback) _carry(hub, pN.fallbackRoute, pR.fallbackRoute);
        return abi.encode(pR);
    }

    /// @dev The reference route's floor in the 4007 frame; the reference's own where `fb` cannot be
    ///      read back (an empty route, an output of at most BPS wei).
    function expected(BlazePhoenixHub hub, Route memory r) internal view returns (uint256) {
        if (r.totalOut <= BPC.BPS || r.hops.length == 0) return r.singleOutFloor;
        uint256 fb = r.singleOutFloor * BPC.BPS / r.totalOut;
        uint256 base = r.totalOut;
        if (!(r.hops.length == 1 && hub.isBridgeToken(r.hops[0].tokenOut))) {
            uint256 feeHop = type(uint256).max;
            for (uint256 h; h < r.hops.length; ++h) {
                if (hub.isBridgeToken(r.hops[h].tokenIn)) { feeHop = h; break; }
            }
            base = BPC.netOfInputFees(r.hops, r.totalOut, feeHop, false);
        }
        return BPC.mulDivUp(base, fb, BPC.BPS);
    }

    function _carry(BlazePhoenixHub hub, Route memory n, Route memory r) private view {
        if (n.singleOutFloor != expected(hub, r)) return;
        r.singleOutFloor = n.singleOutFloor;
        r.hasSurplus = r.totalOut > r.singleOutFloor;
    }
}
