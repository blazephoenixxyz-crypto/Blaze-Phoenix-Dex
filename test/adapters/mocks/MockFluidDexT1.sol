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

/// WETH9: deposit mints, withdraw pays with transfer's 2300-gas stipend.
contract MockWETH9 is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() public payable { this.mint(msg.sender, msg.value); }
    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "weth: balance");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        payable(msg.sender).transfer(wad);
    }
    receive() external payable { deposit(); }
}

/// Fluid Liquidity, as far as the adapter sees it: it holds the tokens (native ETH included),
/// answers `readFromStorage`, and pays out only for a pool its factory created; native ETH with
/// SafeTransfer.safeTransferNative's 50 000 gas (fluid-contracts-public libraries/safeTransfer.sol).
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
        if (token == NATIVE) {
            (bool ok, ) = to.call{value: amt, gas: 50_000}("");
            require(ok, "native transfer");
        } else {
            MockERC20(token).transfer(to, amt);
        }
    }

    /// A native input arrives as the operate's value (userModule/main.sol:803-811): no callback.
    receive() external payable {}
}

address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

/// DexFactory.deployDex: CREATE at nonce = ++totalDexes (dexId), so getDexAddress(id) is the
/// CREATE address of (factory, id).
contract MockFluidFactory {
    uint256 public totalDexes;

    function deploy(address liquidity, address token0, address token1) external returns (MockFluidDexT1 d) {
        uint256 id = ++totalDexes;
        d = new MockFluidDexT1(id, liquidity, token0, token1);
        if (MockFluidLiquidity(payable(liquidity)).factory() == address(this)) MockFluidLiquidity(payable(liquidity)).addDex(address(d));
    }
}

/// A Fluid DEX T1 pool at a fixed rate, faithful in the parts the adapter relies on:
/// `swapInWithCallback` sets the reentrancy bit (dexVariables bit 0), asks the caller for
/// exactly amountIn through `dexCallback` (main.sol liquidityCallback), requires Liquidity to
/// have received it, has Liquidity pay `to`, and clears the bit; `swapIn(.., 0x…dEaD)` reverts
/// FluidDexSwapResult(out). A native input is the call's value, equal to amountIn (main.sol:83-85,
/// Liquidity takes msg.value and asks no callback); `swapIn` (no callback) also executes.
/// Hostile modes for the callback tests; AskOnNative asks a callback on a native input.
contract MockFluidDexT1 {
    enum Mode { Honest, Twice, Over, WrongToken, NoCallback, Intruder, ProbeQuote, Paused, AskOnNative }

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public immutable id;
    address public immutable liquidity;
    address public immutable token0;
    address public immutable token1;

    uint256 public dexVariables;
    uint256 public rateBps = 9_970;
    /// 1 -> 0 at its own rate when set: a reversed direction prices differently.
    uint256 public rate1to0Bps;
    address public askToken;
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
    function setRate1to0(uint256 r) external { rate1to0Bps = r; }
    function setAskToken(address t) external { askToken = t; }
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

    function _out(uint256 amt, bool swap0to1) internal view returns (uint256) {
        return amt * (swap0to1 || rate1to0Bps == 0 ? rateBps : rate1to0Bps) / 10_000;
    }

    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256)
    {
        if (mode == Mode.Paused) revert Paused();
        if (to == DEAD) {
            require(dexVariables & 1 == 0, "reentered");
            dexVariables |= 1; // _check writes the bit before the result: the simulation is not a view
            revert IFluidDexT1.FluidDexSwapResult(_out(amountIn, swap0to1));
        }
        return _swap(swap0to1, amountIn, amountOutMin, to, false);
    }

    function swapInWithCallback(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external payable returns (uint256)
    {
        return _swap(swap0to1, amountIn, amountOutMin, to, true);
    }

    function _swap(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to, bool isCallback)
        internal returns (uint256 out)
    {
        require(dexVariables & 1 == 0, "reentered");
        dexVariables |= 1;
        (address tIn, address tOut) = swap0to1 ? (token0, token1) : (token1, token0);
        if (msg.value > 0) {
            require(msg.value == amountIn, "DexT1__EthAndAmountInMisMatch");
            require(tIn == NATIVE, "DexT1__EthSentForNonNativeSwap");
        }
        out = _out(amountIn, swap0to1);
        require(out >= amountOutMin, "out min");
        address payer = to == address(0) ? msg.sender : to;
        if (tIn == NATIVE) {
            require(msg.value == amountIn, "Liquidity: native not received"); // memVar2_ > msg.value
            if (mode == Mode.AskOnNative) IDexCallbackLike(msg.sender).dexCallback(askToken, amountIn);
            (bool ok, ) = liquidity.call{value: msg.value}("");
            require(ok);
            MockFluidLiquidity(payable(liquidity)).pay(tOut, payer, out);
            dexVariables &= ~uint256(1);
            return out;
        }
        require(isCallback, "mock: ERC20 input only by callback");
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
        MockFluidLiquidity(payable(liquidity)).pay(tOut, payer, out);
        dexVariables &= ~uint256(1);
    }
}

/// Another contract calling the adapter's callback while a real exec is open.
contract Intruder {
    function steal(address adapter, address token, uint256 amount) external {
        IDexCallbackLike(adapter).dexCallback(token, amount);
    }
}
