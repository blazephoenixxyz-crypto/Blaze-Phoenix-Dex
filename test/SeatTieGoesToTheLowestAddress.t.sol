// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Math:327 (`BlazePhoenixMath.seatOf`, INV-7). The split's remainder seat is the deepest
// survivor by measured weight; a weight TIE goes to the LOWEST pool address, never to the
// position the candidate arrived in. `select` moves the seat to the last kept position, and its
// `map` says which candidate stands there, so the oracle reads the seat straight off `select`:
//
//   seat = cands[map[n - 1]].pool == the lowest address among the rows of greatest depth.
//
// Every row here is one V2 pair at the same price and fee (all inside the band, no Hub read),
// so only the depth and the address can choose the seat.
// Mutant (mutants.py "Math:327"): the tie goes to the HIGHER address. Red in both
// arrival orders of the two-row test: the seat then reads the order, or the wrong end of it.
//
//   forge test --match-path test/SeatTieGoesToTheLowestAddress.t.sol -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMath, IHubMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

contract SeatTieGoesToTheLowestAddressTest is Test {
    uint256 constant RATE = 997e15;   // 0.997 out per in: a 0.3% pair at price 1
    uint256 constant FEE  = 3000;     // pips
    uint256 constant MASS = 300e18;

    /// The seat `select` picks over rows (pools[i], depths[i]): the pool at the last kept slot.
    function _seat(address[] memory pools, uint256[] memory depths) internal view returns (address, uint256) {
        uint256 n = pools.length;
        uint256[] memory rates = new uint256[](n);
        uint256[] memory bals = new uint256[](n);
        uint256[] memory fe = new uint256[](n);
        PoolInfo[] memory c = new PoolInfo[](n);
        for (uint256 i; i < n; ++i) {
            rates[i] = RATE;
            bals[i] = depths[i];
            fe[i] = FEE;
            c[i] = PoolInfo({
                active: true, stable: false, kind: BPC.KIND_V2, fee: 0, tickSpacing: 0,
                token0: address(0xA), token1: address(0xB), pool: pools[i], hooks: address(0)
            });
        }
        (uint256 nBand, uint256 kept, , uint256[] memory map, ) =
            BlazePhoenixMath.select(rates, depths, bals, fe, c, address(0xA), IHubMath(address(0)), 8);
        assertEq(nBand, n, "premise: every row is in the band");
        assertEq(kept, n, "premise: no funnel cut, the seat alone moves the rows");
        return (pools[map[kept - 1]], kept);
    }

    function _two(address a, address b, uint256 da, uint256 db) internal view returns (address seat) {
        address[] memory p = new address[](2);
        uint256[] memory d = new uint256[](2);
        (p[0], p[1], d[0], d[1]) = (a, b, da, db);
        (seat, ) = _seat(p, d);
    }

    /// Two rows of equal depth: the seat is the lower address, whichever row arrived first.
    function test_ATieAtTheSeatGoesToTheLowerAddressInEitherArrivalOrder() public view {
        address lo = address(0x1000);
        address hi = address(0x2000);
        assertEq(_two(lo, hi, MASS, MASS), lo, "tie, lower address first: the lower address is seated");
        assertEq(_two(hi, lo, MASS, MASS), lo, "tie, lower address last: the lower address is seated");
    }

    /// Control: the weight comes before the address. A deeper row at the higher address is
    /// seated in either arrival order (the tie-break never overrides a measured difference).
    function test_TheDeeperRowIsSeatedWhateverItsAddress() public view {
        address lo = address(0x1000);
        address hi = address(0x2000);
        assertEq(_two(lo, hi, MASS, 2 * MASS), hi, "the deeper row is seated (arrived last)");
        assertEq(_two(hi, lo, 2 * MASS, MASS), hi, "the deeper row is seated (arrived first)");
    }

    /// Any number of tied rows (2..8), any distinct addresses, any arrival order: the seat is
    /// the lowest address of the tie.
    function testFuzz_TheSeatOfATieIsTheLowestAddressInAnyOrder(uint256 seed, uint8 nRaw) public view {
        uint256 n = bound(nRaw, 2, 8);
        address[] memory p = new address[](n);
        uint256[] memory d = new uint256[](n);
        address min = address(type(uint160).max);
        for (uint256 i; i < n; ++i) {
            // distinct by construction: the low 16 bits carry the index
            p[i] = address(uint160(uint256(keccak256(abi.encode(seed, i))) << 16 | (0x100 + i)));
            d[i] = MASS;
            if (p[i] < min) min = p[i];
        }
        (address seat, ) = _seat(p, d);
        assertEq(seat, min, "the seat of a tie is the lowest address");
    }
}
