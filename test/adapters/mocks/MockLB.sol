// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

interface IMockLBToken {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amt) external returns (bool);
}

/// The Liquidity Book factory's registry (LFJ v2.1 / v2.2 LBFactory, Pharaoh DLMMFactory):
/// `getLBPairInformation` sorts the two tokens and reads the record under a uint256 bin step;
/// a pair nobody created answers all zeros.
contract MockLBFactory {
    struct Info {
        uint16 binStep;
        address pair;
    }

    mapping(address => mapping(address => mapping(uint256 => Info))) internal _info;
    /// The fourth field of every record, as the owner's setLBPairIgnored leaves it.
    bool public ignoredForRouting;

    function setIgnored(bool ignored) external {
        ignoredForRouting = ignored;
    }

    /// Registers `pair` under its own two tokens, as createLBPair does.
    function register(MockLBPair pair, uint16 binStep) external {
        _set(pair.getTokenX(), pair.getTokenY(), binStep, address(pair));
    }

    /// Registers `pair` under tokens it may not hold: a registry that lies about its record.
    function registerAs(address tokenA, address tokenB, uint16 binStep, address pair) external {
        _set(tokenA, tokenB, binStep, pair);
    }

    function _set(address a, address b, uint16 binStep, address pair) internal {
        (a, b) = a < b ? (a, b) : (b, a);
        _info[a][b][binStep] = Info(binStep, pair);
    }

    function getLBPairInformation(address tokenA, address tokenB, uint256 binStep)
        external view returns (uint16, address, bool, bool)
    {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        Info memory i = _info[a][b][binStep];
        return (i.binStep, i.pair, false, ignoredForRouting);
    }
}

