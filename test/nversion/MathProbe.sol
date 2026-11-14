// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import {BlazePhoenixMath, IHubMath} from "../../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../../src/BlazePhoenixCore.sol";

/// The Math library's one entry behind a contract every n-version profile compiles: the same rows
/// in, the whole answer out (the band, its size, the psi sum, the order map and every psi). Every
/// row is active, so the Hub is never read (test/MedianBandMath.t.sol builds its rows the same
/// way); bit i of `blindMask` makes row i a blind (external) venue.
contract MathProbe {
    function select(
        uint256[] memory rates, uint256[] memory depths, uint256[] memory bals, uint256[] memory fe,
        uint256 blindMask, uint256 budget
    ) external view returns (uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory map, uint256[] memory psis) {
        PoolInfo[] memory c = new PoolInfo[](rates.length);
        for (uint256 i; i < rates.length; ++i) {
            c[i] = PoolInfo({
                active: true, stable: false, kind: (blindMask >> i) & 1 == 1 ? BPC.KIND_EXTERNAL : BPC.KIND_V2,
                fee: 0, tickSpacing: 0, token0: address(0xA), token1: address(0xB),
                pool: address(uint160(0x1000 + i)), hooks: address(0)
            });
        }
        return BlazePhoenixMath.select(rates, depths, bals, fe, c, address(0xA), IHubMath(address(0)), budget);
    }
}
