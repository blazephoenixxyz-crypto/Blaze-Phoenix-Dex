// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Every candidate discovery returns has code.
//
//  Inside `Hub._probeRow`:
//
//      if (p != address(0) && BPC.hasCode(p)) {
//          if (fac.mode < 4 && (BPC.token0Of(p) != t0 || BPC.token1Of(p) != t1)) return k;
//          ... hits[k] = PoolInfo({... pool: p ...}); ++k;
//      }
//
//  For the CREATE2 modes (4-7, 9) the pair proof does not run, so `hasCode` is
//  the only check between a derived address and the candidate list. An address
//  derived from an init-code hash that matches nothing deployed has no code -
//  the ordinary state of a row whose hash is not live. The property pinned here
//  is the set-level one: the list discovery returns is a list of contracts.
//  Mode 4 stands for the CREATE2 family, which shares this line; a mode-0 row
//  serving a real pair keeps the list non-empty.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// @dev A factory that always answers the same pair (mode 0, `getPair`).
contract AnsweringPairFactory {
    address internal immutable answer;
    constructor(address a) { answer = a; }
    function getPair(address, address) external view returns (address) { return answer; }
}

contract DiscoveryListsOnlyContractsTest is Test {
    BlazePhoenixHub internal hub;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockV2Pair internal honestPool;

    uint8 internal constant MODE_ASK        = 0;
    uint8 internal constant MODE_CREATE2_V2 = 4;

    /// @dev An init-code hash that matches nothing deployed.
    bytes32 internal constant INIT_NEVER_DEPLOYED =
        0x1111111111111111111111111111111111111111111111111111111111111111;

    address internal nonContractFactory = address(0xFAC7);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        (address t0, address t1) = BPC.sortTokens(address(tokenA), address(tokenB));

        honestPool = new MockV2Pair(t0, t1);
        AnsweringPairFactory f = new AnsweringPairFactory(address(honestPool));
        hub.addFactory(address(f), BPC.KIND_V2, MODE_ASK, bytes32(0), new uint24[](0), new int24[](0));
        hub.addFactory(
            nonContractFactory, BPC.KIND_V2, MODE_CREATE2_V2, INIT_NEVER_DEPLOYED,
            new uint24[](0), new int24[](0)
        );
    }

    function _discovered() internal view returns (PoolInfo[] memory) {
        return hub.discoverFor(address(tokenA), address(tokenB));
    }

    function _has(PoolInfo[] memory hits, address x) internal pure returns (bool) {
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == x) return true;
        return false;
    }

    /// @dev The address the mode-4 row derives: salt = keccak256(t0, t1),
    ///      origin = the factory itself.
    function _derivedAddress() internal view returns (address) {
        (address t0, address t1) = BPC.sortTokens(address(tokenA), address(tokenB));
        return BPC.create2Address(
            nonContractFactory, keccak256(abi.encodePacked(t0, t1)), INIT_NEVER_DEPLOYED
        );
    }

    /// @notice Apparatus: the derived address is real and has no code.
    function test_Apparatus_TheDerivedAddressIsRealAndCodeless() public view {
        address p = _derivedAddress();
        assertTrue(p != address(0), "precondition: the derivation is a real address");
        assertEq(p.code.length, 0, "precondition: nothing was deployed there");
    }

    /// @notice Control: the mode-0 row keeps serving the real pool.
    function test_Control_TheHonestPoolIsListed() public view {
        assertTrue(_has(_discovered(), address(honestPool)),
            "the asked mode must keep serving a real pool");
    }

    /// @notice The property: every listed candidate has code.
    function test_EveryListedCandidateHasCode() public view {
        PoolInfo[] memory hits = _discovered();
        assertGt(hits.length, 0, "non-vacuous: the honest row must be listed");
        for (uint256 i; i < hits.length; ++i) {
            assertGt(hits[i].pool.code.length, 0, "discovery must never list an address with no code");
        }
    }

    /// @notice The direct form: the codeless derived address is not listed.
    function test_TheCodelessDerivedAddressIsNotListed() public view {
        assertFalse(_has(_discovered(), _derivedAddress()),
            "a derived address with no code is not a candidate");
    }
}
