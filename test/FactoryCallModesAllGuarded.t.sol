// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The four factory-call modes (0-3): each derives, each is codehash-pinned,
//  and each runs the pair proof.
//
//  `MODES_VALID` admits modes 0-7 and 9. Modes 0-3 are the factory-answers
//  family (0 getPair, 1 getPool uint24, 2 getPool bool, 3 getPool int24), all
//  implemented in `Core._factoryLookup`. Three guards in discovery draw the
//  family's boundary with the literal 4:
//
//      if (fac.mode < 4 && fac.factory.codehash != pinned) return k;      // pin
//      if (fac.mode >= 4 && fac.initHash == bytes32(0)) return k;         // CREATE2 needs a hash
//      if (fac.mode < 4 && (token0Of(p) != t0 || token1Of(p) != t1)) return k;  // pair proof
//
//  This file registers a row in EVERY factory-call mode, including 3 - the
//  mode that sits right under the boundary - and asserts the outcome each
//  guard protects: the honest pool is discovered, a factory whose runtime
//  changed stops steering discovery, and an answered pool that does not prove
//  its own pair is never listed. Mode 2 is a production dialect (Velodrome V1
//  on Optimism). This measures coverage of the modes, not their use.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

/// @dev A factory whose ANSWER lives in storage: its runtime never changes, so
///      the codehash pin holds. Implements the four factory-call selectors.
contract SettableModeFactory {
    address public answer;
    function setAnswer(address a) external { answer = a; }
    function getPair(address, address) external view returns (address) { return answer; }
    function getPool(address, address, uint24) external view returns (address) { return answer; }
    function getPool(address, address, bool) external view returns (address) { return answer; }
    function getPool(address, address, int24) external view returns (address) { return answer; }
}

/// @dev A DIFFERENT runtime (the answer is immutable, so it lives in the code):
///      etching it moves the codehash.
contract FixedAnswerLogic {
    address internal immutable answer;
    constructor(address a) { answer = a; }
    function getPair(address, address) external view returns (address) { return answer; }
    function getPool(address, address, uint24) external view returns (address) { return answer; }
    function getPool(address, address, bool) external view returns (address) { return answer; }
    function getPool(address, address, int24) external view returns (address) { return answer; }
}

/// @dev A pair whose declared tokens are set by hand: what the pair proof reads.
contract DeclaredPairStub {
    address public token0;
    address public token1;
    constructor(address t0, address t1) { token0 = t0; token1 = t1; }
}

contract FactoryCallModesAllGuardedTest is Test {
    BlazePhoenixHub internal hub;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint8 internal constant MODE_CL_ASK = 3; // getPool(address,address,int24)

    SettableModeFactory[4] internal fac;
    address[4] internal honestPool;
    address internal foreignPool;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        (address t0, address t1) = BPC.sortTokens(address(tokenA), address(tokenB));

        // One honest pool per mode, of the kind the mode serves in production.
        honestPool[0] = address(new MockV2Pair(t0, t1));
        honestPool[1] = address(new MockV3Pool(t0, t1, 3_000));
        honestPool[2] = address(new MockSolidlyPair(t0, t1, false));
        honestPool[3] = address(new MockV3Pool(t0, t1, 100));

        for (uint256 m; m < 4; ++m) {
            fac[m] = new SettableModeFactory();
            fac[m].setAnswer(honestPool[m]);
            hub.addFactory(
                address(fac[m]), _kindOf(uint8(m)), uint8(m), bytes32(0),
                new uint24[](0), new int24[](0)
            );
        }
        // A real pool, on the real pair, that nobody admitted.
        foreignPool = address(new MockV2Pair(t0, t1));
    }

    function _kindOf(uint8 mode) internal pure returns (uint8) {
        if (mode == 0) return BPC.KIND_V2;
        if (mode == 2) return BPC.KIND_SOLIDLY;
        return BPC.KIND_V3;
    }

    function _discovered() internal view returns (address[] memory found) {
        PoolInfo[] memory hits = hub.discoverFor(address(tokenA), address(tokenB));
        found = new address[](hits.length);
        for (uint256 i; i < hits.length; ++i) found[i] = hits[i].pool;
    }

    function _has(address[] memory set, address x) internal pure returns (bool) {
        for (uint256 i; i < set.length; ++i) if (set[i] == x) return true;
        return false;
    }

    /// @notice Every factory-call mode derives its honest pool.
    function test_AllFourFactoryCallModesDerive() public view {
        address[] memory found = _discovered();
        for (uint256 m; m < 4; ++m) {
            assertTrue(_has(found, honestPool[m]),
                "a row admitted under a factory-call mode must derive");
        }
    }

    /// @notice After renunciation, a factory whose runtime is replaced at the
    ///         same address stops steering discovery - in every factory-call mode.
    function test_CodehashPinAppliesToEveryFactoryCallMode() public {
        hub.renounceControl();

        bytes memory hostile = address(new FixedAnswerLogic(foreignPool)).code;
        for (uint256 m; m < 4; ++m) {
            bytes32 before_ = address(fac[m]).codehash;
            vm.etch(address(fac[m]), hostile);
            assertTrue(address(fac[m]).codehash != before_, "precondition: the runtime changed");
        }

        assertFalse(_has(_discovered(), foreignPool),
            "a factory whose runtime changed must not steer discovery, in any factory-call mode");
    }

    /// @notice Mode 3 answers a pool that matches the pair on one side only:
    ///         the pair proof refuses it.
    function test_PairProofAppliesToTheHighestFactoryCallMode() public {
        (address t0, address t1) = BPC.sortTokens(address(tokenA), address(tokenB));
        MockERC20 tokenC = new MockERC20("C", "C");

        DeclaredPairStub wrong = new DeclaredPairStub(t0, address(tokenC));
        assertEq(wrong.token0(), t0, "precondition: one side matches");
        assertTrue(wrong.token1() != t1, "precondition: the other side does not");

        SettableModeFactory f = new SettableModeFactory();
        f.setAnswer(address(wrong));
        hub.addFactory(address(f), BPC.KIND_V3, MODE_CL_ASK, bytes32(0), new uint24[](0), new int24[](0));

        assertFalse(_has(_discovered(), address(wrong)),
            "an answered pool that does not prove its own pair must never be listed");
    }
}
