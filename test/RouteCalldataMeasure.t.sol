// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

/// Measurement-only: how many calldata bytes does a Route cost today,
/// and what would a key-compressed form cost. No behavior under test.
contract RouteCalldataMeasureTest is Test {

    function _leg() internal pure returns (Leg memory) {
        return Leg({
            pool: 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640,
            hooks: address(0),
            kind: 2,
            fee: 500,
            tickSpacing: 10,
            zeroForOne: true,
            stable: false,
            amountIn: 1_234_567890123456789,
            expectedOut: 3_210_987654321098765,
            auxId: bytes32(uint256(uint160(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)))
        });
    }

    function _hop(uint256 nLegs) internal pure returns (Hop memory h) {
        h.tokenIn  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        h.tokenOut = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        h.amountIn = 1_234_567890123456789;
        h.expectedOut = 3_210_987654321098765;
        h.legs = new Leg[](nLegs);
        for (uint256 i; i < nLegs; i++) h.legs[i] = _leg();
    }

    function _route(uint256 nHops, uint256 legsPerHop) internal pure returns (Route memory r) {
        r.hops = new Hop[](nHops);
        for (uint256 i; i < nHops; i++) r.hops[i] = _hop(legsPerHop);
        r.totalOut = 3_210_987654321098765;
        r.singleOut = 3_200_000000000000000;
        r.singleOutFloor = 3_100_000000000000000;
        r.expectedImpactBps = 12;
        r.confidenceWad = 990000000000000000;
        r.estGas = 210000;
        r.hasSurplus = false;
        r.isV4Bundle = false;
    }

    function _count(bytes memory b) internal pure returns (uint256 z, uint256 nz) {
        for (uint256 i; i < b.length; i++) {
            if (b[i] == 0) z++; else nz++;
        }
    }

    function _report(string memory label, bytes memory cd) internal pure {
        (uint256 z, uint256 nz) = _count(cd);
        // standard calldata gas 4/16 ; EIP-7623 floor 10/40
        console2.log(label);
        console2.log("  bytes total / zero / nonzero:", cd.length, z, nz);
        console2.log("  calldata gas (4z+16nz):", 4 * z + 16 * nz);
        console2.log("  EIP-7623 floor (10z+40nz):", 10 * z + 40 * nz);
    }

    function test_measure_routes() public pure {
        address rec = 0x1111111111111111111111111111111111111111;
        uint256 amt = 1_234_567890123456789;
        uint256 minOut = 3_000_000000000000000;
        uint256 dl = 1766000000;

        _report("swapExactIn 1 hop x 1 leg", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_route(1, 1), amt, minOut, rec, dl)));
        _report("swapExactIn 1 hop x 3 legs", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_route(1, 3), amt, minOut, rec, dl)));
        _report("swapExactIn 1 hop x 5 legs", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_route(1, 5), amt, minOut, rec, dl)));
        _report("swapExactIn 2 hops x 1 leg", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_route(2, 1), amt, minOut, rec, dl)));
        _report("swapExactIn 2 hops x 3 legs", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_route(2, 3), amt, minOut, rec, dl)));

        _report("swapBestExactIn (3-arg discovery)", abi.encodeCall(
            BlazePhoenixRouter.swapBestExactIn,
            (0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
             0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
             amt, minOut, rec, dl)));

        // ── candidate compressed forms (packed mock, not implemented) ──
        // per leg: bytes32 registry key + uint16 share-ppm-ish weight
        //          + uint128 expectedOut floor  => 32+2+16 = 50 B
        // per hop: tokenOut only (tokenIn = previous hop / entry token): 20 B
        // header: selector 4 + tokenIn 20 + amountIn 16 + minOut 16
        //         + recipient 20 + deadline 5 = 81 B
        bytes memory leg50 = abi.encodePacked(
            keccak256("key"), uint16(65535), uint128(3_210_987654321098765));
        console2.log("compressed leg (key32+w2+out16):", leg50.length);
        for (uint256 legs = 1; legs <= 5; legs += 2) {
            uint256 total = 81 + 20 + legs * leg50.length; // 1 hop
            console2.log("compressed 1 hop, legs:", legs, "total bytes:", total);
        }
        console2.log("compressed 2 hops x 1 leg:", 81 + 2 * 20 + 2 * leg50.length);
        console2.log("compressed 2 hops x 3 legs:", 81 + 2 * 20 + 6 * leg50.length);
    }
}

