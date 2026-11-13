// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WHAT THE REGISTRY COSTS, AND WHAT A WARM TRANSACTION SAVES, PINNED.
//
//  The Hub's registry doors one by one (discoverFor, seedPool, recordSwap, addBridge,
//  getActivePools, getPsi, keyOf), the registry's life as the swap door sees it
//  (empty, recorded, curated, stale), and warmth: what the second swap or the second
//  plan costs when the first one, in the same transaction, already paid the cold
//  accesses (EIP-2929).
//
//  THE INSTRUMENT (isolation mode: `isolate = true` in foundry.toml, asserted in
//  the setUp of each gas contract below):
//  - A top-level CALL from a test runs as its own transaction: it carries the
//    intrinsic cost (21 000 + calldata) and starts with every account and slot cold.
//    A top-level STATICCALL runs in place, also cold. `RegistryInstrumentTest` pins
//    both facts against the EVM's own constants; with `isolate` off
//    (FOUNDRY_ISOLATE=false, or --no-isolate) both of its tests fail, and so does
//    the exact relation of the plan pair. Every other number in this file is read
//    with the instrument those two tests pin.
//  - Every budget is the measured snapshot itself (`vm.startSnapshotGas` ..
//    `vm.stopSnapshotGas` around a view, `vm.snapshotGasLastFrame` after a call,
//    `vm.snapshotValue` for a figure measured inside a frame), written to
//    snapshots/<group>.json. No ceiling is set by hand. The gate is equality: with
//    FORGE_SNAPSHOT_CHECK=true any window that moves, up or down, fails the run
//    while every assert still passes. A change meant to move gas regenerates the
//    files in the same commit.
//  - One group per test function, named after it: a partial run (`--match-test`, as
//    the mutation guard runs) rewrites the groups it ran, and only those.
//  - A window around a call that is not `view` carries the intrinsic cost: those
//    entries end in `_tx`. A window around a `view` carries none.
//  - Warmth is measured INSIDE one frame (`ReadPair`, `SwapTwice`, `PlanTwice`): the
//    first and the second call run the same code on the same calldata, so the
//    difference between them is the access list the first one built. The relations
//    asserted on it are derived from EIP-2929 (2 600 / 2 100 cold, 100 warm), never
//    a gas figure.
//
//  FOUNDRY_PROFILE=release forge test --match-path test/gas/RegistryWarmthGas.t.sol
//  FOUNDRY_PROFILE=release FORGE_SNAPSHOT_CHECK=true forge test --match-path test/gas/RegistryWarmthGas.t.sol
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {QuoteWorld} from "../QuoteWorld.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, QuoteCtx, PoolInfo} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {MockV2Factory} from "../mocks/MockV2Factory.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";
import {MockAlgebraPool} from "../mocks/MockAlgebraPool.sol";
import {MockSolidlyPair} from "../mocks/MockSolidlyPair.sol";
import {MockV4TickManager} from "../mocks/MockV4TickManager.sol";

// EIP-2929 / Yellow Paper constants (cancun): the only gas numbers the asserts use.
uint256 constant COLD_ACCOUNT = 2_600; // COLD_ACCOUNT_ACCESS_COST
uint256 constant COLD_SLOT = 2_100;    // COLD_SLOAD_COST
uint256 constant WARM = 100;           // WARM_STORAGE_READ_COST
uint256 constant TX_BASE = 21_000;     // G_transaction

/// One account, one slot.
contract WarmthProbe {
    uint256 internal x = 1;

    function noop() external {}

    function read() external view returns (uint256) { return x; }
}

/// The same read twice in one frame. Memory stays in the scratch space, so both windows
/// run the same opcodes and differ only by what the first read left warm.
contract ReadPair {
    function run(address p) external view returns (uint256 cold, uint256 warm) {
        bytes4 sel = WarmthProbe.read.selector;
        assembly ("memory-safe") {
            mstore(0, sel)
            for { let i := 0 } lt(i, 2) { i := add(i, 1) } {
                let g := gas()
                let ok := staticcall(gas(), p, 0, 4, 0x20, 0x20)
                let used := sub(g, gas())
                if iszero(ok) { revert(0, 0) }
                switch i
                case 0 { cold := used }
                default { warm := used }
            }
        }
    }
}

