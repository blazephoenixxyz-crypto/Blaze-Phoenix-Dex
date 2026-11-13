// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  IDENTITY IS ONE DERIVATION.
//
//  Two questions, one formula:
//    * the Hub's discovery: "where does factory F deploy the pool of (t0, t1, coordinate)?"
//      - `Core.deriveAddress`, which asks F in modes 0-3 and derives by CREATE2 in modes 4-7;
//    * the kind-9 door: "is this pool the admitted Gate's wrapper for (t0, t1, key)?"
//      - `Core.gateWrapperLive`, which until 2e4fdaa spelled the mode-5 derivation by hand
//      (sort, `v3Salt`, `create2Address`) instead of asking `deriveAddress`.
//
//  Part 1 pins the rewrite: the frozen hand-spelled identity (test/ref/GateWrapperLiveRef2e4fdaa.sol)
//  and the live one answer alike on every vector - the honest wrapper, a wrapper of another key, a
//  pool that only names the gate, an unadmitted gate, a gate whose code moved, a cleared family,
//  the other token - and on the vector where a naive rewrite does not: key 0. `deriveAddress`
//  reads `fee == 0` in mode 5 as the Algebra sentinel and takes its CREATE2 origin from the
//  factory's `poolDeployer()`; a gate that answered it would make another deployer's wrapper pass.
//  RED at db6ab51 (the rewrite without the key-0 refusal): the frozen identity refuses that
//  wrapper, the rewritten one accepted it. One verdict changes on purpose, and is pinned as such:
//  a wrapper deployed AT key 0 (which the real Gate refuses to create) is refused, because the
//  Hub's discovery never derives it (test_IdentityKeyZero_TheDoorAgreesWithDiscovery).
//
//  Part 2 pins `deriveAddress` itself, mode by mode, against the factory's own answer: in the
//  asking modes the factory's reply, in the CREATE2 modes the address the EVM gave the factory's
//  own CREATE2 deployment. The oracle is the EVM and the venue's salt convention spelled here,
//  never `Core.v3Salt` or `Core.create2Address`, so a drifted producer cannot agree with itself.
//
//  Matrix (range x vector x dimension):
//    ranges   : key 0, key with family 0 and slot > 0, top family 0xff, fuzzed keys; fuzzed tokens
//               (both orders), fuzzed fee / tick spacing / stable bit
//    vectors  : honest wrapper, other key's wrapper, pool naming the gate, unadmitted gate, gate
//               code moved, cleared family, foreign token, gate naming a second deployer at key 0;
//               asking factory, CREATE2 factory, Algebra factory with a separate deployer
//    dims     : unit, fuzz (parity and per-mode derivation), mutant (.github/scripts/mutants.py)
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {GateWrapperLiveRef2e4fdaa as Ref} from "./ref/GateWrapperLiveRef2e4fdaa.sol";

/// A wrapper stand-in: constant creation code, so its init hash is a constant; told its gate after birth.
contract IdWrapper {
    address public gate;
    function setGate(address g) external { gate = g; }
}

/// The admission pin, as the Hub answers it (`factoryCodehashOf`).
contract IdHub {
    mapping(address => bytes32) public factoryCodehashOf;
    function admit(address f) external { factoryCodehashOf[f] = f.codehash; }
}

/// A Gate stand-in. Deploys its wrappers under the Uniswap-V3 salt of (t0, t1, key), spelled here.
contract IdGate {
    bytes32 public immutable WRAPPER_INIT_HASH;
    mapping(uint8 => address) public liveAdapter;
    constructor() { WRAPPER_INIT_HASH = keccak256(type(IdWrapper).creationCode); }
    function setAdapter(uint8 f, address a) external { liveAdapter[f] = a; }
    function make(address tA, address tB, uint24 key) external returns (address w) {
        (address t0, address t1) = tA < tB ? (tA, tB) : (tB, tA);
        w = address(new IdWrapper{salt: keccak256(abi.encode(t0, t1, key))}());
        IdWrapper(w).setGate(address(this));
    }
}

/// A second deployer that plants a wrapper under the Algebra salt of (t0, t1) and names a gate.
contract IdSecondDeployer {
    function plant(address t0, address t1, address gate_) external returns (address w) {
        w = address(new IdWrapper{salt: keccak256(abi.encode(t0, t1))}());
        IdWrapper(w).setGate(gate_);
    }
}

