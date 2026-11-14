// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../../mocks/MockERC20.sol";
import {IInfinityCLPoolManager, ILockCallback} from "../../../src/adapters/BlazePhoenixAdapterInfinityCL.sol";

/// Faithful to pancake infinity-core Vault.sol where the adapter touches it (ERC-20 only): `lock`
/// refuses a second locker (LockerAlreadySet), calls back msg.sender's `lockAcquired`, and reverts
/// CurrencyNotSettled unless every (settler, currency) delta is back to zero; `sync` records the
/// Vault's balance of a currency; `settle` credits the balance gained since that sync, and with no
/// sync it is the native path (msg.value, so an ERC-20 paid without a sync is credited nothing);
/// `take` debits and transfers; `accountAppBalanceDelta` only from the registered app, only while
/// locked (NoLocker). Hostile (SETTLE custody): `poke` calls an adapter's callback from the Vault,
/// as the locker, outside any lock the adapter asked for.
contract MockInfVault {
    error LockerAlreadySet(address locker);
    error CurrencyNotSettled();
    error NoLocker();
    error AppUnregistered();

    address public getLocker;
    address public app;
    uint256 public unsettled;
    mapping(address => mapping(address => int256)) public delta; // settler => currency => credit
    address internal synced;
    uint256 internal syncedReserve;

    function registerApp(address a) external { app = a; }

    function lock(bytes calldata data) external returns (bytes memory result) {
        if (getLocker != address(0)) revert LockerAlreadySet(getLocker);
        getLocker = msg.sender;
        result = ILockCallback(msg.sender).lockAcquired(data);
        if (unsettled != 0) revert CurrencyNotSettled();
        getLocker = address(0);
    }

    function _account(address settler, address currency, int256 d) internal {
        if (d == 0) return;
        int256 prev = delta[settler][currency];
        int256 next = prev + d;
        if (prev == 0) ++unsettled;
        else if (next == 0) --unsettled;
        delta[settler][currency] = next;
    }

    function sync(address currency) external {
        synced = currency;
        syncedReserve = MockERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        if (getLocker == address(0)) revert NoLocker();
        address c = synced;
        if (c != address(0)) {
            paid = MockERC20(c).balanceOf(address(this)) - syncedReserve;
            synced = address(0);
        } else {
            paid = msg.value;
        }
        _account(msg.sender, c, int256(paid));
    }

    function take(address currency, address to, uint256 amount) external {
        if (getLocker == address(0)) revert NoLocker();
        _account(msg.sender, currency, -int256(amount));
        MockERC20(currency).transfer(to, amount);
    }

    function accountAppBalanceDelta(address c0, address c1, int256 d, address settler) external {
        if (getLocker == address(0)) revert NoLocker();
        if (msg.sender != app) revert AppUnregistered();
        _account(settler, c0, d >> 128);
        _account(settler, c1, int256(int128(d)));
    }

    /// Hostile: the Vault calling an adapter's callback outside the adapter's own lock.
    function poke(address target, bytes calldata data) external {
        getLocker = target;
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
        getLocker = address(0);
    }
}

interface IMockBeforeSwap {
    function beforeSwap(address sender) external;
}

