// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AdapterHarness} from "../adapters/AdapterHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixAdapterFluidDexT1, IFluidDexT1} from "../../src/adapters/BlazePhoenixAdapterFluidDexT1.sol";

interface IFluidDexFactory {
    function getDexAddress(uint256 dexId) external view returns (address);
    function isDex(address dex) external view returns (bool);
    function totalDexes() external view returns (uint256);
}

contract FluidForkProbe is BlazePhoenixAdapterFluidDexT1 {
    constructor(address g) BlazePhoenixAdapterFluidDexT1(g, address(1), address(1), address(1)) {}
    function createAddress(address d, uint256 n) external pure returns (address) { return _createAddress(d, n); }
}

/// A Fluid user swapping on its own, by callback: inside the pool's real operation it asks the
/// wrapper for its depth, then pays Liquidity.
contract FluidSwapper {
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address public wrapper;
    uint256 public depthInside = type(uint256).max;

    function run(address dex, address w, bool swap0to1, uint256 amt) external {
        wrapper = w;
        IFluidDexT1(dex).swapInWithCallback(swap0to1, amt, 1, address(this));
    }

    function dexCallback(address token, uint256 amount) external {
        (, depthInside) = BlazePhoenixGateWrapper(wrapper).quote(true, 0);
        MockERC20(token).transfer(LIQUIDITY, amount);
    }
}

