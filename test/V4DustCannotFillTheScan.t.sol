// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  V4 DUST CANNOT FILL THE SCAN (3317), AND A MISS ASKS ONLY THE TABLE.
//
//  `_scanV4` stopped at V4_CAP = 8 emitted pools. The native pass and the wrapped
//  canonical tiers are probed before the wrapped extras, so eight live dust pools
//  (liquidity 1: anyone can initialize one) at those cells used up every slot, and a
//  deep pool at a wrapped extra was never built: discovery did not list it and the
//  Solver never quoted it. The scan is now bounded by its table (the native and the
//  wrapped pass, four canonical tiers and the row's extras each, plus two learned
//  codes: the bound `discoverFor` reserves), not by a count. The deep pool is listed
//  next to the dust, and the Solver's funnel weighs the dust against the pair's depth.
//
//  A miss used to end in the cold-start grid: 40 generator tiers (fee 10_000 * j,
//  spacing 100 * j) probed whenever the pair's own tiers found nothing. It is gone:
//  a miss asks the four canonical tiers and the row's extras.
//
//  RED on 59ecf3f: test_DustAtTheEarlyCells_CannotHideADeepPool (the deep pool is not
//  listed) and test_AMiss_AsksOnlyTheTable (45 cells asked, not 5). The second pins a
//  removal; it is a regression guard, not the reproduction of a defect.
//
//  forge test --match-path test/V4DustCannotFillTheScan.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4ScanManager} from "./mocks/MockV4ScanManager.sol";

contract V4DustCannotFillTheScanTest is Test {
    BlazePhoenixHub hub;
    MockV4ScanManager mgr;
    MockERC20 x;
    MockERC20 y;

    address constant WETH = address(0xEEE0);
    uint8 constant MODE_V4_DERIVE = 9;
    bytes4 constant EXTSLOAD_BATCH = 0xdbd035ff; // extsload(bytes32[])

    // The row's one extra tier: probed after the four canonical tiers of each pass.
    uint24 constant EXTRA_FEE = 2500;
    int24  constant EXTRA_TS  = 50;

    uint128 constant DUST = 1;
    uint128 constant DEEP = 1e24;

    /// @dev The Hub's router role is this contract; the native pass asks it for WETH.
    function weth() external pure returns (address) { return WETH; }

    function setUp() public {
        mgr = new MockV4ScanManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        hub.setRoles(address(this), address(this), address(this));
        x = new MockERC20("X", "X");
        y = new MockERC20("Y", "Y");
        // The manager holds both tokens, so the solvency gate lets the scan run.
        x.mint(address(mgr), 1e18);
        y.mint(address(mgr), 1e18);
        uint24[] memory fees = new uint24[](1);
        int24[]  memory sps  = new int24[](1);
        fees[0] = EXTRA_FEE;
        sps[0]  = EXTRA_TS;
        hub.addFactory(address(0xFAC7), BPC.KIND_V4, MODE_V4_DERIVE, bytes32(0), fees, sps);
    }

    // --- helpers -----------------------------------------------------------

    /// Plant a live hookless pool, StateLibrary layout: slot0 at keccak(abi.encode(pid, 6))
    /// with sqrtPriceX96 = Q96 and both fees 0, liquidity at +3.
    function _plantAt(bytes32 pid, uint128 liq) private returns (address) {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(liq)));
        return address(uint160(uint256(pid)));
    }

    function _native(uint24 fee, int24 ts, uint128 liq) private returns (address) {
        return _plantAt(BPC.computeV4PoolId(address(0), address(x), fee, ts, address(0)), liq);
    }

    function _wrapped(address a, address b, uint24 fee, int24 ts, uint128 liq) private returns (address) {
        (address s0, address s1) = BPC.sortTokens(a, b);
        return _plantAt(BPC.computeV4PoolId(s0, s1, fee, ts, address(0)), liq);
    }

    function _contains(PoolInfo[] memory hits, address pool) private pure returns (bool) {
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == pool) return true;
        return false;
    }

    /// One scan, with the cells it asked the manager through the batched extsload.
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

    // --- 3317: a count let dust decide what was built ----------------------

    function test_DustAtTheEarlyCells_CannotHideADeepPool() public {
        uint24[4] memory f = [uint24(500), 3000, 10_000, 100];
        int24[4]  memory s = [int24(10), 60, 200, 1];
        for (uint256 i; i < 4; ++i) {
            _native(f[i], s[i], DUST);                    // native pass, canonical tiers
            _wrapped(WETH, address(x), f[i], s[i], DUST); // wrapped pass, canonical tiers
        }
        address deep = _wrapped(WETH, address(x), EXTRA_FEE, EXTRA_TS, DEEP); // probed last

        (PoolInfo[] memory hits, ) = _scan(WETH, address(x));
        assertTrue(_contains(hits, deep), "eight dust pools at the early cells hid the deep pool");
        assertEq(hits.length, 9, "every live pool of the table is listed, the dust included");
    }

    // --- the grid is gone: a miss asks the table and nothing else ----------

    function test_AMiss_AsksOnlyTheTable() public {
        (PoolInfo[] memory hits, uint256 cells) = _scan(address(x), address(y));
        assertEq(hits.length, 0, "nothing is planted");
        assertEq(cells, 5, "a miss asks the four canonical tiers and the row's one extra");
    }
}
