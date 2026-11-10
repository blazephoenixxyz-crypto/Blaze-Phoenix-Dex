// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Differential tests - the Core's pure arithmetic against slow references.
//
//  Written at origin/main e01b503 (atq-1111, front "dif"). Every function below
//  had ZERO registered mutants at that commit: sqrtPriceAtTick, create2Address,
//  the CREATE2 sub-modes of deriveAddress, ilog10, mulDivUp and to18. They are
//  green on e01b503 (no defect found); each test is paired with a mutant in
//  .github/scripts/mutants.py ([ATQ-dif-1] .. [ATQ-dif-15]) that turns it red.
//
//  The oracle is never the function under test:
//    * sqrtPriceAtTick - the 20 table words below were transcribed mechanically
//      from Uniswap v3-core's TickMath.getSqrtRatioAtTick (not from the Core)
//      and are walked by a loop instead of an unrolled chain; the two domain
//      edges are pinned to the constants that file publishes (MIN_SQRT_RATIO,
//      MAX_SQRT_RATIO) and tick 0 to 2^96.
//    * create2Address - EIP-1014 spelled with abi.encodePacked, Foundry's own
//      computeCreate2Address, and the address the EVM really deploys to.
//    * deriveAddress - each venue family's salt rebuilt here from its factory's
//      published formula, over tokens sorted by the test.
//    * ilog10 - the definition of a floor logarithm (two powers of ten that
//      bracket the input), not a second digit-counting routine.
//    * mulDivUp - plain checked arithmetic on products that fit the word, and
//      a factorisation of 2^257 - 1 for the one case where the ceiling does not.
//    * to18 - repeated multiplication / division by ten.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @dev External door over the library's internal functions, so that a refusal is observable by
///      its reason from one call frame above.
contract DiffCoreMathDoor {
    function sqrtPriceAtTick(int24 t) external pure returns (uint160) { return BPC.sqrtPriceAtTick(t); }
    function mulDivUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) { return BPC.mulDivUp(a, b, d); }
    function create2Address(address dep, bytes32 salt, bytes32 ih) external pure returns (address) {
        return BPC.create2Address(dep, salt, ih);
    }
    function ilog10(uint256 x) external pure returns (uint256) { return BPC.ilog10(x); }
    function to18(uint256 v, uint8 dec) external pure returns (uint256) { return BPC.to18(v, dec); }
}

/// @dev The smallest thing CREATE2 can deploy; its address is the measurement.
contract DiffTiny {
    uint256 public immutable tag = 7;
}

/// @dev An Algebra-style factory: it names a separate pool deployer.
contract DiffAlgebraFactory {
    address public immutable poolDeployer;
    constructor(address d) { poolDeployer = d; }
}

