// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, RoutePlan} from "../../src/BlazePhoenixCore.sol";

/// @notice The same-answer meta-guards (G52, D10) compare the Solver's returndata with a frozen
///         Solver to the byte. 4007 (2026-11-11) moves one figure by design: the Solver attests
///         `singleOutFloor` on the output net of the input fees, where the frozen Solvers attested
///         it on the gross output. This carries the reference's floor (and `hasSurplus`, which
///         reads it) into the 4007 frame, and only where the new floor IS the reference's floor
///         rate on the net output: `floorBps` is read back off the reference (`floors` below), the net output is the one producer
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

    /// @dev The floors the reference route admits in the 4007 frame, [lo, hi]; the reference's own
    ///      for an empty route or a zero output.
    ///      The reference publishes F = ceil(T * fb / BPS) (T its totalOut, fb its floorBps). The
    ///      rates that give F are exactly those with F - 1 < T * fb / BPS <= F, that is
    ///        fLo = floor((F - 1) * BPS / T) + 1  <=  fb  <=  fHi = floor(F * BPS / T)
    ///      (fLo = fHi = 0 when F = 0). No size cut is coded; the set's own width decides it:
    ///      - Where the rate reconstructs. The set lies in a half-open interval of length BPS / T,
    ///        so T >= BPS leaves one rate (fLo = fHi = fb) and the range below is one floor, the
    ///        reference's rate on the net output. Below BPS wei the set may hold several rates
    ///        (seed 11933: 1 wei; seed 116847: 2 wei; seed 307163716377032989948697243942600083929:
    ///        838 wei).
    ///      - The width. The new floor is ceil(B * fb / BPS) for B, the net output, <= T, which is
    ///        monotone in fb, so the admitted floors are [ceil(B * fLo / BPS), ceil(B * fHi / BPS)],
    ///        every value inside reached (a step of fb moves it by at most ceil(B / BPS) = 1 wei
    ///        below BPS). Its width is < B * (fHi - fLo) / BPS + 1 < B / T + 1 <= 2, so hi - lo
    ///        <= 1 wei at every size, and 0 once T >= BPS.
    function floors(BlazePhoenixHub hub, Route memory r) internal view returns (uint256, uint256) {
        if (r.hops.length == 0 || r.totalOut == 0) return (r.singleOutFloor, r.singleOutFloor);
        uint256 base = r.totalOut;
        if (!(r.hops.length == 1 && hub.isBridgeToken(r.hops[0].tokenOut))) {
            uint256 feeHop = type(uint256).max;
            for (uint256 h; h < r.hops.length; ++h) {
                if (hub.isBridgeToken(r.hops[h].tokenIn)) { feeHop = h; break; }
            }
            base = BPC.netOfInputFees(r.hops, r.totalOut, feeHop, false);
        }
        uint256 f = r.singleOutFloor;
        uint256 fHi = f * BPC.BPS / r.totalOut;
        uint256 fLo = f == 0 ? 0 : (f - 1) * BPC.BPS / r.totalOut + 1;
        return (BPC.mulDivUp(base, fLo, BPC.BPS), BPC.mulDivUp(base, fHi, BPC.BPS));
    }

    function _carry(BlazePhoenixHub hub, Route memory n, Route memory r) private view {
        (uint256 lo, uint256 hi) = floors(hub, r);
        if (n.singleOutFloor < lo || n.singleOutFloor > hi) return;
        r.singleOutFloor = n.singleOutFloor;
        r.hasSurplus = r.totalOut > r.singleOutFloor;
    }
}