/// The Fluid DEX T1 adapter against the live pools on Base, behind the Gate, at a FIXED block.
/// Addresses read on chain on 23/10 at block 52 980 225: the factory's `getDexAddress`/`isDex`/
/// `totalDexes`, each pool's `constantsView`, DexReservesResolver.getPoolReserves. Skips, never
/// passes, when the fork cannot be opened (the public endpoint may prune old state).
contract AdapterFluidDexT1ForkTest is AdapterHarness {
    uint256 internal constant BLOCK = 52_980_225;
    address internal constant FACTORY = 0x91716C4EDA1Fb55e84Bf8b4c7085f84285c19085;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant RESERVES_RESOLVER = 0x05Bd8269A20C472b148246De20E6852091BF16Ff;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant SUSDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address internal constant DEX18 = 0xf063BD202E45d6b2843102cb4EcE339026645D4a; // sUSDai/USDC
    uint24 internal constant KEY = uint24(5) << 16 | 1;

    BlazePhoenixAdapterFluidDexT1 internal a;

    function _fork() internal returns (bool) {
        try vm.createSelectFork("base", BLOCK) {} catch { vm.skip(true); return false; }
        gate = new BlazePhoenixGate(address(this));
        a = new BlazePhoenixAdapterFluidDexT1(address(gate), FACTORY, LIQUIDITY, WETH_BASE);
        _accept(5, address(a));
        return true;
    }

    function _pair(address x, address y) internal {
        (t0, t1) = x < y ? (MockERC20(x), MockERC20(y)) : (MockERC20(y), MockERC20(x));
    }

    function _swapReal(address w, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        (address tIn, address tOut) = zeroForOne ? (address(t0), address(t1)) : (address(t1), address(t0));
        deal(tIn, address(this), amt);
        uint256 b = MockERC20(tOut).balanceOf(address(this));
        BlazePhoenixGateWrapper(w).swap(address(this), zeroForOne, int256(amt), 0, "");
        out = MockERC20(tOut).balanceOf(address(this)) - b;
    }

    function _w18() internal returns (address w) {
        _pair(USDC, SUSDAI);
        w = gate.create(USDC, SUSDAI, KEY, abi.encode(uint256(18)));
    }

    /// The derivation is the factory's own, for every pool it has created.
    function testFork_Fluid_Base_DerivedIdentityIsTheFactorys() public {
        if (!_fork()) return;
        FluidForkProbe p = new FluidForkProbe(address(gate));
        uint256 n = IFluidDexFactory(FACTORY).totalDexes();
        assertEq(n, 18);
        for (uint256 id = 1; id <= n; ++id) {
            address d = p.createAddress(FACTORY, id);
            assertEq(d, IFluidDexFactory(FACTORY).getDexAddress(id));
            assertTrue(IFluidDexFactory(FACTORY).isDex(d));
        }
        assertEq(p.createAddress(FACTORY, 18), DEX18);
    }

    function testFork_Fluid_Base_UsdcToSUSDai_QuoteCallIsExecution() public {
        if (!_fork()) return;
        address w = _w18();
        assertEq(BlazePhoenixGateWrapper(w).aux0(), bytes32(uint256(uint160(DEX18))));
        assertEq(BlazePhoenixGateWrapper(w).venuePool(), LIQUIDITY);
        bool z = address(t0) == USDC;
        uint256 q = BlazePhoenixGateWrapper(w).quoteCall(z, 100e6);
        assertGt(q, 0);
        assertEq(_swapReal(w, z, 100e6), q, "FluidDexSwapResult == the executed swap on the same state");
        _assertEmpty(address(a), w, DEX18);
        _assertEmpty(address(a), w, LIQUIDITY);
        uint256 q2 = BlazePhoenixGateWrapper(w).quoteCall(!z, 50e18);
        assertGt(q2, 0);
        assertEq(_swapReal(w, !z, 50e18), q2);
        _assertEmpty(address(a), w, LIQUIDITY);
    }

    /// The adapter's depth18 is the resolver's collateral real reserves, short side, 18 decimals.
    function testFork_Fluid_Base_DepthAgreesWithTheResolver() public {
        if (!_fork()) return;
        address w = _w18();
        (, uint256 depth) = BlazePhoenixGateWrapper(w).quote(true, 0);
        (bool ok, bytes memory r) = RESERVES_RESOLVER.call(abi.encodeWithSignature("getPoolReserves(address)", DEX18));
        assertTrue(ok);
        (, address r0, address r1, , , uint256 c0, uint256 c1) =
            abi.decode(r, (address, address, address, uint256, uint256, uint256, uint256));
        assertEq(r0, address(t0));
        assertEq(r1, address(t1));
        uint256 want = BPC.shortSide18(c0, BPC.decimalsOf(r0), c1, BPC.decimalsOf(r1));
        assertGt(want, 1_000e18, "a live pool");
        // The pool (coreHelpers `_getLiquidityCollateral`, via `calcExchangePrices`) and the
        // resolver decode the collateral at the supply exchange price accrued to now; the adapter
        // reads Liquidity's STORED price, never higher: at most what the pool counts, never more
        // than the resolver (336 ppm under on the USDC side at block 52 980 225).
        assertLe(depth, want, "never above the resolver's accrued reserves");
        assertApproxEqRel(depth, want, 1e15, "decoded collateral == resolver real reserves (0.1 %)");
        assertLt(depth, BPC.maxSide18(c0, BPC.decimalsOf(r0), c1, BPC.decimalsOf(r1)), "the short side");
        (, uint256 vd, ) = gate.vitalOf(w);
        assertEq(vd, depth, "Liquidity holds more than the pool: the Gate's cap does not bind");
    }

    /// The read guard inside a REAL Fluid operation: a Fluid user's callback reads the depth as 0.
    function testFork_Fluid_Base_DepthZeroInsideARealSwap() public {
        if (!_fork()) return;
        address w = _w18();
        (, uint256 outside) = BlazePhoenixGateWrapper(w).quote(true, 0);
        assertGt(outside, 0);
        FluidSwapper s = new FluidSwapper();
        deal(USDC, address(s), 10e6);
        s.run(DEX18, w, USDC == address(t0), 10e6);
        assertEq(s.depthInside(), 0);
    }

    function testFork_Fluid_Base_GateQuoteGas_UsdcToSUSDai() public {
        if (!_fork()) return;
        address w = _w18();
        address[] memory cold = new address[](3);
        (cold[0], cold[1], cold[2]) = (DEX18, LIQUIDITY, address(a));
        (uint256 out, , uint256 gCall) = _armUnderCap(w, address(t0) == USDC, 100e6, cold);
        assertGt(out, 0);
        assertLt(gCall, GATE_QUOTE_GAS);
    }


    /// A pool id whose pair is not the wrapper's: the factory's own pool, refused by its tokens.
    function testFork_Fluid_Base_OtherPairsPoolRefused() public {
        if (!_fork()) return;
        vm.expectRevert(_aerr(3));
        gate.create(USDC, SUSDAI, KEY, abi.encode(uint256(12)));
    }
}

interface IWETHLike {
    function deposit() external payable;
}

