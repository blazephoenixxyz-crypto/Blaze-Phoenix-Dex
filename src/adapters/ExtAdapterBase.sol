// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../BlazePhoenixCore.sol";
import {IGateWrappers, IGateWrapperState} from "./IExtAdapter.sol";

/// A venue that answers by index (Curve StableSwap-NG `coins`/`balances(i)`, Twocrypto-NG and
/// Tricrypto-NG `coins`/`balances` public arrays): the same two getters on all three.
interface IIndexedVenue {
    function coins(uint256 i) external view returns (address);
    function balances(uint256 i) external view returns (uint256);
}

/// @notice What every Gate adapter shares: who may run it, which tokens it moves, and the one
///         custody discipline for a venue that pulls (PULL mode).
/// @dev Code that the Gate's scan admits: no DELEGATECALL, CALLCODE or SELFDESTRUCT, so only
///      `internal` library functions are used (a `public` library function is a DELEGATECALL).
///      Error codes, shared by all adapters:
///        0 zero address at construction   1 the caller is not a wrapper of the Gate
///        2 the venue does not vouch for the pool (registry / factory / vault)
///        3 the pair is not traded by that pool        4 an asset of the pool is refused
///        5 an allowance survived the venue call (PULL)
///        6 a venue callback outside the adapter's own call, or not from the venue
///        7 the pool's hooks are refused                8 the hint is malformed
abstract contract ExtAdapterBase {
    error AdapterE(uint8 code);

    IGateWrappers public immutable GATE;

    constructor(address gate) {
        if (gate == address(0)) revert AdapterE(0);
        GATE = IGateWrappers(gate);
    }

    /// The ONE producer of "who may run exec, and on which tokens". The caller must be a wrapper
    /// the Gate created, and the tokens are that wrapper's immutables: never an argument, so a
    /// venue pool or a token cannot be named by whoever calls (the HUNT-001 class: an approval
    /// to a pool that calldata named).
    function _wrapperTokens(bool zeroForOne) internal view returns (address tIn, address tOut) {
        (tIn, tOut) = _pairOf(msg.sender, zeroForOne);
    }

    /// exec's hot path when only the input token is needed (PUSH): one wrapper read, not two.
    function _wrapperTokenIn(bool zeroForOne) internal view returns (address tIn) {
        _requireWrapper(msg.sender);
        tIn = zeroForOne ? IGateWrapperState(msg.sender).token0() : IGateWrapperState(msg.sender).token1();
    }

    function _requireWrapper(address w) private view {
        if (!GATE.isWrapper(w)) revert AdapterE(1);
    }

    function _pairOf(address w, bool zeroForOne) internal view returns (address tIn, address tOut) {
        _requireWrapper(w);
        address a = IGateWrapperState(w).token0();
        address b = IGateWrapperState(w).token1();
        (tIn, tOut) = zeroForOne ? (a, b) : (b, a);
    }

    /// The ONE producer of "is t0 and t1 a pair of `coins`": both present, at distinct indices.
    function _indices(address[] memory coins, address t0, address t1) internal pure returns (uint256 i0, uint256 i1) {
        uint256 n = coins.length;
        i0 = n;
        i1 = n;
        for (uint256 k; k < n; ) {
            if (coins[k] == t0) i0 = k;
            else if (coins[k] == t1) i1 = k;
            unchecked { ++k; }
        }
        if (i0 == n || i1 == n) revert AdapterE(3);
    }

    /// The ONE adapter producer of a declared depth18: the shorter side of the balances the venue
    /// itself reports, each normalised by its token's decimals, through Core's `shortSide18` - the
    /// registry's own depth of a pair (`registryDepth18`'s reserves arm, `depthFromL18`), so one
    /// mass reads one depth on both doors, and the formula of the cap the Gate applies over what
    /// the venue holds (`Gate.vitalOf`). Never reads amtIn.
    function _depth18(address a, uint256 ba, address b, uint256 bb) internal view returns (uint256) {
        return BPC.shortSide18(ba, BPC.decimalsOf(a), bb, BPC.decimalsOf(b));
    }

    /// depth18 of a venue that answers by index: the pool's own `coins(i)` and `balances(i)` at
    /// the pair's indices (the record `resolve` matched). A read that fails reverts the quote; the
    /// wrapper's `quote` catches it, and the Quoter then prices by `quoteCall`, which reads no depth.
    function _indexedDepth18(address pool, uint256 i0, uint256 i1) internal view returns (uint256) {
        IIndexedVenue p = IIndexedVenue(pool);
        return _depth18(p.coins(i0), p.balances(i0), p.coins(i1), p.balances(i1));
    }

    /// depth18 of a venue that answers by list (a Balancer Vault's tokens and balances of a pool):
    /// matched to the calling wrapper's pair (`_pairOf`, as in exec and quoteCall), never to an
    /// argument; a pair the list no longer holds is refused (AdapterE(3)).
    function _listedDepth18(address[] memory tokens, uint256[] memory bals) internal view returns (uint256) {
        (address a, address b) = _pairOf(msg.sender, true);
        (uint256 i0, uint256 i1) = _indices(tokens, a, b);
        return _depth18(a, bals[i0], b, bals[i1]);
    }

    /// PULL custody, step 1: an approval for exactly this call's input.
    function _approveExact(address token, address spender, uint256 amt) internal {
        BPC.forceApprove(token, spender, amt);
    }

    /// PULL custody, step 2: the venue must have taken all of it. A venue that paid without
    /// pulling (HUNT-001: paid from its own stock) or pulled less leaves an allowance standing;
    /// that is refused, not reset, because the input it did not take is still here.
    function _requireNoAllowance(address token, address spender) internal view {
        if (_allowance(token, spender) != 0) revert AdapterE(5);
    }

    /// allowance(this, spender). A failed read is not a zero (same rule as BPC.balanceOf).
    function _allowance(address token, address spender) internal view returns (uint256 a) {
        bool ok;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xdd62ed3e00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), address())
            mstore(add(m, 36), and(spender, 0xffffffffffffffffffffffffffffffffffffffff))
            ok := staticcall(gas(), token, m, 68, m, 32)
            if ok {
                switch lt(returndatasize(), 32)
                case 0 { a := mload(m) }
                default { ok := 0 }
            }
        }
        if (!ok) revert AdapterE(5);
    }
}
