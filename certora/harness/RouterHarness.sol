// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";

/// @notice Certora harness: the Router itself, plus the rescue key CVL cannot build
///         (CVL has no abi.encodePacked). `rescueKey` is a COPY of the key expression in
///         queueRescue / cancelRescue / executeRescue; if the Router's key changes, the
///         rescue rules read the wrong slot and fail, they do not pass silently.
contract RouterHarness is BlazePhoenixRouter {
    constructor(address hub_, address solver_, address admin_, address t1, address t2)
        BlazePhoenixRouter(hub_, solver_, admin_, t1, t2)
    {}

    function rescueKey(address token, address to) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, to));
    }
}
