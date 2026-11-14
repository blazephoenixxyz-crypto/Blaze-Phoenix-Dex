// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterConformance} from "../AdapterConformance.sol";
import {BlazePhoenixAdapterBalancerV2} from "../../../src/adapters/BlazePhoenixAdapterBalancerV2.sol";
import {MockBalancerFactory, MockBalancerV2Vault} from "../mocks/MockBalancerV2.sol";

/// Balancer V2 (PULL) mounted for the shared obligations A1-A10.
contract BalancerV2Conformance is AdapterConformance {
    MockBalancerV2Vault internal vault;

    function _mount() internal override {
        vault = new MockBalancerV2Vault();
        MockBalancerFactory f = new MockBalancerFactory();
        t0.mint(address(vault), HOLD);
        t1.mint(address(vault), HOLD);
        address[] memory t = new address[](2);
        (t[0], t[1]) = (address(t0), address(t1));
        bytes32 pid = keccak256("conformance");
        vault.registerPool(pid, address(0xB001), t);
        uint256[] memory b = new uint256[](2);
        (b[0], b[1]) = (HOLD, HOLD);
        vault.setPoolBalances(pid, b); // the Vault's accounting of the pool, not its token balance
        f.add(address(0xB001));
        adapter_ = address(new BlazePhoenixAdapterBalancerV2(
            address(gate), address(vault), [address(f), address(0), address(0), address(0)]
        ));
        _accept(2, adapter_);
        (venue_, key_, hint_) = (address(vault), uint24(2) << 16 | 1, abi.encode(pid));
        w_ = gate.create(address(t0), address(t1), key_, hint_);
    }

    function _midOperation(bytes memory call) internal override {
        vault.callOutMidOperation(address(this), call);
    }
}
