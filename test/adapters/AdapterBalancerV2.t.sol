// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixAdapterBalancerV2} from "../../src/adapters/BlazePhoenixAdapterBalancerV2.sol";
import {MockBalancerFactory, MockBalancerV2Vault} from "./mocks/MockBalancerV2.sol";
import {MockERC20Dec} from "./mocks/MockERC20Dec.sol";

/// Balancer V2 adapter behind the real wrapper: PULL custody against a Vault-faithful mock.
contract AdapterBalancerV2Test is AdapterHarness {
    uint8 internal constant FAM = 2;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    bytes32 internal constant PID = keccak256("pool-1");

    MockBalancerV2Vault internal vault;
    MockBalancerFactory internal f0;
    MockBalancerFactory internal f3;
    BlazePhoenixAdapterBalancerV2 internal adapter;
    address internal w;

    function setUp() public {
        _tokens();
        vault = new MockBalancerV2Vault();
        f0 = new MockBalancerFactory();
        f3 = new MockBalancerFactory();
        t0.mint(address(vault), 1_000_000e18);
        t1.mint(address(vault), 1_000_000e18);
        _register(PID, address(0xB001), f0, address(t0), address(t1));
        adapter = new BlazePhoenixAdapterBalancerV2(
            address(gate), address(vault), [address(f0), address(0), address(0), address(f3)]
        );
        _accept(FAM, address(adapter));
        w = gate.create(address(t0), address(t1), KEY, abi.encode(PID));
    }

    function _register(bytes32 id, address pool, MockBalancerFactory f, address a, address b) internal {
        address[] memory t = new address[](2);
        (t[0], t[1]) = (a, b);
        vault.registerPool(id, pool, t);
        if (address(f) != address(0)) f.add(pool);
    }

    // ─── execution: exact approval, fully consumed, recipient paid by the Vault ───

    function test_BalV2_Swap_ExactApproval_RecipientPaid_NothingLeft() public {
        assertEq(_swap(w, true, 10e18), 10e18 * 9_970 / 10_000);
        assertEq(vault.allowanceSeen(), 10e18, "approval is exactly the input");
        _assertEmpty(address(adapter), w, address(vault));
        assertEq(vault.internalBalance(address(this), address(t1)), 0, "never internal balance");
        assertEq(_swap(w, false, 3e18), 3e18 * 9_970 / 10_000);
        _assertEmpty(address(adapter), w, address(vault));
    }

    function testFuzz_BalV2_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne) public {
        amt = uint96(bound(amt, 1e6, 1e23)); // dust pays 0 and the venue's limit of 1 reverts; <= 10 % of 1e24
        _swap(w, zeroForOne, amt);
        _assertEmpty(address(adapter), w, address(vault));
    }

    function test_BalV2_QuoteCallEqualsExecution_QuoteIsZero() public {
        vault.setRateOf(address(t1), 9_000); // t1->t0 prices apart: a reversed pair is seen ([610])
        BlazePhoenixGateWrapper wr = BlazePhoenixGateWrapper(w);
        (uint256 q, uint256 d) = wr.quote(true, 5e18);
        assertEq(q, 0);
        assertEq(d, 1_000_000e18, "depth18: the pool's long side in the Vault (adapter-depth-1021)");
        uint256 qc = wr.quoteCall(true, 5e18);
        assertGt(qc, 0);
        assertEq(qc, 5e18 * 9_970 / 10_000, "quoteCall prices t0->t1");
        assertEq(_swap(w, true, 5e18), qc);
    }

    // ─── hostile Vault (PULL) — HUNT-001: an allowance must never outlive the call ───

    function test_BalV2_HostileVaultPaysWithoutPulling_Refused() public {
        vault.setMode(1);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(5));
        BlazePhoenixGateWrapper(w).swap(address(this), true, 1e18, 0, "");
    }

    function test_BalV2_HostileVaultPullsLess_Refused() public {
        vault.setMode(2);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(5));
        BlazePhoenixGateWrapper(w).swap(address(this), true, 1e18, 0, "");
    }

    // ─── who may call ───

    function test_BalV2_ExecFromNonWrapper_Refused() public {
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(vault), PID, bytes32(0), true, 1e18, address(this));
    }

    /// `_requireWrapper`: the pair a query prices is the calling wrapper's, so a non-wrapper is refused.
    function test_BalV2_QuoteCallOnNonWrapper_Refused() public {
        vm.expectRevert(_aerr(1));
        adapter.quoteCall(address(vault), PID, bytes32(0), true, 1e18);
    }

    // ─── identity at resolve: the Vault and a listed factory vouch ───

    function test_BalV2_Resolve_UnknownPoolId_Refused() public {
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(keccak256("nope")));
    }

    function test_BalV2_Resolve_PoolFromUnlistedFactory_Refused() public {
        bytes32 id = keccak256("stray");
        _register(id, address(0xB002), new MockBalancerFactory(), address(t0), address(t1));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(id));
    }

    function test_BalV2_Resolve_LastFactorySlotCounts() public {
        bytes32 id = keccak256("pool-f3");
        _register(id, address(0xB003), f3, address(t1), address(t0));
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(id));
        assertEq(BlazePhoenixGateWrapper(w2).aux0(), id);
        assertEq(BlazePhoenixGateWrapper(w2).venuePool(), address(vault));
    }

    function test_BalV2_Resolve_PairNotInPool_Refused() public {
        bytes32 id = keccak256("other");
        MockERC20 x = new MockERC20("X", "X");
        _register(id, address(0xB004), f0, address(t0), address(x));
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(id));
    }

    function test_BalV2_Resolve_MalformedHint_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(PID, uint8(0)));
    }

    // ─── depth18: the Vault's balances of the pool, the larger side in 18 decimals (adapter-depth-1021) ───

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }

    /// Quantity: adapter depth18 (Balancer V2) = max over the wrapper's pair of to18 of
    /// `Vault.getPoolTokens(poolId)` balances: the pool's balances in the Vault's accounting, not
    /// the Vault's holdings, for any amtIn and either direction; what Gate.vitalOf reads.
    function test_BalV2_Depth18_IsThePoolsLongSideInTheVault() public {
        vault.setPoolBalances(PID, _two(400e18, 700e18)); // t0, t1; the Vault holds 1e24 of each
        BlazePhoenixGateWrapper wr = BlazePhoenixGateWrapper(w);
        (uint256 q, uint256 d) = wr.quote(true, 0);
        assertEq(q, 0, "no view quote");
        assertEq(d, 700e18, "the long side of the pool's balances");
        (, uint256 d2) = wr.quote(false, 5e18);
        assertEq(d2, d, "depth18 does not depend on amtIn or direction");
        (, uint256 dv, ) = gate.vitalOf(w);
        assertEq(dv, d, "vitalOf reads the word below the mass held");
    }

    /// Quantity: adapter depth18 (Balancer V2) normalises by each token's decimals before the max.
    function test_BalV2_Depth18_NormalisesDecimalsBeforeTheMax() public {
        MockERC20Dec d6 = new MockERC20Dec(6);
        bytes32 pid6 = keccak256("pool-6");
        _register(pid6, address(0xB006), f0, address(d6), address(t0));
        vault.setPoolBalances(pid6, _two(2_000_000e6, 1_000_000e18));
        address w6 = gate.create(address(d6), address(t0), KEY, abi.encode(pid6));
        (, uint256 d) = BlazePhoenixGateWrapper(w6).quote(true, 0);
        assertEq(d, 2_000_000e18, "6-decimal side, normalised, is the long side");
    }

    /// Quantity: adapter depth18 (Balancer V2) is read only outside a Vault operation, by
    /// VaultReentrancyLib.ensureNotInVaultContext's probe. An exit sends its tokens out before the
    /// Vault stores the pool's new balances (PoolBalances.sol `_joinOrExit`), so a read from inside
    /// that transfer sees balances the exit is about to lower.
    function test_BalV2_Depth18_ZeroInsideAVaultOperation() public {
        vault.setPoolBalances(PID, _two(400e18, 700e18));
        vault.callOutMidOperation(address(this), abi.encodeCall(this.readMidOperation, ()));
        assertEq(_dMid, 0, "mid-operation: the adapter declares no depth");
        assertEq(_vMid, 0, "mid-operation: vitalOf reads no depth");
        (, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 0);
        assertEq(d, 700e18, "after the operation: the pool's long side");
    }
    uint256 internal _dMid;
    uint256 internal _vMid;
    /// Called by the Vault mid-operation: the pool's stored balance is still the pre-exit one.
    function readMidOperation() external {
        vault.setPoolBalances(PID, _two(400e18, 700_000e18));
        (, _dMid) = BlazePhoenixGateWrapper(w).quote(true, 0);
        (, _vMid, ) = gate.vitalOf(w);
        vault.setPoolBalances(PID, _two(400e18, 700e18));
    }

    /// The pair is the calling wrapper's, as in quoteCall: a caller the Gate did not create is refused.
    function test_BalV2_Depth18_OnlyForTheGatesWrapper() public {
        vm.expectRevert(_aerr(1));
        adapter.quote(address(vault), PID, bytes32(0), true, 0);
    }
}
