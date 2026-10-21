// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../../mocks/MockERC20.sol";

/// Faithful to the signatures of curvefi/stableswap-ng CurveStableSwapFactoryNG.vy that the adapter
/// reads (get_implementation_address L419, get_coins L175, get_pool_asset_types L441, is_meta L430).
contract MockCurveNGFactory {
    struct P { address impl; address[] coins; uint8[] types; bool meta; }
    mapping(address => P) internal p;

    function register(address pool, address[] memory coins, uint8[] memory types, bool meta) external {
        p[pool] = P(address(0x1111), coins, types, meta);
    }

    function get_implementation_address(address pool) external view returns (address) { return p[pool].impl; }
    function get_coins(address pool) external view returns (address[] memory) { return p[pool].coins; }
    function get_pool_asset_types(address pool) external view returns (uint8[] memory) { return p[pool].types; }
    function is_meta(address pool) external view returns (bool) { return p[pool].meta; }
}

/// Faithful to CurveStableSwapNG.vy where the adapter touches it: `exchange_received` swaps
/// balanceOf(self) - stored_balances[i] and asserts it is >= _dx (L556, _transfer_in L357-392);
/// `exchange` pulls by transferFrom; both nonreentrant('lock'); `get_dy` view without the lock;
/// `get_virtual_price` view WITH the lock (L1737-1740). The price is a fixed rate per coin and a
/// 4 bps fee, so get_dy == the exchange output on the same state (as in the real pool).
/// `mode` turns it hostile: 1 keeps the input and pays nothing, 2 pays the caller instead of the
/// receiver, 3 re-enters the adapter's exec directly.
contract MockCurveNGPool {
    address[] public coinsList;
    uint256[] public stored;
    uint256[] public rate;
    bool public locked;
    uint8 public mode;
    uint256 public calls;

    constructor(address[] memory coins_, uint256[] memory rate_) {
        coinsList = coins_;
        rate = rate_;
        stored = new uint256[](coins_.length);
    }

    function coins(uint256 i) external view returns (address) { return coinsList[i]; }
    /// The pool's own word of its balances (NG: stored_balances - admin_balances; no admin fee here).
    function balances(uint256 i) external view returns (uint256) { return stored[i]; }
    function setMode(uint8 m) external { mode = m; }
    function setLocked(bool b) external { locked = b; }

    function sync() public {
        for (uint256 k; k < coinsList.length; ++k) {
            if (coinsList[k].code.length != 0) stored[k] = MockERC20(coinsList[k]).balanceOf(address(this));
        }
    }

    function _dy(uint256 i, uint256 j, uint256 dx) internal view returns (uint256) {
        return dx * rate[i] / rate[j] * 9_996 / 10_000;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        return _dy(uint256(uint128(i)), uint256(uint128(j)), dx);
    }

    function get_virtual_price() external view returns (uint256) {
        require(!locked, "lock");
        return 1e18;
    }

    function exchange_received(int128 i, int128 j, uint256 _dx, uint256 _minDy, address receiver)
        external returns (uint256 dy)
    {
        require(!locked, "lock");
        locked = true;
        calls++;
        (uint256 a, uint256 b) = (uint256(uint128(i)), uint256(uint128(j)));
        uint256 dx = MockERC20(coinsList[a]).balanceOf(address(this)) - stored[a];
        require(dx >= _dx, "dx");
        stored[a] += dx;
        if (mode == 3) {
            // A hostile pool calling the adapter as if it were a wrapper.
            (bool ok, bytes memory r) = msg.sender.call(
                abi.encodeWithSignature(
                    "exec(address,bytes32,bytes32,bool,uint256,address)",
                    address(this), bytes32(0), bytes32(0), true, uint256(1), address(this)
                )
            );
            if (!ok) assembly { revert(add(r, 32), mload(r)) }
        }
        if (mode == 1) { locked = false; return 0; }
        dy = _dy(a, b, dx);
        require(dy >= _minDy, "min_dy");
        require(receiver != address(0), "receiver");
        stored[b] -= dy;
        MockERC20(coinsList[b]).transfer(mode == 2 ? msg.sender : receiver, dy);
        locked = false;
    }

    function exchange(int128 i, int128 j, uint256 _dx, uint256 _minDy, address receiver) external returns (uint256 dy) {
        require(!locked, "lock");
        locked = true;
        (uint256 a, uint256 b) = (uint256(uint128(i)), uint256(uint128(j)));
        require(_dx > 0, "dx");
        MockERC20(coinsList[a]).transferFrom(msg.sender, address(this), _dx);
        stored[a] += _dx;
        dy = _dy(a, b, _dx);
        require(dy >= _minDy, "min_dy");
        stored[b] -= dy;
        MockERC20(coinsList[b]).transfer(receiver, dy);
        locked = false;
    }
}
