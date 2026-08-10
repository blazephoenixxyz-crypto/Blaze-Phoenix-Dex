// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPermit2} from "../../src/BlazePhoenixRouter.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Minimal Permit2 stand-in for unit tests: honors the
///         SignatureTransfer call shape (permitTransferFrom) and moves the
///         tokens via a plain transferFrom, mirroring the real Permit2's
///         model where users hold a standing ERC20 approval TO Permit2 and
///         each transfer is authorized per-call. Signature verification is
///         deliberately not replicated (that is Permit2's own audited
///         concern, not this repo's) — the Router-side behavior under test
///         is the call shape, the amount bound, and the measured receive.
contract MockPermit2 {
    function permitTransferFrom(
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata details,
        address owner,
        bytes calldata /* signature */
    ) external {
        require(details.requestedAmount <= permit.permitted.amount, "MockPermit2: over-request");
        require(
            IERC20Minimal(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount),
            "MockPermit2: transferFrom failed"
        );
    }
}
