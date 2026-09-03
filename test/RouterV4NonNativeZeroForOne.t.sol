// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  C7 / item #51 -- Router:1910  `if (key.currency0 == address(0) && zfo) {`
//
//  THE CLAIM
//  ---------
//  The native-ETH JIT seam inside `BlazePhoenixRouter.unlockCallback` may be
//  entered ONLY for a pool key whose currency0 really is the native currency.
//  A NON-native V4 pool swapped zeroForOne must take the ERC20 seam instead:
//
//      sync(tIn) -> safeTransfer(tIn, mgr, owe) -> settle()
//
//  and must NEVER call `IWETH(tIn).withdraw(owe)` on an ordinary ERC20, nor
//  attempt `settle{value: owe}()` with ETH the Router does not hold.
//  The mirror site at Router:1920 carries the same claim for the take side:
//  a non-native leg must take the ERC20, not `take(address(0), ...)` followed
//  by `IWETH(tOut).deposit{value: recv}()`.
//
//  WHY THIS FILE EXISTS (the missing evidence, not a defect)
//  --------------------------------------------------------
//  The MC/DC campaign reported the `key.currency0 == address(0)` sub-condition
//  at Router:1910 as one no test can flip on its own. With `zfo` held TRUE,
//  nothing in the suite reaches that line with `currency0 != address(0)`:
//
//    * test/RouterV4NativeEth.t.sol builds ONLY KIND_V4_NATIVE legs, so
//      currency0 IS address(0) in every one of its executions;
//    * test/RefusalsNeverDriven.t.sol DOES build a KIND_V4 (non-native) leg
//      and does execute it through unlockCallback, but its direction is
//      `zfo = address(vA) < address(vB)` -- a deployment-address accident, not
//      a chosen orientation. Whichever half of the site it exercises is a
//      property of Foundry's nonce ordering, and it silently flips if a
//      contract is added to that setUp. It is also driven by
//      `BubblingV4Manager`, whose `sync`/`settle` are empty no-ops, so even
//      when it does run the ERC20 seam it asserts nothing about it.
//
//  This file pins the orientation BY CONSTRUCTION: the two ERC20s are deployed
//  and then sorted, and the LOWER-sorting one is made tokenIn. `zfo == true`
//  therefore holds regardless of the addresses Foundry hands out.
//
//  EXPECTED AGAINST main @ 6438fe4 -- ALL THREE GREEN. This is a
//  missing-evidence cluster, not a live defect: the guard is written
//  correctly. The value is in the paired mutants (see .github/scripts/mutants.py):
//  when this file was drafted, both arms at Router:1910 and Router:1920 could
//  be deleted with the whole suite still green. They are watched now.
//
//    test_V4NonNative_ZeroForOne_TakesErc20Seam    GREEN today.
//        Kills the Router:1910 mutant. This is the test the site lacks.
//    test_V4NonNative_OneForZero_TakesErc20Seam    GREEN today. CONTROL,
//        and it kills the Router:1920 mutant.
//    test_V4Native_ZeroForOne_TakesNativeSeam      GREEN today. CONTROL.
//
//  THE CONTROL THAT MUST SURVIVE ANY FIX
//  -------------------------------------
//  `test_V4Native_ZeroForOne_TakesNativeSeam` is the control in the sense of
//  section 8 of the briefing: it is green today, it is green under BOTH
//  mutants in this cluster, and it must stay green after any change to
//  Router:1910. A "fix" that bought the non-native property by disabling the
//  native input seam -- narrowing the `currency0` test, or gating it on
//  something the native leg no longer satisfies -- turns it red. It asserts a
//  POSITIVE behaviour (raw ETH of exactly the owed amount reached the
//  manager), not merely "no revert".
//
//  NOTE, so nobody claims more than is true: deleting the `zfo` arm ALONE
//  leaves this test GREEN. With the line reduced to
//  `if (key.currency0 == address(0))`, a native zeroForOne leg still takes the
//  native seam, which is exactly what this test executes. The case that arm
//  protects is native ONE-for-zero -- where the reduced line would call
//  `IWETH(tIn).withdraw` on the ERC20 counterpart -- and that case is pinned
//  in test/RouterV4NativeEth.t.sol by
//  `test_Native_TokenToWeth_TakesEthAndRewraps`, not here.
//
//  WHAT EACH GREEN DEMONSTRATES (no unexplained pass)
//  -------------------------------------------------
//  Every assertion below names a settlement act that only one seam can
//  produce, so none of them can be satisfied by an early revert, an
//  unreachable path or a precondition that was already true:
//
//    ERC20 seam ran   <- `mgr.syncedCur() == tIn` (the mock records the
//                        argument of sync(), and its native settle REFUSES to
//                        run if a sync preceded it) AND the manager's ETH
//                        balance is still zero AND the manager's tIn balance
//                        grew by exactly `owe`.
//    native seam ran  <- the manager's ETH balance grew by exactly the owed
//                        amount (the mock's settle() requires
//                        `msg.value == pendingOwe` and `!syncedFlag`), and
//                        `mgr.syncedCur() == address(0)`, i.e. no sync at all.
//    right pool key   <- `mgr.lastKeyId()` equals the poolId recomputed in the
//                        test from the two sorted currencies.
//
//  HARNESS
//  -------
//  `MockV4ManagerNative` and `MockWETH9` from test/RouterV4NativeEth.t.sol.
//  That is the existing manager that executes a V4 leg through
//  `Router.unlockCallback`, and the only one with FAITHFUL settlement
//  semantics on BOTH seams: it refuses `sync(address(0))`, it requires
//  `msg.value == owed` with NO prior sync on the native settle, and it
//  requires a synced ERC20 balance delta on the ordinary settle. No manager is
//  invented here. Precedent for importing it across test files:
//  test/ConditionAdequacyRouter.t.sol:51 and test/UnvisitedCells.t.sol:23.
//
//  forge test --match-contract RouterV4NonNativeZeroForOne -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4ManagerNative, MockWETH9} from "./RouterV4NativeEth.t.sol";

