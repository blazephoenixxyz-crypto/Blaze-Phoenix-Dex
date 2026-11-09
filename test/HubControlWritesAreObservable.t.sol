// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  THE HUB'S CONTROL WRITES ARE OBSERVABLE (P1, P2 of morf-1106).
//
//  P1. The hook pin. `allowHook` and the admission at registration write the codehash the
//      auto-pause compares against (Layer 3), or the HOOK_REVOKED sentinel; no event carried
//      it, so an indexer could not tell which code the curator admitted. HookPinned(hook, pin)
//      logs the value written, and this file reads the slot back with vm.load: log == storage.
//  P2. `setOperator(who, false)` logged RoleSet(4, who), the same line as a grant; `initialize`
//      wrote the operator seat and the V4 manager and logged only the admin; `addFactory` pins
//      the CREATE2 init hash every derived address hangs on and logged only (factory, kind,
//      mode). Now: RoleSet(6, who) on a revoke, RoleSet 4 and 5 at initialize, and an additive
//      FactoryPinned(factory, initHash) after Factory_ (Factory_ itself is unchanged).
//
//  RED at cb1d7d9 (commit "test: hub control writes are observable (red)"): every test below
//  fails there; GREEN with "feat(hub): log the hook pin, the operator revoke, initialize's
//  seats and the factory init hash". The event shapes are the owner's call (SINTESE, question
//  15): the expected events are declared here, so the file compiles on either side of the fix.
//
//  Mutants that turn this file red (.github/scripts/mutants.py, [morf-P3-*]): each new Hub
//  emit deleted; HookPinned(h, bytes32(0)); `ok ? 4 : 6` -> `4`.
// =============================================================================
import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockV4ManagerNative} from "./RouterV4NativeEth.t.sol";

contract HookCode {
    function f() external pure returns (uint256) { return 1; }
}

