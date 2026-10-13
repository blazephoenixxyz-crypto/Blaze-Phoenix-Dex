// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE ALGEBRA SALT HAS TWO PRODUCERS AND NO TEST.
//
//  `Core.algebraSalt` (src/BlazePhoenixCore.sol) is `keccak(encode(t0,t1))`
//  with NO fee component — Algebra fees are dynamic, so they never enter the
//  salt. Two live callers exist and they are supposed to agree forever:
//    * `Core.deriveAddress`, mode 5 when `fee == 0` — the
//      zero fee is the "dynamic fee sentinel" that picks the Algebra arm;
//    * the HUB's attested derive, which spells the same
//      `create2Address(orig, algebraSalt(t0,t1), initHash)` after T19 removed
//      the live `poolDeployer()` ask from that path.
//  Measured on this tree: `algebraSalt` is named by **0** files under `test/`
//  and by **0** entries of `.github/scripts/mutants.py`. Nothing pinned the
//  salt VALUE, and nothing pinned that the two producers agree.
//
//  CORRECTION PAID HERE (first baseline run): this file first asserted
//  that `abi.encode(t0,t1)` and `abi.encodePacked(t0,t1)` are the same
//  preimage. They are NOT: `Packed` emits two 20-byte addresses (40 bytes)
//  and `encode` two left-padded words (64 bytes), and the V2 arm of
//  `deriveAddress` uses the PACKED form — so the two families
//  derive from different salts by design. The test now pins that difference
//  instead of denying it, because "simplifying" `algebraSalt` to the packed
//  form would move every Algebra address.
//
//  Oracle discipline: every expected value is recomputed here from
//  `keccak256(abi.encode(..))` and the textbook CREATE2 preimage
//  `ff ++ deployer ++ salt ++ initCodeHash` — never by asking the code under
//  test which address or which salt it would produce.
//
//  What each block fails on:
//    * the two `mstore` slots swapped inside `algebraSalt` — block 1 and 3;
//    * a `keccak256(0x00, 0x20)`-shaped truncation, or any change of preimage
//      length — block 1;
//    * the `isAlgebra` arm dropped from `deriveAddress` (fee folded back into
//      the salt) — block 4;
//    * the non-Algebra arm (`keccak(t0,t1,fee)`) losing the fee — block 4's
//      negative control is what makes that visible;
//    * the `poolDeployer()` fallback removed (origin staying the factory for
//      an Algebra row) — block 4's second half.
//
//  forge test --match-contract CoreAlgebraSaltIsSharedByBothDerives -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

/// @dev Answers `poolDeployer()` (selector 0x3119049a) with one word — the
///      shape `Core.resolvePoolDeployer` reads (returndatasize >= 32).
contract DeployerAnsweringFactory {
    address public poolDeployer;
    constructor(address d) { poolDeployer = d; }
}

