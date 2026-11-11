// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {QuoteWorld, BlazePhoenixQuoter} from "../QuoteWorld.sol";
import {BlazePhoenixCore as BPC, Route, Hop} from "../../src/BlazePhoenixCore.sol";
import {IPermit2} from "../../src/BlazePhoenixRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockWETH} from "../RouterNativeEntry.t.sol";
import {SealFeeToken} from "../Seal1021FeeNeverBlocks.t.sol";

/// @notice THE DOOR GAS LEDGER: what one transaction through each Router door costs, by door, by
///         mode and by hop count, on constant-product (V2) pools.
///
/// A WINDOW IS ONE TOP-LEVEL CALL. Each window is the door call alone, made right after its prank
/// and read by `vm.snapshotGasLastFrame` before anything else is called. These tests run in
/// isolation mode (`isolate = true`, set in foundry.toml for the default and release profiles and
/// asserted in `setUp`), where every top-level call of a test is its own transaction, so the frame
/// is the whole transaction: the 21 000 of intrinsic gas, the calldata, and every account and slot
/// cold. The entries end in `_tx` for that reason, and a run without isolation does not match them.
///
/// THE BUDGET IS THE SNAPSHOT. Each test writes one group, named after the test, to
/// snapshots/<test>.json, so a partial run (--match-test) never rewrites another test's entries.
/// With FORGE_SNAPSHOT_CHECK=true a run fails on any difference from the committed numbers, in
/// either direction. There is no ceiling here: a number moves only with a re-emitted snapshot.
///
/// MODES:
///   - quoted: empty registry; Quoter.previewPlan, then swapExactIn of the route it serves.
///   - quoted again: the same, after a first swapBestExactIn of the same pair and amount has been
///     committed. Nothing records a plan, so the first trade leaves state, not a plan: the
///     registry rows of the pools it crossed, which the measured swap refreshes where quoted
///     inserts them, and the balances it paid into (the pools, the fee treasury). The first trade
///     is another account's, so the payer's own balance slots start as in quoted.
///   - solve: empty registry; swapBestExactIn, which finds its route inside the transaction.
/// The other doors (Permit2, native ETH, token shapes, claimFee) run on the seeded registry with
/// hand-built routes of one leg per hop, so a window differs from its sibling by its door and by
/// the test double that door calls: the native window pays MockWETH, and the Permit2 window pays
/// MockPermit2, which checks no signature. Those two are door plus mock, not door plus the
/// canonical WETH9 or Permit2.
/// One hop ends in the bridge coin B, and the fee comes out of the output; two hops cross B, and
/// the fee comes out of the second hop's input (Core.feeCalendar).
contract DoorGasLedgerTest is QuoteWorld {
    /// The input of every window: 1 % of AB1's A reserve. An input, not a budget.
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
    }

    /// A test key for the Permit2 signature (see `_permit2Window`).
    uint256 internal constant PERMIT_SIGNER = uint256(keccak256("DoorGasLedger.permit2.signer"));

    // ─── swapExactIn of the quoted route ─────────────────────────────────────

    function test_Gas_SwapExactIn_Quoted_OneHop() public {
        _world(false);
        Route memory r = _quoted(address(A), address(B), 1);
        _fund(A, address(router));
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMOUNT, 1, user, block.timestamp + 1);
        vm.snapshotGasLastFrame("test_Gas_SwapExactIn_Quoted_OneHop", "swapExactIn_tx");
        assertGt(out, 0, "the door delivered");
    }

    function test_Gas_SwapExactIn_Quoted_TwoHops() public {
        _world(false);
        Route memory r = _quoted(address(A), address(C), 2);
        _fund(A, address(router));
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMOUNT, 1, user, block.timestamp + 1);
        vm.snapshotGasLastFrame("test_Gas_SwapExactIn_Quoted_TwoHops", "swapExactIn_tx");
        assertGt(out, 0, "the door delivered");
    }

    function test_Gas_SwapExactIn_QuotedAgain_OneHop() public {
        _world(false);
        _firstTrade(A, B);
        assertTrue(_recorded(AB1, A, B), "the first trade left AB1's row");
        Route memory r = _quoted(address(A), address(B), 1);
        assertEq(r.hops[0].legs[0].pool, address(AB1), "the measured swap crosses the recorded pool");
        _fund(A, address(router));
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMOUNT, 1, user, block.timestamp + 1);
        vm.snapshotGasLastFrame("test_Gas_SwapExactIn_QuotedAgain_OneHop", "swapExactIn_tx");
        assertGt(out, 0, "the door delivered");
    }

    function test_Gas_SwapExactIn_QuotedAgain_TwoHops() public {
        _world(false);
        _firstTrade(A, C);
        assertTrue(_recorded(AB1, A, B) && _recorded(BC1, B, C), "the first trade left both rows");
        Route memory r = _quoted(address(A), address(C), 2);
        assertEq(r.hops[0].legs[0].pool, address(AB1), "hop 0 crosses the recorded pool");
        assertEq(r.hops[1].legs[0].pool, address(BC1), "hop 1 crosses the recorded pool");
        _fund(A, address(router));
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMOUNT, 1, user, block.timestamp + 1);
        vm.snapshotGasLastFrame("test_Gas_SwapExactIn_QuotedAgain_TwoHops", "swapExactIn_tx");
        assertGt(out, 0, "the door delivered");
    }

    // ─── swapBestExactIn: the route is solved inside the transaction ─────────

    function test_Gas_SwapBestExactIn_Solve_OneHop() public {
        _world(false);
        _shape(solver.findBestRoutePlan(address(A), address(B), AMOUNT).best, 1);
        _fund(A, address(router));
        vm.prank(user);
        uint256 out = router.swapBestExactIn(address(A), address(B), AMOUNT, 1, user, block.timestamp + 1);
        vm.snapshotGasLastFrame("test_Gas_SwapBestExactIn_Solve_OneHop", "swapBestExactIn_tx");
        assertGt(out, 0, "the door delivered");
    }

    function test_Gas_SwapBestExactIn_Solve_TwoHops() public {
        _world(false);
        _shape(solver.findBestRoutePlan(address(A), address(C), AMOUNT).best, 2);
        _fund(A, address(router));
        vm.prank(user);
        uint256 out = router.swapBestExactIn(address(A), address(C), AMOUNT, 1, user, block.timestamp + 1);
        vm.snapshotGasLastFrame("test_Gas_SwapBestExactIn_Solve_TwoHops", "swapBestExactIn_tx");
        assertGt(out, 0, "the door delivered");
    }

    // ─── swapExactInWithPermit2 ──────────────────────────────────────────────

    function test_Gas_SwapExactInWithPermit2_OneHop() public {
        _world(true);
        _permit2Window("test_Gas_SwapExactInWithPermit2_OneHop", _handRoute(AB1, address(A), address(B), AMOUNT));
    }

    function test_Gas_SwapExactInWithPermit2_TwoHops() public {
        _world(true);
        _permit2Window(
            "test_Gas_SwapExactInWithPermit2_TwoHops",
            _twoHops(_handRoute(AB1, address(A), address(B), AMOUNT), BC1, address(C))
        );
    }

    // ─── swapExactInNative: ETH at the entry ─────────────────────────────────

    function test_Gas_SwapExactInNative_EthIn_OneHop() public {
        _nativeWindow("test_Gas_SwapExactInNative_EthIn_OneHop", false);
    }

    function test_Gas_SwapExactInNative_EthIn_TwoHops() public {
        _nativeWindow("test_Gas_SwapExactInNative_EthIn_TwoHops", true);
    }

    // ─── swapExactIn by token shape ──────────────────────────────────────────

    /// Three windows, one per shape of the input token: plain, fee-on-transfer (1 % on every
    /// transfer) and no-return-data (transfer, transferFrom and approve return nothing). Each
    /// starts from the same state, and the token and its pool are created after that state, so
    /// they take the same addresses: the windows differ by the token's transfer shape alone.
    function test_Gas_SwapExactIn_TokenShapes_OneHop() public {
        _world(true);
        string[3] memory entry = ["swapExactIn_plain_tx", "swapExactIn_feeOnTransfer_tx", "swapExactIn_noReturnData_tx"];
        uint256[3] memory out;
        address[3] memory born;
        for (uint256 shape; shape < 3; ++shape) {
            uint256 base = vm.snapshotState();
            MockERC20 x = new MockERC20("X", "X");
            if (shape == 1) x.setFeeOnTransferBps(100);
            if (shape == 2) x.setNoReturnData(true);
            born[shape] = address(x);
            MockV2Pair p = _likeAB1(address(x), address(B));
            _fund(x, address(router));
            Route memory r = _handRoute(p, address(x), address(B), AMOUNT);
            vm.prank(user);
            out[shape] = router.swapExactIn(r, AMOUNT, 1, user, block.timestamp + 1);
            vm.snapshotGasLastFrame("test_Gas_SwapExactIn_TokenShapes_OneHop", entry[shape]);
            vm.revertToState(base);
        }
        assertTrue(born[1] == born[0] && born[2] == born[0], "every shape's token was born at the same address");
        assertGt(out[0], 0, "the door delivered");
        assertEq(out[2], out[0], "a token that returns nothing trades as the plain one");
        assertLt(out[1], out[0], "the taxed token delivered less: the pull measured the tax");
    }

    // ─── claimFee ────────────────────────────────────────────────────────────

    /// One swap books the fee a treasury refused, then the treasury claims it. The route S -> C
    /// crosses no bridge, so the fee comes out of hop 0's input in S (Core.feeCalendar), and S
    /// refuses the push to treasury 1 while the swap runs.
    function test_Gas_ClaimFee_AfterOneSwap() public {
        _world(true);
        SealFeeToken s = new SealFeeToken();
        MockV2Pair sc = _likeAB1(address(s), address(C));
        address t1 = router.treasury1();
        s.setRefuse(t1, 1);
        s.mint(user, AMOUNT);
        _approve(user, address(s), address(router));
        Route memory r = _handRoute(sc, address(s), address(C), AMOUNT);
        vm.prank(user);
        router.swapExactIn(r, AMOUNT, 1, user, block.timestamp + 1);
        uint256 owed = router.owed(address(s), 0);
        assertGt(owed, 0, "the refused push was booked");
        s.setRefuse(t1, 0);
        vm.prank(t1);
        router.claimFee(address(s));
        vm.snapshotGasLastFrame("test_Gas_ClaimFee_AfterOneSwap", "claimFee_tx");
        assertEq(s.balanceOf(t1), owed, "the treasury received what it was owed");
        assertEq(router.owed(address(s), 0), 0, "nothing is owed after the claim");
    }

    // ─── windows shared by the two hop counts ────────────────────────────────

    /// The mock does not verify signatures (MockPermit2), so the window holds the Router's side
    /// and the mock's transferFrom: a real Permit2's signature check and nonce write are not in
    /// it. The 65 bytes are an ECDSA signature by a test key over the permit, so the calldata is
    /// shaped like a real one.
    function _permit2Window(string memory group, Route memory r) internal {
        MockPermit2 p2 = new MockPermit2();
        router.setPermit2(address(p2));
        _fund(A, address(p2));
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(A), amount: AMOUNT}),
            nonce: 0,
            deadline: block.timestamp + 1
        });
        (uint8 v, bytes32 sr, bytes32 ss) = vm.sign(PERMIT_SIGNER, keccak256(abi.encode(permit)));
        bytes memory signature = abi.encodePacked(sr, ss, v);
        vm.prank(user);
        uint256 out = router.swapExactInWithPermit2(r, AMOUNT, 1, user, block.timestamp + 1, permit, signature);
        vm.snapshotGasLastFrame(group, "swapExactInWithPermit2_tx");
        assertGt(out, 0, "the door delivered");
    }

    /// The suite's own wiring (RouterNativeEntry): WETH set on the Router, the payer holds ETH.
    function _nativeWindow(string memory group, bool twoHops) internal {
        _world(true);
        MockWETH w = new MockWETH();
        router.setWeth(address(w));
        Route memory r = _handRoute(_likeAB1(address(w), address(B)), address(w), address(B), AMOUNT);
        if (twoHops) r = _twoHops(r, BC1, address(C));
        vm.deal(user, AMOUNT);
        vm.prank(user);
        uint256 out = router.swapExactInNative{value: AMOUNT}(r, 1, user, block.timestamp + 1);
        vm.snapshotGasLastFrame(group, "swapExactInNative_tx");
        assertGt(out, 0, "the door delivered");
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    /// The route the Quoter serves for AMOUNT, checked to be executable and one leg per hop.
    function _quoted(address tIn, address tOut, uint256 hops) internal view returns (Route memory r) {
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(tIn, tOut, AMOUNT);
        assertTrue(pv.canExecute, "the quote is executable");
        r = pv.route;
        _shape(r, hops);
    }

    function _shape(Route memory r, uint256 hops) internal pure {
        assertEq(r.hops.length, hops, "hop count");
        for (uint256 h; h < hops; ++h) assertEq(r.hops[h].legs.length, 1, "one leg per hop");
    }

    /// AMOUNT of `token` to the user, who approves `spender` for it.
    function _fund(MockERC20 token, address spender) internal {
        token.mint(user, AMOUNT);
        _approve(user, address(token), spender);
    }

    /// A standing approval by low-level call: a typed call fails to decode the empty return of a
    /// token that returns nothing.
    function _approve(address who, address token, address spender) internal {
        vm.prank(who);
        (bool ok, ) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        assertTrue(ok, "approve");
    }

    /// Another account's committed swapBestExactIn of AMOUNT, the trade that precedes quoted again.
    function _firstTrade(MockERC20 tIn, MockERC20 tOut) internal {
        tIn.mint(whale, AMOUNT);
        _approve(whale, address(tIn), address(router));
        vm.prank(whale);
        router.swapBestExactIn(address(tIn), address(tOut), AMOUNT, 1, whale, block.timestamp + 1);
    }

    function _recorded(MockV2Pair p, MockERC20 x, MockERC20 y) internal view returns (bool) {
        return hub.getSlot(hub.keyOf(address(p), address(x), address(y))) != 0;
    }

    /// A pool of x against y as deep as AB1 (x in A's place, y in B's), seeded in the registry.
    function _likeAB1(address x, address y) internal returns (MockV2Pair p) {
        (uint112 r0, uint112 r1, ) = AB1.getReserves();
        bool aIs0 = AB1.token0() == address(A);
        p = _pool(MockERC20(x), MockERC20(y), aIs0 ? r0 : r1, aIs0 ? r1 : r0);
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), x, y);
    }

    /// `first`, then its output through `next` into tOut on the amount hop 0 expects to deliver.
    /// The Router rescales hop 1 to what hop 0 really delivered net of the fee.
    function _twoHops(Route memory first, MockV2Pair next, address tOut) internal view returns (Route memory r) {
        Hop[] memory hops = new Hop[](2);
        hops[0] = first.hops[0];
        r = _handRoute(next, hops[0].tokenOut, tOut, hops[0].expectedOut);
        hops[1] = r.hops[0];
        r.hops = hops;
    }
}
