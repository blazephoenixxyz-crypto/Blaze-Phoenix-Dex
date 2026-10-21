// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// `IExtAdapter`, the interface the Gate's wrapper calls (resolve, exec, quote, quoteCall), is
// declared ONCE, in src/BlazePhoenixGate.sol, and re-exported from here: an adapter cannot drift
// from what the wrapper actually calls.
import {IExtAdapter} from "../BlazePhoenixGate.sol";

/// The one question an adapter asks the Gate: "is the caller a wrapper you created?"
interface IGateWrappers {
    function isWrapper(address w) external view returns (bool);
}

/// The wrapper's own record: the adapter reads the tokens from a wrapper the Gate vouches for,
/// never from its arguments.
interface IGateWrapperState {
    function token0() external view returns (address);
    function token1() external view returns (address);
}
