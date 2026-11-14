// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE V4 UNLOCK CONTEXT AND THE FEE BOOK DIE WITH THE SWAP (morf-1106 INV-S1)
//
//  Three transient slots outlive nothing on purpose:
//    - the fee book (TSLOT_FEE): `_payFee` counts, the settlement reads the count
//      (none = RouterE(15), more than one under an index = RouterE(16)) and clears it;
//    - the V4 unlock context (TSLOT_V4IN/V4OUT): `_execV4Amt` writes it before
//      `unlock`, `unlockCallback` clears it before it settles (single-shot) and
//      `_execV4Amt` clears it again when `unlock` returns.
//
//  Foundry resets transient storage between a test's top-level calls, so a clear
//  that is missing is invisible to any test that makes one swap per call. Every
//  test here runs its swaps, and what follows them, inside ONE call:
//    - two V4 swaps and one V3 swap in one call each pay exactly one Fee;
//    - a manager that answers `unlock` without calling back, then calls the
//      callback itself, finds no context (the clear after `unlock`);
//    - a manager that calls the callback again while it pays the output finds no
//      context (the clear before settling).
//
//  Both V4 clears are only reachable through a manager that is not v4-core's: the
//  canonical PoolManager calls the callback exactly once per `unlock` and refuses a
//  nested `unlock`. The manager is the owner's configuration (`hub.initialize`), so
//  these are guards against a wrong one, held live by a manager that misbehaves.
//
//  Guards, green at cb1d7d9 (every clear is there). Red under their mutants in
//  `.github/scripts/mutants.py`: [inv-s1-1635] (the book's clear), [inv-s1-2061]
//  (the clear after `unlock`), [inv-s1-2179] (the clear before settling).
//  Of the book's two checks, RouterE(16) has no mutant of its own (derived, morf-1106
//  INV-S1): while the book is cleared no settlement pays twice under an index (one
//  paying hop, one `_payFee` per hop, no re-entry into `_payFee`), so it fires only
//  with the clear gone, which the batch below sees. RouterE(15) is a live guard, on
//  two hops too: a route anchored at hop 0 whose hop 0 commits nothing, through a
//  middle token whose `balanceOf` answers more on its second read, delivers with
//  nothing in the book. Its guard and its mutant [inv-s1-1633] are in
//  test/UnpaidDeliveryIsRefusedOnTwoHops.t.sol.
//
//  forge test --match-path test/V4ContextAndFeeBookDieWithTheSwap.t.sol -vv
// =============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// @notice V4 manager with a 1:1 swap that can misbehave in two ways: answer `unlock`
///         without calling back (Silent), or call the Router's callback again while it
///         pays the output (ReenterOnTake). `poke` calls the callback from outside any
///         `unlock`. A callback it sends on its own is charged in full and paid nothing.
contract DeviantV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    enum Mode { Honest, Silent, ReenterOnTake }

    Mode    public mode;
    uint256 public swapCalls;
    bytes   public replay;      // the callback data a re-entry or a poke sends
    bool    public replayOk;
    bytes   public replayRet;
    bool    private inReplay;

    address private pendingCur;
    uint256 private pendingOwe;
    address private syncedCur;
    uint256 private syncBal;

    mapping(bytes32 => bytes32) public slots;
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }

    function setMode(Mode m) external { mode = m; }
    function setReplay(bytes calldata d) external { replay = d; }

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (mode == Mode.Silent) {
            (V4PoolKey memory key, bool zfo, uint256 amt,) = abi.decode(data, (V4PoolKey, bool, uint256, bytes));
            MockERC20(zfo ? key.currency1 : key.currency0).transfer(msg.sender, amt);
            // the two words the Router decodes since 2a7c0805 (3958): recv, owe
            return abi.encode(amt, amt);
        }
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        return abi.decode(ret, (bytes));
    }

    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (int256) {
        ++swapCalls;
        uint256 amt = uint256(-p.amountSpecified);
        pendingCur = p.zeroForOne ? key.currency0 : key.currency1;
        pendingOwe = amt;
        int128 owe  = -int128(int256(amt));
        int128 recv = inReplay ? int128(0) : int128(int256(amt));
        return p.zeroForOne
            ? int256((uint256(uint128(owe)) << 128) | uint256(uint128(recv)))
            : int256((uint256(uint128(recv)) << 128) | uint256(uint128(owe)));
    }

    function sync(address c) external {
        syncedCur = c;
        syncBal = MockERC20(c).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 p) {
        require(syncedCur == pendingCur, "settle: not synced");
        require(MockERC20(pendingCur).balanceOf(address(this)) - syncBal >= pendingOwe, "settle: unpaid");
        p = pendingOwe;
        pendingOwe = 0;
    }

    function take(address c, address to, uint256 amount) external {
        if (mode == Mode.ReenterOnTake && !inReplay) _replay(msg.sender);
        require(MockERC20(c).transfer(to, amount), "take: transfer failed");
    }

    function poke(address router) external { _replay(router); }

    function _replay(address router) private {
        inReplay = true;
        (replayOk, replayRet) = router.call(abi.encodeWithSignature("unlockCallback(bytes)", replay));
        inReplay = false;
    }
}