contract RouteCalldataVariantsTest is RouteCalldataMeasureTest {

    /// dead fields zeroed: route.{totalOut,singleOut,expectedImpactBps,
    /// confidenceWad,estGas,hasSurplus,isV4Bundle}, hop.{amountIn,expectedOut},
    // V2-leg dead fields zeroed too; singleOutFloor KEPT (it is read by the Router).
    function _routeZeroed(uint256 nHops, uint256 legsPerHop) internal pure returns (Route memory r) {
        r = _route(nHops, legsPerHop);
        r.totalOut = 0; r.singleOut = 0; r.expectedImpactBps = 0;
        r.confidenceWad = 0; r.estGas = 0;
        for (uint256 h; h < nHops; h++) {
            r.hops[h].amountIn = 0; r.hops[h].expectedOut = 0;
            for (uint256 l; l < legsPerHop; l++) {
                Leg memory g = r.hops[h].legs[l];
                g.hooks = address(0); g.fee = 0; g.tickSpacing = 0;
                g.stable = false; g.auxId = bytes32(0); g.kind = 0; // V2
            }
        }
    }

    function test_measure_variants() public pure {
        address rec = 0x1111111111111111111111111111111111111111;
        uint256 amt = 1_234_567890123456789;
        uint256 minOut = 3_000_000000000000000;
        uint256 dl = 1766000000;

        _report("ZEROED swapExactIn 1x1", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_routeZeroed(1, 1), amt, minOut, rec, dl)));
        _report("ZEROED swapExactIn 1x3", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_routeZeroed(1, 3), amt, minOut, rec, dl)));
        _report("ZEROED swapExactIn 1x5", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_routeZeroed(1, 5), amt, minOut, rec, dl)));
        _report("ZEROED swapExactIn 2x3", abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_routeZeroed(2, 3), amt, minOut, rec, dl)));

        // ── packed-EXPLICIT (no registry): header + hops + V2 legs ──
        bytes memory hdr = abi.encodePacked(
            bytes4(0xBEEF0001),
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,   // tokenIn
            uint128(amt), uint128(minOut), rec, uint32(dl),
            uint128(3_100_000000000000000),               // singleOutFloor
            uint8(1));                                    // nHops
        bytes memory hop = abi.encodePacked(
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, uint8(1)); // tokenOut+nLegs
        bytes memory legV2 = abi.encodePacked(
            0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640,   // pool
            uint8(0x80),                                  // kind+z4o+stable flags
            uint24(0),                                    // fee (0=std)
            uint128(1_234_567890123456789),               // leg amountIn
            uint128(3_210_987654321098765));              // expectedOut
        _report("PACKED-explicit hdr+1hop+1 V2 leg",
            bytes.concat(hdr, hop, legV2));
        _report("PACKED-explicit hdr+1hop+3 V2 legs",
            bytes.concat(hdr, hop, legV2, legV2, legV2));
        _report("PACKED-explicit hdr+1hop+5 V2 legs",
            bytes.concat(hdr, hop, legV2, legV2, legV2, legV2, legV2));
        _report("PACKED-explicit 2hops x 3 legs",
            bytes.concat(hdr, hop, legV2, legV2, legV2, hop, legV2, legV2, legV2));

        // hooked V4 leg: + tick3 + hooks20 (tokenOther derived from hop)
        bytes memory legV4h = abi.encodePacked(
            0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640, uint8(0x84),
            uint24(500), uint24(10),
            0x4444444444444444444444444444444444444444,  // hooks
            uint128(1_234_567890123456789), uint128(3_210_987654321098765));
        _report("PACKED-explicit 1 hooked-V4 leg", bytes.concat(hdr, hop, legV4h));

        // ── packed-KEY (registry indirection): key32+flags1+amt16+out16 ──
        bytes memory legKey = abi.encodePacked(
            keccak256("pool-key"), uint8(0x80),
            uint128(1_234_567890123456789), uint128(3_210_987654321098765));
        _report("PACKED-key hdr+1hop+1 leg", bytes.concat(hdr, hop, legKey));
        _report("PACKED-key hdr+1hop+5 legs",
            bytes.concat(hdr, hop, legKey, legKey, legKey, legKey, legKey));
    }
}

contract RouteCalldataHexDumpTest is RouteCalldataVariantsTest {
    function test_dump_hex() public pure {
        address rec = 0x1111111111111111111111111111111111111111;
        uint256 amt = 1_234_567890123456789;
        uint256 minOut = 3_000_000000000000000;
        uint256 dl = 1766000000;
        console2.log("HEXDUMP abi_1x5");
        console2.logBytes(abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_route(1, 5), amt, minOut, rec, dl)));
        console2.log("HEXDUMP abi_zeroed_1x5");
        console2.logBytes(abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (_routeZeroed(1, 5), amt, minOut, rec, dl)));
        bytes memory hdr = abi.encodePacked(
            bytes4(0xBEEF0001), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            uint128(amt), uint128(minOut), rec, uint32(dl),
            uint128(3_100_000000000000000), uint8(1));
        bytes memory hop = abi.encodePacked(
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, uint8(5));
        // five DISTINCT pools/amounts — realistic, not compressor-friendly dupes
        bytes memory legs;
        for (uint160 i; i < 5; i++) {
            legs = bytes.concat(legs, abi.encodePacked(
                address(uint160(0x88E6a0C2ddD26feEb64F039a2c41296FcB3F5641) + i * 7919),
                uint8(0x80), uint24(0),
                uint128(1_234_567890123456789 / (i + 1)),
                uint128(3_210_987654321098765 / (i + 1))));
        }
        console2.log("HEXDUMP packed_1x5");
        console2.logBytes(bytes.concat(hdr, hop, legs));
    }

    // ABI route with 5 DISTINCT pools (realistic for the compressor)
    function test_dump_hex_distinct() public pure {
        Route memory r = _route(1, 5);
        for (uint160 i; i < 5; i++) {
            r.hops[0].legs[i].pool =
                address(uint160(0x88E6a0C2ddD26feEb64F039a2c41296FcB3F5641) + i * 7919);
            r.hops[0].legs[i].amountIn = 1_234_567890123456789 / (i + 1);
            r.hops[0].legs[i].expectedOut = 3_210_987654321098765 / (i + 1);
        }
        console2.log("HEXDUMP abi_distinct_1x5");
        console2.logBytes(abi.encodeCall(
            BlazePhoenixRouter.swapExactIn,
            (r, 1_234_567890123456789, 3_000_000000000000000,
             0x1111111111111111111111111111111111111111, 1766000000)));
    }
}
