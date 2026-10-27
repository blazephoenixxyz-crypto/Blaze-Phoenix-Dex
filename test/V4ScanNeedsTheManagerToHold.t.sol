// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A V4 POOL CAN ONLY PAY WHAT THE MANAGER HOLDS (P1).
//
//  Every V4 pool keeps its tokens in the one PoolManager. If the manager holds none
//  of a token, no V4 pool on it can pay that token out, and probing the pair's tiers
//  is cold reads for nothing. `_scanV4` now reads the manager's balance of each side
//  before its first probe and stops on a measured zero (`Hub._pmHoldsNone`).
//
//  It fails OPEN. A bridge token is never asked, and neither is the WETH side (its
//  custody is split between WETH and native ETH). A manager inside an unlock is
//  scanned: balances move inside the callback. A read that reverts, runs past
//  GAS_CAP or answers under one word is not a measurement. A donation can only turn
//  the scan back on.
//
//  RED on 59ecf3f: test_ATokenTheManagerHoldsNoneOf_IsNotProbed (the old scan asked
//  the canonical tiers and listed the pool). The others are green on both trees and
//  pin the fail-open arms.
//
//  forge test --match-path test/V4ScanNeedsTheManagerToHold.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4ScanManager} from "./mocks/MockV4ScanManager.sol";

/// @dev A token whose balanceOf is not a measurement: 1 reverts, 2 answers 31 bytes,
///      3 burns about 150k gas (past GAS_CAP = 100k) before answering zero, 4 reverts
///      with one word of zeros (a revert that reads like a zero balance).
contract OddBalanceToken {
    uint8 public mode;
    constructor(uint8 m) { mode = m; }
    function balanceOf(address) external view returns (uint256) {
        if (mode == 1) revert("no");
        if (mode == 2) assembly { mstore(0, 0) return(0, 31) }
        if (mode == 4) assembly { mstore(0, 0) revert(0, 32) }
        bytes32 h;
        for (uint256 i; i < 2000; ++i) h = keccak256(abi.encode(h, i));
        return uint256(h) & 0;
    }
}