/// @notice Runs several swaps in one call and keeps each refusal's bytes.
contract SwapBatch {
    function run(BlazePhoenixRouter router, Route[] calldata routes, uint256[] calldata amts)
        external returns (bytes[] memory errs)
    {
        errs = new bytes[](routes.length);
        for (uint256 i; i < routes.length; ++i) {
            MockERC20(routes[i].hops[0].tokenIn).approve(address(router), amts[i]);
            try router.swapExactIn(routes[i], amts[i], 1, address(this), block.timestamp + 1) returns (uint256) {}
            catch (bytes memory e) { errs[i] = e; }
        }
    }
}

/// @notice Swaps through the manager and then has it call the callback, in one call.
contract SwapThenPoke {
    function run(BlazePhoenixRouter router, DeviantV4Manager mgr, Route calldata route, uint256 amt)
        external returns (uint256 out)
    {
        MockERC20(route.hops[0].tokenIn).approve(address(router), amt);
        out = router.swapExactIn(route, amt, 1, address(this), block.timestamp + 1);
        mgr.poke(address(router));
    }
}

contract V4ContextAndFeeBookDieWithTheSwapTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    DeviantV4Manager   mgr;
    MockV3Pool         v3;
    MockERC20 lo;
    MockERC20 hi;
    MockERC20 x;
    bytes32   pid;

    uint24  constant FEE    = 500;
    int24   constant TS     = 10;
    uint128 constant LIQ    = 1e24;
    uint24  constant PFEE   = 3000;
    uint256 constant DEPTH  = 1_000_000e18;
    uint256 constant HELD   = 1_000e18;   // what the Router holds for others
    uint256 constant AMT    = 10e18;

    bytes32 constant FEE_SIG  = keccak256("Fee(address,uint256,uint256,uint256)");
    bytes32 constant SWAP_SIG = keccak256("Swap(address,address,address,uint256,uint256,uint256)");

    function setUp() public {
        mgr = new DeviantV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));

        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (lo, hi) = address(a) < address(b) ? (a, b) : (b, a);
        x = new MockERC20("X", "X");

        pid = BPC.computeV4PoolId(address(lo), address(hi), FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
        lo.mint(address(mgr), DEPTH);
        hi.mint(address(mgr), DEPTH);

        v3 = new MockV3Pool(address(lo), address(x), PFEE);
        v3.setState(uint160(BPC.Q96), uint128(DEPTH));
        lo.mint(address(v3), DEPTH);
        x.mint(address(v3), DEPTH);
    }

    function _net(uint256 a) private pure returns (uint256) {
        return a - BPC.mulDivUp(a, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function _one(Leg memory leg, address tIn, address tOut, uint256 amt, uint256 expOut)
        private pure returns (Route memory)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: expOut, legs: legs});
        return Route({hops: hops, totalOut: expOut, singleOut: expOut, singleOutFloor: 0,
                      expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _v4(bool zfo, uint256 amt) private view returns (Route memory) {
        (address tIn, address tOut) = zfo ? (address(lo), address(hi)) : (address(hi), address(lo));
        uint256 q = BPC.outV3(_net(amt), uint160(BPC.Q96), LIQ, FEE, zfo, 0);
        return _one(Leg({pool: address(uint160(uint256(pid))), hooks: address(0), kind: BPC.KIND_V4, fee: FEE,
                         tickSpacing: TS, zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: q,
                         auxId: bytes32(uint256(uint160(tOut)))}), tIn, tOut, amt, q);
    }

    function _v3(uint256 amt) private view returns (Route memory) {
        bool zfo = address(lo) < address(x);
        uint256 q = BPC.outV3(amt, uint160(BPC.Q96), uint128(DEPTH), PFEE, zfo, 0);
        return _one(Leg({pool: address(v3), hooks: address(0), kind: BPC.KIND_V3, fee: PFEE, tickSpacing: 60,
                         zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: q, auxId: bytes32(0)}),
                    address(lo), address(x), amt, q);
    }

    function _key(bool zfo, uint256 amt) private view returns (bytes memory) {
        return abi.encode(DeviantV4Manager.V4PoolKey(address(lo), address(hi), FEE, TS, address(0)), zfo, amt, bytes(""));
    }

    function _refusal(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    // ─── the fee book: one Fee per delivery, three deliveries in one call ───

    /// Runs V4 lo->hi, V4 hi->lo and V3 lo->x in one call, with lo and hi bridges: the
    /// first two pay on their output (a direct route into a bridge), the V3 swap pays on
    /// its input (anchored at hop 0). Every one is under an index, so the book is checked
    /// for more than one payment on each.
    function _batch(uint256 a1, uint256 a2, uint256 a3) private {
        hub.addBridge(address(lo));
        hub.addBridge(address(hi));
        SwapBatch batch = new SwapBatch();
        lo.mint(address(batch), a1 + a3);
        hi.mint(address(batch), a2);

        Route[] memory routes = new Route[](3);
        routes[0] = _v4(true, a1);
        routes[1] = _v4(false, a2);
        routes[2] = _v3(a3);
        uint256[] memory amts = new uint256[](3);
        (amts[0], amts[1], amts[2]) = (a1, a2, a3);
        address[3] memory feeToken = [address(hi), address(lo), address(lo)];

        vm.recordLogs();
        bytes[] memory errs = batch.run(router, routes, amts);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < 3; ++i) assertEq(errs[i], bytes(""), "a swap of the batch was refused");

        uint256 delivery;
        uint256 fees;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter != address(router)) continue;
            bytes32 sig = logs[j].topics[0];
            if (sig == FEE_SIG) {
                (uint256 amount, uint256 t1, uint256 t2) = abi.decode(logs[j].data, (uint256, uint256, uint256));
                assertEq(address(uint160(uint256(logs[j].topics[1]))), feeToken[delivery], "the fee was paid in the wrong token");
                assertGt(amount, 0, "a fee of zero");
                assertEq(t1 + t2, amount, "the fee's shares do not add up");
                if (delivery == 2) assertEq(amount, BPC.mulDivUp(a3, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "the anchored fee");
                ++fees;
            } else if (sig == SWAP_SIG) {
                assertEq(fees, 1, "a delivery did not pay exactly one Fee");
                fees = 0;
                ++delivery;
            }
        }
        assertEq(delivery, 3, "three deliveries in the call");
        assertEq(fees, 0, "a Fee after the last delivery");
        assertGt(hi.balanceOf(address(batch)), 0, "the first V4 swap delivered");
        assertGt(x.balanceOf(address(batch)), 0, "the V3 swap delivered");
    }

    /// FAILS IF DELETED: yes - with the book's clear (Router:1635) removed the second swap
    /// of the call starts its book at 1 and is refused RouterE(16), and so is the third.
    function test_TwoV4AndOneV3SwapsInOneCall_EachDeliveryPaysExactlyOneFee() public {
        _batch(AMT, 3e18, 7e18);
    }

    /// The same, over amounts from a few thousand wei to a hundred tokens per swap.
    function testFuzz_TwoV4AndOneV3SwapsInOneCall_EachDeliveryPaysExactlyOneFee(uint256 a1, uint256 a2, uint256 a3)
        public
    {
        a1 = bound(a1, 1e4, 100e18);
        a2 = bound(a2, 1e4, 100e18);
        a3 = bound(a3, 1e4, 100e18);
        _batch(a1, a2, a3);
    }

    // ─── the V4 unlock context ───

    /// FAILS IF DELETED: yes - with the clear after `unlock` (Router:2061) removed, a manager
    /// that never called back leaves the context alive for the rest of the call: its later
    /// callback is served, and the Router pays it what it holds for others.
    function test_AManagerThatNeverCalledBack_FindsNoContextLaterInTheCall() public {
        for (uint256 d; d < 2; ++d) {
            bool zfo = d == 0;
            MockERC20 tIn = zfo ? lo : hi;
            mgr.setMode(DeviantV4Manager.Mode.Silent);
            mgr.setReplay(_key(zfo, HELD));
            tIn.mint(address(router), HELD);
            uint256 heldBefore = tIn.balanceOf(address(router));

            SwapThenPoke caller = new SwapThenPoke();
            tIn.mint(address(caller), AMT);
            uint256 out = caller.run(router, mgr, _v4(zfo, AMT), AMT);

            assertGt(out, 0, "setup: the swap settled");
            assertEq(mgr.swapCalls(), 0, "the late callback reached the manager's swap");
            assertFalse(mgr.replayOk(), "a callback after `unlock` returned was served");
            assertEq(mgr.replayRet(), _refusal(6), "the late callback must find no context (RouterE(6))");
            assertGe(tIn.balanceOf(address(router)), heldBefore, "what the Router holds left with the late callback");
        }
    }

    /// FAILS IF DELETED: yes - with the single-shot clear in `unlockCallback` (Router:2179)
    /// removed, the manager's second callback inside the same `unlock` is served: it is
    /// charged the Router's holdings and the Router is paid nothing for them.
    function test_AManagerCallingBackAgainWhileItPays_FindsNoContext() public {
        for (uint256 d; d < 2; ++d) {
            bool zfo = d == 0;
            MockERC20 tIn = zfo ? lo : hi;
            mgr.setMode(DeviantV4Manager.Mode.ReenterOnTake);
            mgr.setReplay(_key(zfo, HELD));
            tIn.mint(address(router), HELD);
            uint256 heldBefore = tIn.balanceOf(address(router));
            uint256 callsBefore = mgr.swapCalls();

            address user = address(uint160(0xB0B0 + d));
            tIn.mint(user, AMT);
            vm.startPrank(user);
            tIn.approve(address(router), AMT);
            uint256 out = router.swapExactIn(_v4(zfo, AMT), AMT, 1, user, block.timestamp + 1);
            vm.stopPrank();

            assertGt(out, 0, "setup: the swap settled");
            assertEq(mgr.swapCalls(), callsBefore + 1, "the second callback reached the manager's swap");
            assertFalse(mgr.replayOk(), "a second callback inside one unlock was served");
            assertEq(mgr.replayRet(), _refusal(6), "the second callback must find no context (RouterE(6))");
            assertEq(tIn.balanceOf(address(router)), heldBefore, "what the Router holds left with the second callback");
        }
    }
}