/// Two swaps through one router in one transaction. Each call's calldata is copied
/// before its window opens, so a window holds the call and nothing else.
contract SwapTwice {
    function approve(address token, address spender) external {
        MockERC20(token).approve(spender, type(uint256).max);
    }

    function run(address router, bytes calldata d1, bytes calldata d2)
        external returns (uint256 cold, uint256 warm, uint256 out1, uint256 out2)
    {
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, d1.offset, d1.length)
            let g := gas()
            let ok := call(gas(), router, 0, p, d1.length, 0, 0x20)
            cold := sub(g, gas())
            if iszero(ok) { returndatacopy(p, 0, returndatasize()) revert(p, returndatasize()) }
            out1 := mload(0)
            calldatacopy(p, d2.offset, d2.length)
            g := gas()
            ok := call(gas(), router, 0, p, d2.length, 0, 0x20)
            warm := sub(g, gas())
            if iszero(ok) { returndatacopy(p, 0, returndatasize()) revert(p, returndatasize()) }
            out2 := mload(0)
        }
    }
}

/// The same view call twice in one frame, the return data left unread.
contract PlanTwice {
    function run(address target, bytes calldata d) external view returns (uint256 cold, uint256 warm) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, d.offset, d.length)
            // One loop body for both runs: the two windows execute the same opcodes, so their
            // difference is the access list alone (unrolled windows can differ by stack ops).
            for { let i := 0 } lt(i, 2) { i := add(i, 1) } {
                let g := gas()
                let ok := staticcall(gas(), target, p, d.length, 0, 0)
                let used := sub(g, gas())
                if iszero(ok) { returndatacopy(p, 0, returndatasize()) revert(p, returndatasize()) }
                switch i
                case 0 { cold := used }
                default { warm := used }
            }
        }
    }
}

/// What the instrument does, pinned against the EVM's constants.
contract RegistryInstrumentTest is Test {
    /// Two top-level reads of the same slot both pay the cold account and the cold slot,
    /// although the test touched the probe just before: each top-level call starts cold.
    /// Inside one frame the second read pays neither, by exactly the EIP-2929 difference.
    function test_Instrument_TopLevelCallsStartCold() public {
        string memory g = "test_Instrument_TopLevelCallsStartCold";
        WarmthProbe p = new WarmthProbe();
        ReadPair pair = new ReadPair();
        assertEq(p.read(), 1, "the probe answers");

        vm.startSnapshotGas(g, "read_first");
        p.read();
        uint256 first = vm.stopSnapshotGas();
        vm.startSnapshotGas(g, "read_second");
        p.read();
        uint256 second = vm.stopSnapshotGas();
        assertGe(first, COLD_ACCOUNT + COLD_SLOT, "a top-level read pays a cold account and a cold slot");
        assertGe(second, COLD_ACCOUNT + COLD_SLOT, "the next top-level read is cold again");

        (uint256 cold, uint256 warm) = pair.run(address(p));
        vm.snapshotValue(g, "pair_cold", cold);
        vm.snapshotValue(g, "pair_warm", warm);
        assertEq(cold, warm + (COLD_ACCOUNT - WARM) + (COLD_SLOT - WARM),
            "inside one frame the second read saves exactly one cold account and one cold slot");
    }

    /// A top-level CALL is a transaction of its own (intrinsic cost included); the same
    /// function through a top-level STATICCALL runs in place. The two frames run the same
    /// code, so they differ by exactly 21 000 plus the calldata (16 a nonzero byte, 4 a zero).
    function test_Instrument_NonViewWindowCarriesTheIntrinsic() public {
        string memory g = "test_Instrument_NonViewWindowCarriesTheIntrinsic";
        WarmthProbe p = new WarmthProbe();
        bytes memory data = abi.encodeCall(WarmthProbe.noop, ());
        // Each frame is read before anything else runs: an assert is a cheatcode call.
        (bool okCall,) = address(p).call(data);
        uint256 asTx = vm.lastFrameGas().gasTotalUsed;
        (bool okStatic,) = address(p).staticcall(data);
        uint256 inPlace = vm.lastFrameGas().gasTotalUsed;
        assertTrue(okCall && okStatic, "noop answers a call and a staticcall");
        vm.snapshotValue(g, "noop_call_tx", asTx);
        vm.snapshotValue(g, "noop_staticcall", inPlace);
        assertEq(asTx, inPlace + TX_BASE + _calldataGas(data),
            "the call window carries exactly the intrinsic cost of a transaction");
    }

    function _calldataGas(bytes memory d) internal pure returns (uint256 c) {
        for (uint256 i; i < d.length; ++i) c += d[i] == 0 ? 4 : 16;
    }
}

