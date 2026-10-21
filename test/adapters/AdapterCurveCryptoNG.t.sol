// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixAdapterCurveCryptoNG} from "../../src/adapters/BlazePhoenixAdapterCurveCryptoNG.sol";
import {MockCurveCryptoNGFactory, MockCurveCryptoNGPool, MockCurveTricryptoWETHPool} from "./mocks/MockCurveCryptoNG.sol";
import {MockCurveNGFactory} from "./mocks/MockCurveNG.sol";
import {FakeWrapper} from "./AdapterCurveNG.t.sol";

/// Curve crypto NG adapter (Twocrypto-NG incl. FXSwap, Tricrypto-NG) behind the real wrapper.
/// Two factories, two adapters: the 2-coin one (address[2] record) carries the main wrapper `w`,
/// the 3-coin one (address[3]) `w3`. Each guard's mutant is in .github/scripts/mutants.py
/// ([650]-[657]).
contract AdapterCurveCryptoNGTest is AdapterHarness {
    uint8 internal constant FAM = 4;
    uint8 internal constant FAM3 = 5;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    uint24 internal constant KEY3 = uint24(FAM3) << 16 | 1;

    MockCurveCryptoNGFactory internal factory;
    MockCurveCryptoNGFactory internal factory3;
    MockCurveCryptoNGPool internal pool;
    MockCurveCryptoNGPool internal pool3;
    BlazePhoenixAdapterCurveCryptoNG internal adapter;
    BlazePhoenixAdapterCurveCryptoNG internal adapter3;
    MockERC20 internal other;
    address internal w;
    address internal w3;

    function setUp() public {
        _tokens();
        other = new MockERC20("O", "O");
        factory = new MockCurveCryptoNGFactory(2);
        factory3 = new MockCurveCryptoNGFactory(3);
        // Coins out of address order, so the indices are the factory's and not the sort's.
        pool = _pool(factory, _c2(address(t1), address(t0)));
        pool3 = _pool(factory3, _c3(address(t1), address(other), address(t0)));
        adapter = new BlazePhoenixAdapterCurveCryptoNG(address(gate), address(factory));
        adapter3 = new BlazePhoenixAdapterCurveCryptoNG(address(gate), address(factory3));
        _accept(FAM, address(adapter));
        _accept(FAM3, address(adapter3));
        w = gate.create(address(t0), address(t1), KEY, abi.encode(address(pool)));
        w3 = gate.create(address(t0), address(t1), KEY3, abi.encode(address(pool3)));
    }

    function _c2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _c3(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _pool(MockCurveCryptoNGFactory f, address[] memory coins) internal returns (MockCurveCryptoNGPool p) {
        uint256[] memory rate = new uint256[](coins.length);
        for (uint256 k; k < coins.length; ++k) {
            // token0 is worth 2 of everything else: an index mix-up changes the output.
            rate[k] = coins[k] == address(t0) ? 2e18 : 1e18;
        }
        p = new MockCurveCryptoNGPool(coins, rate);
        for (uint256 k; k < coins.length; ++k) MockERC20(coins[k]).mint(address(p), 1_000_000e18);
        p.sync();
        f.register(address(p), coins);
    }

    // ─── execution: PUSH custody, the venue's own number, nothing left behind ───

    function test_CryptoNG_Two_Swap_RecipientGetsTheVenueOutput_BothWays() public {
        uint256 want = pool.get_dy(1, 0, 10e18); // token0 (index 1) -> token1 (index 0)
        assertEq(want, 10e18 * 2 * 9_995 / 10_000);
        assertEq(_swap(w, true, 10e18), want);
        _assertEmpty(address(adapter), w, address(pool));
        want = pool.get_dy(0, 1, 10e18);
        assertEq(_swap(w, false, 10e18), want);
        _assertEmpty(address(adapter), w, address(pool));
    }

    function test_CryptoNG_Tri_Swap_RecipientGetsTheVenueOutput_BothWays() public {
        uint256 want = pool3.get_dy(2, 0, 10e18);
        assertEq(want, 10e18 * 2 * 9_995 / 10_000);
        assertEq(_swap(w3, true, 10e18), want);
        _assertEmpty(address(adapter3), w3, address(pool3));
        want = pool3.get_dy(0, 2, 10e18);
        assertEq(_swap(w3, false, 10e18), want);
        _assertEmpty(address(adapter3), w3, address(pool3));
    }

    function testFuzz_CryptoNG_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne, bool three) public {
        amt = uint96(bound(amt, 1e6, 1e23)); // <= 10 % of the 1e24 the pool holds
        (address ww, address a, address p) = three
            ? (w3, address(adapter3), address(pool3))
            : (w, address(adapter), address(pool));
        _swap(ww, zeroForOne, amt);
        _assertEmpty(a, ww, p);
    }

    function test_CryptoNG_PushHasNoApproveInItsBytecode() public view {
        assertFalse(_hasApproveSelector(address(adapter)));
    }

    /// `_quote` is the one body behind quote and quoteCall (SHARED_QUANTITIES).
    function test_CryptoNG_QuoteEqualsQuoteCallEqualsExecution() public {
        BlazePhoenixGateWrapper wr = BlazePhoenixGateWrapper(w);
        (uint256 q, ) = adapter.quote(wr.venuePool(), wr.aux0(), wr.aux1(), false, 7e18);
        (uint256 qw, ) = wr.quote(false, 7e18);
        uint256 qc = wr.quoteCall(false, 7e18);
        assertGt(q, 0);
        assertEq(qc, q);
        assertEq(qw, q);
        assertEq(_swap(w, false, 7e18), q);
    }

    function test_CryptoNG_QuoteWhilePoolLocked_IsZero() public {
        bytes32 aux0 = BlazePhoenixGateWrapper(w).aux0();
        (uint256 q, ) = adapter.quote(address(pool), aux0, bytes32(0), true, 1e18);
        assertGt(q, 0); // anti-vacuity: the same call answers when the pool is idle
        pool.setLocked(true);
        (q, ) = adapter.quote(address(pool), aux0, bytes32(0), true, 1e18);
        assertEq(q, 0);
    }

    // ─── who may call ───

    function test_CryptoNG_ExecFromNonWrapper_Refused() public {
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(pool), bytes32(uint256(1)), bytes32(0), true, 1e18, address(this));
    }

    /// HUNT-001, the class itself: a contract answering token0/token1 like a wrapper names a pool
    /// and asks the adapter to move what it holds. Only the Gate's record decides (`_requireWrapper`).
    function test_CryptoNG_FakeWrapperWithRealTokens_Refused() public {
        FakeWrapper fake = new FakeWrapper(address(t0), address(t1));
        t0.mint(address(adapter), 1e18);
        bytes32 aux0 = BlazePhoenixGateWrapper(w).aux0(); // read first: prank and expectRevert bind to the next call
        vm.prank(address(fake));
        vm.expectRevert(_aerr(1));
        adapter.exec(address(pool), aux0, bytes32(0), true, 1e18, address(fake));
    }

    function test_CryptoNG_HostilePoolReentersExec_Refused() public {
        pool.setMode(3);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(1));
        BlazePhoenixGateWrapper(w).swap(address(this), true, 1e18, 0, "");
    }

    /// PUSH worst case: the pool keeps the input and pays nothing. Measured 0 at the recipient,
    /// the adapter holds nothing; the Router's floor is what refuses the leg.
    function test_CryptoNG_HostilePoolKeepsInput_MeasuredZero_AdapterEmpty() public {
        pool.setMode(1);
        assertEq(_swap(w, true, 1e18), 0);
        _assertEmpty(address(adapter), w, address(pool));
    }

    function test_CryptoNG_HostilePoolPaysTheAdapter_WrapperRefuses() public {
        pool.setMode(2);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_gerr(14));
        BlazePhoenixGateWrapper(w).swap(address(this), true, 1e18, 0, "");
    }

    // ─── identity and refusals at resolve (asked of the factory, once) ───

    function test_CryptoNG_Resolve_PoolNotFromFactory_Refused() public {
        MockCurveCryptoNGPool stray = new MockCurveCryptoNGPool(_c2(address(t0), address(t1)), new uint256[](2));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(stray)));
    }

    /// CurveTricryptoOptimizedWETH has `WETH20()` and no `exchange_received`: refused at resolve,
    /// not left to fail at every exec.
    function test_CryptoNG_Resolve_NativeTricryptoRefused() public {
        MockCurveTricryptoWETHPool p = new MockCurveTricryptoWETHPool(address(other));
        factory3.register(address(p), _c3(address(t0), address(t1), address(other)));
        vm.expectRevert(_aerr(4));
        gate.create(address(t0), address(t1), KEY3 + 1, abi.encode(address(p)));
    }

    /// A deployment that names the StableSwap-NG factory (same `get_coins(address)` selector,
    /// dynamic array: offset, length, coins) must not read the offset word as coin 0.
    function test_CryptoNG_Resolve_StableSwapFactoryIsNotACryptoRecord_Refused() public {
        MockCurveNGFactory ng = new MockCurveNGFactory();
        BlazePhoenixAdapterCurveCryptoNG a = new BlazePhoenixAdapterCurveCryptoNG(address(gate), address(ng));
        _accept(6, address(a));
        ng.register(address(pool3), _c3(address(t1), address(other), address(t0)), new uint8[](3), false);
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), uint24(6) << 16 | 1, abi.encode(address(pool3)));
    }

    /// A record word with high bits is not an address: refused, not truncated into one.
    function test_CryptoNG_Resolve_DirtyFactoryWord_Refused() public {
        // coin 0 is token0 itself, so a truncating read would resolve the pair.
        MockCurveCryptoNGPool p = _pool(factory, _c2(address(t0), address(t1)));
        factory.setDirty(true);
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p)));
    }

    function test_CryptoNG_Resolve_PairNotInPool_Refused() public {
        MockERC20 x = new MockERC20("X", "X");
        MockCurveCryptoNGPool p = _pool(factory3, _c3(address(t0), address(x), address(other)));
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY3 + 1, abi.encode(address(p)));
    }

    /// A valid pool in the first word and a second word: the hint must be exactly one word.
    function test_CryptoNG_Resolve_MalformedHint_Refused() public {
        MockCurveCryptoNGPool p = _pool(factory, _c2(address(t1), address(t0)));
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p), uint256(0)));
    }
}
