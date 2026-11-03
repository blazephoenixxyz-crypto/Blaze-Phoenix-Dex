// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "../../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

interface IAlgebraSwapCallbackMock {
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// Algebra Integral factory, custom-venue half: the registry `customPoolByPair` (both token
/// orders, as AlgebraFactory.sol:56 keeps it) and one venue deployer of its own.
contract MockAlgebraFactory {
    MockAlgebraVenueDeployer public immutable deployer;
    mapping(address => mapping(address => mapping(address => address))) public customPoolByPair;

    constructor() {
        deployer = new MockAlgebraVenueDeployer();
    }

    /// The custom salt keccak256(abi.encode(customDeployer, token0, token1)), as Algebra's.
    function createCustomVenue(address d, address tA, address tB, address plugin) external returns (MockAlgebraVenue v) {
        (address a, address b) = tA < tB ? (tA, tB) : (tB, tA);
        v = deployer.deploy(keccak256(abi.encode(d, a, b)), plugin, a, b);
        registerAs(d, a, b, address(v));
    }

    /// A registry that says what it is told (the lie the adapter must not believe).
    function registerAs(address d, address a, address b, address v) public {
        customPoolByPair[d][a][b] = v;
        customPoolByPair[d][b][a] = v;
    }
}

/// Algebra's deployer: the venue has no constructor arguments and reads them from here.
contract MockAlgebraVenueDeployer {
    address public pPlugin;
    address public pToken0;
    address public pToken1;

    /// Any salt and any tokens: a venue at the right CREATE2 address can trade other tokens.
    function deploy(bytes32 salt, address plugin, address a, address b) external returns (MockAlgebraVenue v) {
        (pPlugin, pToken0, pToken1) = (plugin, a, b);
        v = new MockAlgebraVenue{salt: salt}();
        (pPlugin, pToken0, pToken1) = (address(0), address(0), address(0));
    }
}

/// A plugin whose afterSwap may call `target` with `data` and bubbles the revert.
contract MockAlgebraPlugin {
    address public target;
    bytes public data;
    uint256 public calls;

    function setReenter(address t, bytes calldata d) external {
        (target, data) = (t, d);
    }

    function afterSwap() external {
        ++calls;
        if (target == address(0)) return;
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }
}

/// A plugin the Gate's code scan refuses (DELEGATECALL).
contract MockAlgebraDirtyPlugin {
    function afterSwap() external {
        (bool ok, ) = msg.sender.delegatecall("");
        ok;
    }
}

/// Algebra Integral venue, exact input only. The swap loop is SwapCalculation's, ported with
/// PriceMovementMath.movePriceTowardsTarget and TokenDeltaMath (bh-build.md, Algebra facts);
/// the tick list is TickManagement's linked list with its MIN/MAX sentinels.
contract MockAlgebraVenue {
    struct Tick {
        uint256 liquidityTotal;
        int128 liquidityDelta;
        int24 prevTick;
        int24 nextTick;
        uint256 outerFeeGrowth0Token;
        uint256 outerFeeGrowth1Token;
    }

    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    uint160 internal constant MIN_SQRT = 4_295_128_739;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    /// Algebra's IAlgebraPoolErrors selector for a venue that is mid-operation (0xcf309012).
    bytes4 internal constant BUSY = 0xcf309012;
    error InvalidLimit();
    error InsufficientInput();

    enum Pay { Honest, PlusOne, Zero }

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    address public plugin;

    uint160 public price;
    int24 public tick;
    uint16 public lastFee = 3000;
    uint8 public pluginConfig;
    uint16 public communityFee = 100;
    bool public idle = true;

    uint128 public liquidity;
    int24 public prevTickGlobal = MIN_TICK;
    int24 public nextTickGlobal = MAX_TICK;
    mapping(int24 => Tick) public ticks;
    uint128 internal reserve0;
    uint128 internal reserve1;
    Pay public pay;
    bool internal swapped;

    constructor() {
        MockAlgebraVenueDeployer d = MockAlgebraVenueDeployer(msg.sender);
        (plugin, token0, token1) = (d.pPlugin(), d.pToken0(), d.pToken1());
        factory = msg.sender;
        ticks[MIN_TICK].prevTick = MIN_TICK;
        ticks[MIN_TICK].nextTick = MAX_TICK;
        ticks[MAX_TICK].prevTick = MIN_TICK;
        ticks[MAX_TICK].nextTick = MAX_TICK;
    }

    // ─── state, as IAlgebraPoolState answers it ───

    function globalState() external view returns (uint160, int24, uint16, uint8, uint16, bool) {
        return (price, tick, lastFee, pluginConfig, communityFee, idle);
    }

    /// Note the order: nextTick before previousTick (AlgebraPoolBase.sol:112-128).
    function safelyGetStateOfAMM() external view returns (uint160, int24, uint16, uint8, uint128, int24, int24) {
        if (!idle) _busy();
        return (price, tick, lastFee, pluginConfig, liquidity, nextTickGlobal, prevTickGlobal);
    }

    function getReserves() external view returns (uint128, uint128) {
        return (reserve0, reserve1);
    }

    // ─── test controls ───

    function initialize(uint160 sp, int24 tk) external {
        (price, tick) = (sp, tk);
    }

    /// Range liquidity, before the first swap only: both ticks enter the list, and the active
    /// liquidity counts it when the price is inside [lo, hi).
    function mintRange(int24 lo, int24 hi, uint128 l) external {
        require(!swapped && lo < hi && lo > MIN_TICK && hi < MAX_TICK, "mock: range");
        _addTick(lo, int128(l), l);
        _addTick(hi, -int128(l), l);
        if (BPC.sqrtPriceAtTick(lo) <= price && price < BPC.sqrtPriceAtTick(hi)) liquidity += l;
        _neighbour(lo);
        _neighbour(hi);
    }

    /// prevTickGlobal: the highest listed tick at or below the price; nextTickGlobal: the lowest above.
    function _neighbour(int24 t) internal {
        if (BPC.sqrtPriceAtTick(t) <= price) {
            if (t > prevTickGlobal) prevTickGlobal = t;
        } else if (t < nextTickGlobal) {
            nextTickGlobal = t;
        }
    }

    function sync() external {
        reserve0 = uint128(MockERC20(token0).balanceOf(address(this)));
        reserve1 = uint128(MockERC20(token1).balanceOf(address(this)));
    }

    function setPluginConfig(uint8 c) external {
        pluginConfig = c;
    }

    /// Algebra's setPlugin resets the config.
    function setPlugin(address p) external {
        (plugin, pluginConfig) = (p, 0);
    }

    function setFee(uint16 f) external {
        lastFee = f;
    }

    function setIdle(bool i) external {
        idle = i;
    }

    function setPay(Pay p) external {
        pay = p;
    }

    // ─── swap (AlgebraPool.sol:246-298 order) ───

    function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160 limitSqrtPrice, bytes calldata data)
        external returns (int256 amount0, int256 amount1)
    {
        if (!idle) _busy();
        idle = false;
        require(amountRequired > 0, "mock: exact input only");
        (uint256 spent, uint256 out, uint256 fees) = _calculateSwap(zeroToOne, uint256(amountRequired), limitSqrtPrice);
        swapped = true;
        uint256 kept = fees * communityFee / 1000;
        (address tIn, address tOut) = zeroToOne ? (token0, token1) : (token1, token0);
        if (zeroToOne) {
            (amount0, amount1) = (int256(spent), -int256(out));
            (reserve0, reserve1) = (reserve0 + uint128(spent - kept), reserve1 - uint128(out));
        } else {
            (amount0, amount1) = (-int256(out), int256(spent));
            (reserve0, reserve1) = (reserve0 - uint128(out), reserve1 + uint128(spent - kept));
        }
        if (out != 0) MockERC20(tOut).transfer(recipient, out);
        uint256 before = MockERC20(tIn).balanceOf(address(this));
        (int256 c0, int256 c1) = (amount0, amount1);
        if (pay == Pay.PlusOne) (c0, c1) = zeroToOne ? (c0 + 1, c1) : (c0, c1 + 1);
        if (pay == Pay.Zero) (c0, c1) = (int256(0), int256(0));
        IAlgebraSwapCallbackMock(msg.sender).algebraSwapCallback(c0, c1, data);
        if (before + spent > MockERC20(tIn).balanceOf(address(this))) revert InsufficientInput();
        idle = true;
        if (pluginConfig & 2 != 0) MockAlgebraPlugin(plugin).afterSwap();
    }