contract RouterV4NonNativeZeroForOneTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockV4ManagerNative mgr;
    MockWETH9 wethT;

    // The NON-native pair, sorted at construction time. `lo` is currency0 and
    // `hi` is currency1 for every non-native key in this file, so a leg with
    // tokenIn == lo is zeroForOne == true BY CONSTRUCTION and never by
    // deployment luck.
    MockERC20 lo;
    MockERC20 hi;

    // The native counterpart token (the pool is (address(0), nat)).
    MockERC20 nat;

    address user = address(0xBEEF);
    uint24  constant FEE = 500;
    int24   constant TS  = 10;
    uint128 constant LIQ = 1e24;

    bytes32 pidErc20;    // keccak of (lo, hi, FEE, TS, 0)
    bytes32 pidNative;   // keccak of (address(0), nat, FEE, TS, 0)

    uint256 constant START = 100e18;

    function setUp() public {
        mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));

        wethT = new MockWETH9();
        nat = new MockERC20("Native Counterpart", "NAT");

        // Deploy two ordinary ERC20s, then SORT them. Roles are assigned from
        // the sort, so `lo < hi` is an invariant of this fixture.
        MockERC20 tA = new MockERC20("V4 Non-native A", "NNA");
        MockERC20 tB = new MockERC20("V4 Non-native B", "NNB");
        if (address(tA) < address(tB)) { lo = tA; hi = tB; } else { lo = tB; hi = tA; }
        // forge-std has no assertLt(address, address) overload, so compare raw.
        assertTrue(address(lo) < address(hi), "fixture: lo must sort below hi");

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        router.setWeth(address(wethT));

        // Pool state for the in-frame quote (extsload): sqrtP = Q96 (price
        // 1:1), lpFee/protocolFee = 0, liquidity = LIQ. Planted at BOTH ids so
        // every leg in this file carries a real, non-zero measured quote and
        // the per-leg floor is armed rather than failing open.
        pidErc20  = BPC.computeV4PoolId(address(lo), address(hi), FEE, TS, address(0));
        pidNative = BPC.computeV4PoolId(address(0), address(nat), FEE, TS, address(0));
        _plant(pidErc20);
        _plant(pidNative);

        // Manager inventory. NOTE: the manager is deliberately given NO ETH.
        // It only ever RECEIVES ETH here (the native settle), and holding none
        // means the Router:1920 mutant cannot accidentally succeed.
        lo.mint(address(mgr), 1_000e18);
        hi.mint(address(mgr), 1_000e18);
        nat.mint(address(mgr), 1_000e18);
        wethT.mint(address(mgr), 1_000e18);
        // ETH backing for MockWETH9.withdraw (direct mints carry no ETH).
        vm.deal(address(wethT), 1_000e18);

        lo.mint(user, START);
        hi.mint(user, START);
        nat.mint(user, START);
        wethT.mint(user, START);

        vm.startPrank(user);
        lo.approve(address(router), type(uint256).max);
        hi.approve(address(router), type(uint256).max);
        nat.approve(address(router), type(uint256).max);
        wethT.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _plant(bytes32 pid) private {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
    }

    /// @dev The input the leg actually receives: the door charges
    ///      PROTOCOL_FEE_BPS on hop 0, rounded UP, before scaling.
    function _netIn(uint256 a) private pure returns (uint256) {
        return a - BPC.mulDivUp(a, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    /// @dev One-hop, one-leg V4 route. `kind` selects native vs non-native;
    ///      `zfo` must agree with the sorting of (tokenIn, tokenOther), which
    ///      every caller below guarantees by construction.
    function _v4Route(
        bytes32 pid, uint8 kind, address tokenIn, address tokenOther,
        bool zfo, uint256 amountIn, uint256 expOut
    ) private pure returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0),
            kind: kind, fee: FEE, tickSpacing: TS,
            zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: expOut,
            auxId: bytes32(uint256(uint160(tokenOther)))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: tokenIn, tokenOut: tokenOther,
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
        assertEq(lo.balanceOf(address(router)), 0, "router holds LO");
        assertEq(hi.balanceOf(address(router)), 0, "router holds HI");
        assertEq(nat.balanceOf(address(router)), 0, "router holds NAT");
        assertEq(wethT.balanceOf(address(router)), 0, "router holds WETH");
    }

    // =========================================================================
    //  THE TEST THE SITE LACKS
    //  A non-native V4 pool, zeroForOne, settles through the ERC20 seam.
    //  Expected GREEN today. Turns RED under the Router:1910 mutant, which
    //  drops the `key.currency0 == address(0)` arm and so would send this
    //  execution into `IWETH(lo).withdraw(owe)` on a plain ERC20.
    // =========================================================================
    function test_V4NonNative_ZeroForOne_TakesErc20Seam() public {
        uint256 amt = 10e18;
        uint256 net = _netIn(amt);
        uint256 quote = BPC.outV3(net, uint160(BPC.Q96), LIQ, FEE, true, 0);
        assertGt(quote, 0, "sanity: the non-native pool must be quotable");

        uint256 mgrLoBefore = lo.balanceOf(address(mgr));
        uint256 mgrEthBefore = address(mgr).balance;
        assertEq(mgrEthBefore, 0, "fixture: the manager must start with no ETH");

        // Struct built BEFORE the cheatcode (briefing section 1).
        Route memory route = _v4Route(
            pidErc20, BPC.KIND_V4, address(lo), address(hi), true, amt, quote
        );
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amt, 1, user, block.timestamp + 1);

        // -- what this green demonstrates --------------------------------
        // 1. The swap really executed and paid out.
        assertGt(delivered, 0, "must deliver");
        assertEq(hi.balanceOf(user), START + delivered, "user did not receive tokenOut");
        assertEq(lo.balanceOf(user), START - amt, "user did not pay tokenIn");
        // 2. The settlement key was the NON-native key: currency0 is `lo`,
        //    not address(0). This is the sub-condition under test.
        assertEq(mgr.lastKeyId(), pidErc20, "settlement key is not the non-native poolId");
        // 3. The ERC20 seam ran: sync() was called with the ERC20 input.
        //    The mock's native settle refuses to run at all once a sync has
        //    happened, so this witness and the native seam are exclusive.
        assertEq(mgr.syncedCur(), address(lo), "sync() was not called with the ERC20 input");
        // 4. The manager was paid in TOKENS, exactly the leg input, and no
        //    ETH moved anywhere in this transaction.
        assertEq(lo.balanceOf(address(mgr)), mgrLoBefore + net, "manager was not paid in tokenIn");
        assertEq(address(mgr).balance, 0, "ETH reached the manager on a non-native pool");
        assertEq(address(wethT).balance, 1_000e18, "the WETH mock's ETH backing moved");
        _assertRouterHoldsNothing();
    }

    // =========================================================================
    //  CONTROL / mirror direction. A non-native V4 pool, oneForZero.
    //  Expected GREEN today. Also the killer for the Router:1920 mutant,
    //  which drops the `key.currency0 == address(0)` arm on the TAKE side and
    //  so would try `take(address(0), ...)` then `IWETH(hi).deposit{value}`.
    // =========================================================================
    function test_V4NonNative_OneForZero_TakesErc20Seam() public {
        uint256 amt = 10e18;
        uint256 net = _netIn(amt);
        uint256 quote = BPC.outV3(net, uint160(BPC.Q96), LIQ, FEE, false, 0);
        assertGt(quote, 0, "sanity: the non-native pool must be quotable");

        uint256 mgrHiBefore = hi.balanceOf(address(mgr));

        // tokenIn is `hi`, which sorts ABOVE `lo`, so this leg is oneForZero
        // by the same construction that made the previous one zeroForOne.
        Route memory route = _v4Route(
            pidErc20, BPC.KIND_V4, address(hi), address(lo), false, amt, quote
        );
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amt, 1, user, block.timestamp + 1);

        assertGt(delivered, 0, "must deliver");
        assertEq(lo.balanceOf(user), START + delivered, "user did not receive tokenOut");
        assertEq(hi.balanceOf(user), START - amt, "user did not pay tokenIn");
        assertEq(mgr.lastKeyId(), pidErc20, "settlement key is not the non-native poolId");
        assertEq(mgr.syncedCur(), address(hi), "sync() was not called with the ERC20 input");
        assertEq(hi.balanceOf(address(mgr)), mgrHiBefore + net, "manager was not paid in tokenIn");
        assertEq(address(mgr).balance, 0, "ETH reached the manager on a non-native pool");
        _assertRouterHoldsNothing();
    }

    // =========================================================================
    //  CONTROL that must survive any fix to Router:1910.
    //  A NATIVE V4 pool, zeroForOne: the JIT unwrap must still happen and the
    //  manager must still be settled in raw ETH of exactly the owed amount.
    //  Expected GREEN today, and GREEN after any fix. If a change to the
    //  non-native behaviour is bought by weakening the `zfo` arm, this is the
    //  test that goes red.
    // =========================================================================
    function test_V4Native_ZeroForOne_TakesNativeSeam() public {
        uint256 amt = 10e18;
        uint256 net = _netIn(amt);
        uint256 quote = BPC.outV3(net, uint160(BPC.Q96), LIQ, FEE, true, 0);
        assertGt(quote, 0, "sanity: the native pool must be quotable");

        uint256 mgrNatBefore = nat.balanceOf(address(mgr));

        // WETH in, NAT out. currency0 of a native key is ALWAYS address(0)
        // (it sorts first), so the WETH side is zeroForOne == true.
        Route memory route = _v4Route(
            pidNative, BPC.KIND_V4_NATIVE, address(wethT), address(nat), true, amt, quote
        );
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amt, 1, user, block.timestamp + 1);

        assertGt(delivered, 0, "must deliver");
        assertEq(nat.balanceOf(user), START + delivered, "user did not receive tokenOut");
        assertEq(wethT.balanceOf(user), START - amt, "user did not pay WETH");
        assertEq(mgr.lastKeyId(), pidNative, "settlement key is not the native poolId");
        // -- the positive native witnesses -------------------------------
        // The manager holds RAW ETH of exactly the owed amount. The mock's
        // settle() accepts value only when it equals `pendingOwe` and only
        // when NO sync preceded it, so this cannot be produced by any other
        // seam and cannot be produced by an early revert.
        assertEq(address(mgr).balance, net, "manager was not settled in raw ETH");
        assertEq(mgr.syncedCur(), address(0), "a sync ran on the native seam");
        // The output side stayed on the ERC20 take (the pool is native only
        // on currency0), so the counterpart really moved as a token.
        assertEq(nat.balanceOf(address(mgr)), mgrNatBefore - delivered, "manager did not pay tokenOut");
        _assertRouterHoldsNothing();
    }
}
