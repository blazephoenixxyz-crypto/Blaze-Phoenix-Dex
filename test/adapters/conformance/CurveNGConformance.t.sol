// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterConformance} from "../AdapterConformance.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {BlazePhoenixAdapterCurveNG} from "../../../src/adapters/BlazePhoenixAdapterCurveNG.sol";
import {MockCurveNGFactory, MockCurveNGPool} from "../mocks/MockCurveNG.sol";

/// Curve stableswap-NG (PUSH) mounted for the shared obligations A1-A10.
contract CurveNGConformance is AdapterConformance {
    MockCurveNGPool internal pool;

    function _mount() internal override {
        MockCurveNGFactory factory = new MockCurveNGFactory();
        address[] memory c = new address[](3);
        (c[0], c[1], c[2]) = (address(t1), address(new MockERC20("O", "O")), address(t0)); // out of sort order
        uint256[] memory rate = new uint256[](3);
        (rate[0], rate[1], rate[2]) = (1e18, 1e18, 2e18); // t0 is worth 2: an index mix-up shows
        pool = new MockCurveNGPool(c, rate);
        for (uint256 k; k < 3; ++k) MockERC20(c[k]).mint(address(pool), HOLD);
        pool.sync();
        factory.register(address(pool), c, new uint8[](3), false);
        adapter_ = address(new BlazePhoenixAdapterCurveNG(address(gate), address(factory)));
        _accept(1, adapter_);
        (venue_, key_, hint_) = (address(pool), uint24(1) << 16 | 1, abi.encode(address(pool)));
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