/// Native-ETH pools of Fluid DEX T1 on Ethereum, Arbitrum and Base, behind the Gate: the path
/// speaks WETH and the adapter unwraps and wraps at the venue boundary. Both directions per pool:
/// WETH in (0.01 ETH), then the token received back to WETH. quoteCall == the measured output,
/// nothing (ETH, WETH or token) left in the adapter or the wrapper. Same Factory and Liquidity
/// on the three chains [checked on chain 23/10]. Pools from each factory's `constantsView` on 23/10:
/// "flipped" = the token sorts above WETH, so the pool's order is the reverse of the wrapper's.
/// Skips, never passes, when the fork cannot be opened.
contract AdapterFluidDexT1NativeForkTest is AdapterHarness {
    address internal constant FACTORY = 0x91716C4EDA1Fb55e84Bf8b4c7085f84285c19085;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint24 internal constant KEY = uint24(5) << 16 | 1;

    BlazePhoenixAdapterFluidDexT1 internal a;
    address internal weth;
    /// ETH the adapter's address held before it was deployed: on mainnet the default test
    /// deployer's second CREATE address carries 1 wei of dust. It is not the swap's to wrap.
    uint256 internal eth0;

    function _fork(string memory chain, uint256 blk, address w) internal returns (bool) {
        try vm.createSelectFork(chain, blk) {} catch { vm.skip(true); return false; }
        weth = w;
        gate = new BlazePhoenixGate(address(this));
        a = new BlazePhoenixAdapterFluidDexT1(address(gate), FACTORY, LIQUIDITY, w);
        eth0 = address(a).balance;
        _accept(5, address(a));
        return true;
    }

    function _empty(address wr, uint256 wrEth0) internal view {
        _assertEmpty(address(a), wr, LIQUIDITY);
        assertEq(address(a).balance, eth0, "adapter ETH: no residue, no dust taken");
        assertEq(wr.balance, wrEth0, "wrapper ETH");
    }

    /// WETH -> token -> WETH on pool `id`; returns the two measured outputs.
    function _roundTrip(uint256 id, address tok, bool flipped) internal returns (uint256 outTok, uint256 outEth) {
        IFluidDexT1.ConstantViews memory c = IFluidDexT1(IFluidDexFactory(FACTORY).getDexAddress(id)).constantsView();
        assertTrue(c.token0 == NATIVE || c.token1 == NATIVE, "a native pool");
        (t0, t1) = tok < weth ? (MockERC20(tok), MockERC20(weth)) : (MockERC20(weth), MockERC20(tok));
        assertEq(flipped, (c.token0 == NATIVE) != (address(t0) == weth), "the order as listed");
        address wr = gate.create(tok, weth, KEY, abi.encode(id));
        uint256 wrEth0 = wr.balance;
        assertEq(uint256(BlazePhoenixGateWrapper(wr).aux1()), flipped ? 3 : 2);
        bool z = address(t0) == weth;

        vm.deal(address(this), 0.01 ether);
        IWETHLike(weth).deposit{value: 0.01 ether}();
        uint256 q = BlazePhoenixGateWrapper(wr).quoteCall(z, 0.01 ether);
        assertGt(q, 0, "priced");
        uint256 b = MockERC20(tok).balanceOf(address(this));
        BlazePhoenixGateWrapper(wr).swap(address(this), z, int256(0.01 ether), 0, "");
        outTok = MockERC20(tok).balanceOf(address(this)) - b;
        assertEq(outTok, q, "WETH in: quoteCall == execution");
        _empty(wr, wrEth0);

        q = BlazePhoenixGateWrapper(wr).quoteCall(!z, outTok);
        assertGt(q, 0, "priced back");
        b = MockERC20(weth).balanceOf(address(this));
        BlazePhoenixGateWrapper(wr).swap(address(this), !z, int256(outTok), 0, "");
        outEth = MockERC20(weth).balanceOf(address(this)) - b;
        assertEq(outEth, q, "WETH out: quoteCall == execution");
        _empty(wr, wrEth0);
        (, uint256 depth) = BlazePhoenixGateWrapper(wr).quote(true, 0);
        (, uint256 vd, ) = gate.vitalOf(wr);
        emit log_named_uint("id", id);
        emit log_named_uint("token out for 0.01 WETH", outTok);
        emit log_named_uint("WETH back", outEth);
        emit log_named_uint("adapter depth18", depth);
        emit log_named_uint("vitalOf depth18 (capped by Liquidity's WETH)", vd);
        emit log_named_uint("adapter ETH dust kept (not wrapped)", eth0);
    }

    function testFork_Fluid_Native_Eth_BothDirections() public {
        if (!_fork("mainnet", 26_255_100, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)) return;
        _roundTrip(1, 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, false); // wstETH / ETH
        _roundTrip(9, 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee, true);  // weETH / ETH
        _roundTrip(43, 0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38, false); // ETH (token0 NATIVE) / 0xf1C9...
    }

    function testFork_Fluid_Native_Arb_BothDirections() public {
        if (!_fork("arbitrum", 517_524_600, 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1)) return;
        _roundTrip(1, 0x5979D7b546E38E414F7E9822514be443A4800529, false); // wstETH / ETH
        _roundTrip(4, 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, true);  // USDC / ETH
    }

    function testFork_Fluid_Native_Base_BothDirections() public {
        if (!_fork("base", 52_983_400, 0x4200000000000000000000000000000000000006)) return;
        _roundTrip(2, 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452, true);  // wstETH / ETH
        _roundTrip(3, 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A, false); // weETH / ETH
    }
}
