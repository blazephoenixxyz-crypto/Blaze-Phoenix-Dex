// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @dev A Uniswap-V4 PoolManager as the derive-scan reads it: both extsload shapes over one
///      settable slot map (the StateLibrary layout the Core reads), and `exttload` for the
///      transient Lock slot the scan's solvency gate asks first (`Hub._pmHoldsNone`). The
///      manager reads as locked (0) until a test sets the word; every other transient slot is 0.
contract MockV4ScanManager {
    /// Lock.IS_UNLOCKED_SLOT: keccak256("Unlocked") - 1.
    bytes32 internal constant IS_UNLOCKED_SLOT =
        0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    mapping(bytes32 => bytes32) public slots;
    bytes32 public unlockedWord;

    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }

    function setUnlocked(bytes32 v) external { unlockedWord = v; }

    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }

    function extsload(bytes32[] calldata targets) external view returns (bytes32[] memory out) {
        out = new bytes32[](targets.length);
        for (uint256 i; i < targets.length; ++i) out[i] = slots[targets[i]];
    }

    function exttload(bytes32 s) external view returns (bytes32) {
        return s == IS_UNLOCKED_SLOT ? unlockedWord : bytes32(0);
    }
}