/// Faithful to infinity-core CLPoolManager.sol / CLPool.sol where the adapter touches it:
/// `initialize` records poolIdToPoolKey[keccak256(abi.encode(key))]; `swap` refuses a key of
/// another manager, an amount of zero, an uninitialised pool, and a price limit outside
/// (MIN_SQRT_RATIO, current) / (current, MAX_SQRT_RATIO) (CLPool.sol:212-214); it calls the hook's
/// beforeSwap when bit 6 of the bitmap is set and the caller is not the hook, and a revert of the
/// hook reaches the caller only inside the ERC-7751 envelope WrappedError(hook, selector, reason,
/// HookCallFailed) (Hooks.sol:77-83, CustomRevert.sol:13-47); exact-in only:
/// consumed = min(amount, maxIn) (a pool that runs out of liquidity before the limit), out =
/// consumed * (1e6 - fee) / 1e6 * rate / 1e18, accounted to the caller at the Vault (input
/// negative) and returned as the BalanceDelta.
contract MockInfCLPoolManager {
    error PoolManagerMismatch();
    error SwapAmountCannotBeZero();
    error PoolNotInitialized();
    error InvalidSqrtPriceLimit(uint160 current, uint160 limit);
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);
    error HookCallFailed();

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    address public vault;
    mapping(bytes32 => IInfinityCLPoolManager.PoolKey) internal keys;
    mapping(bytes32 => uint160) public sqrtPriceOf;
    mapping(bytes32 => uint128) public getLiquidity;
    mapping(bytes32 => uint256) public maxIn;
    mapping(bytes32 => mapping(bool => uint256)) public rateOf;

    constructor(address v) { vault = v; }

    function initialize(IInfinityCLPoolManager.PoolKey memory key, uint160 sp, uint128 liq) external returns (bytes32 id) {
        id = keccak256(abi.encode(key));
        keys[id] = key;
        (sqrtPriceOf[id], getLiquidity[id]) = (sp, liq);
    }

    function setState(bytes32 id, uint160 sp, uint128 liq) external { (sqrtPriceOf[id], getLiquidity[id]) = (sp, liq); }
    function setMaxIn(bytes32 id, uint256 m) external { maxIn[id] = m; }
    function setRate(bytes32 id, bool zeroForOne, uint256 r) external { rateOf[id][zeroForOne] = r; }

    function poolIdToPoolKey(bytes32 id) external view returns (address, address, address, address, uint24, bytes32) {
        IInfinityCLPoolManager.PoolKey memory k = keys[id];
        return (k.currency0, k.currency1, k.hooks, k.poolManager, k.fee, k.parameters);
    }

    function getSlot0(bytes32 id) external view returns (uint160, int24, uint24, uint24) {
        return (sqrtPriceOf[id], 0, 0, keys[id].fee);
    }

    function swap(IInfinityCLPoolManager.PoolKey memory key, IInfinityCLPoolManager.SwapParams memory p, bytes calldata)
        external returns (int256 d)
    {
        if (key.poolManager != address(this)) revert PoolManagerMismatch();
        if (p.amountSpecified == 0) revert SwapAmountCannotBeZero();
        bytes32 id = keccak256(abi.encode(key));
        uint160 sp = sqrtPriceOf[id];
        if (sp == 0) revert PoolNotInitialized();
        if (p.zeroForOne ? (p.sqrtPriceLimitX96 >= sp || p.sqrtPriceLimitX96 <= MIN_SQRT_RATIO)
                         : (p.sqrtPriceLimitX96 <= sp || p.sqrtPriceLimitX96 >= MAX_SQRT_RATIO)) {
            revert InvalidSqrtPriceLimit(sp, uint160(p.sqrtPriceLimitX96));
        }
        if (uint256(key.parameters) & (1 << 6) != 0 && msg.sender != key.hooks) {
            _callHook(key.hooks, abi.encodeCall(IMockBeforeSwap.beforeSwap, (msg.sender)));
        }
        require(p.amountSpecified < 0, "mock: exact-in only");
        uint256 amt = uint256(-p.amountSpecified);
        uint256 used = maxIn[id] != 0 && maxIn[id] < amt ? maxIn[id] : amt;
        uint256 r = rateOf[id][p.zeroForOne];
        uint256 out = used * (1e6 - key.fee) / 1e6 * (r == 0 ? 1e18 : r) / 1e18;
        (int256 a0, int256 a1) = p.zeroForOne ? (-int256(used), int256(out)) : (int256(out), -int256(used));
        d = (a0 << 128) | int256(uint256(uint128(int128(a1))));
        MockInfVault(vault).accountAppBalanceDelta(key.currency0, key.currency1, d, msg.sender);
    }

    /// Hooks.callHook: on a revert, CustomRevert.bubbleUpAndRevertWith(hook, bytes4(data),
    /// HookCallFailed.selector), whose assembly lays out the ABI encoding of this error.
    function _callHook(address h, bytes memory data) internal {
        (bool ok, bytes memory r) = h.call(data);
        if (!ok) revert WrappedError(h, bytes4(data), r, abi.encodePacked(HookCallFailed.selector));
    }
}

/// A hook the adapter pins. Counts its beforeSwap calls; when armed, calls `target` with `payload`
/// from inside the swap and records the answer (a hook re-entering the adapter's callback).
contract PinnedHook {
    uint256 public calls;
    address public target;
    bytes public payload;
    bool public lastOk;
    bytes public lastRet;

    function arm(address t, bytes calldata p) external { (target, payload) = (t, p); }

    function beforeSwap(address) external {
        ++calls;
        if (target != address(0)) {
            (bool ok, bytes memory r) = target.call(payload);
            (lastOk, lastRet) = (ok, r);
        }
    }
}

contract SecondHook {
    uint256 public calls;
    function beforeSwap(address) external { calls += 2; }
}

/// A pinned hook that reverts beforeSwap with the adapter's own quote payload: QuoteOut(1e30).
contract ForgingHook {
    function beforeSwap(address) external pure {
        bytes memory e = abi.encodeWithSignature("QuoteOut(uint256)", uint256(1e30));
        assembly { revert(add(e, 32), mload(e)) }
    }
}

contract OtherHook { function ok() external pure returns (uint256) { return 2; } }