/// A Liquidity Book pair (LFJ v2.2 LBPair / Pharaoh DLMMPool; v2.1 when `hooksMode` is 1) at one
/// constant price, with its OWN maths so the adapter is checked against it and against values
/// fixed by hand: Y raw per X raw = PN / PD; an input fee of FEE_BPS rounded up (FeeHelper); the
/// output rounded down; liquidity up to the reserve the pair reports on the output side, past
/// which `getSwapOut` answers the input it could not use (the real loop's break) and `swap`
/// reverts OutOfLiquidity. PUSH: `swap` trades what arrived above the books, input side only.
contract MockLBPair {
    error LBPair__InsufficientAmountIn();
    error LBPair__OutOfLiquidity();
    error LBPair__InsufficientAmountOut();
    error ReentrancyGuardReentrantCall();
    error BinHelper__MaxLiquidityPerBinExceeded();
    error Hooks__CallFailed();

    uint256 internal constant FEE_BPS = 30;
    uint256 internal constant PN = 2;
    uint256 internal constant PD = 1;
    uint256 internal constant BEFORE_SWAP = 1 << 160;
    uint256 internal constant AFTER_SWAP = 1 << 161;
    bytes4 internal constant BEFORE_SWAP_SEL = 0xfeee3735; // beforeSwap(address,address,bool,bytes32)
    bytes4 internal constant AFTER_SWAP_SEL = 0x53e8079b; // afterSwap(address,address,bool,bytes32)

    address internal immutable X;
    address internal immutable Y;
    /// The books (_reserves): protocol fees included.
    uint128 public reserveX;
    uint128 public reserveY;
    uint128 public pfX;
    uint128 public pfY;
    uint256 public protocolShare = 1_000;
    bytes32 public hooksParameters;
    /// 0 v2.2 / DLMM (answers getLBHooksParameters) | 1 v2.1 (no such function: empty revert)
    /// | 2 the read reverts with data | 3 the read answers 16 bytes
    uint8 public hooksMode;
    bool public swapOutReverts;
    bool internal _entered;

    constructor(address x, address y) {
        (X, Y) = (x, y);
    }

    function getTokenX() external view returns (address) {
        return X;
    }

    function getTokenY() external view returns (address) {
        return Y;
    }

    /// The books follow the balances (what deposits would have written).
    function sync() external {
        reserveX = uint128(IMockLBToken(X).balanceOf(address(this)));
        reserveY = uint128(IMockLBToken(Y).balanceOf(address(this)));
    }

    function setProtocolFees(uint128 fx, uint128 fy) external {
        (pfX, pfY) = (fx, fy);
    }

    function setHooks(bytes32 hp) external {
        hooksParameters = hp;
    }

    function setHooksMode(uint8 m) external {
        hooksMode = m;
    }

    function setSwapOutReverts(bool r) external {
        swapOutReverts = r;
    }

    /// What the LPs own: the books less the protocol's fees.
    function getReserves() external view returns (uint128, uint128) {
        return (reserveX - pfX, reserveY - pfY);
    }

    function getLBHooksParameters() external view returns (bytes32) {
        uint8 m = hooksMode;
        if (m == 1) revert();
        if (m == 2) revert Hooks__CallFailed();
        if (m == 3) {
            assembly ("memory-safe") {
                mstore(0x00, 0)
                return(0x00, 16)
            }
        }
        return hooksParameters;
    }

    function getSwapOut(uint128 amountIn, bool swapForY)
        external view returns (uint128 amountInLeft, uint128 amountOut, uint128 fee)
    {
        if (swapOutReverts) revert BinHelper__MaxLiquidityPerBinExceeded();
        (uint256 l, uint256 o, uint256 f) = _swapOut(amountIn, swapForY);
        (amountInLeft, amountOut, fee) = (uint128(l), uint128(o), uint128(f));
    }

    function swap(bool swapForY, address to) external returns (bytes32 amountsOut) {
        if (_entered) revert ReentrancyGuardReentrantCall();
        _entered = true;
        // PUSH: what arrived above the books, input side only (0.8 checked: a balance below the
        // books panics, as BinHelper.received does).
        uint256 received = swapForY
            ? IMockLBToken(X).balanceOf(address(this)) - reserveX
            : IMockLBToken(Y).balanceOf(address(this)) - reserveY;
        if (received == 0) revert LBPair__InsufficientAmountIn();
        bytes32 hp = hooksParameters;
        bytes32 amountsIn = swapForY ? bytes32(received) : bytes32(received << 128);
        // beforeSwap runs inside the guard, after the input is measured.
        if ((uint256(hp) & BEFORE_SWAP) != 0) _hook(hp, BEFORE_SWAP_SEL, to, swapForY, amountsIn);
        (uint256 left, uint256 out, uint256 fee) = _swapOut(received, swapForY);
        if (left != 0) revert LBPair__OutOfLiquidity();
        if (out == 0) revert LBPair__InsufficientAmountOut();
        uint128 pf = uint128(fee * protocolShare / 10_000);
        if (swapForY) {
            reserveX += uint128(received);
            pfX += pf;
            reserveY -= uint128(out);
            amountsOut = bytes32(out << 128);
        } else {
            reserveY += uint128(received);
            pfY += pf;
            reserveX -= uint128(out);
            amountsOut = bytes32(out);
        }
        require(IMockLBToken(swapForY ? Y : X).transfer(to, out), "mock: pay");
        _entered = false;
        // afterSwap runs after the guard is released.
        if ((uint256(hp) & AFTER_SWAP) != 0) _hook(hp, AFTER_SWAP_SEL, to, swapForY, amountsOut);
    }

    /// The mock's own answer for `amountIn` of the input side: (left, out, fee).
    function _swapOut(uint256 amountIn, bool swapForY)
        internal view returns (uint256 left, uint256 out, uint256 fee)
    {
        fee = (amountIn * FEE_BPS + 9_999) / 10_000;
        uint256 net = amountIn - fee;
        out = swapForY ? net * PN / PD : net * PD / PN;
        uint256 avail = swapForY ? reserveY - pfY : reserveX - pfX;
        if (out > avail) {
            left = amountIn - amountIn * avail / out;
            out = avail;
        }
    }

    /// Hooks._safeCall: a hook's revert bubbles; it must answer its own selector.
    function _hook(bytes32 hp, bytes4 sel, address to, bool swapForY, bytes32 amounts) internal {
        address h = address(uint160(uint256(hp)));
        (bool ok, bytes memory r) = h.call(abi.encodeWithSelector(sel, msg.sender, to, swapForY, amounts));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        if (r.length != 32 || bytes4(abi.decode(r, (bytes32))) != sel) revert Hooks__CallFailed();
    }
}

/// An LB hooks contract: counts its calls, answers its selector, and may call `target` with
/// `data` from inside the swap (a revert there bubbles through the pair).
contract MockLBHooks {
    uint256 public beforeCalls;
    uint256 public afterCalls;
    address public target;
    bytes public data;

    function setReenter(address t, bytes calldata d) external {
        (target, data) = (t, d);
    }

    function beforeSwap(address, address, bool, bytes32) external returns (bytes4) {
        ++beforeCalls;
        _reenter();
        return MockLBHooks.beforeSwap.selector;
    }

    function afterSwap(address, address, bool, bytes32) external returns (bytes4) {
        ++afterCalls;
        _reenter();
        return MockLBHooks.afterSwap.selector;
    }

    function _reenter() internal {
        if (target == address(0)) return;
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }
}
