// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../../mocks/MockERC20.sol";
import {IFluidDexT1} from "../../../src/adapters/BlazePhoenixAdapterFluidDexT1.sol";

interface IDexCallbackLike {
    function dexCallback(address token, uint256 amount) external;
}

interface IWrapperQuoteLike {
    function quote(bool zeroForOne, uint256 amtIn) external view returns (uint256 out, uint256 depth18);
}

/// Fluid Liquidity, as far as the adapter sees it: it holds the tokens, answers `readFromStorage`,
/// and pays out only for a pool its factory created.
contract MockFluidLiquidity {
    mapping(bytes32 => uint256) internal _s;
    mapping(address => bool) public isDex;
    address public immutable factory;

    constructor(address f) { factory = f; }

    function set(bytes32 slot, uint256 v) external { _s[slot] = v; }
    function readFromStorage(bytes32 slot) external view returns (uint256) { return _s[slot]; }
    function addDex(address d) external { require(msg.sender == factory, "factory"); isDex[d] = true; }

    function pay(address token, address to, uint256 amt) external {
        require(isDex[msg.sender], "not a dex");
        MockERC20(token).transfer(to, amt);
    }
}

/// DexFactory.deployDex: CREATE at nonce = ++totalDexes (dexId), so getDexAddress(id) is the
/// CREATE address of (factory, id).
contract MockFluidFactory {
    uint256 public totalDexes;

    function deploy(address liquidity, address token0, address token1) external returns (MockFluidDexT1 d) {
        uint256 id = ++totalDexes;
        d = new MockFluidDexT1(id, liquidity, token0, token1);
        if (MockFluidLiquidity(liquidity).factory() == address(this)) MockFluidLiquidity(liquidity).addDex(address(d));
    }
}

/// A Fluid DEX T1 pool at a fixed rate, faithful in the parts the adapter relies on:
/// `swapInWithCallback` sets the reentrancy bit (dexVariables bit 0), asks the caller for
/// exactly amountIn through `dexCallback` (main.sol liquidityCallback), requires Liquidity to
/// have received it, has Liquidity pay `to`, and clears the bit; `swapIn(.., 0x…dEaD)` reverts
/// FluidDexSwapResult(out). Hostile modes for the callback tests.
contract MockFluidDexT1 {
    enum Mode { Honest, Twice, Over, WrongToken, NoCallback, Intruder, ProbeQuote, Paused }

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public immutable id;
    address public immutable liquidity;
    address public immutable token0;
    address public immutable token1;

    uint256 public dexVariables;
    uint256 public rateBps = 9_970;
    Mode public mode;
    uint256 public claimedId;
    address public claimedLiquidity;
    Intruder public intruder;
    bool public intruderPaid;
    address public probe;
    uint256 public probedDepth = type(uint256).max;

    error Paused();

    constructor(uint256 id_, address liquidity_, address t0, address t1) {
        (id, liquidity, token0, token1) = (id_, liquidity_, t0, t1);
        (claimedId, claimedLiquidity) = (id_, liquidity_);
    }

    function setMode(Mode m) external { mode = m; }
    function setRate(uint256 r) external { rateBps = r; }
    function setDexVariables(uint256 v) external { dexVariables = v; }
    function lie(uint256 id_, address liq) external { (claimedId, claimedLiquidity) = (id_, liq); }
    function setIntruder(Intruder i) external { intruder = i; }
    function setProbe(address w) external { probe = w; }

    function slot(uint256 k) public view returns (bytes32) { return keccak256(abi.encode(address(this), k)); }

    function constantsView() external view returns (IFluidDexT1.ConstantViews memory c) {
        c.dexId = claimedId;
        c.liquidity = claimedLiquidity;
        c.factory = msg.sender; // never read by the adapter
        c.token0 = token0;
        c.token1 = token1;
        c.supplyToken0Slot = slot(0);
        c.borrowToken0Slot = slot(1);
        c.supplyToken1Slot = slot(2);
        c.borrowToken1Slot = slot(3);
        c.exchangePriceToken0Slot = slot(4);
        c.exchangePriceToken1Slot = slot(5);
    }

    function readFromStorage(bytes32 s) external view returns (uint256) {
        return s == bytes32(0) ? dexVariables : 0;
    }

    function _out(uint256 amt) internal view returns (uint256) { return amt * rateBps / 10_000; }

    function swapIn(bool, uint256 amountIn, uint256, address to) external payable returns (uint256) {
        if (mode == Mode.Paused) revert Paused();
        require(dexVariables & 1 == 0, "reentered");
        dexVariables |= 1; // _check writes the bit before the result: the simulation is not a view
        if (to == DEAD) revert IFluidDexT1.FluidDexSwapResult(_out(amountIn));
        revert("mock: only the simulation");
    }

    function swapInWithCallback(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256 out)
    {
        require(dexVariables & 1 == 0, "reentered");
        dexVariables |= 1;
        (address tIn, address tOut) = swap0to1 ? (token0, token1) : (token1, token0);
        out = _out(amountIn);
        require(out >= amountOutMin, "out min");
        uint256 before = MockERC20(tIn).balanceOf(liquidity);
        IDexCallbackLike cb = IDexCallbackLike(msg.sender);
        Mode m = mode;
        if (m == Mode.Twice) { cb.dexCallback(tIn, amountIn); cb.dexCallback(tIn, amountIn); }
        else if (m == Mode.Over) cb.dexCallback(tIn, amountIn + 1);
        else if (m == Mode.WrongToken) cb.dexCallback(tOut, amountIn);
        else if (m == Mode.Intruder) {
            try intruder.steal(msg.sender, tIn, amountIn) { intruderPaid = true; } catch {}
            cb.dexCallback(tIn, amountIn);
        } else if (m == Mode.ProbeQuote) {
            (, probedDepth) = IWrapperQuoteLike(probe).quote(true, 0);
            cb.dexCallback(tIn, amountIn);
        } else if (m != Mode.NoCallback) cb.dexCallback(tIn, amountIn);
        if (m != Mode.NoCallback) {
            require(MockERC20(tIn).balanceOf(liquidity) >= before + amountIn, "Liquidity: not received");
        }
        MockFluidLiquidity(liquidity).pay(tOut, to == address(0) ? msg.sender : to, out);
        dexVariables &= ~uint256(1);
    }
}

/// Another contract calling the adapter's callback while a real exec is open.
contract Intruder {
    function steal(address adapter, address token, uint256 amount) external {
        IDexCallbackLike(adapter).dexCallback(token, amount);
    }
}