    function _calculateSwap(bool zfo, uint256 rem, uint160 limit) internal returns (uint256 spent, uint256 out, uint256 fees) {
        uint160 p = price;
        if (zfo ? (limit >= p || limit <= MIN_SQRT) : (limit <= p || limit >= MAX_SQRT)) revert InvalidLimit();
        (uint128 l, int24 prev, int24 next, uint16 fee) = (liquidity, prevTickGlobal, nextTickGlobal, lastFee);
        uint256 amt = rem;
        while (true) {
            int24 t = zfo ? prev : next;
            uint160 tp = BPC.sqrtPriceAtTick(t);
            uint160 start = p;
            uint256 input;
            uint256 output;
            uint256 feeAmount;
            (p, input, output, feeAmount) = _move(zfo, p, (zfo == (tp < limit)) ? limit : tp, l, rem, fee);
            rem -= input + feeAmount;
            out += output;
            fees += feeAmount;
            if (p == tp) {
                Tick storage k = ticks[t];
                k.outerFeeGrowth0Token += 1;
                if (zfo) {
                    l = _addDelta(l, -k.liquidityDelta);
                    (prev, next, tick) = (k.prevTick, t, t - 1);
                } else {
                    l = _addDelta(l, k.liquidityDelta);
                    (prev, next, tick) = (t, k.nextTick, t);
                }
            } else if (p != start) {
                break;
            }
            if (rem == 0 || p == limit) break;
        }
        (price, liquidity, prevTickGlobal, nextTickGlobal) = (p, l, prev, next);
        spent = amt - rem;
    }

