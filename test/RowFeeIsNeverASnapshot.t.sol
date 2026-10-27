// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

// aero-nova (2026-10-26), fix e. A concentrated row's fee is a STATIC KEY: `quoteV3Fee` returns a
// nonzero row fee without asking the pool. Both registration doors wrote the pool's own fee()
// answer there, and the 2026 Aerodrome CL fee() moves every block: a row born at one block's
// answer priced every later quote at it. The row's fee is now the fee its derivation is keyed by
// (the factory tier the pool was found under), when the pool agrees, else 0, the live read.
// Since DEX-17 (2026-10-27) quoteV3Fee asks fee() of a non-Algebra pool first and the row's key
// answers only when fee() does not: this file now guards that fallback key, not every quote.

/// A V3 pool whose fee moves, as a dynamic-fee pool's does.
contract SettableFeeV3Pool is MockV3Pool {
    constructor(address a, address b, uint24 f) MockV3Pool(a, b, f) {}

    function setFee(uint24 f) external { fee = f; }
}

/// A CL factory that answers by tick spacing (mode 3, getPool(address,address,int24)): its key is
/// the spacing, so none of its hits carries a fee identity.
contract SpacingAskFactory {
    address public token0;
    address public token1;
    address public pool;

    function list(address p, address a, address b) external {
        (token0, token1) = a < b ? (a, b) : (b, a);
        pool = p;
    }

    function getPool(address a, address b, int24) external view returns (address) {
        return (a == token0 && b == token1) || (a == token1 && b == token0) ? pool : address(0);
    }
}

