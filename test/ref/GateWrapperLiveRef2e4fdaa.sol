// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  FROZEN AT 2e4fdaa: `BlazePhoenixCore.gateWrapperLive` and the four helpers
//  it reaches, copied statement for statement from src/BlazePhoenixCore.sol at
//  that commit, comments stripped and `public` made `internal`
//  (GAS_CAP Core:211, ASK_GAS_FLOOR Core:219, `_askWord` Core:1502-1511,
//  `create2Address` Core:639-650, `v3Salt` Core:660-662, `sortTokens`,
//  `gateWrapperLive` Core:808-826). It is the "old" side of the parity in
//  test/IdentityIsOneDerivation.t.sol: the identity of a kind-9 leg spelled by
//  hand, before it was rewritten over `deriveAddress`. Internal functions only,
//  so the importer inlines it and no source line here is ever a mutant target.
//  Do not edit: a change here moves the reference, not the code under test.
// =============================================================================
library GateWrapperLiveRef2e4fdaa {
    uint256 internal constant GAS_CAP = 100_000;
    uint256 internal constant ASK_GAS_FLOOR = 104_587;

    function _askWord(address target, bytes memory cd) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            if lt(gas(), ASK_GAS_FLOOR) { revert(0, 0) }
            ok := staticcall(GAS_CAP, target, add(cd, 32), mload(cd), 0x00, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            if ok { word := mload(0x00) }
        }
    }

    function create2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal pure returns (address p)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(add(m, 0x01), shl(96, deployer))
            mstore(add(m, 0x15), salt)
            mstore(add(m, 0x35), initCodeHash)
            mstore8(m, 0xff)
            p := and(keccak256(m, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function v3Salt(address t0, address t1, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encode(t0, t1, fee));
    }

    function sortTokens(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    function gateWrapperLive(address hub, address pool, address tA, address tB, uint24 fee)
        internal view returns (bool)
    {
        (, uint256 w) = _askWord(pool, abi.encodeWithSignature("gate()"));
        address g = address(uint160(w));
        (, w) = _askWord(hub, abi.encodeWithSignature("factoryCodehashOf(address)", g));
        if (bytes32(w) != g.codehash) return false;
        (, w) = _askWord(g, abi.encodeWithSignature("WRAPPER_INIT_HASH()"));
        (address t0, address t1) = sortTokens(tA, tB);
        if (create2Address(g, v3Salt(t0, t1, fee), bytes32(w)) != pool) return false;
        (, w) = _askWord(g, abi.encodeWithSignature("liveAdapter(uint8)", uint8(fee >> 16)));
        return w != 0;
    }
}
