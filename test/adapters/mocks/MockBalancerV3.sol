// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../../mocks/MockERC20.sol";
import {IBalancerV3Vault} from "../../../src/adapters/BlazePhoenixAdapterBalancerV3.sol";

/// Faithful to balancer-v3-monorepo IVaultMain / IVaultExtension where the adapter touches it:
/// `unlock` calls back msg.sender with `data` and reverts unless every delta is settled at the
/// end; `swap` only while unlocked, EXACT_IN with limit = minimum out, records a debt in tokenIn
/// and a credit in tokenOut; `settle(token, hint)` credits min(reserve delta, hint); `sendTo`
/// pays out of the credit; `quote` runs the callback in a query context (tx.origin == 0) and
/// never settles. Price: rateBps of the input.
/// Hostile (SETTLE custody): `poke` calls the adapter's callback from the Vault outside any
/// unlock the adapter asked for.
contract MockBalancerV3Vault {
    mapping(address => bool) public isPoolRegistered;
    mapping(address => address[]) internal tokensOf;
    mapping(address => IBalancerV3Vault.HooksConfig) internal hooksOf;
    mapping(address => uint256) public reserves;
    mapping(address => int256) public delta; // > 0: owed to the Vault
    address[] internal touched;
    bool public unlocked;
    uint256 public rateBps = 9_970;
    /// Per input token, when set: a pool is not 1:1, so a quote of the wrong direction shows.
    mapping(address => uint256) public rateBpsOf;

    function setRateOf(address tokenIn, uint256 bps) external {
        rateBpsOf[tokenIn] = bps;
    }

    function _rate(address tokenIn) internal view returns (uint256 r) {
        r = rateBpsOf[tokenIn];
        if (r == 0) r = rateBps;
    }

    function registerPool(address pool, address[] memory tokens, IBalancerV3Vault.HooksConfig memory h) external {
        isPoolRegistered[pool] = true;
        tokensOf[pool] = tokens;
        hooksOf[pool] = h;
        for (uint256 k; k < tokens.length; ++k) reserves[tokens[k]] = MockERC20(tokens[k]).balanceOf(address(this));
    }

    function getPoolTokens(address pool) external view returns (address[] memory) { return tokensOf[pool]; }
    function getHooksConfig(address pool) external view returns (IBalancerV3Vault.HooksConfig memory) { return hooksOf[pool]; }

    function _touch(address t, int256 d) internal {
        if (delta[t] == 0) touched.push(t);
        delta[t] += d;
    }

    function unlock(bytes calldata data) external returns (bytes memory r) {
        require(!unlocked, "VaultIsUnlocked");
        unlocked = true;
        bool ok;
        (ok, r) = msg.sender.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
        for (uint256 k; k < touched.length; ++k) require(delta[touched[k]] == 0, "BalanceNotSettled");
        delete touched;
        unlocked = false;
    }

    function swap(IBalancerV3Vault.VaultSwapParams memory p) external returns (uint256, uint256, uint256) {
        require(unlocked, "VaultIsNotUnlocked");
        require(isPoolRegistered[p.pool], "PoolNotRegistered");
        require(p.kind == IBalancerV3Vault.SwapKind.EXACT_IN, "kind");
        uint256 out = p.amountGivenRaw * _rate(p.tokenIn) / 10_000;
        require(out >= p.limitRaw, "SwapLimit");
        _touch(p.tokenIn, int256(p.amountGivenRaw));
        _touch(p.tokenOut, -int256(out));
        return (out, p.amountGivenRaw, out);
    }

    function settle(address token, uint256 hint) external returns (uint256 credit) {
        require(unlocked, "VaultIsNotUnlocked");
        // Vault.sol settle (main, read 21/10): reserves := balance, credit = min(delta, hint);
        // a leftover beyond the hint is absorbed into reserves, not credited.
        uint256 cur = MockERC20(token).balanceOf(address(this));
        uint256 diff = cur - reserves[token];
        reserves[token] = cur;
        credit = diff < hint ? diff : hint;
        _touch(token, -int256(credit));
    }

    function sendTo(address token, address to, uint256 amount) external {
        require(unlocked, "VaultIsNotUnlocked");
        reserves[token] -= amount;
        _touch(token, int256(amount));
        MockERC20(token).transfer(to, amount);
    }

    function quote(bytes calldata data) external returns (bytes memory r) {
        require(tx.origin == address(0), "NotStaticCall");
        unlocked = true;
        bool ok;
        (ok, r) = msg.sender.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
        for (uint256 k; k < touched.length; ++k) delta[touched[k]] = 0;
        delete touched;
        unlocked = false;
    }

    /// Hostile: the Vault calling an adapter's callback outside the adapter's own unlock.
    function poke(address target, bytes calldata data) external {
        unlocked = true;
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
        unlocked = false;
    }
}
