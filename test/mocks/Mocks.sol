// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BlazePhoenixCore as BPC, PoolInfo } from "../../src/BlazePhoenixCore.sol";

/// @dev Minimal ERC20 surface used by the Solver: decimals() and balanceOf().
contract MockERC20 {
    uint8 public immutable dec;
    mapping(address => uint256) public balanceOf;
    constructor(uint8 d) { dec = d; }
    function decimals() external view returns (uint8) { return dec; }
    function setBalance(address who, uint256 amt) external { balanceOf[who] = amt; }
}

/// @dev Uniswap-V2-shaped pool: getReserves + token0/token1.
contract MockV2Pool {
    uint112 private r0;
    uint112 private r1;
    address public token0;
    address public token1;
    constructor(address t0, address t1, uint112 _r0, uint112 _r1) {
        token0 = t0; token1 = t1; r0 = _r0; r1 = _r1;
    }
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, uint32(block.timestamp));
    }
}

/// @dev Uniswap-V3-shaped pool: slot0 (sqrtPriceX96 in word0) + liquidity + tokens.
contract MockV3Pool {
    uint160 public sqrtPriceX96;
    uint128 public liq;
    address public token0;
    address public token1;
    constructor(address t0, address t1, uint160 sp, uint128 _liq) {
        token0 = t0; token1 = t1; sqrtPriceX96 = sp; liq = _liq;
    }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, int24(0), 0, 0, 0, 0, true);
    }
    function liquidity() external view returns (uint128) { return liq; }
}

/// @dev Mock Hub implementing the IHubR / IHubROld surface used by both
///      Solver variants. Pools are registered per sorted (t0,t1) pair.
contract MockHub {
    mapping(bytes32 => PoolInfo[]) internal pools;     // keyed by pairKey
    mapping(bytes32 => uint256) public psiOf;          // keyed by keyOf(pool,t0,t1)
    address public v4PoolManager;

    function _pairKey(address tA, address tB) internal pure returns (bytes32) {
        (address a, address b) = BPC.sortTokens(tA, tB);
        return keccak256(abi.encodePacked(a, b));
    }

    function keyOf(address pool, address tA, address tB) public pure returns (bytes32) {
        (address s0, address s1) = BPC.sortTokens(tA, tB);
        return keccak256(abi.encodePacked(pool, s0, s1));
    }

    function register(address tA, address tB, PoolInfo memory p, uint256 psi) external {
        pools[_pairKey(tA, tB)].push(p);
        psiOf[keyOf(p.pool, p.token0, p.token1)] = psi;
    }

    function getActivePools(address tA, address tB) external view returns (PoolInfo[] memory) {
        return pools[_pairKey(tA, tB)];
    }
    function discoverFor(address, address) external pure returns (PoolInfo[] memory) {
        return new PoolInfo[](0);
    }
    function getPsi(bytes32 key) external view returns (uint256) { return psiOf[key]; }
    function getSlot(bytes32) external pure returns (uint256) { return 0; }
    function bridge(uint8) external pure returns (address) { return address(0); }
    function bridgeCount() external pure returns (uint8) { return 0; }
    function isBridgeToken(address) external pure returns (bool) { return false; }
    function v4EntryCount() external pure returns (uint256) { return 0; }
}
