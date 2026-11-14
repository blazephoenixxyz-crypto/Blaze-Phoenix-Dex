// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterConformance} from "../AdapterConformance.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {BlazePhoenixAdapterCurveCryptoNG} from "../../../src/adapters/BlazePhoenixAdapterCurveCryptoNG.sol";
import {MockCurveCryptoNGFactory, MockCurveCryptoNGPool} from "../mocks/MockCurveCryptoNG.sol";

/// Curve cryptoswap-NG, two coins (PUSH), mounted for the shared obligations A1-A10.
contract CurveCryptoNGConformance is AdapterConformance {
    MockCurveCryptoNGPool internal pool;

    function _mount() internal override {
        MockCurveCryptoNGFactory factory = new MockCurveCryptoNGFactory(2);
        address[] memory c = new address[](2);
        (c[0], c[1]) = (address(t1), address(t0)); // out of sort order
        uint256[] memory rate = new uint256[](2);
        (rate[0], rate[1]) = (1e18, 2e18); // t0 is worth 2: an index mix-up shows
        pool = new MockCurveCryptoNGPool(c, rate);
        for (uint256 k; k < 2; ++k) MockERC20(c[k]).mint(address(pool), HOLD);
        pool.sync();
        factory.register(address(pool), c);
        adapter_ = address(new BlazePhoenixAdapterCurveCryptoNG(address(gate), address(factory)));
        _accept(4, adapter_);
        (venue_, key_, hint_) = (address(pool), uint24(4) << 16 | 1, abi.encode(address(pool)));
        w_ = gate.create(address(t0), address(t1), key_, hint_);
    }

    /// The pool's own reentrancy lock held.
    function _midOperation(bytes memory call) internal override {
        pool.setLocked(true);
        (bool ok, bytes memory r) = address(this).call(call);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
        pool.setLocked(false);
    }
}
