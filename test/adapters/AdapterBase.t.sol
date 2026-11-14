// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../mocks/MockERC20.sol";
import {ExtAdapterBase} from "../../src/adapters/ExtAdapterBase.sol";
import {AdapterHarness} from "./AdapterHarness.sol";

/// ExtAdapterBase exposed as it is, one external door per internal producer. No logic of its own:
/// every refusal the tests below read is the base's.
contract BaseProbe is ExtAdapterBase {
    constructor(address gate, bytes32[3] memory pins) ExtAdapterBase(gate, pins) {}

    function pin(address hooks) external view { _requireHookPinned(hooks); }

    /// `inExec` plays the adapter's own `exec` around the callback (same transaction, same frame).
    function cb(address venue, bool inExec) external {
        _inExec = inExec;
        _requireVenueCallback(venue);
    }

    function atMost(uint256 amt, uint256 max) external pure { _requireAmountAtMost(amt, max); }

    function wrapperTokens(bool zeroForOne) external view returns (address, address) {
        return _wrapperTokens(zeroForOne);
    }

    function indices(address[] memory coins, address a, address b) external pure returns (uint256, uint256) {
        return _indices(coins, a, b);
    }

    function approveThenCheck(address token, address spender, uint256 amt) external {
        _approveExact(token, spender, amt);
        _requireNoAllowance(token, spender);
    }

    function noAllowance(address token, address spender) external view { _requireNoAllowance(token, spender); }
}