/// Shared pieces: bubbling a revert, and two swaps in one transaction.
abstract contract GasBase is Test {
    function _bubble(bool ok, bytes memory ret) internal pure {
        if (!ok) {
            assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
        }
    }

    /// Two swapExactIn calls from one batch contract, in one transaction. `r2` must be
    /// quoted on the state `r1` leaves. `shared` counts the accounts both swaps touch
    /// (the router, the Hub, the venue, both tokens): each is cold in the first swap and
    /// warm in the second, so the second is cheaper by at least `shared` x (2 600 - 100).
    /// Not more is claimed: the slots the first swap wrote are also cheaper to write again
    /// (EIP-2200), and that saving depends on the values, not on the access list. The
    /// floor is loose (the measured gap is far above it): it checks the direction, and the
    /// snapshot is what pins both numbers.
    function _twice(string memory g, address router_, Route memory r1, Route memory r2, uint256 amt, uint256 shared)
        internal
    {
        SwapTwice batch = _batch(r1.hops[0].tokenIn, router_, amt);
        bytes memory d1 = _swapCall(r1, amt, address(batch));
        bytes memory d2 = _swapCall(r2, amt, address(batch));
        (uint256 cold, uint256 warm, uint256 out1, uint256 out2) = batch.run(router_, d1, d2);
        vm.snapshotGasLastFrame(g, "batch_tx");
        vm.snapshotValue(g, "first_swap", cold);
        vm.snapshotValue(g, "second_swap", warm);
        assertGt(out1, 0, "the first swap pays");
        assertGt(out2, 0, "the second swap pays");
        address tOut = r1.hops[r1.hops.length - 1].tokenOut;
        assertEq(MockERC20(tOut).balanceOf(address(batch)), out1 + out2, "each door returns what the batch received");
        assertGe(cold, warm + shared * (COLD_ACCOUNT - WARM), "the second swap finds the shared accounts warm");
    }

    /// A batch contract holding both swaps' input, the router approved.
    function _batch(address tIn, address router_, uint256 amt) private returns (SwapTwice batch) {
        batch = new SwapTwice();
        MockERC20(tIn).mint(address(batch), 2 * amt);
        batch.approve(tIn, router_);
    }

    function _swapCall(Route memory r, uint256 amt, address to) private view returns (bytes memory) {
        return abi.encodeCall(BlazePhoenixRouter.swapExactIn, (r, amt, 1, to, block.timestamp + 1));
    }
}

