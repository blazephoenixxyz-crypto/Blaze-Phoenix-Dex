// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal factory-call-family mock (selector 0xe6a43905,
///         getPair(address,address)) used to exercise BlazePhoenixHub's
///         discoverFor()/addFactory() path (mode 0, no CREATE2/initHash
///         needed) without deploying anything via CREATE2.
contract MockV2Factory {
    mapping(address => mapping(address => address)) public pairs;

    function setPair(address a, address b, address pair) external {
        pairs[a][b] = pair;
        pairs[b][a] = pair;
    }

    function getPair(address a, address b) external view returns (address) {
        return pairs[a][b];
    }
}
