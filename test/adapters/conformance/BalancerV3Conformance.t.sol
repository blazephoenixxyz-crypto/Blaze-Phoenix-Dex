// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterConformance, AdapterConformanceHooked} from "../AdapterConformance.sol";
import {PinnedHook, OtherHook} from "../AdapterBalancerV3.t.sol";
import {BlazePhoenixAdapterBalancerV3, IBalancerV3Vault} from "../../../src/adapters/BlazePhoenixAdapterBalancerV3.sol";
import {MockBalancerFactory} from "../mocks/MockBalancerV2.sol";
import {MockBalancerV3Vault} from "../mocks/MockBalancerV3.sol";

/// Balancer V3 (SETTLE), its pool behind a pinned hook, mounted for the shared obligations A1-A10.
contract BalancerV3Conformance is AdapterConformanceHooked {
    MockBalancerV3Vault internal vault;
    PinnedHook internal hook;

    function _mount() internal override {
        vault = new MockBalancerV3Vault();
        MockBalancerFactory f = new MockBalancerFactory();
        t0.mint(address(vault), HOLD);
        t1.mint(address(vault), HOLD);
        address[] memory t = new address[](2);
        (t[0], t[1]) = (address(t1), address(t0)); // the Vault's order, not the sort's
        hook = new PinnedHook();
        IBalancerV3Vault.HooksConfig memory h;
        (h.shouldCallBeforeSwap, h.hooksContract) = (true, address(hook));
        vault.registerPool(address(0xB301), t, h);
        uint256[] memory b = new uint256[](2);
        (b[0], b[1]) = (HOLD, HOLD);
        vault.setPoolBalances(address(0xB301), b);
        f.add(address(0xB301));
        adapter_ = address(new BlazePhoenixAdapterBalancerV3(
            address(gate), address(vault), [address(f), address(new MockBalancerFactory())], [address(hook).codehash, bytes32(0)]
        ));
        _accept(3, adapter_);
        (venue_, key_, hint_) = (address(vault), uint24(3) << 16 | 1, abi.encode(address(0xB301)));
        w_ = gate.create(address(t0), address(t1), key_, hint_);
    }

    /// The Vault unlocked by someone else: a session that is not ours.
    function _midOperation(bytes memory call) internal override {
        vault.poke(address(this), call);
    }

    function _changeHook() internal override {
        vm.etch(address(hook), address(new OtherHook()).code);
    }
}