/// The Hub's doors on QuoteWorld (B the one bridge; AB1-AB3 on A/B, BC1 on B/C).
contract RegistryHubGasTest is QuoteWorld, GasBase {
    /// One percent of the A side of AB1, the shallowest A/B pool.
    uint256 constant AMOUNT = 1_000e18;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
    }

    /// recordSwap's two paths straight from the router's seat (insert, then refresh), and the
    /// swap door with the Hub live and paused, from one state. Paused, the Hub refuses the
    /// write (HubE(2)); the door swallows the refusal and the swap still pays.
    function test_Gas_Hub_RecordSwap_LiveVsPaused() public {
        _world(false);
        string memory g = "test_Gas_Hub_RecordSwap_LiveVsPaused";
        (address t0, address t1) = BPC.sortTokens(address(A), address(B));
        bool zfo = AB1.token0() == address(A);
        (uint112 r0, uint112 r1,) = AB1.getReserves();
        uint256 out = BPC.outV2(AMOUNT, zfo ? r0 : r1, zfo ? r1 : r0, 30);
        uint256 depth = BPC.tickDepth18(address(AB1), BPC.KIND_V2, t0, t1, address(0), bytes32(0), AMOUNT, out, zfo);
        bytes32 key = hub.keyOf(address(AB1), t0, t1);
        assertEq(hub.getSlot(key), 0, "the empty world holds no row for AB1");

        vm.prank(address(router));
        hub.recordSwap(address(AB1), BPC.KIND_V2, 30, address(0), t0, t1, AMOUNT, out, depth);
        vm.snapshotGasLastFrame(g, "insert_tx");
        assertEq(BPC.decodeTier(hub.getSlot(key)), 2, "a swap writes a permissionless row");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        vm.prank(address(router));
        hub.recordSwap(address(AB1), BPC.KIND_V2, 30, address(0), t0, t1, AMOUNT, out, depth);
        vm.snapshotGasLastFrame(g, "refresh_tx");
        assertEq(BPC.decodeLastUpdateTs(hub.getSlot(key)), block.timestamp, "the refresh stamps the row");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        A.mint(user, AMOUNT);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
        Route memory r = _handRoute(AB1, address(A), address(B), AMOUNT);
        bytes memory data = abi.encodeCall(router.swapExactIn, (r, AMOUNT, 1, user, block.timestamp + 1));

        uint256 s = vm.snapshotState();
        _doorPays(g, "door_live_tx", data);
        assertEq(BPC.decodeLastUpdateTs(hub.getSlot(key)), block.timestamp, "the live door refreshes the row");
        vm.revertToState(s);

        hub.setPaused(true);
        uint256 rowBefore = hub.getSlot(key);
        _doorPays(g, "door_paused_tx", data);
        assertEq(hub.getSlot(key), rowBefore, "a paused Hub writes nothing");
    }

    /// addBridge on a new token and again on the same one (an early return), then the routable
    /// question for a bridge and for a token that is none (the early-out on isBridge).
    function test_Gas_Hub_AddBridgeAndRoutableViews() public {
        _world(false);
        string memory g = "test_Gas_Hub_AddBridgeAndRoutableViews";
        hub.addBridge(address(C));
        vm.snapshotGasLastFrame(g, "add_new_tx");
        hub.addBridge(address(C));
        vm.snapshotGasLastFrame(g, "add_again_tx");
        assertEq(hub.bridgeCount(), 2, "adding a bridge twice adds it once");
        assertEq(hub.bridge(1), address(C), "the new bridge takes the next position");

        vm.startSnapshotGas(g, "routable_bridge");
        bool rb = hub.isRoutableBridge(address(C));
        vm.stopSnapshotGas();
        vm.startSnapshotGas(g, "routable_other");
        bool ro = hub.isRoutableBridge(address(A));
        vm.stopSnapshotGas();
        vm.startSnapshotGas(g, "bridge_token");
        bool bt = hub.isBridgeToken(address(C));
        vm.stopSnapshotGas();
        assertTrue(rb, "a bridge in the first positions is routable");
        assertFalse(ro, "a token that is no bridge is not routable");
        assertTrue(bt, "the new bridge is a bridge token");
    }

    /// getActivePools on one pair holding 1, 4 and 8 curated rows.
    function test_Gas_Hub_GetActivePools_PerPoolCount_1_4_8() public {
        _world(false);
        MockV2Pair[] memory ps = new MockV2Pair[](8);
        _seedRows(ps, 0, 1);
        _activeRows(ps, 1);
        _seedRows(ps, 1, 4);
        _activeRows(ps, 4);
        _seedRows(ps, 4, 8);
        _activeRows(ps, 8);
    }

    /// Curated rows ps[from..to) on A/C, each its own pool.
    function _seedRows(MockV2Pair[] memory ps, uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            ps[i] = _pool(A, C, 100_000e18, 100_000e18);
            hub.seedPool(address(ps[i]), BPC.KIND_V2, 30, address(0), address(A), address(C));
        }
    }

    /// One getActivePools window on A/C while it holds `count` curated rows (rows_<count>).
    function _activeRows(MockV2Pair[] memory ps, uint256 count) internal {
        string memory name = string.concat("rows_", vm.toString(count));
        vm.startSnapshotGas("test_Gas_Hub_GetActivePools_PerPoolCount_1_4_8", name);
        PoolInfo[] memory rows = hub.getActivePools(address(A), address(C));
        vm.stopSnapshotGas();
        assertEq(rows.length, count, "every curated row is active");
        for (uint256 i; i < count; ++i) {
            assertEq(rows[i].pool, address(ps[i]), "rows come back in registration order");
        }
    }

    /// getPsi with the bridge named first and second, on a pool that holds no row, and keyOf.
    function test_Gas_Hub_GetPsiAndKeyOf() public {
        _world(true);
        string memory g = "test_Gas_Hub_GetPsiAndKeyOf";
        vm.startSnapshotGas(g, "psi_bridge_first");
        uint256 p1 = hub.getPsi(address(BC1), address(B), address(C));
        vm.stopSnapshotGas();
        vm.startSnapshotGas(g, "psi_bridge_second");
        uint256 p2 = hub.getPsi(address(BC1), address(C), address(B));
        vm.stopSnapshotGas();
        vm.startSnapshotGas(g, "psi_unregistered");
        uint256 p0 = hub.getPsi(address(0xDEAD), address(B), address(C));
        vm.stopSnapshotGas();
        vm.startSnapshotGas(g, "key_of");
        bytes32 k = hub.keyOf(address(BC1), address(C), address(B));
        vm.stopSnapshotGas();
        assertGt(p1, 0, "a curated row on a bridged pair has fitness");
        assertEq(p1, p2, "psi does not depend on the order the pair is named in");
        assertEq(p0, 0, "a pool that holds no row has no fitness");
        assertEq(k, hub.keyOf(address(BC1), address(B), address(C)), "the key is symmetric in the pair");
        assertEq(k, BPC.pairKey(address(BC1), address(B), address(C)), "the Hub's key is the Core's pairKey");
    }

    /// Two swaps through AB1 in one transaction: the first finds the router, the Hub, AB1,
    /// A and B cold, the second finds them warm.
    function test_Gas_SwapExactIn_ColdThenWarm_InOneTransaction() public {
        _world(true);
        string memory g = "test_Gas_SwapExactIn_ColdThenWarm_InOneTransaction";
        A.mint(user, AMOUNT);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
        Route memory r1 = _handRoute(AB1, address(A), address(B), AMOUNT);
        bytes memory d1 = abi.encodeCall(router.swapExactIn, (r1, AMOUNT, 1, user, block.timestamp + 1));
        uint256 s = vm.snapshotState();
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(d1);
        _bubble(ok, ret);
        Route memory r2 = _handRoute(AB1, address(A), address(B), AMOUNT);
        vm.revertToState(s);
        _twice(g, address(router), r1, r2, AMOUNT, 5);
    }

    /// The same previewPlan twice in one call. The plan is a view: the second run reads the
    /// same accounts and slots, all warm. The state diff of one run names them, so the saving
    /// is exact: (2 600 - 100) per distinct account and (2 100 - 100) per distinct slot,
    /// provided no frame of the plan reverts (a reverted frame takes its accesses back
    /// out of the access list, EIP-2929). The census comes from the same call, so the
    /// equality holds for any plan that reads the same set twice: it checks the
    /// instrument, and the snapshot is what pins the plan's cost.
    function test_Gas_PreviewPlan_ColdThenWarm_InOneCall() public {
        _world(true);
        string memory g = "test_Gas_PreviewPlan_ColdThenWarm_InOneCall";
        bytes memory data = abi.encodeCall(quoter.previewPlan, (address(A), address(B), AMOUNT));
        vm.startStateDiffRecording();
        (bool ok,) = address(quoter).staticcall(data);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertTrue(ok, "the plan answers");
        (uint256 nAcc, uint256 nSlots, uint256 nReverted) = _census(acc, address(quoter));
        assertEq(nReverted, 0, "no frame of the plan reverts");

        PlanTwice twice = new PlanTwice();
        vm.startSnapshotGas(g, "plan_pair");
        (uint256 cold, uint256 warm) = twice.run(address(quoter), data);
        vm.stopSnapshotGas();
        vm.snapshotValue(g, "plan_cold", cold);
        vm.snapshotValue(g, "plan_warm", warm);
        vm.snapshotValue(g, "accounts", nAcc);
        vm.snapshotValue(g, "slots", nSlots);
        assertEq(cold, warm + nAcc * (COLD_ACCOUNT - WARM) + nSlots * (COLD_SLOT - WARM),
            "the second plan saves exactly the access list the first one built");
    }

    /// Distinct accounts and distinct (account, slot) pairs that one call of this test to
    /// `target` touched, and how many of its accesses were reverted. The count starts at that
    /// call's own entry: the recording can open with entries the runner adds before it (a
    /// library deployment through the CREATE2 deployer, for one), which are not the call's.
    /// Left out: the accounts every transaction starts with warm (EIP-2929: origin and
    /// precompiles, 0x01-0x0a on cancun; EIP-3651: the coinbase), this test and the cheatcode
    /// address.
    function _census(Vm.AccountAccess[] memory acc, address target)
        internal view returns (uint256 nAcc, uint256 nSlots, uint256 nReverted)
    {
        uint256 from = acc.length;
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].accessor == address(this) && acc[i].account == target) {
                from = i;
                break;
            }
        }
        assertLt(from, acc.length, "the recording holds the call");
        uint256 total;
        for (uint256 i = from; i < acc.length; ++i) total += acc[i].storageAccesses.length;
        address[] memory accounts = new address[](acc.length);
        bytes32[] memory slots = new bytes32[](total);
        for (uint256 i = from; i < acc.length; ++i) {
            Vm.AccountAccess memory a = acc[i];
            if (a.reverted) ++nReverted;
            address who = a.account;
            bool warmAtStart = who == address(this) || who == address(vm) || who == tx.origin
                || who == block.coinbase || (uint160(who) >= 0x01 && uint160(who) <= 0x0a);
            bool counted = a.kind != VmSafe.AccountAccessKind.Resume && !warmAtStart;
            if (counted && !_seenAccount(accounts, nAcc, who)) accounts[nAcc++] = who;
            for (uint256 j; j < a.storageAccesses.length; ++j) {
                Vm.StorageAccess memory sa = a.storageAccesses[j];
                if (sa.reverted) ++nReverted;
                bytes32 id = keccak256(abi.encode(sa.account, sa.slot));
                if (!_seenSlot(slots, nSlots, id)) slots[nSlots++] = id;
            }
        }
    }

    function _seenAccount(address[] memory xs, uint256 n, address x) private pure returns (bool) {
        for (uint256 i; i < n; ++i) if (xs[i] == x) return true;
        return false;
    }

    function _seenSlot(bytes32[] memory xs, uint256 n, bytes32 x) private pure returns (bool) {
        for (uint256 i; i < n; ++i) if (xs[i] == x) return true;
        return false;
    }

    /// One swapExactIn door, recorded as `name`; the recipient must be paid.
    function _doorPays(string memory g, string memory name, bytes memory data) internal {
        uint256 before = B.balanceOf(user);
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(data);
        vm.snapshotGasLastFrame(g, name);
        _bubble(ok, ret);
        assertGt(B.balanceOf(user) - before, 0, "the door pays");
    }
}

