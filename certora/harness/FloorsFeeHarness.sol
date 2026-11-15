// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

/// @notice Certora harness for the pure floor and fee arithmetic the Router enforces.
///         `ironFloorBpsShv` / `ironFloorBps` and the constants are the library's own.
///         `legFloor`, `hopSlack` and `protocolFee` restate ONE expression of the Router
///         each, verbatim, because the Router computes them inline:
///           legFloor     <- BlazePhoenixRouter `_execScaled`: got < mulDivUp(bound, LEG_FLOOR_BPS, BPS)
///           hopSlack     <- BlazePhoenixRouter `_execute`:    mulDiv(hopBound / hopQuoted, BPS - LEG_FLOOR_BPS, BPS)
///           protocolFee  <- BlazePhoenixRouter `_chargeHopFee` and the output-side fee:
///                           mulDivUp(base, PROTOCOL_FEE_BPS, BPS)
///         A restated expression is a copy, not the code: a mutant on the Router line is
///         killed by the forge suite, not by this spec. The spec proves the arithmetic the
///         Router line uses; the copy is pinned by review against the cited line.
contract FloorsFeeHarness {
    function BPS() external pure returns (uint256) { return BPC.BPS; }
    function PROTOCOL_FEE_BPS() external pure returns (uint256) { return BPC.PROTOCOL_FEE_BPS; }
    function LEG_FLOOR_BPS() external pure returns (uint256) { return BPC.LEG_FLOOR_BPS; }
    function FLOOR_BASE_BPS() external pure returns (uint256) { return BPC.FLOOR_BASE_BPS; }
    function FLOOR_HARD_MAX_LOSS_BPS() external pure returns (uint256) { return BPC.FLOOR_HARD_MAX_LOSS_BPS; }

    function ironFloorBpsShv(uint256 impactBps, uint256 legShv, uint256 sigmaLn)
        external pure returns (uint256)
    {
        return BPC.ironFloorBpsShv(impactBps, legShv, sigmaLn);
    }

    function ironFloorBps(uint256 impactBps, uint256 legCount, uint256 sigmaLn)
        external pure returns (uint256)
    {
        return BPC.ironFloorBps(impactBps, legCount, sigmaLn);
    }

    function legFloor(uint256 bound) external pure returns (uint256) {
        return BPC.mulDivUp(bound, BPC.LEG_FLOOR_BPS, BPC.BPS);
    }

    function hopSlack(uint256 hopBound, uint256 hopQuoted) external pure returns (uint256) {
        return BPC.mulDiv(hopBound / hopQuoted, BPC.BPS - BPC.LEG_FLOOR_BPS, BPC.BPS);
    }

    function protocolFee(uint256 base) external pure returns (uint256) {
        return BPC.mulDivUp(base, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }
}
