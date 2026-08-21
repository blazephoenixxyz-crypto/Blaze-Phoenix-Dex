// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  KIND_V4_NATIVE — native-ETH Uniswap V4 pools behind the WETH-canonical
//  Router. The route speaks WETH end to end; the ONLY place native ETH exists
//  is inside unlockCallback's JIT seam (withdraw -> settle{value} on the input
//  side, take(address(0)) -> deposit on the output side), gated by the
//  TSLOT_ETHOK receive() window. This suite pins:
//
//    (a) WETH -> token and token -> WETH through a native pool, with the
//        Router holding NOTHING (ETH, WETH, token) after the swap;
//    (b) receive() rejects a stranger's bare ETH even DURING the open take
//        window, and rejects the manager itself OUTSIDE its window;
//    (c) receive() rejects everything when no unlock is active — including
//        the zero-value empty-calldata call, bit-compatible with the old
//        no-receive() fallback behaviour;
//    (d) quote == execution poolId parity: the on-chain quote resolves state
//        at the SAME native poolId (address(0), token, fee, ts, hooks) the
//        settlement key hashes to — proven by a nonzero ExecutionProof.quoted
//        (only the native pid has state in the mock) plus the recorded key id;
//    (e) fail-closed: a kind-8 leg where neither side is the canonical WETH
//        reverts RouterE(8), as does kind 8 with weth unwired.
//
//  Mock fidelity (mirrors HostileV4Manager's ABI-compat idiom, extended to
//  native): settle() with value must receive EXACTLY the owed amount and must
//  NOT have been preceded by sync (native settle takes no sync — sync of the
//  native currency reverts here to pin the Router's path); take(address(0))
//  pushes raw ETH via call; the WETH mock's withdraw pays through transfer()
//  (2300-gas stipend), pinning that the Router's receive() stays stipend-thin.
//
//  forge test --match-contract RouterV4NativeEth -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface IERC20Min {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev WETH9-shaped mock with a REAL withdraw: burns balance and pays raw ETH
///      through transfer() — the 2300-gas stipend path canonical WETH9 uses —
///      so the Router's receive() is proven to fit the stipend. Direct mint()
///      calls (test liquidity seeding) are backed by vm.deal in setUp.
contract MockWETH9 is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() public payable {
        this.mint(msg.sender, msg.value);
    }
    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "weth: balance");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        payable(msg.sender).transfer(wad); // 2300-gas stipend, like WETH9
    }
    receive() external payable { deposit(); }
}

/// @dev A bystander that tries to push bare ETH into the Router on command.
contract Stranger {
    receive() external payable {}
    function tryPay(address to) external returns (bool ok) {
        (ok, ) = to.call{value: 1}("");
    }
}

/// @dev V4 PoolManager mock with FAITHFUL native settlement semantics and the
///      extsload single-slot read the quote path uses. Honest 1:1 fills.
contract MockV4ManagerNative {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    bytes32 public lastKeyId;      // keccak of the key the Router settled with
    address public pendingCur;     // input currency owed after swap()
    uint256 public pendingOwe;
    bool    public syncedFlag;
    address public syncedCur;
    uint256 public syncBal;

    Stranger public stranger;      // armed: probes the Router INSIDE the take window
    bool  public strangerPaid;     // true only if the guard FAILED
    bool  public probeMidSwap;     // armed: manager probes OUTSIDE its window
    bool  public midSwapPaid;      // true only if the guard FAILED

    mapping(bytes32 => bytes32) public slots;   // extsload backing store
    function setSlot(bytes32 s, bytes32 v) external { slots[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slots[s]; }

    function setStranger(Stranger s) external { stranger = s; }
    function setProbeMidSwap(bool b) external { probeMidSwap = b; }

    receive() external payable {}

    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(ok, "unlock: callback reverted");
        return ret;
    }

    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (int256) {
        lastKeyId = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        uint256 amt = uint256(-p.amountSpecified);
        pendingCur = p.zeroForOne ? key.currency0 : key.currency1;
        pendingOwe = amt;
        if (probeMidSwap) {
            // The manager itself, OUTSIDE its window (flag is zero mid-swap):
            // must be rejected like anyone else.
            (bool okMid, ) = msg.sender.call{value: 1}("");
            midSwapPaid = okMid;
        }
        int128 owe = -int128(int256(amt));
        int128 recv = int128(int256(amt));
        return p.zeroForOne
            ? int256((uint256(uint128(owe)) << 128) | uint256(uint128(recv)))
            : int256((uint256(uint128(recv)) << 128) | uint256(uint128(owe)));
    }

    function sync(address currency) external {
        // Native settle takes NO sync — pin the Router's path by refusing it.
        require(currency != address(0), "sync: native currency");
        syncedFlag = true;
        syncedCur = currency;
        syncBal = IERC20Min(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256) {
        if (msg.value > 0 || pendingCur == address(0)) {
            // Native settlement: exactly the owed value, no prior sync.
            require(pendingCur == address(0), "settle: value for erc20 owe");
            require(msg.value == pendingOwe, "settle: value != owed");
            require(!syncedFlag, "settle: sync before native settle");
        } else {
            require(syncedFlag && syncedCur == pendingCur, "settle: not synced");
            require(
                IERC20Min(pendingCur).balanceOf(address(this)) - syncBal >= pendingOwe,
                "settle: unpaid"
            );
            syncedFlag = false;
        }
        uint256 p = pendingOwe;
        pendingOwe = 0;
        return p;
    }

    function take(address currency, address to, uint256 amount) external {
        if (currency == address(0)) {
            if (address(stranger) != address(0)) {
                // INSIDE the open receive() window (expected sender = this
                // manager): a stranger's bare ETH must still be rejected.
                strangerPaid = stranger.tryPay(to);
            }
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "take: eth send failed");
        } else {
            require(IERC20Min(currency).transfer(to, amount), "take: transfer failed");
        }
    }
}