/// Discovery: the factory sweep on its own, and the registry's life through the swap door
/// (LifecycleMetrics' world: four V2 pools on one pair, each behind its own factory).
contract RegistryDiscoveryGasTest is GasBase {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair[] pools;
    address user = address(0xBEEF);

    uint256 constant N_POOLS = 4; // >= the Solver's MIN_FRESH_VENUES: four curated rows vouch for the pair
    uint256 constant TTL = 3_600; // DISCOVERY_TTL_SECONDS
    uint256 constant DEPTH = 1_000_000e18;
    uint256 constant AMT = 100e18;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tokenIn = new MockERC20("IN", "IN");
        tokenOut = new MockERC20("OUT", "OUT");
        for (uint256 i; i < N_POOLS; ++i) pools.push(_pairBehindFactory(hub));
        tokenIn.mint(user, DEPTH);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    /// discoverFor with 1, 2, 4 and 8 factories registered, each holding one pool for the pair.
    function test_Gas_DiscoverFor_Factories_1_2_4_8() public {
        BlazePhoenixHub h = new BlazePhoenixHub(address(this));
        h.initialize(address(this), address(0));
        MockV2Pair[] memory ps = new MockV2Pair[](8);
        uint256 n;
        for (uint256 k = 1; k <= 8; k *= 2) {
            for (; n < k; ++n) ps[n] = _pairBehindFactory(h);
            _sweep(h, ps, k);
        }
    }

    /// One discoverFor window while `k` factories are registered (factories_<k>).
    function _sweep(BlazePhoenixHub h, MockV2Pair[] memory ps, uint256 k) internal {
        string memory name = string.concat("factories_", vm.toString(k));
        vm.startSnapshotGas("test_Gas_DiscoverFor_Factories_1_2_4_8", name);
        PoolInfo[] memory hits = h.discoverFor(address(tokenIn), address(tokenOut));
        vm.stopSnapshotGas();
        assertEq(hits.length, k, "one pool per factory");
        for (uint256 i; i < k; ++i) assertEq(hits[i].pool, address(ps[i]), "the sweep follows the factory order");
    }

    /// swapBestExactIn through the registry's life, each stage from its own state:
    /// empty (the Solver sweeps the factories), recorded (four permissionless rows, fresh,
    /// still sweeps: only curated rows vouch for coverage), curated (four seeded rows: no
    /// sweep), curated exactly TTL seconds later (still fresh: the bound is inclusive) and
    /// one second past it (stale: sweeps again). Whether a stage swept is read from the
    /// state diff of its own transaction: a staticcall into Hub.discoverFor.
    function test_Gas_SwapBestExactIn_RegistryLifecycle_EmptyRecordedStale() public {
        string memory g = "test_Gas_SwapBestExactIn_RegistryLifecycle_EmptyRecordedStale";
        uint256 s0 = vm.snapshotState();
        assertTrue(_bestDoor(g, "empty_tx"), "an empty registry sweeps the factories");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _recordAll();
        // Stamped: what keeps the sweep on below is the rows' tier, not a missing stamp.
        hub.refreshPair(address(tokenIn), address(tokenOut));
        for (uint256 i; i < N_POOLS; ++i) {
            assertEq(BPC.decodeTier(hub.getSlot(_key(i))), 2, "every pool holds a permissionless row");
        }
        assertTrue(_bestDoor(g, "recorded_tx"), "permissionless rows do not switch the sweep off");

        vm.revertToState(s0);
        for (uint256 i; i < N_POOLS; ++i) {
            hub.seedPool(address(pools[i]), BPC.KIND_V2, 30, address(0), address(tokenIn), address(tokenOut));
        }
        hub.refreshPair(address(tokenIn), address(tokenOut)); // the sweep finds only these rows
        uint256 seededAt = block.timestamp;
        uint256 s1 = vm.snapshotState();
        assertFalse(_bestDoor(g, "curated_tx"), "fresh curated rows switch the sweep off");

        vm.revertToState(s1);
        vm.warp(seededAt + TTL);
        assertFalse(_bestDoor(g, "curated_at_ttl_tx"), "a row exactly TTL seconds old is still fresh");

        vm.revertToState(s1);
        vm.warp(seededAt + TTL + 1);
        assertTrue(_bestDoor(g, "curated_past_ttl_tx"), "past the TTL the sweep comes back");
    }

    function _pairBehindFactory(BlazePhoenixHub h) internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(tokenIn), address(tokenOut));
        tokenIn.mint(address(p), DEPTH);
        tokenOut.mint(address(p), DEPTH);
        p.setReserves(uint112(DEPTH), uint112(DEPTH));
        MockV2Factory f = new MockV2Factory();
        f.setPair(address(tokenIn), address(tokenOut), address(p));
        h.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
    }

    function _key(uint256 i) internal view returns (bytes32) {
        return hub.keyOf(address(pools[i]), address(tokenIn), address(tokenOut));
    }

    /// The router's own write for every pool: the recordSwap a swap of AMT through it
    /// would make, priced on the pool as it stands. No swap runs, so the reserves are
    /// untouched and the depth recorded is the pre-swap one.
    function _recordAll() internal {
        (address t0, address t1) = BPC.sortTokens(address(tokenIn), address(tokenOut));
        bool zfo = t0 == address(tokenIn);
        for (uint256 i; i < N_POOLS; ++i) {
            address p = address(pools[i]);
            (uint112 r0, uint112 r1,) = pools[i].getReserves();
            uint256 out = BPC.outV2(AMT, zfo ? r0 : r1, zfo ? r1 : r0, 30);
            uint256 depth = BPC.tickDepth18(p, BPC.KIND_V2, t0, t1, address(0), bytes32(0), AMT, out, zfo);
            vm.prank(address(router));
            hub.recordSwap(p, BPC.KIND_V2, 30, address(0), t0, t1, AMT, out, depth);
        }
    }

    /// One swapBestExactIn, recorded as `name`; returns whether it swept the factories.
    function _bestDoor(string memory g, string memory name) internal returns (bool swept) {
        bytes memory data = abi.encodeCall(
            router.swapBestExactIn, (address(tokenIn), address(tokenOut), AMT, 1, user, block.timestamp + 1));
        uint256 before = tokenOut.balanceOf(user);
        vm.startStateDiffRecording();
        vm.prank(user);
        (bool ok, bytes memory ret) = address(router).call(data);
        vm.snapshotGasLastFrame(g, name);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        _bubble(ok, ret);
        assertGt(tokenOut.balanceOf(user) - before, 0, "the door pays");
        for (uint256 i; i < acc.length; ++i) {
            Vm.AccountAccess memory a = acc[i];
            bool isCall = a.kind == VmSafe.AccountAccessKind.StaticCall || a.kind == VmSafe.AccountAccessKind.Call;
            if (isCall && a.account == address(hub) && a.data.length >= 4
                && bytes4(a.data) == BlazePhoenixHub.discoverFor.selector) return true;
        }
    }
}

