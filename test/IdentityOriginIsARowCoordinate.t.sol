// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE CREATE2 ORIGIN IS A COORDINATE OF THE ROW.
//
//  A CREATE2 address is ff ++ origin ++ salt ++ initHash. The salt follows the mode, the init
//  hash is written at admission, and the origin is whoever runs CREATE2: the factory for most
//  families, a separate PoolDeployer for Algebra (Camelot) and Pancake V3. Until identity-2 the
//  Hub took the attested origin (`factoryDeployer`, pinned in `addFactory`) only for mode 5 with
//  fee 0; every other derive row derived from the factory, so a Pancake V3 row (mode 5, fee 500)
//  derived an address nobody deployed at and listed nothing.
//
//  Now every derive row (modes 4-7) is attested at admission and derives from its pin (zero means
//  the factory itself); an asking row (modes 0-3) asks the factory, never the pin, and never
//  writes it. The Gate answers no `poolDeployer()`, so its wrappers keep deriving from the Gate.
//
//  RED at ab0bc56 (before identity-2): test_Probe_DeriveRowUsesTheAttestedOrigin and
//  test_Probe_EveryDeriveModeTakesTheAttestedOrigin list nothing. The other three are guards: green
//  at ab0bc56, each red under its own mutant (.github/scripts/mutants.py, idr-2, idr-3, idr-5).
//
//  Oracle: the EVM. Every expected pool is the address a CREATE2 deployment actually landed at,
//  under the venue's salt spelled here; never `Core.v3Salt` or `Core.create2Address`.
//
//  Matrix (range x vector x dimension):
//    ranges   : fees 100 / 500 / 10000 (mode 5); stable false and true (mode 6); spacing 50 (mode 7);
//               the right init hash and a wrong one
//    vectors  : deployer != factory (Pancake / Algebra shape); a factory re-admitted from a derive
//               row to an asking row while a deployer still answers; a deployer that would answer
//               a getPool of its own; a factory whose getPool answers while the derive misses; the
//               real Gate
//    dims     : unit (Hub.discoverFor, storage read of the pin), mutant
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixGate} from "../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// The deployed venue: empty, so its creation code (and init hash) is a constant.
contract OrgPool {}

/// An asked venue: proves its own pair, as `_probe` requires of an asking row.
contract OrgAskedPool {
    address public immutable token0;
    address public immutable token1;
    constructor(address t0, address t1) { token0 = t0; token1 = t1; }
}

/// The contract that runs CREATE2, under each venue's salt spelled from the venue.
/// It also answers a getPool of its own, so an asking row that asked it would list that answer.
contract OrgDeployer {
    address public answer;
    function setAnswer(address a) external { answer = a; }
    function getPool(address, address, uint24) external view returns (address) { return answer; }
    function v2(address t0, address t1) external returns (address) {
        return address(new OrgPool{salt: keccak256(abi.encodePacked(t0, t1))}());
    }
    function v3(address t0, address t1, uint24 fee) external returns (address) {
        return address(new OrgPool{salt: keccak256(abi.encode(t0, t1, fee))}());
    }
    function solidly(address t0, address t1, bool stable) external returns (address) {
        return address(new OrgPool{salt: keccak256(abi.encodePacked(t0, t1, stable))}());
    }
    function cl(address t0, address t1, int24 sp) external returns (address) {
        return address(new OrgPool{salt: keccak256(abi.encode(t0, t1, sp))}());
    }
}

/// A factory that names a separate deployer (Pancake V3 / Algebra shape) and answers getPool.
contract OrgFactory {
    address public immutable poolDeployer;
    address public answer;
    constructor(address d) { poolDeployer = d; }
    function setAnswer(address a) external { answer = a; }
    function getPool(address, address, uint24) external view returns (address) { return answer; }
}