contract RouterV4NativeEthTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockWETH9 wethT;
    MockERC20 tok;
    MockV4ManagerNative mgr;
    Stranger stranger;

    address user = address(0xBEEF);
    uint24  constant FEE = 500;
    int24   constant TS  = 10;
    uint128 constant LIQ = 1e24;

    bytes32 pid; // the NATIVE poolId: (address(0), tok, FEE, TS, hooks=0)

    function setUp() public {
        mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        wethT = new MockWETH9();
        tok = new MockERC20("Token", "TOK");
        stranger = new Stranger();

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        router.setWeth(address(wethT));

        // Native pool state for the QUOTE path (extsload): sqrtP = Q96 (price
        // 1:1), lpFee/protocolFee = 0, liquidity = LIQ — set ONLY at the
        // native pid, so a quote resolving any other pid reads zero state and
        // ExecutionProof.quoted would be 0 (that is what test (d) leans on).
        pid = BPC.computeV4PoolId(address(0), address(tok), FEE, TS, address(0));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));

        // Funding: WETH backing for withdraw (direct mints carry no ETH),
        // manager-side token + ETH inventory, user balances + approvals.
        vm.deal(address(wethT), 1_000e18);
        vm.deal(address(mgr), 1_000e18);
        vm.deal(address(stranger), 1e18);
        tok.mint(address(mgr), 1_000e18);
        wethT.mint(user, 100e18);
        tok.mint(user, 100e18);
        vm.prank(user);
        wethT.approve(address(router), type(uint256).max);
        vm.prank(user);
        tok.approve(address(router), type(uint256).max);
    }

    /// @dev One-leg native-V4 route in WETH-canonical terms. wethIsIn selects
    ///      direction; zeroForOne == wethIsIn because a native pool's
    ///      currency0 is ALWAYS address(0) (sorts first), i.e. the WETH side.
    function _nativeRoute(bool wethIsIn, uint256 amountIn, uint256 expOut)
        private view returns (Route memory route)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0),
            kind: BPC.KIND_V4_NATIVE, fee: FEE, tickSpacing: TS,
            zeroForOne: wethIsIn, stable: false,
            amountIn: amountIn, expectedOut: expOut,
            auxId: bytes32(uint256(uint160(wethIsIn ? address(tok) : address(wethT))))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: wethIsIn ? address(wethT) : address(tok),
            tokenOut: wethIsIn ? address(tok) : address(wethT),
            amountIn: amountIn, expectedOut: expOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: expOut, singleOut: expOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _assertRouterHoldsNothing() private view {
        assertEq(address(router).balance, 0, "router holds ETH");
        assertEq(wethT.balanceOf(address(router)), 0, "router holds WETH");
        assertEq(tok.balanceOf(address(router)), 0, "router holds TOK");
    }

    // ── (a) both directions through a native pool ────────────────────────


    /// @dev A fee do protocolo passou a ser cobrada na ENTRADA (2026-08-21): 28 bps do input
    ///      comprometido, em tokenIn, antes de a rota comecar. Logo a rota preca sobre o LIQUIDO.
    ///      Ver test/FeeEscapeViaBridgeResidual.t.sol para a razao da mudanca.
    function _netIn(uint256 a) internal pure returns (uint256) { return a - (a * 28) / 10_000; }

    function test_Native_WethToToken_SettlesWithValueAndDelivers() public {
        uint256 amt = 10e18;
        uint256 realQuote = BPC.outV3(_netIn(amt), uint160(BPC.Q96), LIQ, FEE, true);
        assertGt(realQuote, 0, "sanity: quotable");
        uint256 mgrEthBefore = address(mgr).balance;

        Route memory route = _nativeRoute(true, amt, realQuote);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amt, 1, user, block.timestamp + 1);

        assertGt(delivered, 0, "must deliver");
        assertEq(tok.balanceOf(user), 100e18 + delivered, "user got tokenOut");
        assertEq(wethT.balanceOf(user), 100e18 - amt, "user paid WETH");
        // The manager was settled in RAW ETH (exactly the owed amount) —
        // the mock's settle() reverts on any other value.
        assertEq(address(mgr).balance, mgrEthBefore + _netIn(amt), "mgr settled in ETH liquido de fee");
        assertEq(mgr.lastKeyId(), pid, "settlement key == native poolId");
        _assertRouterHoldsNothing();
    }

    function test_Native_TokenToWeth_TakesEthAndRewraps() public {
        uint256 amt = 10e18;
        uint256 realQuote = BPC.outV3(_netIn(amt), uint160(BPC.Q96), LIQ, FEE, false);
        assertGt(realQuote, 0, "sanity: quotable");
        uint256 mgrEthBefore = address(mgr).balance;

        Route memory route = _nativeRoute(false, amt, realQuote);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amt, 1, user, block.timestamp + 1);

        assertGt(delivered, 0, "must deliver");
        // The user receives WETH — the raw ETH taken from the manager was
        // wrapped back INSIDE the callback frame, invisible outside the seam.
        assertEq(wethT.balanceOf(user), 100e18 + delivered, "user got WETH out");
        assertEq(tok.balanceOf(user), 100e18 - amt, "user paid TOK");
        assertEq(address(mgr).balance, mgrEthBefore - _netIn(amt), "mgr paid raw ETH liquido de fee");
        assertEq(mgr.lastKeyId(), pid, "settlement key == native poolId");
        _assertRouterHoldsNothing();
    }

    // ── (b) stranger mid-unlock / manager outside its window ─────────────

    function test_Receive_RejectsStrangerInsideOpenWindow_AndMgrOutsideIt() public {
        mgr.setStranger(stranger);
        mgr.setProbeMidSwap(true);
        uint256 amt = 5e18;
        uint256 realQuote = BPC.outV3(_netIn(amt), uint160(BPC.Q96), LIQ, FEE, false);

        // token -> WETH so the take window (expected sender = mgr) opens.
        Route memory route = _nativeRoute(false, amt, realQuote);
        vm.prank(user);
        router.swapExactIn(route, amt, 1, user, block.timestamp + 1);

        assertFalse(mgr.strangerPaid(), "stranger paid the Router inside the open take window");
        assertFalse(mgr.midSwapPaid(), "manager paid the Router outside its window");
        _assertRouterHoldsNothing();
    }

    // ── (c) no unlock active: everything rejected ────────────────────────

    function test_Receive_RejectsAllWhenNoUnlockActive() public {
        vm.deal(address(this), 2e18);
        (bool ok, ) = address(router).call{value: 1e18}("");
        assertFalse(ok, "bare ETH accepted outside an unlock");
        // Zero-value empty calldata also reverts — bit-compatible with the
        // old no-receive() fall-through-to-fallback behaviour.
        (bool ok2, ) = address(router).call("");
        assertFalse(ok2, "empty call accepted outside an unlock");
        assertEq(address(router).balance, 0, "no ETH may lodge in the Router");
    }

    // ── (d) quote == execution poolId parity ─────────────────────────────

    function test_Native_QuoteAndExecutionShareTheNativePoolId() public {
        uint256 amt = 10e18;
        uint256 realQuote = BPC.outV3(_netIn(amt), uint160(BPC.Q96), LIQ, FEE, true);
        Route memory route = _nativeRoute(true, amt, realQuote);

        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(route, amt, 1, user, block.timestamp + 1);

        // Execution side: the settlement key hashed to the native poolId.
        assertEq(mgr.lastKeyId(), pid, "execution key != native poolId");
        // Quote side: ExecutionProof.quoted is the in-frame on-chain quote —
        // pool state exists ONLY at the native pid in the mock, so a nonzero
        // figure proves the quote read the very same id. It must also equal
        // the exact outV3 figure for the state planted at that pid.
        bytes32 sig = keccak256("ExecutionProof(address,address,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            (uint256 quoted, , , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(quoted, realQuote, "quote path resolved a different poolId/state");
        }
        assertTrue(found, "ExecutionProof missing");
    }

    // ── (e) fail-closed on malformed native legs ─────────────────────────

    function test_Native_RevertsWhenNeitherSideIsCanonicalWeth() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(user, 10e18);
        vm.prank(user);
        other.approve(address(router), type(uint256).max);

        // kind 8 leg trading TOK -> OTHER: no side is the canonical WETH, so
        // the native mapping must fail closed (8) instead of unwrapping or
        // wrapping through an attacker-named token.
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0),
            kind: BPC.KIND_V4_NATIVE, fee: FEE, tickSpacing: TS,
            zeroForOne: false, stable: false,
            amountIn: 1e18, expectedOut: 0,
            auxId: bytes32(uint256(uint160(address(other))))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tok), tokenOut: address(other),
            amountIn: 1e18, expectedOut: 0, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(route, 1e18, 1, user, block.timestamp + 1);
    }

    function test_Native_RevertsWhenWethUnwired() public {
        BlazePhoenixRouter bare = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        vm.prank(user);
        wethT.approve(address(bare), type(uint256).max);
        Route memory route = _nativeRoute(true, 1e18, 0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        bare.swapExactIn(route, 1e18, 1, user, block.timestamp + 1);
    }
}
