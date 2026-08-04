// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Testing the SSTORE2 theory from research note 056 §5 against this codebase's REAL data shape.
//
// Context that motivates it: DiscoveryModeGas.t.sol measured discovery at ~7,062 gas per
// registered factory and showed the derivation mechanism (factory-call vs CREATE2) accounts for
// almost none of it — the cost is dominated by reading each `Factory` struct out of storage.
// Note 056 §5 proposes storing that registry as immutable BYTECODE (write once with CREATE,
// read with EXTCODECOPY) instead of storage slots, claiming "~2606 gas via bytecode against
// ~4200 equivalent in storage", scaling with the per-factory fees/spacings arrays.
//
// This measures the READ path only — the path every `discoverFor` pays. The write happens once,
// in `addFactory` (onlyAdmin), and is deliberately out of scope.
//
// Data shape mirrors Hub.Factory as wired on Base: address + kind + mode + initHash +
// uint24[4] fees + int24[4] spacings.
//
// forge test --match-contract Sstore2RegistryGas -vv

import {Test, console2} from "forge-std/Test.sol";

/// @dev Registry held in ordinary storage, laid out the way Solidity lays out Hub.Factory.
contract StorageRegistry {
    struct Factory {
        address factory;
        uint8 kind;
        uint8 mode;
        bytes32 initHash;
        uint24[] fees;
        int24[] spacings;
    }

    Factory[] public factories;

    function add(address f, uint8 kind, uint8 mode, bytes32 ih) external {
        Factory storage s = factories.push();
        s.factory = f;
        s.kind = kind;
        s.mode = mode;
        s.initHash = ih;
        s.fees = [uint24(100), 500, 3000, 10000];
        s.spacings = [int24(1), 10, 60, 200];
    }

    /// @notice Reads every field the discovery scan actually touches, accumulating so the
    ///         optimiser cannot elide the loads.
    function readAll(uint256 i) external view returns (uint256 acc) {
        Factory storage s = factories[i];
        acc = uint256(uint160(s.factory)) + s.kind + s.mode + uint256(s.initHash);
        uint256 fl = s.fees.length;
        for (uint256 j; j < fl; ++j) acc += s.fees[j];
        uint256 sl = s.spacings.length;
        for (uint256 j; j < sl; ++j) acc += uint256(int256(s.spacings[j]));
    }
}

/// @dev The same record serialised into a data contract's runtime bytecode, read via
///      EXTCODECOPY — the SSTORE2 pattern.
contract Sstore2Registry {
    mapping(uint256 => address) public ptr;

    function setPtr(uint256 i, address p) external { ptr[i] = p; }

    function readAll(uint256 i) external view returns (uint256 acc) {
        address p = ptr[i];
        // 20 (factory) + 1 (kind) + 1 (mode) + 32 (initHash) + 4*3 (fees) + 4*3 (spacings) = 78
        bytes memory buf = new bytes(78);
        assembly {
            extcodecopy(p, add(buf, 0x20), 0, 78)
        }
        uint256 o;
        uint256 f;
        assembly { f := shr(96, mload(add(buf, 0x20))) }
        acc = f;
        o = 20;
        acc += uint8(buf[o]) + uint8(buf[o + 1]);
        o += 2;
        bytes32 ih;
        assembly { ih := mload(add(add(buf, 0x20), o)) }
        acc += uint256(ih);
        o += 32;
        for (uint256 j; j < 8; ++j) {
            uint256 v = (uint256(uint8(buf[o])) << 16) | (uint256(uint8(buf[o + 1])) << 8)
                | uint256(uint8(buf[o + 2]));
            acc += v;
            o += 3;
        }
    }
}

contract Sstore2RegistryGasTest is Test {
    StorageRegistry st;
    Sstore2Registry s2;

    address constant FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD; // real Base UniV3
    bytes32 constant INIT_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    function setUp() public {
        st = new StorageRegistry();
        s2 = new Sstore2Registry();

        // Same logical record in both arms.
        for (uint256 i; i < 9; ++i) {
            st.add(FACTORY, 1, 5, INIT_HASH);

            bytes memory blob = abi.encodePacked(
                FACTORY, uint8(1), uint8(5), INIT_HASH,
                uint24(100), uint24(500), uint24(3000), uint24(10000),
                int24(1), int24(10), int24(60), int24(200)
            );
            address p = address(uint160(uint256(keccak256(abi.encode("blob", i)))));
            vm.etch(p, blob);
            s2.setPtr(i, p);
        }
    }

    function test_ReadGas_Storage_vs_Sstore2() public view {
        // Index 0 of each arm, both cold on first touch within this call.
        uint256 g0 = gasleft();
        st.readAll(0);
        uint256 gStorage = g0 - gasleft();

        uint256 g1 = gasleft();
        s2.readAll(0);
        uint256 gS2 = g1 - gasleft();

        console2.log("read one factory record");
        console2.log("   storage (SLOADs)     gas:", gStorage);
        console2.log("   SSTORE2 (EXTCODECOPY) gas:", gS2);
        if (gStorage > gS2) {
            console2.log("   saved:", gStorage - gS2);
            console2.log("   saved, percent:", ((gStorage - gS2) * 100) / gStorage);
        } else {
            console2.log("   SSTORE2 NOT cheaper; extra:", gS2 - gStorage);
        }
    }

    function test_ReadGas_FullSweep_NineFactories() public view {
        uint256 g0 = gasleft();
        for (uint256 i; i < 9; ++i) st.readAll(i);
        uint256 gStorage = g0 - gasleft();

        uint256 g1 = gasleft();
        for (uint256 i; i < 9; ++i) s2.readAll(i);
        uint256 gS2 = g1 - gasleft();

        console2.log("full sweep, 9 factories (the real Base deploy count)");
        console2.log("   storage  gas:", gStorage);
        console2.log("   SSTORE2  gas:", gS2);
        if (gStorage > gS2) {
            console2.log("   saved:", gStorage - gS2);
            console2.log("   saved, percent:", ((gStorage - gS2) * 100) / gStorage);
            console2.log("   saved per factory:", (gStorage - gS2) / 9);
        }
    }
}
