// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../../mocks/MockERC20.sol";

/// Faithful to the one getter the adapter reads from curvefi/twocrypto-ng TwocryptoFactory.vy
/// (get_coins L357-363 -> address[2]) and curvefi/tricrypto-ng CurveTricryptoFactory.vy
/// (get_coins L415-421 -> address[3]): a static array of N_COINS words, all zero for a pool the
/// factory did not deploy. `dirty` answers the first word with high bits set (not an address).
contract MockCurveCryptoNGFactory {
    uint256 public immutable N;
    mapping(address => address[]) internal p;
    bool public dirty;

    constructor(uint256 n) { N = n; }

    function register(address pool, address[] memory coins) external { p[pool] = coins; }
    function setDirty(bool b) external { dirty = b; }

    function get_coins(address pool) external view returns (address[2] memory) {
        address[] memory c = p[pool];
        uint256 n = N;
        bool d = dirty;
        assembly {
            let m := mload(0x40)
            for { let k := 0 } lt(k, n) { k := add(k, 1) } {
                let v := 0
                if lt(k, mload(c)) { v := mload(add(c, mul(add(k, 1), 32))) }
                mstore(add(m, mul(k, 32)), v)
            }
            if d { mstore(m, or(mload(m), shl(160, 1))) }
            return(m, mul(n, 32))
        }
    }
}

/// Faithful to Twocrypto.vy / CurveTricryptoOptimized.vy where the adapter touches them:
/// `exchange_received(uint256,uint256,uint256,uint256,address)` swaps balanceOf(self) - stored[i]
/// and asserts it is >= dx (Twocrypto.vy `_transfer_in` L158-191); `exchange` pulls by
/// transferFrom; both nonreentrant; `get_dy` without the lock; `get_virtual_price` WITH it
/// (L1289-1290). Fixed rate per coin and a 5 bps fee, so get_dy == the exchange output on the
/// same state. `mode`: 1 keeps the input and pays nothing, 2 pays the caller instead of the
/// receiver, 3 re-enters the adapter's exec directly.
contract MockCurveCryptoNGPool {
    address[] public coinsList;
    uint256[] public stored;
    uint256[] public rate;
    bool public locked;
    uint8 public mode;

    constructor(address[] memory coins_, uint256[] memory rate_) {
        coinsList = coins_;
        rate = rate_;
        stored = new uint256[](coins_.length);
    }

    function coins(uint256 i) external view returns (address) { return coinsList[i]; }
    /// The pool's own word of its balances (`balances: public(uint256[N_COINS])`).
    function balances(uint256 i) external view returns (uint256) { return stored[i]; }
    function setMode(uint8 m) external { mode = m; }
    function setLocked(bool b) external { locked = b; }

    function sync() public {
        for (uint256 k; k < coinsList.length; ++k) stored[k] = MockERC20(coinsList[k]).balanceOf(address(this));
    }

    function _dy(uint256 i, uint256 j, uint256 dx) internal view returns (uint256) {
        return dx * rate[i] / rate[j] * 9_995 / 10_000;
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256) {
        return _dy(i, j, dx);
    }

    function get_virtual_price() external view returns (uint256) {
        require(!locked, "lock");
        return 1e18;
    }

    function exchange_received(uint256 i, uint256 j, uint256 _dx, uint256 _minDy, address receiver)
        external returns (uint256 dy)
    {
        require(!locked, "lock");
        locked = true;
        uint256 dx = MockERC20(coinsList[i]).balanceOf(address(this)) - stored[i];
        require(dx >= _dx, "user didn't give us coins");
        stored[i] += dx;
        if (mode == 3) {
            (bool ok, bytes memory r) = msg.sender.call(
                abi.encodeWithSignature(
                    "exec(address,bytes32,bytes32,bool,uint256,address)",
                    address(this), bytes32(0), bytes32(0), true, uint256(1), address(this)
                )
            );
            if (!ok) assembly { revert(add(r, 32), mload(r)) }
        }
        if (mode == 1) { locked = false; return 0; }
        dy = _dy(i, j, dx);
        require(dy >= _minDy, "min_dy");
        stored[j] -= dy;
        MockERC20(coinsList[j]).transfer(mode == 2 ? msg.sender : receiver, dy);
        locked = false;
    }
}

/// CurveTricryptoOptimizedWETH.vy's shape: `WETH20()` (L141) and NO `exchange_received`
/// (`exchange` has a `use_eth` argument, L410-417). Only what the adapter's resolve can see.
contract MockCurveTricryptoWETHPool {
    address public immutable WETH20;
    constructor(address weth) { WETH20 = weth; }
    function get_virtual_price() external pure returns (uint256) { return 1e18; }
    function get_dy(uint256, uint256, uint256 dx) external pure returns (uint256) { return dx; }
}
