// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// FROZEN REFERENCE for test/OnlyControlOneBody.t.sol: the Router's control gate of cb1d7d9,
// literally. The modifier is src/BlazePhoenixRouter.sol:329 of that commit, the error is :312 and
// the two seats it reads are :254 (admin) and :269 (controlRenounced). Nothing else of the Router
// is here: the test copies the Router's two seats in with `mirror` and asks `door`, under the same
// msg.sender, whether the gate opens and with which bytes it refuses.
contract OnlyControlRefCb1d7d9 {
    address public admin;
    bool    public controlRenounced;

    error RouterE(uint16 code);

    modifier onlyControl() { if (msg.sender != admin || controlRenounced) revert RouterE(1); _; }

    /// The test's writer of the two seats. Not part of the reference.
    function mirror(address admin_, bool renounced_) external { admin = admin_; controlRenounced = renounced_; }

    /// The gate alone, with an empty door behind it.
    function door() external view onlyControl {}
}