/// An admitted gate that also answers `poolDeployer()`, naming the second deployer.
contract IdGateNamingADeployer is IdGate {
    address public poolDeployer;
    constructor(address d) { poolDeployer = d; }
}

/// A pool that only names the gate.
contract IdLiar {
    address public gate;
    constructor(address g) { gate = g; }
}

/// The deployed venue: empty, so its creation code (and init hash) is a constant.
contract IdPool {}

/// An asking factory (modes 0-3): answers what it was told, under the venue's own signatures.
contract IdAskFactory {
    address public answer;
    constructor(address a) { answer = a; }
    function getPair(address, address) external view returns (address) { return answer; }
    function getPool(address, address, uint24) external view returns (address) { return answer; }
    function getPool(address, address, bool) external view returns (address) { return answer; }
    function getPool(address, address, int24) external view returns (address) { return answer; }
}

/// A CREATE2 factory (modes 4-7): each venue's salt convention, spelled from the venue, not the Core.
contract IdCreate2Factory {
    function v2(address t0, address t1) external returns (address) {
        return address(new IdPool{salt: keccak256(abi.encodePacked(t0, t1))}());
    }
    function v3(address t0, address t1, uint24 fee) external returns (address) {
        return address(new IdPool{salt: keccak256(abi.encode(t0, t1, fee))}());
    }
    function solidly(address t0, address t1, bool stable) external returns (address) {
        return address(new IdPool{salt: keccak256(abi.encodePacked(t0, t1, stable))}());
    }
    function cl(address t0, address t1, int24 spacing) external returns (address) {
        return address(new IdPool{salt: keccak256(abi.encode(t0, t1, spacing))}());
    }
}

/// Algebra: the factory names a separate deployer, which deploys under keccak(abi.encode(t0, t1)).
contract IdAlgebraDeployer {
    function deploy(address t0, address t1) external returns (address) {
        return address(new IdPool{salt: keccak256(abi.encode(t0, t1))}());
    }
}

contract IdAlgebraFactory {
    address public immutable poolDeployer;
    constructor(address d) { poolDeployer = d; }
}