/// The base every Gate adapter inherits (PR 124, L4): the hooks pin with three slots, the venue
/// callback guard and the amount ceiling moved out of Balancer V3 into ExtAdapterBase, and the error
/// table's codes read by selector and code. Codes 0, 1, 3, 5, 6, 7 and 9 are read here on the probe;
/// 2, 4 and 8 by the adapters' own tests (test_CurveNG_Resolve_PoolNotFromFactory_Refused,
/// test_CurveNG_Resolve_RebasingCoinRefused, test_CurveNG_Resolve_MalformedHint_Refused).
/// Red at bb4cdbb: the base had no `_requireHookPinned`, `_requireVenueCallback`,
/// `_requireAmountAtMost` nor a constructor taking pins, so this file did not compile.
/// Mutants: block "124-L4" in .github/scripts/mutants.py, and [594], [596] re-pointed at the base.
contract AdapterBaseTest is AdapterHarness {
    address constant HOOKS = address(0xB00C);
    bytes32[3] internal none;

    function setUp() public {
        _tokens();
    }

    function _probe(bytes32[3] memory pins) internal returns (BaseProbe) {
        return new BaseProbe(address(gate), pins);
    }

    function _pinsWith(bytes32 h, uint256 slot, bytes32 a, bytes32 b) internal pure returns (bytes32[3] memory p) {
        slot %= 3;
        p[slot] = h;
        p[(slot + 1) % 3] = a;
        p[(slot + 2) % 3] = b;
    }

    // ---- code 0 ----

    function test_Base_ZeroGate_Refused() public {
        vm.expectRevert(_aerr(0));
        new BaseProbe(address(0), none);
    }

    // ---- code 7: the hooks pin ----

    function test_Base_Pin_NoHooksPasses_EvenWithNoSlotFilled() public {
        _probe(none).pin(address(0));
    }

    /// An address without code has codehash 0, the value of an empty slot: refused before the slots.
    function test_Base_Pin_AddressWithoutCode_Refused_EvenWithEmptySlots() public {
        BaseProbe p = _probe(none);
        vm.expectRevert(_aerr(7));
        p.pin(address(0xDEAD));
    }

    function test_Base_Pin_EachSlotAdmitsItsCode_AndOnlyIt() public {
        vm.etch(HOOKS, hex"60016000f3");
        bytes32 h = HOOKS.codehash;
        for (uint256 s; s < 3; ++s) {
            _probe(_pinsWith(h, s, bytes32(0), bytes32(0))).pin(HOOKS);
        }
        BaseProbe p = _probe(_pinsWith(keccak256("other"), 0, keccak256("other1"), keccak256("other2")));
        vm.expectRevert(_aerr(7));
        p.pin(HOOKS);
    }

    /// The same address, its code changed after the pin: refused (the pin reads the code, not the name).
    function test_Base_Pin_CodeChangedUnderTheSameAddress_Refused() public {
        vm.etch(HOOKS, hex"60016000f3");
        BaseProbe p = _probe(_pinsWith(HOOKS.codehash, 2, bytes32(0), bytes32(0)));
        p.pin(HOOKS);
        vm.etch(HOOKS, hex"60026000f3");
        vm.expectRevert(_aerr(7));
        p.pin(HOOKS);
    }

    function testFuzz_Base_Pin_ACodeOutsideThePinsIsRefused(bytes32[3] memory pins, bytes memory code) public {
        vm.assume(code.length != 0);
        vm.etch(HOOKS, code);
        bytes32 h = keccak256(code);
        vm.assume(h != pins[0] && h != pins[1] && h != pins[2]);
        BaseProbe p = _probe(pins);
        vm.expectRevert(_aerr(7));
        p.pin(HOOKS);
    }

    function testFuzz_Base_Pin_EachSlotAdmitsItsCode(bytes memory code, uint8 slot, bytes32 a, bytes32 b) public {
        vm.assume(code.length != 0);
        vm.etch(HOOKS, code);
        _probe(_pinsWith(keccak256(code), slot, a, b)).pin(HOOKS);
    }

    // ---- code 6: the venue callback ----

    function test_Base_Callback_FromTheVenueInsideExec_Passes() public {
        _probe(none).cb(address(this), true);
    }

    function test_Base_Callback_FromTheVenueOutsideExec_Refused() public {
        BaseProbe p = _probe(none);
        vm.expectRevert(_aerr(6));
        p.cb(address(this), false);
    }

    function test_Base_Callback_FromAnotherInsideExec_Refused() public {
        BaseProbe p = _probe(none);
        vm.expectRevert(_aerr(6));
        p.cb(address(0xBEEF), true);
    }

    function testFuzz_Base_Callback_OnlyTheVenueInsideExec(address other, bool fromVenue, bool inExec) public {
        vm.assume(other != address(this));
        BaseProbe p = _probe(none);
        address venue = fromVenue ? address(this) : other;
        if (!(fromVenue && inExec)) vm.expectRevert(_aerr(6));
        p.cb(venue, inExec);
    }

    // ---- code 9: the amount ceiling ----

    function test_Base_AmountAtMost_Extremes() public {
        BaseProbe p = _probe(none);
        p.atMost(0, 0);
        p.atMost(1, 1);
        p.atMost(0, type(uint256).max);
        p.atMost(type(uint256).max, type(uint256).max);
        vm.expectRevert(_aerr(9));
        p.atMost(1, 0);
        vm.expectRevert(_aerr(9));
        p.atMost(2, 1);
        vm.expectRevert(_aerr(9));
        p.atMost(type(uint256).max, type(uint256).max - 1);
    }

    function testFuzz_Base_AmountAtMost_UpToTheCeilingPasses(uint256 max, uint256 x) public {
        BaseProbe p = _probe(none);
        p.atMost(bound(x, 0, max), max);
        p.atMost(max, max);
    }

    function testFuzz_Base_AmountAtMost_OnePastTheCeilingRefused(uint256 max, uint256 x) public {
        max = bound(max, 0, type(uint256).max - 1);
        BaseProbe p = _probe(none);
        vm.expectRevert(_aerr(9));
        p.atMost(max + 1, max);
        vm.expectRevert(_aerr(9));
        p.atMost(bound(x, max + 1, type(uint256).max), max);
    }

    // ---- codes 1, 3, 5: the rest of the table, on the same probe ----

    function test_Base_TokensForACallerTheGateDidNotCreate_Refused() public {
        BaseProbe p = _probe(none);
        vm.expectRevert(_aerr(1));
        p.wrapperTokens(true);
    }

    function test_Base_PairNotInTheList_Refused() public {
        BaseProbe p = _probe(none);
        address[] memory coins = new address[](2);
        (coins[0], coins[1]) = (address(t0), address(0xC01));
        (uint256 i0, uint256 i1) = p.indices(coins, address(0xC01), address(t0));
        assertEq(i0, 1);
        assertEq(i1, 0);
        vm.expectRevert(_aerr(3));
        p.indices(coins, address(t0), address(t1));
        vm.expectRevert(_aerr(3));
        p.indices(coins, address(t0), address(t0));
    }

    function test_Base_AllowanceSurvivingTheCall_Refused_AndAFailedReadIsNotZero() public {
        BaseProbe p = _probe(none);
        p.approveThenCheck(address(t0), address(0x5EED), 0);
        vm.expectRevert(_aerr(5));
        p.approveThenCheck(address(t0), address(0x5EED), 1);
        vm.expectRevert(_aerr(5));
        p.noAllowance(address(0xC0DE), address(0x5EED));
        assertEq(MockERC20(address(t0)).allowance(address(p), address(0x5EED)), 0);
    }
}
