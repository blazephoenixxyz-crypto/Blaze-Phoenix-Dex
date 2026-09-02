// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  T19 (external report, Thomas) — the Algebra derive's live poolDeployer().
//
//  Hub:872 exempts every derive mode (>= 4) from the factory codehash pin,
//  on the theory that "a derivation is a theorem the factory cannot
//  influence". Mode 5 with fee 0 (Algebra) breaks the theorem: Core:467
//  staticcalls factory.poolDeployer() LIVE at scan time and uses the answer
//  as the CREATE2 origin — unpinned, uncached, unvalidated. A factory whose
//  ANSWER changes after admission steers which address discovery treats as
//  the pair's pool.
//
//  The mock here is deliberately proxy-shaped (EIP-1967 threat model): its
//  runtime code NEVER changes between admission and scan — only the answer
//  does. So these tests fail against the unfixed Hub AND against the
//  too-weak fix shape (extending the codehash pin to mode 5), which is
//  blind to an implementation swap behind a constant-codehash proxy.
//
//  Expected addresses are computed by an INDEPENDENT inline CREATE2 formula
//  from literal constants — never by asking the code under test which
//  address it would derive (eight-ways rule 4: the oracle must not be the
//  object).
//
//  forge test --match-contract T19AlgebraDeployerPin -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// @dev Proxy stand-in: the public getter compiles to selector
///      poolDeployer() (0x3119049a) — exactly what Core resolves — and the
///      stored answer is mutable while the runtime code (and so the
///      codehash) stays constant. This is what an EIP-1967 factory proxy
///      looks like to a codehash pin: invisible.
contract SwappableDeployerFactory {
    address public poolDeployer;
    constructor(address d) { poolDeployer = d; }
    function setPoolDeployer(address d) external { poolDeployer = d; }
}