contract DiffCoreMathSlowReferencesTest is Test {
    DiffCoreMathDoor internal door;

    int24 internal constant MAX_TICK = 887272;
    /// Uniswap v3-core TickMath.MIN_SQRT_RATIO / MAX_SQRT_RATIO, as published.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// 20 words of 16 bytes: word i is 2^128 / sqrt(1.0001)^(2^i), i = 0 .. 19.
    bytes internal constant TABLE = hex"fffcb933bd6fad37aa2d162d1a594001fff97272373d413259a46990580e213afff2e50f5f656932ef12357cf3c7fdccffe5caca7e10e4e61c3624eaa0941cd0ffcb9843d60f6159c9db58835c926644ff973b41fa98c081472e6896dfb254c0ff2ea16466c96a3843ec78b326b52861fe5dee046a99a2a811c461f1969c3053fcbe86c7900a88aedcffc83b479aa3a4f987a7253ac413176f2b074cf7815e54f3392b0822b70005940c7a398e4b70f3e7159475a2c29b7443b29c7fa6e889d9d097f3bdfd2022b8845ad8f792aa5825a9f746462d870fdf8a65dc1f90e061e570d869a156d2a1b890bb3df62baf32f731be135f97d08fd981231505542fcfa609aa508b5b7a84e1c677de54f3e99bc9005d6af8dedb81196699c329225ee60400002216e584f5fa1ea926041bedfe9800000000048a170391f7dc42444e8fa2";

    function setUp() public {
        door = new DiffCoreMathDoor();
    }

    // ------------------------------------------------------------------ sqrtPriceAtTick

    function _refSqrt(int24 tick) internal pure returns (uint160) {
        bytes memory t = TABLE;
        uint256 a = uint256(tick < 0 ? -int256(tick) : int256(tick));
        uint256 r = 1 << 128;
        for (uint256 i; i < 20; ++i) {
            if ((a >> i) & 1 == 0) continue;
            uint256 w;
            assembly ("memory-safe") { w := shr(128, mload(add(add(t, 0x20), mul(i, 16)))) }
            r = (r * w) >> 128;
        }
        if (tick > 0) r = type(uint256).max / r;
        return uint160((r + ((1 << 32) - 1)) >> 32);
    }

    function testFuzz_SqrtPriceAtTick_EqualsTheCanonicalTableWalkedByALoop(int24 tick) public view {
        tick = int24(bound(int256(tick), -int256(MAX_TICK), int256(MAX_TICK)));
        assertEq(door.sqrtPriceAtTick(tick), _refSqrt(tick), "Core left the canonical table");
    }

    function test_SqrtPriceAtTick_Grid_EveryPowerOfTwoTickOnBothSidesMatchesTheTable() public view {
        for (uint256 i; i < 20; ++i) {
            int24 p = int24(int256(1 << i));
            int24[4] memory ts = [p, -p, p - 1, -(p - 1)];
            for (uint256 k; k < 4; ++k) {
                if (ts[k] > MAX_TICK || ts[k] < -MAX_TICK) continue;
                assertEq(door.sqrtPriceAtTick(ts[k]), _refSqrt(ts[k]), "grid tick left the canonical table");
            }
        }
        assertEq(door.sqrtPriceAtTick(MAX_TICK - 1), _refSqrt(MAX_TICK - 1), "one inside the upper edge");
        assertEq(door.sqrtPriceAtTick(-(MAX_TICK - 1)), _refSqrt(-(MAX_TICK - 1)), "one inside the lower edge");
    }

    function test_SqrtPriceAtTick_BothDomainEdgesAndUnityLandOnThePublishedConstants() public view {
        assertEq(door.sqrtPriceAtTick(-MAX_TICK), MIN_SQRT_RATIO, "lower edge is not MIN_SQRT_RATIO");
        assertEq(door.sqrtPriceAtTick(MAX_TICK), MAX_SQRT_RATIO, "upper edge is not MAX_SQRT_RATIO");
        assertEq(door.sqrtPriceAtTick(0), uint160(1 << 96), "tick 0 is not a price of one");
    }

    function test_SqrtPriceAtTick_OneTickOutsideTheDomainIsRefusedByItsReason() public {
        vm.expectRevert(bytes("BPC:tick"));
        door.sqrtPriceAtTick(MAX_TICK + 1);
        vm.expectRevert(bytes("BPC:tick"));
        door.sqrtPriceAtTick(-MAX_TICK - 1);
        vm.expectRevert(bytes("BPC:tick"));
        door.sqrtPriceAtTick(type(int24).min);
        // The edges themselves are inside: the refusal is at the boundary, not before it.
        assertGt(door.sqrtPriceAtTick(MAX_TICK), door.sqrtPriceAtTick(-MAX_TICK));
    }

    function testFuzz_SqrtPriceAtTick_OneTickUpIsAStrictlyHigherPrice(int24 tick) public view {
        tick = int24(bound(int256(tick), -int256(MAX_TICK), int256(MAX_TICK) - 1));
        assertLt(door.sqrtPriceAtTick(tick), door.sqrtPriceAtTick(tick + 1), "price did not rise with the tick");
    }

    // ------------------------------------------------------------------ create2Address

    function _eip1014(address dep, bytes32 salt, bytes32 ih) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), dep, salt, ih)))));
    }

    function testFuzz_Create2Address_EqualsTheEip1014FormulaAndFoundrysOwn(address dep, bytes32 salt, bytes32 ih)
        public view
    {
        address got = door.create2Address(dep, salt, ih);
        assertEq(got, _eip1014(dep, salt, ih), "not EIP-1014");
        assertEq(got, vm.computeCreate2Address(salt, ih, dep), "not what Foundry computes");
    }

    function test_Create2Address_PredictsWhereTheEvmReallyDeploys() public {
        bytes32 ih = keccak256(type(DiffTiny).creationCode);
        for (uint256 s = 1; s <= 4; ++s) {
            address predicted = door.create2Address(address(this), bytes32(s), ih);
            assertEq(predicted.code.length, 0, "fixture: the address is already taken");
            DiffTiny d = new DiffTiny{salt: bytes32(s)}();
            assertEq(address(d), predicted, "the EVM deployed somewhere else");
        }
    }

    // ------------------------------------------------------------------ deriveAddress, CREATE2 family

    function test_DeriveAddress_EachCreate2SubModeHashesItsOwnSaltOverSortedTokens() public {
        address f = makeAddr("factory-without-code");
        bytes32 ih = keccak256("init code hash");
        address a = address(0xA11CE);
        address b = address(0xB0B);
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        for (uint256 dir; dir < 2; ++dir) {
            (address x, address y) = dir == 0 ? (a, b) : (b, a);
            // mode 4 - Uniswap-V2 family: keccak(packed(token0, token1)).
            assertEq(BPC.deriveAddress(f, x, y, 3000, true, 60, 4, ih),
                     _eip1014(f, keccak256(abi.encodePacked(t0, t1)), ih), "sub-mode 0");
            // mode 5, fee != 0 - Uniswap-V3 family: keccak(abi.encode(token0, token1, fee)).
            assertEq(BPC.deriveAddress(f, x, y, 3000, true, 60, 5, ih),
                     _eip1014(f, keccak256(abi.encode(t0, t1, uint24(3000))), ih), "sub-mode 1, fee");
            assertEq(BPC.deriveAddress(f, x, y, 500, true, 60, 5, ih),
                     _eip1014(f, keccak256(abi.encode(t0, t1, uint24(500))), ih), "sub-mode 1, other fee");
            // mode 5, fee == 0 - Algebra: keccak(abi.encode(token0, token1)); a factory that names no
            // deployer is its own CREATE2 origin.
            assertEq(BPC.deriveAddress(f, x, y, 0, true, 60, 5, ih),
                     _eip1014(f, keccak256(abi.encode(t0, t1)), ih), "sub-mode 1, Algebra, no deployer");
            // mode 6 - Solidly family: keccak(packed(token0, token1, stable)).
            assertEq(BPC.deriveAddress(f, x, y, 3000, true, 60, 6, ih),
                     _eip1014(f, keccak256(abi.encodePacked(t0, t1, true)), ih), "sub-mode 2, stable");
            assertEq(BPC.deriveAddress(f, x, y, 3000, false, 60, 6, ih),
                     _eip1014(f, keccak256(abi.encodePacked(t0, t1, false)), ih), "sub-mode 2, volatile");
            // mode 7 - tick-spacing family: keccak(abi.encode(token0, token1, tickSpacing)).
            assertEq(BPC.deriveAddress(f, x, y, 3000, true, 60, 7, ih),
                     _eip1014(f, keccak256(abi.encode(t0, t1, int24(60))), ih), "sub-mode 3");
            assertEq(BPC.deriveAddress(f, x, y, 3000, true, 200, 7, ih),
                     _eip1014(f, keccak256(abi.encode(t0, t1, int24(200))), ih), "sub-mode 3, other spacing");
        }
    }

    function test_DeriveAddress_AnAlgebraPoolIsDerivedFromTheDeployerTheFactoryNames() public {
        address dep = makeAddr("algebra pool deployer");
        address f = address(new DiffAlgebraFactory(dep));
        bytes32 ih = keccak256("algebra init code hash");
        address a = address(0xA11CE);
        address b = address(0xB0B);
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        bytes32 salt = keccak256(abi.encode(t0, t1));
        assertEq(BPC.deriveAddress(f, a, b, 0, false, 0, 5, ih), _eip1014(dep, salt, ih), "origin is not the named deployer");
        // The same factory in the same slot with a fee is a plain V3: the factory itself is the origin.
        assertEq(BPC.deriveAddress(f, a, b, 3000, false, 0, 5, ih),
                 _eip1014(f, keccak256(abi.encode(t0, t1, uint24(3000))), ih), "a fee'd pool left the factory origin");
    }

    // ------------------------------------------------------------------ ilog10

    function test_Ilog10_Grid_EveryPowerOfTenAndBothNeighboursLandOnTheFloorLogarithm() public view {
        assertEq(door.ilog10(0), 0, "zero");
        uint256 p = 1;
        for (uint256 k; k <= 77; ++k) {
            assertEq(door.ilog10(p), k, "10^k");
            if (k > 0) {
                assertEq(door.ilog10(p - 1), k - 1, "10^k - 1");
                assertEq(door.ilog10(p + 1), k, "10^k + 1");
            }
            if (k < 77) p *= 10;
        }
        assertEq(door.ilog10(type(uint256).max), 77, "the whole word");
    }

    function testFuzz_Ilog10_TheAnswerBracketsTheInputBetweenConsecutivePowersOfTen(uint256 x, uint8 shift) public view {
        x = (x >> shift) | 1; // every magnitude, never zero
        uint256 n = door.ilog10(x);
        assertLe(n, 77, "more digits than the word holds");
        assertLe(10 ** n, x, "10^n is above the input");
        if (n < 77) assertLt(x, 10 ** (n + 1), "10^(n+1) is not above the input");
    }

    // ------------------------------------------------------------------ mulDivUp

    function testFuzz_MulDivUp_IsTheCeilingOfTheExactQuotientWhenTheProductFitsTheWord(uint128 a, uint128 b, uint256 d)
        public view
    {
        d = bound(d, 1, type(uint256).max);
        uint256 p = uint256(a) * uint256(b);
        uint256 ceil = p / d + (p % d == 0 ? 0 : 1);
        assertEq(door.mulDivUp(a, b, d), ceil, "not the ceiling");
        // And on the exact multiples, where rounding up must add nothing.
        if (b != 0) assertEq(door.mulDivUp(a, b, b), a, "an exact quotient was rounded up");
    }

    function test_MulDivUp_ACeilingOnePastTheWordIsRefusedByItsReasonNotWrappedToZero() public {
        // p * q = 2^257 - 1 = (2^256 - 1) * 2 + 1: the floor of p*q/2 is the largest word and the
        // remainder is 1, so the ceiling is 2^256 and does not exist.
        uint256 p = 535006138814359;
        uint256 q = 0x10d5effea103c44aaf18a26b449186a7de3dd6c1ce3d26d03dfd9;
        unchecked { assertEq(p * q, type(uint256).max, "witness: low word"); }
        assertEq(mulmod(p, q, type(uint256).max), 1, "witness: high word is 1");
        vm.expectRevert(bytes("BPC:mulDivUp"));
        door.mulDivUp(p, q, 2);
        // The largest word itself is reachable when nothing has to be rounded.
        assertEq(door.mulDivUp(type(uint256).max, 7, 7), type(uint256).max, "an exact maximum was refused");
    }

    // ------------------------------------------------------------------ to18

    /// @dev `dec` stays below 78: BPC._decimalsOf reads nothing larger (it falls back to 18).
    function testFuzz_To18_ScalingUpIsRepeatedTensAndStopsAtTheWord(uint256 v, uint8 dec, uint8 shift) public view {
        dec = uint8(bound(dec, 0, 18));
        v = v >> shift;
        uint256 ref = v;
        for (uint256 i = dec; i < 18 && ref != type(uint256).max; ++i) {
            ref = ref > type(uint256).max / 10 ? type(uint256).max : ref * 10;
        }
        assertEq(door.to18(v, dec), ref, "not v * 10^(18 - dec), saturated");
    }

    function testFuzz_To18_ScalingDownIsRepeatedDivisionByTen(uint256 v, uint8 dec, uint8 shift) public view {
        dec = uint8(bound(dec, 19, 77));
        v = v >> (shift % 64);
        uint256 ref = v;
        for (uint256 i = 18; i < dec; ++i) ref /= 10;
        assertEq(door.to18(v, dec), ref, "not v / 10^(dec - 18)");
    }
}