/// A world with a V4 manager: seedPool per kind, and two V4 swaps in one transaction.
contract RegistryV4WorldGasTest is GasBase {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    address tA;
    address tB;
    address constant USER = address(0xBEEF);

    uint256 constant DEPTH = 1_000_000e18;
    uint128 constant LIQ = uint128(DEPTH);
    uint256 constant AMT = 1_000e18;
    int24 constant V4_RANGE = 60;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(0xC0FFEE));
        address x = address(new MockERC20("X", "X"));
        address y = address(new MockERC20("Y", "Y"));
        (tA, tB) = x < y ? (x, y) : (y, x);
        MockERC20(tA).mint(USER, DEPTH);
        MockERC20(tA).mint(address(mgr), DEPTH);
        MockERC20(tB).mint(address(mgr), DEPTH);
        vm.prank(USER);
        MockERC20(tA).approve(address(router), type(uint256).max);
    }

    /// seedPool for every kind the operator's door admits, each from the same state (the pair
    /// holds no row before the seed). The row is curated (tier 0) and carries the kind.
    function test_Gas_Hub_SeedPool_PerKind() public {
        string memory g = "test_Gas_Hub_SeedPool_PerKind";
        uint256 s = vm.snapshotState();
        _seedOne(g, "v2_tx", BPC.KIND_V2, 30, _v2());
        vm.revertToState(s);
        _seedOne(g, "v3_tx", BPC.KIND_V3, 3000, _v3());
        vm.revertToState(s);
        _seedOne(g, "algebra_tx", BPC.KIND_ALGEBRA, 0, _algebra());
        vm.revertToState(s);
        _seedOne(g, "solidly_volatile_tx", BPC.KIND_SOLIDLY, 30, _solidly(false));
        vm.revertToState(s);
        _seedOne(g, "solidly_stable_tx", BPC.KIND_SOLIDLY, 30, _solidly(true));
        vm.revertToState(s);
        // V4: initialized on the manager, never registered by addV4; seedPool recovers the
        // tick spacing from the fee's canonical tier (500 -> 10) and checks the id.
        _seedOne(g, "v4_tx", BPC.KIND_V4, 500, address(uint160(uint256(_v4Initialized(500, 10)))));
    }

    /// Two swaps through one V4 pool in one transaction: the first finds the router, the Hub,
    /// the manager and both tokens cold, the second finds them warm. Each swap sets and
    /// clears the router's transient unlock context.
    function test_Gas_SwapExactIn_V4_TwoSwapsInOneTransaction() public {
        string memory g = "test_Gas_SwapExactIn_V4_TwoSwapsInOneTransaction";
        bytes32 pid = _v4Initialized(3000, 60);
        hub.addV4(tA, tB, 3000, 60, address(0));
        address pool = address(uint160(uint256(pid)));
        Route memory r1 = _v4Route(pool, 3000, 60, AMT);
        bytes memory d1 = abi.encodeCall(router.swapExactIn, (r1, AMT, 1, USER, block.timestamp + 1));
        uint256 s = vm.snapshotState();
        vm.prank(USER);
        (bool ok, bytes memory ret) = address(router).call(d1);
        _bubble(ok, ret);
        Route memory r2 = _v4Route(pool, 3000, 60, AMT);
        vm.revertToState(s);
        _twice(g, address(router), r1, r2, AMT, 5);
    }

    function _seedOne(string memory g, string memory name, uint8 kind, uint24 fee, address pool) internal {
        hub.seedPool(pool, kind, fee, address(0), tA, tB);
        vm.snapshotGasLastFrame(g, name);
        uint256 row = hub.getSlot(hub.keyOf(pool, tA, tB));
        assertTrue(row != 0, "the row is written");
        assertEq(BPC.decodeTier(row), 0, "the operator's door writes a curated row");
        assertEq(BPC.decodeKind(row), kind, "the row carries the kind");
    }

    function _fund(address p) internal {
        MockERC20(tA).mint(p, DEPTH);
        MockERC20(tB).mint(p, DEPTH);
    }

    function _v2() internal returns (address) {
        MockV2Pair p = new MockV2Pair(tA, tB);
        p.setReserves(uint112(DEPTH), uint112(DEPTH));
        _fund(address(p));
        return address(p);
    }

    function _v3() internal returns (address) {
        MockV3Pool p = new MockV3Pool(tA, tB, 3000);
        p.setState(uint160(BPC.Q96), LIQ);
        _fund(address(p));
        return address(p);
    }

    function _algebra() internal returns (address) {
        MockAlgebraPool p = new MockAlgebraPool(tA, tB, uint16(3000));
        p.setState(uint160(BPC.Q96), LIQ);
        _fund(address(p));
        return address(p);
    }

    function _solidly(bool stable) internal returns (address) {
        MockSolidlyPair p = new MockSolidlyPair(tA, tB, stable);
        p.setReserves(uint112(DEPTH), uint112(DEPTH));
        _fund(address(p));
        return address(p);
    }

    function _v4Initialized(uint24 fee, int24 ts) internal returns (bytes32 pid) {
        pid = BPC.computeV4PoolId(tA, tB, fee, ts, address(0));
        mgr.initialize(pid, uint160(BPC.Q96), 0, fee);
        mgr.addPosition(pid, -V4_RANGE, V4_RANGE, ts, LIQ);
    }

    /// A one-leg V4 route tA -> tB, quoted by the Core on the current state.
    function _v4Route(address pool, uint24 fee, int24 ts, uint256 amt) internal view returns (Route memory r) {
        uint256 q = _v4Quote(pool, fee, ts, amt);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V4, fee: fee, tickSpacing: ts,
                       zeroForOne: true, stable: false, amountIn: amt, expectedOut: q,
                       auxId: bytes32(uint256(uint160(tB)))});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tA, tokenOut: tB, amountIn: amt, expectedOut: q, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
                   confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// The Core's quote for `amt` of tA through the V4 pool, on the current state.
    function _v4Quote(address pool, uint24 fee, int24 ts, uint256 amt) internal view returns (uint256 q) {
        QuoteCtx memory c = QuoteCtx({
            kind: BPC.KIND_V4, pool: pool, zeroForOne: true, fee: fee, tickSpacing: ts, stable: false,
            tokenIn: tA, tokenOther: tB, hooks: address(0), v4Manager: address(mgr), hub: address(hub),
            decIn1: MockERC20(tA).decimals() + 1, decOther1: MockERC20(tB).decimals() + 1
        });
        (q, , , ) = BPC.universalQuoteRank(c, amt, type(uint256).max, false);
    }
}
