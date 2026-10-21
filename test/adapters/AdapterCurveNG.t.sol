// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGateWrapper} from "./vendor/BlazePhoenixGateSnapshot.sol";
import {BlazePhoenixAdapterCurveNG} from "../../src/adapters/BlazePhoenixAdapterCurveNG.sol";
import {MockCurveNGFactory, MockCurveNGPool} from "./mocks/MockCurveNG.sol";

/// Answers like a wrapper and is not one.
contract FakeWrapper {
    address public token0;
    address public token1;
    constructor(address a, address b) { (token0, token1) = (a, b); }
}

/// Curve StableSwap-NG adapter behind the real wrapper. Red-first at adapters-1021: every test
/// below was written before the adapter body; the guard each one watches has its mutant in
/// .github/scripts/mutants.py ([520]-[535]).
contract AdapterCurveNGTest is AdapterHarness {
    uint8 internal constant FAM = 1;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;

    MockCurveNGFactory internal factory;
    MockCurveNGPool internal pool;
    BlazePhoenixAdapterCurveNG internal adapter;
    MockERC20 internal other;
    address internal w;

    function setUp() public {
        _tokens();
        other = new MockERC20("O", "O");
        factory = new MockCurveNGFactory();
        // Coins out of address order, so the indices are the factory's and not the sort's.
        pool = _pool(_coins(address(t1), address(other), address(t0)), _u8(0, 0, 0), false);
        adapter = new BlazePhoenixAdapterCurveNG(address(gate), address(factory));
        _accept(FAM, address(adapter));
        w = gate.create(address(t0), address(t1), KEY, abi.encode(address(pool)));
    }

    function _coins(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _u8(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory r) {
        r = new uint8[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _pool(address[] memory coins, uint8[] memory types, bool meta) internal returns (MockCurveNGPool p) {
        uint256[] memory rate = new uint256[](coins.length);
        for (uint256 k; k < coins.length; ++k) {
            // token0 is worth 2 of everything else: an index mix-up changes the output.
            rate[k] = coins[k] == address(t0) ? 2e18 : 1e18;
        }
        p = new MockCurveNGPool(coins, rate);
        for (uint256 k; k < coins.length; ++k) {
            if (coins[k] != 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) MockERC20(coins[k]).mint(address(p), 1_000_000e18);
        }
        p.sync();
        factory.register(address(p), coins, types, meta);
    }

    // ─── execution: PUSH custody, the venue's own number, nothing left behind ───

    function test_CurveNG_Swap_RecipientGetsTheVenueOutput_BothWays() public {
        uint256 want = pool.get_dy(2, 0, 10e18); // token0 -> token1
        assertEq(want, 10e18 * 2 * 9_996 / 10_000);
        assertEq(_swap(w, true, 10e18), want);
        _assertEmpty(address(adapter), w, address(pool));
        want = pool.get_dy(0, 2, 10e18); // token1 -> token0
        assertEq(_swap(w, false, 10e18), want);
        _assertEmpty(address(adapter), w, address(pool));
    }

    function testFuzz_CurveNG_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne) public {
        amt = uint96(bound(amt, 1e6, 1e23)); // dust pays 0 and the venue's limit of 1 reverts; <= 10 % of 1e24
        _swap(w, zeroForOne, amt);
        _assertEmpty(address(adapter), w, address(pool));
    }

    function test_CurveNG_PushHasNoApproveInItsBytecode() public view {
        assertFalse(_hasApproveSelector(address(adapter)));
    }

    /// `_quote` is the one body behind quote and quoteCall (SHARED_QUANTITIES).
    function test_CurveNG_QuoteEqualsQuoteCallEqualsExecution() public {
        BlazePhoenixGateWrapper wr = BlazePhoenixGateWrapper(w);
        (uint256 q, ) = adapter.quote(wr.venuePool(), wr.aux0(), wr.aux1(), false, 7e18);
        (uint256 qw, ) = wr.quote(false, 7e18);
        uint256 qc = adapter.quoteCall(w, false, 7e18);
        assertGt(q, 0);
        assertEq(qc, q);
        assertEq(qw, q);
        assertEq(_swap(w, false, 7e18), q);
    }

    function test_CurveNG_QuoteWhilePoolLocked_IsZero() public {
        (uint256 q, ) = adapter.quote(address(pool), BlazePhoenixGateWrapper(w).aux0(), bytes32(0), true, 1e18);
        assertGt(q, 0); // anti-vacuity: the same call answers when the pool is idle
        pool.setLocked(true);
        (q, ) = adapter.quote(address(pool), BlazePhoenixGateWrapper(w).aux0(), bytes32(0), true, 1e18);
        assertEq(q, 0);
    }

    // ─── who may call ───

    function test_CurveNG_ExecFromNonWrapper_Refused() public {
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(pool), bytes32(uint256(2)), bytes32(0), true, 1e18, address(this));
    }

    /// HUNT-001, the class itself: a contract that answers token0/token1 like a wrapper, names a
    /// pool, and asks the adapter to move what it holds. Only the Gate's record decides
    /// (`_requireWrapper`, which asks `Gate.isWrapper`).
    function test_CurveNG_FakeWrapperWithRealTokens_Refused() public {
        FakeWrapper fake = new FakeWrapper(address(t0), address(t1));
        t0.mint(address(adapter), 1e18);
        bytes32 aux0 = BlazePhoenixGateWrapper(w).aux0(); // read first: prank and expectRevert bind to the next call
        vm.prank(address(fake));
        vm.expectRevert(_aerr(1));
        adapter.exec(address(pool), aux0, bytes32(0), true, 1e18, address(fake));
    }

    function test_CurveNG_HostilePoolReentersExec_Refused() public {
        pool.setMode(3);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(1));
        BlazePhoenixGateWrapper(w).swap(address(this), true, 1e18, 0, "");
    }

    /// PUSH worst case: the pool keeps the input and pays nothing. The wrapper reports 0 (measured
    /// at the recipient, never the pool's return), the adapter holds nothing; the Router's floor
    /// is what refuses the leg.
    function test_CurveNG_HostilePoolKeepsInput_MeasuredZero_AdapterEmpty() public {
        pool.setMode(1);
        assertEq(_swap(w, true, 1e18), 0);
        _assertEmpty(address(adapter), w, address(pool));
    }

    function test_CurveNG_HostilePoolPaysTheAdapter_WrapperRefuses() public {
        pool.setMode(2);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_gerr(14));
        BlazePhoenixGateWrapper(w).swap(address(this), true, 1e18, 0, "");
    }

    // ─── identity and refusals at resolve (asked of the factory, once) ───

    function test_CurveNG_Resolve_PoolNotFromFactory_Refused() public {
        MockCurveNGPool stray = new MockCurveNGPool(_coins(address(t0), address(t1), address(other)), new uint256[](3));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(stray)));
    }

    function test_CurveNG_Resolve_RebasingCoinRefused() public {
        MockCurveNGPool p = _pool(_coins(address(t0), address(t1), address(other)), _u8(0, 0, 2), false);
        vm.expectRevert(_aerr(4));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p)));
    }

    function test_CurveNG_Resolve_OracleCoinRefused() public {
        MockCurveNGPool p = _pool(_coins(address(t0), address(t1), address(other)), _u8(0, 1, 0), false);
        vm.expectRevert(_aerr(4));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p)));
    }

    function test_CurveNG_Resolve_ERC4626CoinAccepted() public {
        MockCurveNGPool p = _pool(_coins(address(t0), address(t1), address(other)), _u8(3, 0, 0), false);
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p)));
        assertEq(BlazePhoenixGateWrapper(w2).venuePool(), address(p));
    }

    function test_CurveNG_Resolve_RawEthCoinRefused() public {
        MockCurveNGPool p = _pool(_coins(address(t0), address(t1), 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), _u8(0, 0, 0), false);
        vm.expectRevert(_aerr(4));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p)));
    }

    function test_CurveNG_Resolve_MetapoolRefused() public {
        MockCurveNGPool p = _pool(_coins(address(t0), address(t1), address(other)), _u8(0, 0, 0), true);
        vm.expectRevert(_aerr(4));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p)));
    }

    function test_CurveNG_Resolve_PairNotInPool_Refused() public {
        MockERC20 x = new MockERC20("X", "X");
        MockCurveNGPool p = _pool(_coins(address(t0), address(x), address(other)), _u8(0, 0, 0), false);
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p)));
    }

    /// The factory's two lists must describe the same coins: a type list of another length is
    /// not a record of this pool.
    function test_CurveNG_Resolve_TypesLengthMismatch_Refused() public {
        address[] memory coins = _coins(address(t0), address(t1), address(other));
        MockCurveNGPool p = _pool(coins, _u8(0, 0, 0), false);
        uint8[] memory four = new uint8[](4);
        factory.register(address(p), coins, four, false);
        vm.expectRevert(_aerr(4));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(p)));
    }

    function test_CurveNG_Resolve_MalformedHint_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(pool), uint256(0)));
    }
}