contract CoreAlgebraSaltIsSharedByBothDerivesTest is Test {
    /// A deployer address with no relation to the test contract, so a
    /// "the origin is this test contract" mutation cannot pass by accident.
    address constant POOL_DEPLOYER = address(0xdEADbeEF00000000000000000000000000000001);
    bytes32 constant INIT_HASH   = keccak256("blaze-phoenix:algebra-pool-initcode");
    uint24  constant ALGEBRA_FEE = 0;      // the dynamic-fee sentinel
    uint24  constant V3_FEE      = 500;

    address constant TOK_A = address(0xAaAa0000000000000000000000000000000000A1);
    address constant TOK_B = address(0xBbbB0000000000000000000000000000000000B2);

    /// The textbook CREATE2 address, written once here and never taken from
    /// the Core: `ff ++ deployer ++ salt ++ initCodeHash`.
    function _create2(address deployer, bytes32 salt, bytes32 initHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initHash)))));
    }

    // ─── 1. the salt value ───────────────────────────────────────────────────

    /// `algebraSalt(t0,t1)` is `keccak256(abi.encode(t0,t1))` — two left-padded
    /// words (64 bytes), no fee. The PACKED form is a different preimage (two
    /// 20-byte addresses, 40 bytes) and is the V2 arm's salt; it is
    /// pinned as different here, because "simplifying" the Algebra salt into it
    /// would move every Algebra address.
    function test_AlgebraSaltIsTheAbiEncodedPairHash() public pure {
        assertEq(BPC.algebraSalt(TOK_A, TOK_B), keccak256(abi.encode(TOK_A, TOK_B)),
            "algebraSalt != keccak(abi.encode(t0,t1))");
        assertTrue(BPC.algebraSalt(TOK_A, TOK_B) != keccak256(abi.encodePacked(TOK_A, TOK_B)),
            "the packed pair hash is a different preimage (40 vs 64 bytes): the Algebra salt must not collapse into the V2 one");
        assertEq(BPC.algebraSalt(address(0), address(0)), keccak256(abi.encode(address(0), address(0))),
            "the zero pair is still the hash of two zero words");
        assertEq(BPC.algebraSalt(TOK_A, TOK_B), BPC.algebraSalt(TOK_A, TOK_B),
            "the pure function must be deterministic");
    }

    function testFuzz_AlgebraSaltMatchesAbiEncode(address a, address b) public pure {
        assertEq(BPC.algebraSalt(a, b), keccak256(abi.encode(a, b)), "salt != keccak(encode(a,b))");
    }

    /// The docstring owes the caller the order: `requires t0 < t1`. Pinned as
    /// behaviour, not prose — the function must NOT sort internally, or a
    /// caller that sorts twice would silently produce the same address for
    /// both orders and the pair key would stop being order-informative.
    function test_AlgebraSaltDoesNotSortItsArguments() public pure {
        assertTrue(TOK_A != TOK_B, "fixture: the two tokens must differ");
        assertEq(BPC.algebraSalt(TOK_A, TOK_B), keccak256(abi.encode(TOK_A, TOK_B)), "sorted order");
        assertEq(BPC.algebraSalt(TOK_B, TOK_A), keccak256(abi.encode(TOK_B, TOK_A)), "inverted order");
        assertTrue(BPC.algebraSalt(TOK_A, TOK_B) != BPC.algebraSalt(TOK_B, TOK_A),
            "the salt must be order sensitive: it does not sort its own arguments");
    }

    // ─── 2. the two producers agree ──────────────────────────────────────────

    /// Mode 5 with `fee == 0` is the Algebra arm. Its origin is the deployer the
    /// factory answers, and its salt is `algebraSalt` — exactly the expression
    /// the Hub's attested derive spells out. Sorted internally:
    /// the SAME expected address must come out of either argument order.
    function test_DeriveAlgebraSlotIsTheSaltWithoutTheFee() public {
        DeployerAnsweringFactory fac = new DeployerAnsweringFactory(POOL_DEPLOYER);
        (address t0, address t1) = TOK_A < TOK_B ? (TOK_A, TOK_B) : (TOK_B, TOK_A);
        address want = _create2(POOL_DEPLOYER, keccak256(abi.encode(t0, t1)), INIT_HASH);

        assertEq(BPC.deriveAddress(address(fac), TOK_A, TOK_B, ALGEBRA_FEE, false, 0, 5, INIT_HASH), want,
            "mode 5 with fee 0 must derive from algebraSalt and the answered deployer");
        assertEq(BPC.deriveAddress(address(fac), TOK_B, TOK_A, ALGEBRA_FEE, false, 0, 5, INIT_HASH), want,
            "the derive sorts the pair itself: both argument orders are one address");
    }

    /// The negative control: the same slot with a NON-zero fee keeps the fee in
    /// the salt (`keccak(encode(t0,t1,fee))`), so the Algebra arm is a branch
    /// and not an accident of the slot number. Plus the `poolDeployer()`
    /// fallback: a factory that does not answer it derives from the factory.
    ///
    /// CORRECTION PAID HERE (first baseline run): the `poolDeployer()`
    /// origin override is ALGEBRA-ONLY — `Core.deriveAddress` asks for the deployer
    /// inside `if (isAlgebra)`. A mode-5 row with a non-zero fee derives from
    /// the FACTORY itself, deployer-answer or not. This block first expected
    /// the answered deployer there and was red; the expectation was wrong, and
    /// the pair of assertions below now pins both origins at once.
    function test_DeriveKeepsTheFeeWhenItIsNotAlgebra_AndFallsBackWithoutADeployer() public {
        DeployerAnsweringFactory fac = new DeployerAnsweringFactory(POOL_DEPLOYER);
        (address t0, address t1) = TOK_A < TOK_B ? (TOK_A, TOK_B) : (TOK_B, TOK_A);

        address wantV3 = _create2(address(fac), keccak256(abi.encode(t0, t1, V3_FEE)), INIT_HASH);
        address gotV3 = BPC.deriveAddress(address(fac), TOK_A, TOK_B, V3_FEE, false, 0, 5, INIT_HASH);
        assertEq(gotV3, wantV3, "a non-Algebra mode-5 row keeps the fee in its salt and derives from the FACTORY");
        assertTrue(gotV3 != _create2(POOL_DEPLOYER, keccak256(abi.encode(t0, t1, V3_FEE)), INIT_HASH),
            "the poolDeployer() origin is Algebra-only: a fee-carrying row must not use the answered deployer");

        address algebra = BPC.deriveAddress(address(fac), TOK_A, TOK_B, ALGEBRA_FEE, false, 0, 5, INIT_HASH);
        assertTrue(algebra != gotV3, "the fee must move the address: the Algebra arm is a real branch");

        // A factory with no code answers nothing: the origin stays the factory.
        address plain = address(0xFAC701);
        assertEq(BPC.deriveAddress(plain, TOK_A, TOK_B, ALGEBRA_FEE, false, 0, 5, INIT_HASH),
            _create2(plain, keccak256(abi.encode(t0, t1)), INIT_HASH),
            "with no poolDeployer() answer the CREATE2 origin must stay the factory");
    }

    /// The Hub's attested derive is the same expression, so pinning it here is
    /// pinning the Hub's address for an Algebra row: one salt producer, one
    /// preimage producer (`Core.create2Address`), zero live input.
    function test_TheAttestedExpressionAndTheLiveDeriveAreOneAddress() public {
        (address t0, address t1) = TOK_A < TOK_B ? (TOK_A, TOK_B) : (TOK_B, TOK_A);
        DeployerAnsweringFactory fac = new DeployerAnsweringFactory(POOL_DEPLOYER);

        address attestedShaped = BPC.create2Address(POOL_DEPLOYER, BPC.algebraSalt(t0, t1), INIT_HASH);
        assertEq(attestedShaped,
            BPC.deriveAddress(address(fac), t0, t1, ALGEBRA_FEE, false, 0, 5, INIT_HASH),
            "the Hub's expression and Core's mode-5 arm must produce one address");
        assertEq(attestedShaped, _create2(POOL_DEPLOYER, keccak256(abi.encode(t0, t1)), INIT_HASH),
            "and that address must be the textbook ff-form CREATE2 of the salt");
    }
}