contract RowFeeIsNeverASnapshotTest is Test {
    uint8 internal constant MODE_CL_ASK = 3;

    BlazePhoenixHub internal hub;
    MockERC20 internal tA;
    MockERC20 internal tB;
    address internal t0;
    address internal t1;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        // This contract is the Router and the operator: the two registration doors.
        hub.setRoles(address(this), address(this), address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        (t0, t1) = BPC.sortTokens(address(tA), address(tB));
    }

    function _pool(uint24 fee) internal returns (SettableFeeV3Pool p) {
        p = new SettableFeeV3Pool(address(tA), address(tB), fee);
        p.setState(uint160(1 << 96), 1e21);
    }

    function _spacingOrigin(address p) internal {
        SpacingAskFactory f = new SpacingAskFactory();
        f.list(p, address(tA), address(tB));
        int24[] memory sps = new int24[](1);
        sps[0] = 100;
        hub.addFactory(address(f), BPC.KIND_V3, MODE_CL_ASK, bytes32(0), new uint24[](0), sps);
    }

    function _swapDoor(address p, uint24 declared) internal {
        hub.recordSwap(p, BPC.KIND_V3, declared, address(0), address(tA), address(tB), 1e18, 1e18, 1e18);
    }

    function _slot(address p) internal view returns (uint256) {
        return hub.getSlot(hub.keyOf(p, t0, t1));
    }

    /// The Aerodrome shape: a pool found by spacing. The swap door wrote the block's fee as the
    /// key; it now writes 0, and the quote follows the pool when its fee moves.
    function test_ASpacingKeyedRowFromASwapReadsTheFeeLive() public {
        SettableFeeV3Pool p = _pool(500);
        _spacingOrigin(address(p));
        _swapDoor(address(p), 500);
        uint256 s = _slot(address(p));
        assertTrue(s != 0, "the swap door seats the pool");
        assertEq(BPC.decodeFee(s), 0, "the row carries no snapshot of fee()");
        p.setFee(3000);
        assertEq(BPC.quoteV3Fee(address(p), BPC.decodeFee(s), 0, false), 3000, "the quote follows the pool");
    }

    /// The operator's door, the same pool shape, the same answer.
    function test_ASpacingKeyedRowFromTheOperatorReadsTheFeeLive() public {
        SettableFeeV3Pool p = _pool(500);
        _spacingOrigin(address(p));
        hub.seedPool(address(p), BPC.KIND_V3, 500, address(0), address(tA), address(tB));
        uint256 s = _slot(address(p));
        assertTrue(s != 0, "the operator seats the pool");
        assertEq(BPC.decodeFee(s), 0, "the row carries no snapshot of fee()");
        p.setFee(3000);
        assertEq(BPC.quoteV3Fee(address(p), BPC.decodeFee(s), 0, false), 3000, "the quote follows the pool");
    }

    /// META-GUARD. A factory tier is not always the pool's fee (a mode that derives by spacing,
    /// wired with tiers, stamps its first tier on every hit): a tier the pool contradicts is not
    /// written.
    function test_ATierThePoolContradictsIsNotWritten() public {
        SettableFeeV3Pool p = _pool(500);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, 3000);
        _swapDoor(address(p), 500);
        uint256 s = _slot(address(p));
        assertTrue(s != 0, "the swap door seats the pool");
        assertEq(BPC.decodeFee(s), 0, "a contradicted tier is not a key");
    }

    /// GUARD, positive side: the tier the pool answers is written as the row's key. The key is
    /// not what a quote charges: since DEX-17 (2026-10-27) quoteV3Fee asks the pool's fee() on
    /// every non-Algebra CL quote, and the key answers only when fee() does not.
    function test_ATierThePoolAnswersIsWritten() public {
        SettableFeeV3Pool p = _pool(3000);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, 3000);
        _swapDoor(address(p), 500);
        assertEq(BPC.decodeFee(_slot(address(p))), 3000, "the derived tier is the key");
    }

    // Outcomes of one door call at a given gas.
    uint8 internal constant OOG = 1;   // reverted having spent all it was given
    uint8 internal constant CHEAP = 2; // reverted handing gas back
    uint8 internal constant SKIP = 3;  // returned without writing a row
    uint8 internal constant WROTE = 4; // wrote a row

    function _at(address p, bytes memory data, uint256 g) internal returns (uint8 outcome, uint24 fee) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        (bool ok,) = address(hub).call{gas: g}(data);
        uint256 used = g0 - gasleft();
        if (!ok) {
            outcome = used >= g ? OOG : CHEAP;
        } else {
            uint256 s = _slot(p);
            outcome = s == 0 ? SKIP : WROTE;
            fee = BPC.decodeFee(s);
        }
        vm.revertToState(snap);
    }

    /// The least gas at which the door writes `fee` (the predicate is monotone in the gas).
    function _least(address p, bytes memory data, uint24 fee) internal returns (uint256 lo) {
        lo = 100_000;
        uint256 hi = 3_000_000;
        (uint8 o, uint24 f) = _at(p, data, hi);
        assertTrue(o == WROTE && f == fee, "harness: the door writes the tier with ample gas");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (o, f) = _at(p, data, mid);
            if (o == WROTE && f == fee) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    /// GUARD of the swap door. The Router swallows `recordSwap`, so a revert there that hands its
    /// gas back makes the cheapest gas limit the one that skips registration (an estimateGas
    /// picks it). Around the read's floor, every gas either writes the tier or writes 0 (the live
    /// read); none reverts cheaply.
    function test_AStarvedSwapDoorWritesTheLiveReadAndNeverRevertsCheaply() public {
        SettableFeeV3Pool p = _pool(3000);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, 3000);
        bytes memory data = abi.encodeCall(
            BlazePhoenixHub.recordSwap,
            (address(p), BPC.KIND_V3, uint24(3000), address(0), address(tA), address(tB), 1e18, 1e18, 1e18)
        );
        _at(address(p), data, 3_000_000); // warm every account the door touches
        uint256 b = _least(address(p), data, 3000);
        bool sawZero;
        for (uint256 g = b - 2_500; g <= b + 500; g += 20) {
            (uint8 o, uint24 f) = _at(address(p), data, g);
            assertTrue(o != CHEAP, "the swap door reverted handing its gas back");
            assertTrue(o == WROTE && (f == 0 || f == 3000), "near the floor the door writes the tier or 0");
            if (f == 0) sawZero = true;
        }
        assertTrue(sawZero, "a starved frame writes 0, the live read");
    }

    /// The operator's door is not swallowed: a frame too short for the read reverts, so the
    /// operator's gas estimate always includes the read and an agreeing V3 row is its tier.
    function test_AStarvedOperatorDoorRevertsInsteadOfWritingZero() public {
        SettableFeeV3Pool p = _pool(3000);
        Origin.wire(hub, address(p), address(tA), address(tB), BPC.KIND_V3, 3000);
        bytes memory data = abi.encodeCall(
            BlazePhoenixHub.seedPool, (address(p), BPC.KIND_V3, uint24(3000), address(0), address(tA), address(tB))
        );
        _at(address(p), data, 3_000_000);
        uint256 b = _least(address(p), data, 3000);
        for (uint256 g = b - 2_500; g <= b + 500; g += 20) {
            (uint8 o, uint24 f) = _at(address(p), data, g);
            assertTrue(o != WROTE || f == 3000, "the operator's door wrote 0 for an agreeing tier");
        }
    }
}
