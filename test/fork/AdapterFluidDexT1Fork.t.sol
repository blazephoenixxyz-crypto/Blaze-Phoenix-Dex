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
    constructor(address g) BlazePhoenixAdapterFluidDexT1(g, address(1), address(1)) {}
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
    address internal constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant DEX18 = 0xf063BD202E45d6b2843102cb4EcE339026645D4a; // sUSDai/USDC
    uint24 internal constant KEY = uint24(5) << 16 | 1;

    BlazePhoenixAdapterFluidDexT1 internal a;

    function _fork() internal returns (bool) {
        try vm.createSelectFork("base", BLOCK) {} catch { vm.skip(true); return false; }
        gate = new BlazePhoenixGate(address(this));
        a = new BlazePhoenixAdapterFluidDexT1(address(gate), FACTORY, LIQUIDITY);
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
        // The pool decodes its collateral at Liquidity's STORED supply exchange price
        // (coreHelpers `_getLiquidityCollateral`), the resolver at the price accrued to now: the
        // adapter reads what the pool reads, never more than the resolver (336 ppm under on the USDC side at this block).
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

    function testFork_Fluid_Base_NativePoolRefused() public {
        if (!_fork()) return;
        assertEq(IFluidDexT1(IFluidDexFactory(FACTORY).getDexAddress(2)).constantsView().token1, NATIVE);
        vm.expectRevert(_aerr(4));
        gate.create(WSTETH, NATIVE, KEY, abi.encode(uint256(2)));
    }

    /// A pool id whose pair is not the wrapper's: the factory's own pool, refused by its tokens.
    function testFork_Fluid_Base_OtherPairsPoolRefused() public {
        if (!_fork()) return;
        vm.expectRevert(_aerr(3));
        gate.create(USDC, SUSDAI, KEY, abi.encode(uint256(12)));
    }
}
