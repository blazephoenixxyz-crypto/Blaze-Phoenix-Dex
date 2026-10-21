// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// ALIGN AT MERGE WITH gate-1021. `IExtAdapter` below is the interface the Gate's wrapper calls,
// copied from src/BlazePhoenixGate.sol of the gate-1021 working tree (phase 2, not yet committed
// on 2026-10-21). When the Gate lands, it must declare the interface ONCE: the Gate imports it from
// here, or these adapters import it from the Gate. `quoteCall` is the SDK's eth_call entry from the
// family design (desenho-plugins-familias-1021 §1.3); the wrapper never calls it.

interface IExtAdapter {
    /// Asked once, by the Gate, at `create`. Must prove from the VENUE (registry, factory,
    /// vault) that `hint` is its pool for (t0, t1) and return what `exec` needs.
    function resolve(address t0, address t1, uint24 venueKey, bytes calldata hint)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1);
    /// Called only by a Gate wrapper, with `amtIn` of the input already in the adapter.
    /// Delivers the output to `recipient`. The return value is advisory and never read.
    function exec(address venuePool, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256 out);
    /// View quote; 0 means "not quotable on-chain".
    function quote(address venuePool, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out, uint256 depth18);
}

interface IExtAdapterQuoteCall {
    /// Off-chain eth_call quote for the leg whose pool is `wrapper`, may be non-view. Takes the
    /// wrapper, not (venuePool, aux0, aux1) as the family design sketched: a venue that is a
    /// singleton (Balancer) needs the pair, and the wrapper is the one record of all five.
    /// Rule (M4): when `quote` answers non-zero, it answers the same number, from the same body.
    function quoteCall(address wrapper, bool zeroForOne, uint256 amtIn) external returns (uint256 out);
}

/// The one question an adapter asks the Gate: "is the caller a wrapper you created?"
interface IGateWrappers {
    function isWrapper(address w) external view returns (bool);
}

/// The wrapper's own record: the adapter reads tokens (and, for `quoteCall`, the venue) from a
/// wrapper the Gate vouches for, never from its arguments.
interface IGateWrapperState {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function venuePool() external view returns (address);
    function aux0() external view returns (bytes32);
    function aux1() external view returns (bytes32);
}