contract IdentityIsOneDerivationTest is Test {
    IdHub internal hub;
    IdGate internal gate;
    address internal constant TA = address(0xA11CE);
    address internal constant TB = address(0xB0B);
    address internal constant TC = address(0xCAFE);
    address internal constant ADAPTER = address(0xADA);
    uint24 internal constant KEY = (3 << 16) | 7; // family 3, slot 7
    bytes32 internal poolInit;

    function setUp() public {
        hub = new IdHub();
        gate = new IdGate();
        hub.admit(address(gate));
        gate.setAdapter(3, ADAPTER);
        poolInit = keccak256(type(IdPool).creationCode);
    }

    function _both(address pool, address a, address b, uint24 fee) internal view returns (bool oldV, bool newV) {
        oldV = Ref.gateWrapperLive(address(hub), pool, a, b, fee);
        newV = BPC.gateWrapperLive(address(hub), pool, a, b, fee);
    }

    function _same(address pool, address a, address b, uint24 fee, bool expected, string memory why) internal view {
        (bool oldV, bool newV) = _both(pool, a, b, fee);
        assertEq(oldV, expected, string.concat("frozen identity: ", why));
        assertEq(newV, oldV, string.concat("parity with the frozen identity: ", why));
    }

    // ─── Part 1: the rewritten identity is the frozen one ──────────────────────

    /// NOT VACUOUS: both identities accept the honest wrapper, in both token orders.
    function test_IdentityParity_HonestWrapperIsAcceptedByBoth() public {
        address w = gate.make(TA, TB, KEY);
        _same(w, TA, TB, KEY, true, "honest wrapper");
        _same(w, TB, TA, KEY, true, "honest wrapper, tokens reversed");
    }

    function test_IdentityParity_EveryRefusalIsShared() public {
        address w = gate.make(TA, TB, KEY);
        address other = gate.make(TA, TB, KEY + 1);
        _same(w, TA, TB, KEY + 1, false, "a wrapper offered under another key");
        _same(other, TA, TB, KEY, false, "another key's wrapper offered under this key");
        _same(w, TA, TC, KEY, false, "the other token");
        _same(address(new IdLiar(address(gate))), TA, TB, KEY, false, "a pool that only names the gate");
        _same(address(0xDEAD), TA, TB, KEY, false, "an address with no code");

        IdGate stranger = new IdGate();
        stranger.setAdapter(3, ADAPTER);
        _same(stranger.make(TA, TB, KEY), TA, TB, KEY, false, "an unadmitted gate's wrapper");

        gate.setAdapter(3, address(0));
        _same(w, TA, TB, KEY, false, "a cleared family");
        gate.setAdapter(3, ADAPTER);

        // Another runtime at the gate's address (same storage, same init hash): only the pin moves.
        vm.etch(address(gate), address(new IdGateNamingADeployer(address(0))).code);
        assertTrue(address(gate).codehash != hub.factoryCodehashOf(address(gate)), "precondition: code moved");
        _same(w, TA, TB, KEY, false, "the gate's code moved since admission");
    }

    /// Family 0 with a non-zero slot and the top family are keys like any other: same verdict.
    function test_IdentityParity_FamilyEdgesAreKeysLikeAnyOther() public {
        gate.setAdapter(0, ADAPTER);
        gate.setAdapter(0xff, ADAPTER);
        uint24 low = 1;                        // family 0, slot 1
        uint24 top = uint24(0xff << 16) | 0xffff;
        _same(gate.make(TA, TB, low), TA, TB, low, true, "family 0, slot 1");
        _same(gate.make(TA, TB, top), TA, TB, top, true, "family 0xff, top slot");
    }

    /// THE KEY-0 VECTOR. Key 0 is the Hub's Algebra sentinel (Gate.create refuses it). An admitted
    /// gate that answers `poolDeployer()` with a second deployer, which planted a wrapper naming the
    /// gate under the Algebra salt, with family 0 live: the frozen identity derives from the gate
    /// and refuses it; a rewrite that let `deriveAddress` pick the origin would accept it.
    function test_IdentityParity_KeyZeroNeverTakesAnOriginFromTheGate() public {
        IdSecondDeployer second = new IdSecondDeployer();
        IdGateNamingADeployer g = new IdGateNamingADeployer(address(second));
        hub.admit(address(g));
        g.setAdapter(0, ADAPTER);
        (address t0, address t1) = TA < TB ? (TA, TB) : (TB, TA);
        address planted = second.plant(t0, t1, address(g));
        // Preconditions: everything but the origin rule would let the planted wrapper through.
        assertEq(IdWrapper(planted).gate(), address(g), "precondition: it names the gate");
        assertEq(hub.factoryCodehashOf(address(g)), address(g).codehash, "precondition: the gate is admitted");
        assertEq(planted.codehash, keccak256(type(IdWrapper).runtimeCode), "precondition: wrapper code");
        assertTrue(g.liveAdapter(0) != address(0), "precondition: family 0 is live");
        _same(planted, TA, TB, 0, false, "key 0: a wrapper the gate did not deploy");
    }

    function testFuzz_IdentityParity(uint8 vector, uint24 key, bool flip, address foreign) public {
        vm.assume(foreign != TA && foreign != TB);
        uint8 fam = uint8(key >> 16);
        gate.setAdapter(fam, ADAPTER);
        address a = flip ? TB : TA;
        address b = flip ? TA : TB;
        address pool;
        uint24 asked = key;
        uint256 v = vector % 6;
        if (v == 0) {
            pool = gate.make(TA, TB, key);
        } else if (v == 1) {
            pool = gate.make(TA, TB, key);
            asked = key ^ 1;
        } else if (v == 2) {
            pool = gate.make(TA, TB, key);
            b = foreign;
        } else if (v == 3) {
            pool = address(new IdLiar(address(gate)));
        } else if (v == 4) {
            pool = gate.make(TA, TB, key);
            gate.setAdapter(fam, address(0));
        } else {
            IdSecondDeployer second = new IdSecondDeployer();
            IdGateNamingADeployer g = new IdGateNamingADeployer(address(second));
            hub.admit(address(g));
            g.setAdapter(fam, ADAPTER);
            (address t0, address t1) = TA < TB ? (TA, TB) : (TB, TA);
            pool = second.plant(t0, t1, address(g));
        }
        // Key 0 on an honest wrapper is the one documented change (test_IdentityKeyZero_*).
        vm.assume(!(v == 0 && key == 0));
        (bool oldV, bool newV) = _both(pool, a, b, asked);
        assertEq(newV, oldV, "the rewritten identity answers as the frozen one");
    }

    /// THE ONE BEHAVIOUR CHANGE. A gate that deployed a wrapper at key 0 passed the frozen identity,
    /// yet the Hub's discovery never found that wrapper: mode 5 with fee 0 is the Algebra derive.
    /// The real Gate refuses key 0 at create (Gate.sol:214), so no live wrapper is affected. The
    /// rewritten identity refuses key 0: the door admits what discovery derives, nothing else.
    function test_IdentityKeyZero_TheDoorAgreesWithDiscovery() public {
        gate.setAdapter(0, ADAPTER);
        address w = gate.make(TA, TB, 0);
        (bool oldV, bool newV) = _both(w, TA, TB, 0);
        assertTrue(oldV, "the frozen identity accepted a key-0 wrapper");
        assertFalse(newV, "the rewritten identity refuses key 0");
        assertTrue(BPC.deriveAddress(address(gate), TA, TB, 0, false, 0, 5, gate.WRAPPER_INIT_HASH()) != w,
            "discovery's derive for key 0 is not the key-0 wrapper");
    }

    // ─── Part 2: deriveAddress, mode by mode, against the factory's own answer ──

    function _pair(address a, address b) internal pure returns (address t0, address t1) {
        vm.assume(a != address(0) && b != address(0) && a != b);
        (t0, t1) = a < b ? (a, b) : (b, a);
    }

    function testFuzz_IdentityDerive_AskingModesReturnTheFactorysAnswer(
        address a, address b, uint24 fee, bool stable, int24 sp, address answer
    ) public {
        _pair(a, b);
        address f = address(new IdAskFactory(answer));
        for (uint8 mode; mode < 4; ++mode) {
            assertEq(BPC.deriveAddress(f, a, b, fee, stable, sp, mode, bytes32(0)), answer,
                "an asking mode returns the factory's reply under the venue's own signature");
        }
    }

    function testFuzz_IdentityDerive_Mode4IsWhereTheFactoryDeployed(address a, address b) public {
        (address t0, address t1) = _pair(a, b);
        IdCreate2Factory f = new IdCreate2Factory();
        address deployed = f.v2(t0, t1);
        assertEq(BPC.deriveAddress(address(f), b, a, 0, false, 0, 4, poolInit), deployed, "mode 4 (V2 packed salt)");
    }

    function testFuzz_IdentityDerive_Mode5IsWhereTheFactoryDeployed(address a, address b, uint24 fee) public {
        vm.assume(fee != 0);
        (address t0, address t1) = _pair(a, b);
        IdCreate2Factory f = new IdCreate2Factory();
        address deployed = f.v3(t0, t1, fee);
        assertEq(BPC.deriveAddress(address(f), b, a, fee, false, 0, 5, poolInit), deployed, "mode 5 (V3 salt)");
    }

    function testFuzz_IdentityDerive_AlgebraIsWhereTheNamedDeployerDeployed(address a, address b) public {
        (address t0, address t1) = _pair(a, b);
        IdAlgebraDeployer d = new IdAlgebraDeployer();
        IdAlgebraFactory f = new IdAlgebraFactory(address(d));
        address deployed = d.deploy(t0, t1);
        assertEq(BPC.deriveAddress(address(f), b, a, 0, false, 0, 5, poolInit), deployed,
            "mode 5, fee 0 (Algebra salt, the named deployer as origin)");
    }

    function testFuzz_IdentityDerive_Mode6IsWhereTheFactoryDeployed(address a, address b, bool stable) public {
        (address t0, address t1) = _pair(a, b);
        IdCreate2Factory f = new IdCreate2Factory();
        address deployed = f.solidly(t0, t1, stable);
        assertEq(BPC.deriveAddress(address(f), b, a, 0, stable, 0, 6, poolInit), deployed, "mode 6 (Solidly salt)");
    }

    function testFuzz_IdentityDerive_Mode7IsWhereTheFactoryDeployed(address a, address b, int24 sp) public {
        (address t0, address t1) = _pair(a, b);
        IdCreate2Factory f = new IdCreate2Factory();
        address deployed = f.cl(t0, t1, sp);
        assertEq(BPC.deriveAddress(address(f), b, a, 0, false, sp, 7, poolInit), deployed, "mode 7 (CL spacing salt)");
    }
}
