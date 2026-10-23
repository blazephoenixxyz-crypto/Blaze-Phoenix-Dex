// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "./AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixAdapterBalancerV3, IBalancerV3Vault} from "../../src/adapters/BlazePhoenixAdapterBalancerV3.sol";
import {MockBalancerFactory} from "./mocks/MockBalancerV2.sol";
import {MockBalancerV3Vault} from "./mocks/MockBalancerV3.sol";
import {MockERC20Dec} from "./mocks/MockERC20Dec.sol";

contract PinnedHook { function ok() external pure returns (uint256) { return 1; } }
contract OtherHook { function ok() external pure returns (uint256) { return 2; } }

/// Balancer V3 adapter behind the real wrapper: SETTLE custody against a Vault-faithful mock.
contract AdapterBalancerV3Test is AdapterHarness {
    uint8 internal constant FAM = 3;
    uint24 internal constant KEY = uint24(FAM) << 16 | 1;
    address internal constant POOL = address(0xB301);

    MockBalancerV3Vault internal vault;
    MockBalancerFactory internal f0;
    MockBalancerFactory internal f1;
    PinnedHook internal hook;
    BlazePhoenixAdapterBalancerV3 internal adapter;
    address internal w;

    function setUp() public {
        _tokens();
        vault = new MockBalancerV3Vault();
        f0 = new MockBalancerFactory();
        f1 = new MockBalancerFactory();
        hook = new PinnedHook();
        t0.mint(address(vault), 1_000_000e18);
        t1.mint(address(vault), 1_000_000e18);
        _register(POOL, f0, address(t1), address(t0), _hooks(false, address(0)));
        adapter = new BlazePhoenixAdapterBalancerV3(
            address(gate), address(vault), [address(f0), address(f1)], [address(hook).codehash, bytes32(0)]
        );
        _accept(FAM, address(adapter));
        w = gate.create(address(t0), address(t1), KEY, abi.encode(POOL));
    }

    function _hooks(bool adjusted, address h) internal pure returns (IBalancerV3Vault.HooksConfig memory c) {
        c.enableHookAdjustedAmounts = adjusted;
        c.shouldCallBeforeSwap = h != address(0);
        c.hooksContract = h;
    }

    function _register(address pool, MockBalancerFactory f, address a, address b, IBalancerV3Vault.HooksConfig memory h)
        internal
    {
        address[] memory t = new address[](2);
        (t[0], t[1]) = (a, b);
        vault.registerPool(pool, t, h);
        if (address(f) != address(0)) f.add(pool);
    }

    function _settled() internal view {
        assertEq(vault.delta(address(t0)), 0, "delta t0");
        assertEq(vault.delta(address(t1)), 0, "delta t1");
        assertFalse(vault.unlocked());
    }

    // ─── execution: transfer exactly, settle with that hint, Vault pays the recipient ───

    function test_BalV3_Swap_RecipientPaidByVault_Settled_NothingLeft() public {
        assertEq(_swap(w, true, 10e18), 10e18 * 9_970 / 10_000);
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
        assertEq(_swap(w, false, 4e18), 4e18 * 9_970 / 10_000);
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
    }

    function testFuzz_BalV3_CustodyEmptyAfterEveryExec(uint96 amt, bool zeroForOne) public {
        amt = uint96(bound(amt, 1e6, 1e23)); // dust pays 0 and the venue's limit of 1 reverts; <= 10 % of 1e24
        _swap(w, zeroForOne, amt);
        _assertEmpty(address(adapter), w, address(vault));
        _settled();
    }

    function test_BalV3_NoApproveInItsBytecode() public view {
        assertFalse(_hasApproveSelector(address(adapter)));
    }

    function test_BalV3_QuoteCallEqualsExecution_QuoteIsZero() public {
        vault.setRateOf(address(t0), 9_000); // t0->t1 prices apart: a reversed pair is seen ([611])
        (uint256 q, ) = BlazePhoenixGateWrapper(w).quote(false, 6e18);
        assertEq(q, 0);
        vm.prank(address(this), address(0)); // eth_call context, as the Vault's quote demands
        uint256 qc = BlazePhoenixGateWrapper(w).quoteCall(false, 6e18);
        assertGt(qc, 0);
        assertEq(qc, 6e18 * 9_970 / 10_000, "quoteCall prices t1->t0");
        _settled();
        assertEq(_swap(w, false, 6e18), qc);
    }

    /// settle's hint is what was transferred, never more: a stray donation sitting in the Vault
    /// would otherwise be credited to us, leave a delta open, and revert the whole unlock.
    function test_BalV3_DonationToVault_DoesNotBreakSettle() public {
        t0.mint(address(vault), 1); // unsettled: the Vault's reserves do not count it
        assertEq(_swap(w, true, 2e18), 2e18 * 9_970 / 10_000);
        _settled();
    }

    // ─── hostile callers of the callback (SETTLE: the unlock's credit is the runner's) ───

    function test_BalV3_OnUnlockFromNonVault_Refused() public {
        vm.expectRevert(_aerr(6));
        adapter.onUnlock(POOL, address(t0), address(t1), 1e18, address(this));
    }

    function test_BalV3_VaultCallbackOutsideOwnExec_Refused() public {
        t0.mint(address(adapter), 1e18); // something to steal, were the callback open
        vm.expectRevert(_aerr(6));
        vault.poke(address(adapter), abi.encodeCall(adapter.onUnlock, (POOL, address(t0), address(t1), 1e18, address(this))));
    }

    function test_BalV3_OnQuoteFromNonVault_Refused() public {
        vm.expectRevert(_aerr(6));
        adapter.onQuote(POOL, address(t0), address(t1), 1e18);
    }

    function test_BalV3_ExecFromNonWrapper_Refused() public {
        t0.mint(address(adapter), 1e18);
        vm.expectRevert(_aerr(1));
        adapter.exec(address(vault), bytes32(uint256(uint160(POOL))), bytes32(0), true, 1e18, address(this));
    }

    // ─── identity and hooks at resolve; the pin again at exec ───

    function test_BalV3_Resolve_UnregisteredPool_Refused() public {
        f0.add(address(0xB302));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(0xB302)));
    }

    function test_BalV3_Resolve_PoolFromUnlistedFactory_Refused() public {
        _register(address(0xB303), new MockBalancerFactory(), address(t0), address(t1), _hooks(false, address(0)));
        vm.expectRevert(_aerr(2));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(0xB303)));
    }

    function test_BalV3_Resolve_SecondFactoryCounts() public {
        _register(address(0xB304), f1, address(t0), address(t1), _hooks(false, address(0)));
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(0xB304)));
        assertEq(BlazePhoenixGateWrapper(w2).aux0(), bytes32(uint256(uint160(address(0xB304)))));
    }

    function test_BalV3_Resolve_PairNotInPool_Refused() public {
        MockERC20 x = new MockERC20("X", "X");
        _register(address(0xB305), f0, address(t0), address(x), _hooks(false, address(0)));
        vm.expectRevert(_aerr(3));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(0xB305)));
    }

    function test_BalV3_Resolve_HookAdjustedAmounts_Refused() public {
        _register(address(0xB306), f0, address(t0), address(t1), _hooks(true, address(hook)));
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(0xB306)));
    }

    function test_BalV3_Resolve_UnpinnedHook_Refused() public {
        _register(address(0xB307), f0, address(t0), address(t1), _hooks(false, address(new OtherHook())));
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(0xB307)));
    }

    function test_BalV3_Resolve_HookWithoutCode_Refused() public {
        _register(address(0xB308), f0, address(t0), address(t1), _hooks(false, address(0xDEAD)));
        vm.expectRevert(_aerr(7));
        gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(0xB308)));
    }

    /// `_requireHookPinned` at resolve and again at exec (SHARED_QUANTITIES).
    function test_BalV3_PinnedHook_Accepted_ThenCodeChanges_ExecRefused() public {
        _register(address(0xB309), f0, address(t0), address(t1), _hooks(false, address(hook)));
        address w2 = gate.create(address(t0), address(t1), KEY + 1, abi.encode(address(0xB309)));
        assertEq(BlazePhoenixGateWrapper(w2).aux1(), bytes32(uint256(uint160(address(hook)))));
        assertGt(_swap(w2, true, 1e18), 0); // anti-vacuity: the pinned hook trades
        vm.etch(address(hook), address(new OtherHook()).code);
        t0.mint(address(this), 1e18);
        vm.expectRevert(_aerr(7));
        BlazePhoenixGateWrapper(w2).swap(address(this), true, 1e18, 0, "");
    }

    function test_BalV3_Resolve_MalformedHint_Refused() public {
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(POOL));
        // Longer than one word, with a valid pool in the first word: refused too ([546]).
        vm.expectRevert(_aerr(8));
        gate.create(address(t0), address(t1), KEY + 1, abi.encodePacked(abi.encode(POOL), uint8(0)));
    }

    // ─── depth18: the Vault's raw balances of the pool, the shorter side in 18 decimals (adapter-depth-1021;
    //     the short side since 2026-10-23: the registry's own depth of a pair) ───

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }

    /// Quantity: adapter depth18 (Balancer V3) = min over the wrapper's pair of to18 of
    /// `Vault.getPoolTokenInfo(pool).balancesRaw`, matched by token in the Vault's registration
    /// order, for any amtIn and either direction, whichever token holds the shorter side; what
    /// Gate.vitalOf reads. Red at 1b4f2d4 (the long side, 700e18).
    function test_BalV3_Depth18_IsThePoolsShortSideInTheVault() public {
        vault.setPoolBalances(POOL, _two(700e18, 400e18)); // registered (t1, t0)
        BlazePhoenixGateWrapper wr = BlazePhoenixGateWrapper(w);
        (uint256 q, uint256 d) = wr.quote(true, 0);
        assertEq(q, 0, "no view quote");
        assertEq(d, 400e18, "the short side of the pool's raw balances");
        (, uint256 d2) = wr.quote(false, 6e18);
        assertEq(d2, d, "depth18 does not depend on amtIn or direction");
        (, uint256 dv, ) = gate.vitalOf(w);
        assertEq(dv, d, "vitalOf reads the word below the mass held");
        vault.setPoolBalances(POOL, _two(400e18, 700e18));
        (, d) = wr.quote(true, 0);
        assertEq(d, 400e18, "the short side follows the token that holds it");
    }

    /// Quantity: adapter depth18 (Balancer V3) normalises by each token's decimals before the max.
    function test_BalV3_Depth18_NormalisesDecimalsBeforeTheMin() public {
        MockERC20Dec d6 = new MockERC20Dec(6);
        address pool6 = address(0xB3006);
        _register(pool6, f0, address(t0), address(d6), _hooks(false, address(0)));
        vault.setPoolBalances(pool6, _two(1_000_000e18, 2_000_000e6));
        address w6 = gate.create(address(d6), address(t0), KEY, abi.encode(pool6));
        (, uint256 d) = BlazePhoenixGateWrapper(w6).quote(true, 0);
        assertEq(d, 1_000_000e18, "normalised, the 6-decimal side is the deeper one: the short side is the other");
    }

    /// Quantity: adapter depth18 (Balancer V3) is asked only while the Vault is not mid-operation
    /// (`isUnlocked`), the Curve adapters' lock probe in the Vault's form. Inside an unlock a swap
    /// writes the pool's balances before its debt is settled (Vault.sol `_swap`: debt and credit,
    /// then `poolBalances[...]`; settlement only when the outermost unlock ends), so a flash-sized
    /// swap would read as depth, and the Gate's cap is the whole Vault's holding, not the pool's.
    function test_BalV3_Depth18_ZeroWhileTheVaultIsUnlocked() public {
        vault.setPoolBalances(POOL, _two(700e18, 400e18));
        vault.unlock(abi.encodeCall(this.inflateAndRead, ()));
        assertEq(_dUnlocked, 0, "unlocked: the adapter declares no depth");
        assertEq(_vUnlocked, 0, "unlocked: vitalOf reads no depth");
        (, uint256 d) = BlazePhoenixGateWrapper(w).quote(true, 0);
        assertEq(d, 400e18, "locked again: the pool's short side");
    }

    uint256 internal _dUnlocked;
    uint256 internal _vUnlocked;

    /// The Vault's unlock callback: the pool's balance as a swap on credit leaves it mid-session.
    function inflateAndRead() external {
        vault.setPoolBalances(POOL, _two(700_000e18, 400e18));
        (, _dUnlocked) = BlazePhoenixGateWrapper(w).quote(true, 0);
        (, _vUnlocked, ) = gate.vitalOf(w);
        vault.setPoolBalances(POOL, _two(700e18, 400e18));
    }

    /// The pair is the calling wrapper's, as in quoteCall: a caller the Gate did not create is refused.
    function test_BalV3_Depth18_OnlyForTheGatesWrapper() public {
        vm.expectRevert(_aerr(1));
        adapter.quote(address(vault), bytes32(uint256(uint160(POOL))), bytes32(0), true, 0);
    }
}
