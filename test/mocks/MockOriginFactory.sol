// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

/// @notice The origin of the pools of one pair (rizki-3107). Since the swap door asks for proof
///         of origin (`Hub._derivedByFactory`: the pool must be among `discoverFor`'s hits), a
///         fixture that seats a pool by a swap must wire the factory that deployed it. This mock
///         is the factory-call family (modes 0-2): it answers getPair / getPool(fee) /
///         getPool(stable) for the pools it lists and address(0) for anything else.
///         One factory per venue, as forks are. A fixture that seats more pools of one pair
///         than `MAX_FACTORIES` allows uses ONE factory with a fee tier per pool (`Origin.tiers`),
///         as a V3 factory lists one pool per tier.
///         `forget` makes it stop listing every pool: the only state, after the fix, in which a
///         row the swap door wrote is vouched for by no factory (`Solver._mutedVotes`).
contract MockOriginFactory {
    address public token0;
    address public token1;
    bool    public stable;
    uint24  public firstTier;
    mapping(uint24 => address) public poolAt;
    uint24[] internal listed;

    /// Lists `p` (on the pair a/b) at fee tier `f`. Every call must name the same pair.
    function list(address p, address a, address b, uint24 f, bool s) external {
        (address x, address y) = a < b ? (a, b) : (b, a);
        if (listed.length == 0) (token0, token1, stable, firstTier) = (x, y, s, f);
        else require(x == token0 && y == token1, "one pair per origin");
        poolAt[f] = p;
        listed.push(f);
    }

    function pool() external view returns (address) { return poolAt[firstTier]; }

    function forget() external {
        for (uint256 i; i < listed.length; ++i) delete poolAt[listed[i]];
    }

    function _at(address a, address b, uint24 f) internal view returns (address) {
        return (a == token0 && b == token1) || (a == token1 && b == token0) ? poolAt[f] : address(0);
    }

    function getPair(address a, address b) external view returns (address) { return _at(a, b, firstTier); }

    function getPool(address a, address b, uint24 f) external view returns (address) { return _at(a, b, f); }

    function getPool(address a, address b, bool s) external view returns (address) {
        return s == stable ? _at(a, b, firstTier) : address(0);
    }
}

/// @notice Wires `MockOriginFactory` origins. The caller must be the Hub's admin and must not
///         hold a pending prank.
library Origin {
    /// A fresh factory as the origin of `pool`, in the family of `kind`: V2 asks getPair
    /// (mode 0), V3 and Algebra ask getPool(fee) at the one fee tier (mode 1; Algebra's tier
    /// is 0), Solidly asks getPool(stable) (mode 2).
    function wire(BlazePhoenixHub hub, address pool, address a, address b, uint8 kind, uint24 fee, bool stable)
        internal returns (MockOriginFactory f)
    {
        f = open(hub, kind, fee);
        f.list(pool, a, b, fee, stable);
    }

    /// The same factory, wired before it has deployed anything: the fixture lists the pool
    /// later with `f.list(pool, a, b, fee, stable)` (a venue wired before its pools exist).
    function open(BlazePhoenixHub hub, uint8 kind, uint24 fee) internal returns (MockOriginFactory f) {
        f = new MockOriginFactory();
        uint8 mode = kind == BPC.KIND_SOLIDLY ? 2 : (kind == BPC.KIND_V2 ? 0 : 1);
        uint24[] memory fees = new uint24[](mode == 1 ? 1 : 0);
        if (mode == 1) fees[0] = fee;
        hub.addFactory(address(f), kind, mode, bytes32(0), fees, new int24[](0));
    }

    function wire(BlazePhoenixHub hub, address pool, address a, address b, uint8 kind, uint24 fee)
        internal returns (MockOriginFactory f)
    {
        return wire(hub, pool, a, b, kind, fee, false);
    }

    /// ONE factory (mode 1, family `kind`) with fee tiers 1..n, listing nothing yet: the
    /// fixture lists each pool as it is born with `f.list(pool, a, b, tier, false)`.
    /// The tier is the factory's lookup key only; the row's fee is what the swap door measures.
    function tiers(BlazePhoenixHub hub, uint8 kind, uint256 n) internal returns (MockOriginFactory f) {
        f = new MockOriginFactory();
        uint24[] memory fees = new uint24[](n);
        for (uint256 i; i < n; ++i) fees[i] = uint24(i + 1);
        hub.addFactory(address(f), kind, 1, bytes32(0), fees, new int24[](0));
    }
}