contract T19AlgebraDeployerPinTest is Test {
    BlazePhoenixHub hub;
    SwappableDeployerFactory fac;

    // Sorted bare-address tokens (house style): tokenA < tokenB.
    address constant tokenA = address(0x2222);
    address constant tokenB = address(0x3333);

    // The deployer attested at admission, and the one swapped in afterwards.
    address constant DEP_ATTESTED = address(0xA77E57ED);
    address constant DEP_SWAPPED  = address(0xBAD0DE99);

    uint8  constant MODE_CREATE2_V3 = 5;    // Hub-internal constant, pinned
    bytes32 constant INIT_HASH = keccak256("algebra-init");

    uint24[] internal noFees;
    int24[]  internal noSpacings;
    uint24[] internal v3Fees;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xD00D));
    }

    /// Independent oracle: consensus CREATE2 address formula with the Algebra
    /// salt (keccak(abi.encode(t0, t1)) — no fee component; Core:451 mirrors
    /// this, but the expectation here is built from literals, not from Core.
    function _algebraPool(address origin) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", origin, keccak256(abi.encode(tokenA, tokenB)), INIT_HASH
        )))));
    }

    function _admitAlgebra() private {
        fac = new SwappableDeployerFactory(DEP_ATTESTED);
        hub.addFactory(address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings);
    }

    // =========================================================================
    //  RED #1 — the answer swap (proxy implementation swap, codehash intact).
    // =========================================================================

    /// Admission attests poolDeployer() == DEP_ATTESTED. The factory then
    /// changes its ANSWER — its code and codehash untouched — and an
    /// attacker parks bytecode at the address derived from the new answer.
    /// Discovery must keep deriving from the ATTESTED origin: the honest
    /// pool stays served, the steered address is never emitted.
    function test_T19_AnswerSwap_DerivesFromAttestedDeployer() public {
        _admitAlgebra();
        address poolHonest = _algebraPool(DEP_ATTESTED);
        vm.etch(poolHonest, hex"fe");

        // Control: with the honest answer live, the honest pool is the hit.
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "control: one Algebra candidate");
        assertEq(hits[0].pool, poolHonest, "control: derived from the attested deployer");

        // The swap: answer changes, codehash does not (proxy upgrade shape).
        bytes32 chBefore = address(fac).codehash;
        fac.setPoolDeployer(DEP_SWAPPED);
        assertEq(address(fac).codehash, chBefore, "premise: the codehash pin sees nothing");

        // The attacker deploys at the steered derivation.
        address poolSteered = _algebraPool(DEP_SWAPPED);
        vm.etch(poolSteered, hex"fe");

        hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "the steered derivation must not add a candidate");
        assertEq(
            hits[0].pool, poolHonest,
            "discovery must derive from the deployer attested at admission, not the live answer"
        );
    }

    // =========================================================================
    //  RED #2 — resolver death after admission (fail closed, never dark).
    // =========================================================================

    /// The factory's code mutates after admission into something that no
    /// longer answers poolDeployer() at all. The live-resolve path would
    /// silently fall back to origin = factory and derive a phantom; the pin
    /// keeps serving the pool attested at admission. This is the mode-5
    /// analogue of test_L872_MutatedCreate2Factory_StillDerives: a code
    /// change must not darken an already-attested derivation.
    function test_T19_ResolverDies_AttestedPoolStaysServed() public {
        _admitAlgebra();
        address poolHonest = _algebraPool(DEP_ATTESTED);
        vm.etch(poolHonest, hex"fe");

        // Post-admission code mutation: poolDeployer() now reverts.
        vm.etch(address(fac), hex"fe");

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "the attested Algebra pool must keep being discovered");
        assertEq(hits[0].pool, poolHonest, "derived from the attested deployer, not the dead resolver's fallback");
    }

    // =========================================================================
    //  GUARDS (green before and after) — the arms the fix must not touch.
    // =========================================================================

    /// A plain V3 CREATE2 row in the same mode-5 slot (fee != 0) never
    /// consults poolDeployer(): its derivation must stay on the untouched
    /// Core path, origin = factory, fee in the salt.
    function test_T19_PlainV3Mode5_FeeInSalt_FactoryOrigin() public {
        v3Fees.push(3000);
        address facV3 = address(0xFAC0503);          // codeless: no resolver to ask
        hub.addFactory(facV3, BPC.KIND_V3, MODE_CREATE2_V3, INIT_HASH, v3Fees, noSpacings);

        address pool = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", facV3,
            keccak256(abi.encode(tokenA, tokenB, uint24(3000))),
            INIT_HASH
        )))));
        vm.etch(pool, hex"fe");

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "plain V3 mode-5 row still derives");
        assertEq(hits[0].pool, pool, "origin is the factory, fee is in the salt");
    }

    /// Factory that answers zero-at-admission (no poolDeployer selector):
    /// the attested origin degenerates to the factory itself — Core's own
    /// fallback, frozen. The derivation still works.
    function test_T19_NoResolverAtAdmission_FactoryIsOrigin() public {
        address facBare = address(0xFAC0500);        // codeless at admission
        hub.addFactory(facBare, BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings);

        address pool = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", facBare, keccak256(abi.encode(tokenA, tokenB)), INIT_HASH
        )))));
        vm.etch(pool, hex"fe");

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "zero-pin Algebra row derives from the factory");
        assertEq(hits[0].pool, pool, "origin fallback matches Core's, frozen at admission");
    }

    // =========================================================================
    //  SEMANTICS the pin must keep written down (review 2026-09-02).
    // =========================================================================

    /// The pin is keyed on MODE, not on kind: a V3-kind row in the mode-5 slot
    /// with an EMPTY fee list probes with fee 0 (Hub `_scanFactory`:
    /// `fees.length == 0 ? 0`), which is the Algebra derive. It must be pinned
    /// like an Algebra row, or a V3-declared proxy factory keeps the live ask.
    function test_T19_V3KindMode5EmptyFees_IsPinnedToo() public {
        fac = new SwappableDeployerFactory(DEP_ATTESTED);
        hub.addFactory(address(fac), BPC.KIND_V3, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings);
        address poolHonest = _algebraPool(DEP_ATTESTED);
        vm.etch(poolHonest, hex"fe");

        fac.setPoolDeployer(DEP_SWAPPED);
        vm.etch(_algebraPool(DEP_SWAPPED), hex"fe");

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "V3-kind, mode 5, fee 0: one candidate");
        assertEq(hits[0].pool, poolHonest, "V3-kind mode-5 row derives from the ATTESTED deployer too");
    }

    /// Re-admission re-attests the CURRENT answer (the same semantics as the
    /// codehash pin one line above it). The mapping is per factory address and
    /// shared by every row of that factory, so a second admission after an
    /// answer swap moves ALL rows to the new origin: the attested pool stops
    /// being served and the steered one starts. This is by design (admission
    /// is a human act that trusts the factory as it stands) and it is what an
    /// operator must know before re-admitting a factory "to add a tier".
    function test_T19_ReAdmission_ReAttestsTheCurrentAnswer() public {
        _admitAlgebra();
        vm.etch(_algebraPool(DEP_ATTESTED), hex"fe");
        fac.setPoolDeployer(DEP_SWAPPED);
        address poolNew = _algebraPool(DEP_SWAPPED);
        vm.etch(poolNew, hex"fe");

        // Before re-admission: the first attestation still governs.
        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits[0].pool, _algebraPool(DEP_ATTESTED), "first attestation governs");

        // Re-admit the same factory (a second row; seats are permanent).
        hub.addFactory(address(fac), BPC.KIND_ALGEBRA, MODE_CREATE2_V3, INIT_HASH, noFees, noSpacings);
        hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "two rows, one factory, one attested origin: dedup to one hit");
        assertEq(hits[0].pool, poolNew, "re-admission attested the CURRENT answer for every row");
    }
}
