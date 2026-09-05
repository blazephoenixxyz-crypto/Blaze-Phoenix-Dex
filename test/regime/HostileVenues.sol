// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Hostile venues — pools and tokens that misbehave at the seams the contracts
//  read and pay through. Each is one pathology on an otherwise honest venue,
//  so a cell of the matrix (test/regime/HostileVenueMatrix.t.sol) isolates one
//  behaviour: a pair that swaps without paying, one that pays half, one whose
//  reserves come back as a returndata bomb, ones that burn all gas on a read
//  or on the swap, a token whose decimals() never returns, a V3 pool that
//  fires its callback twice, one that re-enters the Router mid-swap, and one
//  whose slot0() reverts.
// =============================================================================

import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

interface IERC20H {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IV3CallbackH {
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external;
}

interface IRouterDoor {
    function swapBestExactIn(address, address, uint256, uint256, address, uint256) external returns (uint256);
}

// ----------------------------------------------------------------------------- V2 shapes

abstract contract HostileV2Base {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }

    function getReserves() external view virtual returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function _pay(uint256 amount0Out, uint256 amount1Out, address to) internal {
        if (amount0Out > 0) IERC20H(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20H(token1).transfer(to, amount1Out);
        reserve0 = uint112(IERC20H(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20H(token1).balanceOf(address(this)));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external virtual {
        _pay(amount0Out, amount1Out, to);
    }

    function _burn() internal view {
        // burns whatever gas the caller forwarded; a view loop the optimiser cannot fold
        uint256 x;
        for (uint256 i; ; ++i) { assembly { x := add(x, sload(i)) } }
    }
}

/// Takes the input, pays nothing.
contract LyingV2Pair is HostileV2Base {
    constructor(address a, address b) HostileV2Base(a, b) {}
    function swap(uint256, uint256, address, bytes calldata) external override {
        reserve0 = uint112(IERC20H(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20H(token1).balanceOf(address(this)));
    }
}

/// Pays half of what it was asked for.
contract HalfPayV2Pair is HostileV2Base {
    constructor(address a, address b) HostileV2Base(a, b) {}
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external override {
        _pay(amount0Out / 2, amount1Out / 2, to);
    }
}

/// Reserves come back as 64 KiB of returndata (the first three words honest).
contract ReturnBombV2Pair is HostileV2Base {
    constructor(address a, address b) HostileV2Base(a, b) {}
    function getReserves() external view override returns (uint112, uint112, uint32) {
        uint112 r0 = reserve0; uint112 r1 = reserve1; uint32 ts = uint32(block.timestamp);
        assembly {
            let p := mload(0x40)
            mstore(p, r0) mstore(add(p, 32), r1) mstore(add(p, 64), ts)
            return(p, 65536)
        }
    }
}

/// The reserve read never returns: it burns every unit of gas it is given.
contract GasBombReadV2Pair is HostileV2Base {
    constructor(address a, address b) HostileV2Base(a, b) {}
    function getReserves() external view override returns (uint112, uint112, uint32) {
        _burn();
        return (0, 0, 0);
    }
}

/// The swap never returns: it burns every unit of gas it is given.
contract GasBombSwapV2Pair is HostileV2Base {
    constructor(address a, address b) HostileV2Base(a, b) {}
    function swap(uint256, uint256, address, bytes calldata) external view override {
        _burn();
    }
}

// ----------------------------------------------------------------------------- token

/// An honest ERC-20 whose decimals() burns every unit of gas it is given.
contract GasBombDecimalsToken {
    string public name = "Bomb"; string public symbol = "BOMB";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external view returns (uint8) {
        uint256 x;
        for (uint256 i; ; ++i) { assembly { x := add(x, sload(i)) } }
        return uint8(x);
    }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; totalSupply += amt; }
    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { _move(msg.sender, to, amt); return true; }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt); return true;
    }
    function _move(address from, address to, uint256 amt) private { balanceOf[from] -= amt; balanceOf[to] += amt; }
}

// ----------------------------------------------------------------------------- V3 shapes

abstract contract HostileV3Base {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    constructor(address a, address b, uint24 f) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
    }
    function setState(uint160 p, uint128 l) external { sqrtPriceX96 = p; liquidity = l; }

    function slot0() external view virtual returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function _quote(bool zeroForOne, uint256 amtIn) internal view returns (uint256) {
        return BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne, 0);
    }

    function _settle(address recipient, bool zeroForOne, uint256 amtIn, uint256 amtOut, bytes calldata data, uint256 callbacks)
        internal returns (int256 amount0, int256 amount1)
    {
        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;
        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);
        uint256 before = IERC20H(tokenIn).balanceOf(address(this));
        for (uint256 c; c < callbacks; ++c) {
            IV3CallbackH(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        }
        require(IERC20H(tokenIn).balanceOf(address(this)) - before >= amtIn, "hostile: insufficient input");
        IERC20H(tokenOut).transfer(recipient, amtOut);
    }
}

/// Fires the payment callback twice for one swap.
contract DoubleCallbackV3Pool is HostileV3Base {
    constructor(address a, address b, uint24 f) HostileV3Base(a, b, f) {}
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external returns (int256, int256)
    {
        uint256 amtIn = uint256(amountSpecified);
        return _settle(recipient, zeroForOne, amtIn, _quote(zeroForOne, amtIn), data, 2);
    }
}

/// Re-enters the Router through its solve-in-transaction door before paying.
contract ReentrantV3Pool is HostileV3Base {
    address public router;
    bool public reentered;   // set only if the Router let the nested swap run
    constructor(address a, address b, uint24 f, address router_) HostileV3Base(a, b, f) { router = router_; }
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external returns (int256, int256)
    {
        address tokenIn = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;
        (bool ok,) = router.call(abi.encodeCall(IRouterDoor.swapBestExactIn, (tokenIn, tokenOut, 1, 1, address(this), block.timestamp + 1)));
        if (ok) reentered = true;
        uint256 amtIn = uint256(amountSpecified);
        return _settle(recipient, zeroForOne, amtIn, _quote(zeroForOne, amtIn), data, 1);
    }
}

/// slot0() reverts; liquidity() and the swap are honest.
contract SlotRevertV3Pool is HostileV3Base {
    constructor(address a, address b, uint24 f) HostileV3Base(a, b, f) {}
    function slot0() external pure override returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        revert("hostile: slot0");
    }
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external returns (int256, int256)
    {
        uint256 amtIn = uint256(amountSpecified);
        return _settle(recipient, zeroForOne, amtIn, _quote(zeroForOne, amtIn), data, 1);
    }
}