contract V4ScanNeedsTheManagerToHoldTest is Test {
    BlazePhoenixHub hub;
    MockV4ScanManager mgr;
    MockERC20 bridge;
    MockERC20 tail;

    uint8 constant MODE_V4_DERIVE = 9;
    /// The manager sits where its address's 16th byte is zero. `_pmHoldsNone` writes the
    /// balanceOf call over the scratch word (the selector at 0x00, the manager's word from
    /// 0x04), so until the answer overwrites it the word's last byte is that 16th byte. A token
    /// that answers 31 zero bytes leaves it there: only with it zero does a short answer read as
    /// a full zero, which is what lets the under-one-word arm be seen at all (mutant [872]).
    address constant MGR = address(uint160(0xB0B0) << 144 | 0xBEEF);
    bytes4 constant EXTSLOAD_BATCH = 0xdbd035ff; // extsload(bytes32[])
    uint24 constant FEE = 3000;                  // a canonical tier
    int24  constant TS  = 60;

    address wethToken;
    function weth() external view returns (address) { return wethToken; }

    function setUp() public {
        vm.etch(MGR, address(new MockV4ScanManager()).code);
        mgr = MockV4ScanManager(MGR);
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        bridge = new MockERC20("B", "B");
        tail = new MockERC20("T", "T");
        hub.addBridge(address(bridge));
        uint24[] memory noFees = new uint24[](0);
        int24[]  memory noSps  = new int24[](0);
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), noFees, noSps);
        // Router role unset: weth() is address(0) and the native pass does not run.
    }

    function _plant(address a, address b) private returns (address) {
        (address s0, address s1) = BPC.sortTokens(a, b);
        bytes32 pid = BPC.computeV4PoolId(s0, s1, FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(1e24)));
        return address(uint160(uint256(pid)));
    }

    function _contains(PoolInfo[] memory hits, address pool) private pure returns (bool) {
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == pool) return true;
        return false;
    }

    function _scan(address a, address b) private returns (PoolInfo[] memory hits, uint256 cells) {
        vm.startStateDiffRecording();
        hits = hub.discoverFor(a, b);
        VmSafe.AccountAccess[] memory r = vm.stopAndReturnStateDiff();
        for (uint256 i; i < r.length; ++i) {
            if (r[i].kind != VmSafe.AccountAccessKind.StaticCall || r[i].account != address(mgr)) continue;
            bytes memory d = r[i].data;
            if (d.length < 68 || bytes4(d) != EXTSLOAD_BATCH) continue;
            uint256 len;
            assembly { len := mload(add(d, 68)) }
            cells += len;
        }
    }

    // --- RED: a measured zero stops the scan before its first cold probe ---

    function test_ATokenTheManagerHoldsNoneOf_IsNotProbed() public {
        // One tail on each side of the sorted pair: the gate has an arm per side.
        address[2] memory tails = [address(uint160(address(bridge)) - 1), address(uint160(address(bridge)) + 1)];
        for (uint256 i; i < 2; ++i) {
            vm.etch(tails[i], address(tail).code);
            address pool = _plant(address(bridge), tails[i]);
            uint256 g = gasleft();
            (PoolInfo[] memory hits, uint256 cells) = _scan(address(bridge), tails[i]);
            emit log_named_uint("discoverFor gas, tail held by no one", g - gasleft());
            assertEq(cells, 0, "a pair whose tail the manager holds none of was probed");
            assertFalse(_contains(hits, pool), "a pool that cannot pay the tail out was listed");
        }
    }

    // --- GREEN: what turns it back on, and what is never asked ------------

    function test_OneWeiDonation_TurnsTheScanBackOn() public {
        address pool = _plant(address(bridge), address(tail));
        tail.mint(address(mgr), 1);
        (PoolInfo[] memory hits, uint256 cells) = _scan(address(bridge), address(tail));
        assertEq(cells, 4, "a held tail is scanned: the four canonical tiers");
        assertTrue(_contains(hits, pool), "the pool is listed once the manager holds the tail");
    }

    function test_AnUnlockedManager_IsScanned() public {
        address pool = _plant(address(bridge), address(tail));
        mgr.setUnlocked(bytes32(uint256(1)));
        (PoolInfo[] memory hits, ) = _scan(address(bridge), address(tail));
        assertTrue(_contains(hits, pool), "inside an unlock a zero balance is not a measurement");
    }

    function test_AFailedBalanceRead_IsNotAZero() public {
        assertEq(uint8(uint160(address(mgr)) >> 32), 0, "setup: the scratch word's last byte is zero");
        for (uint8 m = 1; m <= 4; ++m) {
            OddBalanceToken odd = new OddBalanceToken(m);
            address pool = _plant(address(bridge), address(odd));
            (PoolInfo[] memory hits, ) = _scan(address(bridge), address(odd));
            assertTrue(_contains(hits, pool), "a balance read that failed was taken for a zero");
        }
    }

    function test_ABridge_IsNeverAsked() public {
        tail.mint(address(mgr), 1e18);                // the tail is held, the bridge is not
        address pool = _plant(address(bridge), address(tail));
        (PoolInfo[] memory hits, ) = _scan(address(bridge), address(tail));
        assertTrue(_contains(hits, pool), "a bridge side was gated on the manager's balance");
    }

    function test_TheWethSide_IsNeverAsked() public {
        MockERC20 w = new MockERC20("W", "W");        // the manager holds no WETH
        wethToken = address(w);
        hub.setRoles(address(this), address(this), address(this));
        tail.mint(address(mgr), 1e18);
        address pool = _plant(address(w), address(tail));
        (PoolInfo[] memory hits, ) = _scan(address(w), address(tail));
        assertTrue(_contains(hits, pool), "the WETH side was gated on the manager's WETH balance");
    }
}
