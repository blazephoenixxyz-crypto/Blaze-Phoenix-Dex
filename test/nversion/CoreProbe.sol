// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

/// @notice The Core's quote maths behind an external surface, so the SAME source can be
///         compiled under several code-generation settings and the binaries compared on
///         the same inputs (N-version testing). The library is internal and inlined, so
///         this probe's bytecode is the maths as each profile emitted it.
contract CoreProbe {
    function outV2(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee) external pure returns (uint256) {
        return BPC.outV2(ain, rIn, rOut, fee);
    }
    function outV3(uint256 ain, uint160 sqrtP, uint128 liq, uint24 fee, bool zfo, uint160 lim) external pure returns (uint256) {
        return BPC.outV3(ain, sqrtP, liq, fee, zfo, lim);
    }
    function outSolidly(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, bool stable) external pure returns (uint256) {
        return BPC.outSolidly(ain, rIn, rOut, fee, stable);
    }
    function outSolidlyStable(uint256 ain, uint256 rIn, uint256 rOut, uint256 fee, uint8 dIn, uint8 dOut) external pure returns (uint256) {
        return BPC.outSolidlyStable(ain, rIn, rOut, fee, dIn, dOut);
    }
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return BPC.mulDiv(a, b, d);
    }
    function mulDivUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return BPC.mulDivUp(a, b, d);
    }
}
