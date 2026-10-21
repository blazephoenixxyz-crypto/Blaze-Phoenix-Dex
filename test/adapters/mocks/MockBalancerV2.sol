// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../../mocks/MockERC20.sol";
import {IBalancerV2Vault} from "../../../src/adapters/BlazePhoenixAdapterBalancerV2.sol";

contract MockBalancerFactory {
    mapping(address => bool) public isPoolFromFactory;
    function add(address p) external { isPoolFromFactory[p] = true; }
}

/// Faithful to balancer-v2-monorepo IVault.sol / Swaps.sol where the adapter touches it: `swap`
/// is nonReentrant, authenticates funds.sender == msg.sender (no relayer), pulls by transferFrom
/// unless fromInternalBalance, pays recipient or its internal balance, checks deadline and the
/// GIVEN_IN limit (amountOut >= limit). `queryBatchSwap` is non-view. Price: rateBps of the input.
/// `mode` turns it hostile (PULL custody): 1 pays without pulling (HUNT-001), 2 pulls one wei
/// less than asked.
contract MockBalancerV2Vault {
    mapping(bytes32 => address) internal poolOf;
    mapping(bytes32 => address[]) internal tokensOf;
    mapping(address => mapping(address => uint256)) public internalBalance;
    uint256 public rateBps = 9_970;
    /// Per input token, when set: a pool is not 1:1, so a quote of the wrong direction shows.
    mapping(address => uint256) public rateBpsOf;
    uint8 public mode;
    bool internal entered;
    uint256 public allowanceSeen;
    uint256 public queries;

    function setRateOf(address tokenIn, uint256 bps) external {
        rateBpsOf[tokenIn] = bps;
    }

    function _rate(address tokenIn) internal view returns (uint256 r) {
        r = rateBpsOf[tokenIn];
        if (r == 0) r = rateBps;
    }

    function registerPool(bytes32 id, address pool, address[] memory tokens) external {
        poolOf[id] = pool;
        tokensOf[id] = tokens;
    }

    function setMode(uint8 m) external { mode = m; }

    function getPool(bytes32 id) external view returns (address, IBalancerV2Vault.PoolSpecialization) {
        return (poolOf[id], IBalancerV2Vault.PoolSpecialization.GENERAL);
    }

    function getPoolTokens(bytes32 id) external view returns (address[] memory t, uint256[] memory b, uint256) {
        t = tokensOf[id];
        b = new uint256[](t.length);
        for (uint256 k; k < t.length; ++k) b[k] = MockERC20(t[k]).balanceOf(address(this));
        return (t, b, 0);
    }

    function swap(
        IBalancerV2Vault.SingleSwap memory s,
        IBalancerV2Vault.FundManagement memory f,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256 out) {
        require(!entered, "BAL#400");
        entered = true;
        require(f.sender == msg.sender, "BAL#401");
        require(block.timestamp <= deadline, "BAL#508");
        require(s.kind == IBalancerV2Vault.SwapKind.GIVEN_IN, "kind");
        require(poolOf[s.poolId] != address(0), "BAL#500");
        allowanceSeen = MockERC20(s.assetIn).allowance(f.sender, address(this));
        if (f.fromInternalBalance) {
            internalBalance[f.sender][s.assetIn] -= s.amount;
        } else if (mode == 2) {
            MockERC20(s.assetIn).transferFrom(f.sender, address(this), s.amount - 1);
        } else if (mode != 1) {
            MockERC20(s.assetIn).transferFrom(f.sender, address(this), s.amount);
        }
        out = s.amount * _rate(s.assetIn) / 10_000;
        require(out >= limit, "BAL#507");
        if (f.toInternalBalance) internalBalance[f.recipient][s.assetOut] += out;
        else MockERC20(s.assetOut).transfer(f.recipient, out);
        entered = false;
    }

    function queryBatchSwap(
        IBalancerV2Vault.SwapKind,
        IBalancerV2Vault.BatchSwapStep[] memory steps,
        address[] memory assets,
        IBalancerV2Vault.FundManagement memory
    ) external returns (int256[] memory d) {
        queries++; // non-view, as the real one
        d = new int256[](2);
        d[0] = int256(steps[0].amount);
        d[1] = -int256(steps[0].amount * _rate(assets[steps[0].assetInIndex]) / 10_000);
    }
}
