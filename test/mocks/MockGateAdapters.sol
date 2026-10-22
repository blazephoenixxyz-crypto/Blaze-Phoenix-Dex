// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixGate, IExtAdapter} from "../../src/BlazePhoenixGate.sol";
import {MockERC20} from "./MockERC20.sol";

/// A PUSH venue: input transferred first, then `sell` pays `payBps` of it at a 1:1 price.
contract MockGateVenue {
    address public token0;
    address public token1;
    uint256 public payBps = 9_970;
    uint256 internal r0;
    uint256 internal r1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setPayBps(uint256 b) external { payBps = b; }

    function sync() public {
        r0 = MockERC20(token0).balanceOf(address(this));
        r1 = MockERC20(token1).balanceOf(address(this));
    }

    function sell(bool zeroForOne, address to) external returns (uint256 out) {
        (address tIn, address tOut, uint256 rIn) = zeroForOne ? (token0, token1, r0) : (token1, token0, r1);
        out = (MockERC20(tIn).balanceOf(address(this)) - rIn) * payBps / 10_000;
        MockERC20(tOut).transfer(to, out);
        sync();
    }

    function quoteSell(uint256 amtIn) external view returns (uint256) {
        return amtIn * payBps / 10_000;
    }
}

/// The venue's own registry: the adapter's identity question is asked HERE, never of calldata.
contract MockGateRegistry {
    mapping(address => bool) public isPool;
    function add(address p) external { isPool[p] = true; }
}

/// Honest PUSH adapter.
contract MockGateAdapter is IExtAdapter {
    BlazePhoenixGate public immutable GATE;
    MockGateRegistry public immutable REG;

    /// The depth this adapter declares with its quote (0 = none, the default).
    uint256 public declaredDepth;

    constructor(BlazePhoenixGate g, MockGateRegistry r) {
        GATE = g;
        REG = r;
    }

    function setDeclaredDepth(uint256 d) external { declaredDepth = d; }

    function resolve(address t0, address t1, uint24, bytes calldata hint)
        external view virtual returns (address vp, bytes32 x0, bytes32 x1)
    {
        vp = abi.decode(hint, (address));
        require(REG.isPool(vp), "resolve: not the venue's pool");
        require(MockGateVenue(vp).token0() == t0 && MockGateVenue(vp).token1() == t1, "resolve: pair");
    }

    function exec(address vp, bytes32, bytes32, bool zeroForOne, uint256 amtIn, address recipient)
        external virtual returns (uint256)
    {
        require(GATE.isWrapper(msg.sender), "exec: not a wrapper");
        address tIn = zeroForOne ? MockGateVenue(vp).token0() : MockGateVenue(vp).token1();
        MockERC20(tIn).transfer(vp, amtIn);
        return MockGateVenue(vp).sell(zeroForOne, recipient);
    }

    function quote(address vp, bytes32, bytes32, bool, uint256 amtIn)
        external view virtual returns (uint256, uint256)
    {
        return (MockGateVenue(vp).quoteSell(amtIn), declaredDepth);
    }

    function quoteCall(address vp, bytes32, bytes32, bool, uint256 amtIn) external virtual returns (uint256) {
        return MockGateVenue(vp).quoteSell(amtIn);
    }
}

interface IGateWrapperSwap {
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

/// Hostile adapter. Uses no banned opcode, so the scan admits it: what stops it is the
/// wrapper's custody check, the lock, and the Router's floors.
contract MockGateHostileAdapter is MockGateAdapter {
    uint8 public constant KEEP_INPUT = 1;  // keeps the input, pays the output from its own stock
    uint8 public constant SKIM_OUTPUT = 2; // trades honestly, keeps 1 % of the output
    uint8 public constant REENTER = 3;     // re-enters the wrapper from exec
    uint8 public constant LIE = 4;         // trades honestly, returns ten times the output
    uint8 public constant ZERO_POOL = 5;   // resolve answers no pool
    uint8 public constant CALL_ONLY = 6;   // honest, but prices only by quoteCall (quote = 0)
    uint8 public constant BURN = 7;        // quote and quoteCall spend every unit of gas given
    uint8 public constant REFUND_WRAPPER = 8; // hands the input back to the wrapper, pays the output from its own stock
    uint8 public constant OUT_TO_WRAPPER = 9; // trades honestly, but delivers the output to the wrapper
    uint8 public constant OVERQUOTE = 10;  // quotes twice what it delivers; trades honestly
    uint8 public mode;

    constructor(BlazePhoenixGate g, MockGateRegistry r) MockGateAdapter(g, r) {}

    function setMode(uint8 m) external { mode = m; }

    function resolve(address t0, address t1, uint24 k, bytes calldata hint)
        external view override returns (address vp, bytes32 x0, bytes32 x1)
    {
        if (mode == ZERO_POOL) return (address(0), 0, 0);
        return this.resolveHonest(t0, t1, k, hint);
    }

    function resolveHonest(address t0, address t1, uint24, bytes calldata hint)
        external view returns (address vp, bytes32 x0, bytes32 x1)
    {
        vp = abi.decode(hint, (address));
        require(REG.isPool(vp), "resolve: not the venue's pool");
        require(MockGateVenue(vp).token0() == t0 && MockGateVenue(vp).token1() == t1, "resolve: pair");
    }

    function exec(address vp, bytes32, bytes32, bool zeroForOne, uint256 amtIn, address recipient)
        external override returns (uint256 out)
    {
        (address tIn, address tOut) = zeroForOne
            ? (MockGateVenue(vp).token0(), MockGateVenue(vp).token1())
            : (MockGateVenue(vp).token1(), MockGateVenue(vp).token0());
        if (mode == KEEP_INPUT) {
            out = amtIn * 9_970 / 10_000;
            MockERC20(tOut).transfer(recipient, out);
            return out;
        }
        if (mode == REFUND_WRAPPER) {
            out = amtIn * 9_970 / 10_000;
            MockERC20(tIn).transfer(msg.sender, amtIn);
            MockERC20(tOut).transfer(recipient, out);
            return out;
        }
        if (mode == REENTER) {
            IGateWrapperSwap(msg.sender).swap(recipient, zeroForOne, 1, 0, "");
        }
        MockERC20(tIn).transfer(vp, amtIn);
        if (mode == SKIM_OUTPUT) {
            out = MockGateVenue(vp).sell(zeroForOne, address(this));
            MockERC20(tOut).transfer(recipient, out * 99 / 100);
            return out;
        }
        out = MockGateVenue(vp).sell(zeroForOne, mode == OUT_TO_WRAPPER ? msg.sender : recipient);
        if (mode == LIE) out *= 10;
    }

    function quote(address vp, bytes32, bytes32, bool, uint256 amtIn)
        external view override returns (uint256, uint256)
    {
        if (mode == BURN) _burn();
        if (mode == CALL_ONLY) return (0, 0);
        if (mode == OVERQUOTE) return (2 * MockGateVenue(vp).quoteSell(amtIn), declaredDepth);
        return (MockGateVenue(vp).quoteSell(amtIn), declaredDepth);
    }

    function quoteCall(address vp, bytes32, bytes32, bool, uint256 amtIn) external override returns (uint256) {
        if (mode == BURN) _burn();
        return MockGateVenue(vp).quoteSell(amtIn);
    }

    function _burn() internal pure {
        while (true) {}
    }
}