    /// PriceMovementMath.movePriceTowardsTarget, exact input.
    function _move(bool zfo, uint160 p, uint160 target, uint128 l, uint256 rem, uint16 fee)
        internal pure returns (uint160 np, uint256 input, uint256 output, uint256 feeAmount)
    {
        uint256 afterFee = BPC.mulDiv(rem, 1e6 - fee, 1e6);
        input = zfo ? _token0Delta(target, p, l, true) : _token1Delta(p, target, l, true);
        if (afterFee >= input) {
            np = target;
            feeAmount = BPC.mulDivUp(input, fee, 1e6 - fee);
        } else {
            np = _newPriceAfterInput(p, l, afterFee, zfo);
            require(target != np, "mock: assert");
            input = zfo ? _token0Delta(np, p, l, true) : _token1Delta(p, np, l, true);
            feeAmount = rem - input;
        }
        output = zfo ? _token1Delta(np, p, l, false) : _token0Delta(p, np, l, false);
    }

    /// TokenDeltaMath.getToken0Delta(lo, hi).
    function _token0Delta(uint160 lo, uint160 hi, uint128 l, bool up) internal pure returns (uint256) {
        uint256 d = uint256(hi) - lo;
        require(d < hi, "mock: lo");
        if (!up) return BPC.mulDiv(d, uint256(l) << 96, hi) / lo;
        uint256 q = BPC.mulDivUp(d, uint256(l) << 96, hi);
        return q / lo + (q % lo > 0 ? 1 : 0);
    }

    /// TokenDeltaMath.getToken1Delta(lo, hi).
    function _token1Delta(uint160 lo, uint160 hi, uint128 l, bool up) internal pure returns (uint256) {
        uint256 d = uint256(hi) - lo;
        return up ? BPC.mulDivUp(d, l, 1 << 96) : BPC.mulDiv(d, l, 1 << 96);
    }

    /// PriceMovementMath.getNewPrice, from input.
    function _newPriceAfterInput(uint160 p, uint128 l, uint256 amt, bool zfo) internal pure returns (uint160) {
        require(l != 0, "mock: liquidity");
        if (amt == 0) return p;
        uint256 n = uint256(l) << 96;
        if (zfo) {
            unchecked {
                uint256 product = amt * p;
                if (product / amt == p) {
                    uint256 den = n + product;
                    if (den >= n) return uint160(BPC.mulDivUp(n, p, den));
                }
            }
            uint256 y = n / p + amt;
            return uint160(n / y + (n % y > 0 ? 1 : 0));
        }
        uint256 q = amt <= type(uint160).max ? (amt << 96) / l : BPC.mulDiv(amt, 1 << 96, l);
        uint256 r = uint256(p) + q;
        require(r <= type(uint160).max, "mock: price");
        return uint160(r);
    }

    function _addDelta(uint128 l, int128 d) internal pure returns (uint128) {
        return d < 0 ? l - uint128(-d) : l + uint128(d);
    }

    function _addTick(int24 t, int128 delta, uint128 l) internal {
        Tick storage k = ticks[t];
        if (k.liquidityTotal == 0) {
            int24 p = MIN_TICK;
            while (ticks[p].nextTick < t) p = ticks[p].nextTick;
            int24 n = ticks[p].nextTick;
            (k.prevTick, k.nextTick) = (p, n);
            ticks[p].nextTick = t;
            ticks[n].prevTick = t;
        }
        k.liquidityTotal += l;
        k.liquidityDelta += delta;
    }

    function _busy() internal pure {
        bytes4 s = BUSY;
        assembly {
            mstore(0, s)
            revert(0, 4)
        }
    }
}
