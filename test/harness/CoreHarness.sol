// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BlazePhoenixCore as BPC } from "../../src/BlazePhoenixCore.sol";

/// @dev External wrapper exposing Core's internal pure/view math so fuzz tests
///      can call them across a real call boundary (enabling try/catch on the
///      revert paths such as mulDiv overflow).
contract CoreHarness {
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return BPC.mulDiv(a, b, d);
    }
    function mulDivUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return BPC.mulDivUp(a, b, d);
    }
    function outV2(uint256 a, uint256 ri, uint256 ro, uint256 f) external pure returns (uint256) {
        return BPC.outV2(a, ri, ro, f);
    }
    function outV3(uint256 a, uint160 sp, uint128 l, uint24 f, bool z) external pure returns (uint256) {
        return BPC.outV3(a, sp, l, f, z);
    }
    function ironFloorBps(uint256 imp, uint256 legs, uint256 sig) external pure returns (uint256) {
        return BPC.ironFloorBps(imp, legs, sig);
    }
    function impactV2Bps(uint256 a, uint256 ri) external pure returns (uint256) {
        return BPC.impactV2Bps(a, ri);
    }
    function depthBucket(uint256 d) external pure returns (uint8) { return BPC.depthBucket(d); }
    function bucketWeight(uint8 b) external pure returns (uint256) { return BPC.bucketWeight(b); }

    function encodeSlot(
        bool active, uint24 fee, uint8 kind, uint8 tier, uint16 conc,
        uint32 ts, uint32 emaIn, uint32 emaOut, uint32 sc, uint32 regBlk, uint32 lastBlk
    ) external pure returns (uint256) {
        return BPC.encodeSlot(active, fee, kind, tier, conc, ts, emaIn, emaOut, sc, regBlk, lastBlk);
    }
    function decodeKind(uint256 s) external pure returns (uint8) { return BPC.decodeKind(s); }
    function decodeFee(uint256 s) external pure returns (uint24) { return BPC.decodeFee(s); }
    function decodeBucket(uint256 s) external pure returns (uint8) { return BPC.decodeBucket(s); }
    function decodeSwapCount(uint256 s) external pure returns (uint32) { return BPC.decodeSwapCount(s); }
    function decodeLastBlk(uint256 s) external pure returns (uint32) { return BPC.decodeLastBlk(s); }
    function isActive(uint256 s) external pure returns (bool) { return BPC.isActive(s); }
    function setBucket(uint256 s, uint8 b) external pure returns (uint256) { return BPC.setBucket(s, b); }
}