contract IdentityOriginIsARowCoordinateTest is Test {
    BlazePhoenixHub internal hub;
    OrgDeployer internal dep;

    // Sorted bare-address tokens: tokenA < tokenB.
    address internal constant tokenA = address(0x2222);
    address internal constant tokenB = address(0x3333);

    bytes32 internal poolInit;
    uint24[] internal noFees;
    int24[] internal noSpacings;

    // `$.factoryDeployer` has no getter. The ERC-7201 namespace is re-derived from its literal, the
    // field index (23) is the one T19ReadmissionEdge counts, and `_pinOf` is checked against a known
    // attestation before any test relies on it (test_Probe_AskRowNeverAsksTheDeployer).
    bytes32 internal constant HUB_SLOT
        = keccak256(abi.encode(uint256(keccak256("blazephoenix.hub.v1")) - 1)) & ~bytes32(uint256(0xff));
    uint256 internal constant FACTORY_DEPLOYER_FIELD = 23;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xD00D));
        dep = new OrgDeployer();
        poolInit = keccak256(type(OrgPool).creationCode);
    }

    function _pinOf(address factory) internal view returns (address) {
        return address(uint160(uint256(vm.load(
            address(hub), keccak256(abi.encode(factory, uint256(HUB_SLOT) + FACTORY_DEPLOYER_FIELD))
        ))));
    }

    function _create2(address origin, bytes32 salt) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", origin, salt, poolInit)))));
    }

    function _has(PoolInfo[] memory hits, address p) internal pure returns (bool) {
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == p) return true;
        return false;
    }

    /// [idr-1] Pancake V3 shape: mode 5 with real fees, the pools deployed by the factory's
    /// poolDeployer(). Discovery finds each of them, and only them.
    function test_Probe_DeriveRowUsesTheAttestedOrigin() public {
        OrgFactory f = new OrgFactory(address(dep));
        uint24[3] memory fs = [uint24(100), 500, 10000];
        uint24[] memory fees = new uint24[](3);
        address[3] memory pools;
        for (uint256 i; i < 3; ++i) {
            fees[i] = fs[i];
            pools[i] = dep.v3(tokenA, tokenB, fs[i]);
            // Not vacuous: the factory's own derivation of the same salt holds nothing.
            assertEq(_create2(address(f), keccak256(abi.encode(tokenA, tokenB, fs[i]))).code.length, 0,
                "premise: nothing is deployed at the factory-origin address");
        }
        hub.addFactory(address(f), BPC.KIND_V3, 5, poolInit, fees, noSpacings);

        PoolInfo[] memory hits = hub.discoverFor(tokenB, tokenA);
        assertEq(hits.length, 3, "one pool per fee, derived from the attested deployer");
        for (uint256 i; i < 3; ++i) {
            assertTrue(_has(hits, pools[i]), "each deployed pool is listed");
        }
    }

    /// [idr-6] Every derive mode takes the attested origin, not mode 5 alone: a V2-salt row (4),
    /// a clone row (6, both stable bits) and a CL row (7), each from a factory naming the deployer.
    function test_Probe_EveryDeriveModeTakesTheAttestedOrigin() public {
        int24[] memory sps = new int24[](1);
        sps[0] = 50;
        address p4 = dep.v2(tokenA, tokenB);
        address p6v = dep.solidly(tokenA, tokenB, false);
        address p6s = dep.solidly(tokenA, tokenB, true);
        address p7 = dep.cl(tokenA, tokenB, 50);
        hub.addFactory(address(new OrgFactory(address(dep))), BPC.KIND_V2, 4, poolInit, noFees, noSpacings);
        hub.addFactory(address(new OrgFactory(address(dep))), BPC.KIND_SOLIDLY, 6, poolInit, noFees, noSpacings);
        hub.addFactory(address(new OrgFactory(address(dep))), BPC.KIND_V3, 7, poolInit, noFees, sps);

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 4, "modes 4, 6 (x2) and 7 each derive from the attested deployer");
        assertTrue(_has(hits, p4), "mode 4 (V2 salt)");
        assertTrue(_has(hits, p6v) && _has(hits, p6s), "mode 6 (clone salt, both curves)");
        assertTrue(_has(hits, p7), "mode 7 (CL spacing salt)");
    }

    /// [idr-2] An asking row asks its factory. The factory was admitted under mode 5 (pin = the
    /// deployer), then re-admitted under mode 1 before renouncing: the pin survives (an asking row
    /// never writes it), and the deployer would answer a getPool of its own. Discovery lists the
    /// factory's answer and nothing else.
    function test_Probe_AskRowNeverAsksTheDeployer() public {
        OrgFactory f = new OrgFactory(address(dep));
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        hub.addFactory(address(f), BPC.KIND_V3, 5, poolInit, fees, noSpacings);
        assertEq(_pinOf(address(f)), address(dep), "premise: the reader sees the attestation");

        address p = address(new OrgAskedPool(tokenA, tokenB));
        address q = address(new OrgAskedPool(tokenA, tokenB));
        f.setAnswer(p);
        dep.setAnswer(q);
        hub.addFactory(address(f), BPC.KIND_V3, 1, bytes32(0), fees, noSpacings);
        assertEq(_pinOf(address(f)), address(dep), "premise: the asking re-admission left the pin as it was");

        PoolInfo[] memory hits = hub.discoverFor(tokenA, tokenB);
        assertEq(hits.length, 1, "one asked pool");
        assertEq(hits[0].pool, p, "the factory's answer, never the deployer's");
    }

    /// [idr-3] A derive row with the wrong init hash finds nothing, even when its factory's own
    /// getPool would answer: a derive that misses is an absence, never a cue to ask.
    function test_Probe_WrongInitHashFindsNothing() public {
        OrgFactory f = new OrgFactory(address(dep));
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        address deployed = dep.v3(tokenA, tokenB, 500);
        f.setAnswer(deployed);
        hub.addFactory(address(f), BPC.KIND_V3, 5, keccak256("another venue's init code"), fees, noSpacings);

        assertEq(f.getPool(tokenA, tokenB, 500), deployed, "premise: the factory would answer");
        assertEq(hub.discoverFor(tokenA, tokenB).length, 0, "the wrong init hash derives an empty address");
    }

    /// [idr-5] The real Gate names no deployer: admitted as a mode-5 row it pins zero, so its
    /// wrappers derive from the Gate itself, the origin the kind-9 door checks (Core.gateWrapperLive).
    function test_Door_TheGateNamesNoDeployer() public {
        BlazePhoenixGate gate = new BlazePhoenixGate(address(this));
        uint24[] memory fees = new uint24[](1);
        fees[0] = (3 << 16) | 7;
        // Not vacuous: the reader sees a non-zero attestation in this same Hub.
        OrgFactory f = new OrgFactory(address(dep));
        hub.addFactory(address(f), BPC.KIND_V3, 5, poolInit, fees, noSpacings);
        assertEq(_pinOf(address(f)), address(dep), "premise: the reader sees an attestation");

        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, noSpacings);
        assertEq(BPC.resolvePoolDeployer(address(gate)), address(0), "the Gate answers no poolDeployer()");
        assertEq(_pinOf(address(gate)), address(0), "the Gate's row pins no origin: it derives from the Gate");
    }
}
