// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Red at 56d0736: getReserves masked each word to 112 bits, so a reserve of 2^112 + x
// was read as x - a small, wrong number instead of an unreadable one. A word that does
// not fit the uint112 the V2 interface promises now reads as no reserves (fail closed).
// The same file pins the shape probe: a stable() answer that is not a canonical ABI bool
// does not make a pool Solidly-shaped.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract WideReservesPair {
    uint256 public r0;
    uint256 public r1;
    constructor(uint256 a, uint256 b) { r0 = a; r1 = b; }
    function getReserves() external view returns (uint256, uint256, uint256) { return (r0, r1, 0); }
}

contract StableWordPool {
    uint256 public immutable word;
    constructor(uint256 w) { word = w; }
    fallback(bytes calldata) external returns (bytes memory) { return abi.encode(word); }
}

contract ReservesWiderThan112BitsAreNotTruncated is Test {
    function readReserves(address p) external view returns (uint256 a, uint256 b) { return BPC.getReserves(p); }
    function shaped(address p) external view returns (bool) { return BPC.isSolidlyShaped(p); }

    function test_ReserveWordAbove112Bits_ReadsAsNoReserves() public {
        uint256 wide = (uint256(1) << 112) + 5;
        WideReservesPair p = new WideReservesPair(wide, 1e18);
        (uint256 a, uint256 b) = this.readReserves(address(p));
        assertEq(a, 0, "a 113-bit reserve was truncated into a small one");
        assertEq(b, 0, "a pair with one unreadable reserve has no reserves");
    }

    function test_ReserveWordAtUint112Max_IsReadExactly() public {
        uint256 top = (uint256(1) << 112) - 1;
        WideReservesPair p = new WideReservesPair(top, 7);
        (uint256 a, uint256 b) = this.readReserves(address(p));
        assertEq(a, top, "control: the largest uint112 reads exactly");
        assertEq(b, 7, "control: the other side reads exactly");
    }

    function test_NonCanonicalStableWord_IsNotSolidlyShaped() public {
        assertFalse(this.shaped(address(new StableWordPool(2))), "a stable() word of 2 is not an ABI bool");
        assertTrue(this.shaped(address(new StableWordPool(1))), "control: true is a shape answer");
        assertTrue(this.shaped(address(new StableWordPool(0))), "control: false is a shape answer");
    }
}