contract HubControlWritesAreObservableTest is Test {
    event HookPinned(address indexed hook, bytes32 codehash);
    event FactoryPinned(address indexed factory, bytes32 initHash);

    address constant ADM = address(0xAD31);
    address constant WHO = address(0x0B0B);
    address constant TOK_A = address(0xA11A);
    address constant TOK_B = address(0xB22B);
    bytes32 constant HOOK_REVOKED = bytes32(uint256(1)); // Hub:524
    // ERC-7201 root (Hub: "blazephoenix.hub.v1"). Fields: 0 admin, 4 operator, 14 factories,
    // 16 v4PoolManager, 18 hookCodehash (counted as T19ReadmissionEdge.t.sol:183-205 does).
    bytes32 constant HUB_SLOT =
        keccak256(abi.encode(uint256(keccak256("blazephoenix.hub.v1")) - 1)) & ~bytes32(uint256(0xff));

    BlazePhoenixHub hub;
    address mgr;

    function setUp() public {
        mgr = address(new MockV4ManagerNative());
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), mgr);
    }

    function _field(uint256 f) internal pure returns (bytes32) {
        return bytes32(uint256(HUB_SLOT) + f);
    }

    function _at(address h, bytes32 s) internal view returns (bytes32) {
        return vm.load(h, s);
    }

    function _pin(address h) internal view returns (bytes32) {
        return _at(address(hub), keccak256(abi.encode(h, _field(18))));
    }

    function _isOperator(address h, address who) internal view returns (bool) {
        return _at(h, keccak256(abi.encode(who, _field(4)))) != 0;
    }

    function _countPins(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hub) && logs[i].topics[0] == HookPinned.selector) ++n;
        }
    }

    // ─── P1: the hook pin ───

    function test_HookPin_AllowEmitsTheCodehash() public {
        address h = address(new HookCode());
        vm.expectEmit(true, true, true, true, address(hub));
        emit HookPinned(h, h.codehash);
        hub.allowHook(h, true);
        assertEq(_pin(h), h.codehash, "the logged pin is the stored pin");
        assertTrue(h.codehash != bytes32(0));
        // A hook without code is pinned to what it has (nothing), and says so.
        address bare = address(0x4004);
        vm.expectEmit(true, true, true, true, address(hub));
        emit HookPinned(bare, bare.codehash);
        hub.allowHook(bare, true);
        assertEq(_pin(bare), bare.codehash);
    }

    function test_HookPin_RevokeEmitsTheSentinel() public {
        address h = address(new HookCode());
        hub.allowHook(h, true);
        vm.expectEmit(true, true, true, true, address(hub));
        emit HookPinned(h, HOOK_REVOKED);
        hub.allowHook(h, false);
        assertEq(_pin(h), HOOK_REVOKED, "the logged sentinel is the stored sentinel");
        // Re-listing re-pins the code, and logs it.
        vm.expectEmit(true, true, true, true, address(hub));
        emit HookPinned(h, h.codehash);
        hub.allowHook(h, true);
        // After renounce a revoke is refused (HubE(1)) and logs nothing.
        hub.renounceControl();
        vm.recordLogs();
        (bool ok, bytes memory ret) = address(hub).call(abi.encodeCall(hub.allowHook, (h, false)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(1)));
        assertEq(vm.getRecordedLogs().length, 0, "a refused revoke logs nothing");
        assertEq(_pin(h), h.codehash);
    }

    function test_HookPin_AdmissionAtRegistrationEmits() public {
        address h = address(new HookCode());
        vm.expectEmit(true, true, true, true, address(hub));
        emit HookPinned(h, h.codehash);
        hub.seedPool(address(0xC001), BPC.KIND_V2, 30, h, TOK_A, TOK_B);
        assertEq(_pin(h), h.codehash, "the logged pin is the stored pin");
        // Already listed: the second row admits nothing, writes no pin and logs none.
        vm.recordLogs();
        hub.seedPool(address(0xC002), BPC.KIND_V2, 30, h, TOK_A, TOK_B);
        assertEq(_countPins(vm.getRecordedLogs()), 0, "no admission, no pin log");
    }

    // ─── P2: operator, initialize, factory ───

    function test_SetOperator_GrantAndRevokeAreDistinguishable() public {
        vm.expectEmit(true, true, true, true, address(hub));
        emit BlazePhoenixHub.RoleSet(4, WHO);
        hub.setOperator(WHO, true);
        assertTrue(_isOperator(address(hub), WHO));
        vm.expectEmit(true, true, true, true, address(hub));
        emit BlazePhoenixHub.RoleSet(6, WHO);
        hub.setOperator(WHO, false);
        assertFalse(_isOperator(address(hub), WHO), "RoleSet 6 is a seat taken away");
    }

    function test_Initialize_EmitsEverySeatItWrites() public {
        BlazePhoenixHub h = new BlazePhoenixHub(address(this));
        vm.expectEmit(true, true, true, true, address(h));
        emit BlazePhoenixHub.RoleSet(0, ADM);
        vm.expectEmit(true, true, true, true, address(h));
        emit BlazePhoenixHub.RoleSet(4, ADM);
        vm.expectEmit(true, true, true, true, address(h));
        emit BlazePhoenixHub.RoleSet(5, mgr);
        h.initialize(ADM, mgr);
        assertEq(address(uint160(uint256(_at(address(h), _field(0))))), ADM, "seat 0 written");
        assertTrue(_isOperator(address(h), ADM), "seat 4 written");
        assertEq(address(uint160(uint256(_at(address(h), _field(16))))), h.v4PoolManager(), "seat 5 read where it lives");
        assertEq(h.v4PoolManager(), mgr, "seat 5 written");
    }

    function test_AddFactory_EmitsTheInitHash() public {
        address f = address(0x6666);
        bytes32 ih = keccak256("a v2 pair's creation code");
        vm.expectEmit(true, true, true, true, address(hub));
        emit BlazePhoenixHub.Factory_(f, BPC.KIND_V2, 0);
        vm.expectEmit(true, true, true, true, address(hub));
        emit FactoryPinned(f, ih);
        hub.addFactory(f, BPC.KIND_V2, 0, ih, new uint24[](0), new int24[](0));
        // factories[0]: slot 0 packs (factory, kind, mode), slot 1 is initHash.
        bytes32 base = keccak256(abi.encode(_field(14)));
        assertEq(address(uint160(uint256(_at(address(hub), base)))), f, "premise: the row is read where it lives");
        assertEq(_at(address(hub), bytes32(uint256(base) + 1)), ih, "the logged init hash is the stored one");
    }
}