/// Faithful to infinity-core BinPoolManager.sol:133-177 / BinPool.sol:111-215 where the adapter
/// touches it: `initialize` records poolIdToPoolKey[keccak256(abi.encode(key))] and the active
/// bin; `swap` refuses an amount of zero and an uninitialised pool, calls the hook's beforeSwap
/// as the CL mock does (BinHooks calls the shared Hooks.callHook: the same ERC-7751 envelope);
/// exact-in only, and an exact-in spends the whole input or reverts BinPool__OutOfLiquidity (the
/// bin loop ends only at amountsLeft == 0, BinPool.sol:188-199): `maxIn` is what the bins can
/// take; out = amt * (1e6 - fee) / 1e6 * rate / 1e18, and an out of 0 is
/// BinPool__InsufficientAmountUnSpecified (BinPool.sol:203). `getBin` answers each bin's own
/// reserves, so a read of the wrong bin is seen.
contract MockInfBinPoolManager {
    error PoolNotInitialized();
    error AmountSpecifiedIsZero();
    error BinPool__OutOfLiquidity();
    error BinPool__InsufficientAmountUnSpecified();
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);
    error HookCallFailed();

    address public vault;
    mapping(bytes32 => IInfinityCLPoolManager.PoolKey) internal keys;
    mapping(bytes32 => uint24) public activeIdOf;
    mapping(bytes32 => mapping(uint24 => uint256)) internal binOf; // reserveX << 128 | reserveY
    mapping(bytes32 => uint256) public maxIn;
    mapping(bytes32 => mapping(bool => uint256)) public rateOf;
    /// Off unless a test sets it: a hook's revert then leaves `swap` raw, without the envelope
    /// the live manager puts on it, so what the test pins is the adapter's own catch.
    bool public rawHookRevert;

    constructor(address v) { vault = v; }

    function setRawHookRevert(bool on) external { rawHookRevert = on; }

    function initialize(IInfinityCLPoolManager.PoolKey memory key, uint24 activeId) external returns (bytes32 id) {
        id = keccak256(abi.encode(key));
        (keys[id], activeIdOf[id]) = (key, activeId);
    }

    function setBin(bytes32 id, uint24 binId, uint128 rx, uint128 ry) external { binOf[id][binId] = uint256(rx) << 128 | ry; }
    function setActiveId(bytes32 id, uint24 a) external { activeIdOf[id] = a; }
    function setMaxIn(bytes32 id, uint256 m) external { maxIn[id] = m; }
    function setRate(bytes32 id, bool swapForY, uint256 r) external { rateOf[id][swapForY] = r; }

    function poolIdToPoolKey(bytes32 id) external view returns (address, address, address, address, uint24, bytes32) {
        IInfinityCLPoolManager.PoolKey memory k = keys[id];
        return (k.currency0, k.currency1, k.hooks, k.poolManager, k.fee, k.parameters);
    }

    function getSlot0(bytes32 id) external view returns (uint24, uint24, uint24) {
        return (activeIdOf[id], 0, keys[id].fee);
    }

    function getBin(bytes32 id, uint24 binId) external view returns (uint128, uint128, uint256, uint256) {
        uint256 b = binOf[id][binId];
        return (uint128(b >> 128), uint128(b), 0, 0);
    }

    function swap(IInfinityCLPoolManager.PoolKey memory key, bool swapForY, int128 amountSpecified, bytes calldata)
        external returns (int256 d)
    {
        if (amountSpecified == 0) revert AmountSpecifiedIsZero();
        bytes32 id = keccak256(abi.encode(key));
        if (keys[id].poolManager == address(0)) revert PoolNotInitialized();
        if (uint256(key.parameters) & (1 << 6) != 0 && msg.sender != key.hooks) {
            (bool ok, bytes memory r) = key.hooks.call(abi.encodeCall(IMockBeforeSwap.beforeSwap, (msg.sender)));
            if (!ok && rawHookRevert) assembly { revert(add(r, 32), mload(r)) }
            if (!ok) revert WrappedError(key.hooks, IMockBeforeSwap.beforeSwap.selector, r, abi.encodePacked(HookCallFailed.selector));
        }
        require(amountSpecified < 0, "mock: exact-in only");
        uint256 amt = uint256(-int256(amountSpecified));
        if (maxIn[id] != 0 && amt > maxIn[id]) revert BinPool__OutOfLiquidity();
        uint256 r = rateOf[id][swapForY];
        uint256 out = amt * (1e6 - key.fee) / 1e6 * (r == 0 ? 1e18 : r) / 1e18;
        if (out == 0) revert BinPool__InsufficientAmountUnSpecified();
        (int256 a0, int256 a1) = swapForY ? (-int256(amt), int256(out)) : (int256(out), -int256(amt));
        d = (a0 << 128) | int256(uint256(uint128(int128(a1))));
        MockInfVault(vault).accountAppBalanceDelta(key.currency0, key.currency1, d, msg.sender);
    }
}
