// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// DEX-11 (Penpie class) and DEX-09 — what a leg's measured delta may count.
//
// The Router measures each leg as the change of its own tokenOut balance across the venue call
// (_execScaled) and floors that delta at 80% of the leg's attested bound. Inside that window other
// code runs: the transfer of the leg input (a token with a hook), the venue itself, a callback.
// Whatever lands on the Router there is counted as the leg's output. A donation of tokenOut inside
// the window therefore carries an over-attested leg past its floor, and the inflated attestation
// is what _recordHits writes to the Hub (fabricated fitness). The donor recovers the donation as
// the recipient; the cost is the fee and the gas.
//
// The guard: the delta may not exceed `declared`, what the venue itself says it paid (V2/Solidly: the
// output the Router asked for; V3/Algebra/Gate: the out side returned by swap; V4: the amount the
// Router takes). RouterE(20).
//
// Red at ae5f1ae: the two donation tests settled (no revert). The reentry, control and DEX-09
// tests are watchers of guards that already exist (lock, per-leg floor, the two balance deltas).

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockV4ManagerNative} from "./RouterV4NativeEth.t.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../src/BlazePhoenixGate.sol";
import {MockGateVenue, MockGateRegistry, MockGateAdapter} from "./mocks/MockGateAdapters.sol";

interface IERC20LD {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// A V2-shaped pair that can pay more than it was asked (mode 1) or re-enter the Router from
/// inside its swap (mode 2). Mode 0 is an honest pair.
contract WindowPair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint8 public mode;
    uint256 public extra;
    address public router;
    bytes public reentry;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    function arm(uint8 m, uint256 x, address r, bytes calldata p) external {
        mode = m;
        extra = x;
        router = r;
        reentry = p;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (mode == 2) {
            (bool ok, bytes memory ret) = router.call(reentry);
            if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        }
        uint256 x = mode == 1 ? extra : 0;
        if (amount0Out > 0) IERC20LD(token0).transfer(to, amount0Out + x);
        if (amount1Out > 0) IERC20LD(token1).transfer(to, amount1Out + x);
        reserve0 = uint112(IERC20LD(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20LD(token1).balanceOf(address(this)));
    }
}

/// The leg input: a plain token whose transfer to the armed pool also sends `giftAmt` of `gift`
/// to the sender (the Router), inside the leg's measurement window.
contract HookedIn {
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hookPool;
    address public gift;
    uint256 public giftAmt;

    function arm(address pool, address token, uint256 amt) external {
        hookPool = pool;
        gift = token;
        giftAmt = amt;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        if (to == hookPool && giftAmt != 0) {
            uint256 g = giftAmt;
            giftAmt = 0;
            IERC20LD(gift).transfer(msg.sender, g);
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
        return true;
    }

    function _move(address from, address to, uint256 amt) private {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

contract LegDeltaNeverExceedsTheVenuesDeclarationTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    HookedIn inTok;
    MockERC20 outTok;
    WindowPair pair;
    address user = address(0xBEEF);
    address recipient = address(0xCAFE);
    uint256 constant R = 1000e18;
    uint256 constant AMT = 1e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(quoter));
        inTok = new HookedIn();
        outTok = new MockERC20("OUT", "OUT");
        pair = new WindowPair(address(inTok), address(outTok));
        Origin.wire(hub, address(pair), address(inTok), address(outTok), BPC.KIND_V2, 30);
        inTok.mint(address(pair), R);
        outTok.mint(address(pair), R);
        pair.setReserves(uint112(R), uint112(R));
        inTok.mint(user, 100e18);
        vm.prank(user);
        inTok.approve(address(router), type(uint256).max);
    }

    /// The honest output of the leg: constant product at 30 bps, computed here and not read
    /// from the Core.
    function _q() internal pure returns (uint256) {
        uint256 af = AMT * 9970;
        return af * R / (R * 10_000 + af);
    }

    function _route(uint256 attested) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: pair.token0() == address(inTok), stable: false,
            amountIn: AMT, expectedOut: attested, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(inTok), tokenOut: address(outTok), amountIn: AMT, expectedOut: attested, legs: legs
        });
        r = Route({
            hops: hops, totalOut: attested, singleOut: attested, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _err(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// DEX-11: a third party (here the leg input's own transfer hook) donates tokenOut to the
    /// Router inside the leg's window; the leg attests twice what the pool pays.
    function test_ADonationInsideTheLegWindowIsNotTheLegsOutput() public {
        uint256 q = _q();
        outTok.mint(address(inTok), q);
        inTok.arm(address(pair), address(outTok), q);
        Route memory r = _route(2 * q);
        vm.prank(user);
        vm.expectRevert(_err(20));
        router.swapExactIn(r, AMT, 1, recipient, block.timestamp + 1);
    }

    /// DEX-11: the venue itself pays more than the output the Router asked of it.
    function test_AVenueThatPaysMoreThanItWasAskedIsRefused() public {
        uint256 q = _q();
        outTok.mint(address(pair), q);
        pair.arm(1, q, address(0), "");
        Route memory r = _route(2 * q);
        vm.prank(user);
        vm.expectRevert(_err(20));
        router.swapExactIn(r, AMT, 1, recipient, block.timestamp + 1);
    }

    /// The regime of the two tests above: without the donation the over-attested leg fails its
    /// own floor, so the donation is what carried it.
    function test_TheOverAttestedLegFailsItsFloorWithoutTheDonation() public {
        Route memory r = _route(2 * _q());
        vm.prank(user);
        vm.expectRevert(_err(5));
        router.swapExactIn(r, AMT, 1, recipient, block.timestamp + 1);
    }

    /// The lock covers the window: the venue re-entering a door between the two balance reads
    /// is refused with the lock's own code.
    function test_ReentryIntoADoorInsideTheLegWindowIsRefused() public {
        Route memory r = _route(_q());
        pair.arm(2, 0, address(router), abi.encodeCall(
            BlazePhoenixRouter.swapExactIn, (r, AMT, 1, address(router), block.timestamp + 1)
        ));
        vm.prank(user);
        vm.expectRevert(_err(7));
        router.swapExactIn(r, AMT, 1, recipient, block.timestamp + 1);
    }

    /// DEX-09 (leg window): tokenOut the Router already held before the leg is not the leg's
    /// output, so it cannot carry an over-attested leg past its floor.
    function test_TheLegDeltaExcludesTheRoutersPriorBalance() public {
        uint256 q = _q();
        outTok.mint(address(router), q);
        Route memory r = _route(2 * q);
        vm.prank(user);
        vm.expectRevert(_err(5));
        router.swapExactIn(r, AMT, 1, recipient, block.timestamp + 1);
    }

    /// DEX-09 (recipient window): what the recipient held before is not what the swap delivered.
    /// tokenOut is a bridge, so the protocol fee comes out of the output: amountOut >= minOut but
    /// the net delivered is below it.
    function test_DeliveredExcludesTheRecipientsPriorBalance() public {
        hub.addBridge(address(outTok));
        uint256 q = _q();
        uint256 fee = q * 28 / 10_000; // BPC.PROTOCOL_FEE_BPS = 28
        outTok.mint(recipient, 1e18);
        Route memory r = _route(q);
        vm.prank(user);
        vm.expectRevert(_err(5));
        router.swapExactIn(r, AMT, q - fee / 2, recipient, block.timestamp + 1);
    }
}

/// DEX-11 on the two other window shapes. The V3 callback and the V4 settle pay the leg input
/// inside the window, so the same hooked input donates tokenOut there. G1 compares the delta with
/// the out side swap returns (V3) and with the amount unlockCallback takes (V4). Without G1 both
/// over-attested legs settle on the donation.
contract LegDeltaDonationOnV3AndV4Test is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    HookedIn inTok;
    MockERC20 outTok;
    MockV3Pool v3;
    MockV4ManagerNative mgr;
    address user = address(0xBEEF);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = 1e27;
    uint24 constant FEE4 = 500;
    int24 constant TS4 = 10;
    uint256 constant AMT = 1e18;

    function setUp() public {
        mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        router = new BlazePhoenixRouter(
            address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2)
        );
        inTok = new HookedIn();
        outTok = new MockERC20("OUT", "OUT");
        v3 = new MockV3Pool(address(inTok), address(outTok), 3000);
        v3.setState(Q96, LIQ);
        outTok.mint(address(v3), 1_000e18);
        bytes32 base = keccak256(abi.encode(_pid(), uint256(6)));
        mgr.setSlot(base, bytes32(uint256(Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
        outTok.mint(address(mgr), 1_000e18);
        inTok.mint(user, 100e18);
        vm.prank(user);
        inTok.approve(address(router), type(uint256).max);
    }

    function _pid() internal view returns (bytes32) {
        (address c0, address c1) = address(inTok) < address(outTok)
            ? (address(inTok), address(outTok)) : (address(outTok), address(inTok));
        return BPC.computeV4PoolId(c0, c1, FEE4, TS4, address(0));
    }

    /// The V3 pool's own output for AMT (the mock prices with this formula).
    function _q3() internal view returns (uint256) {
        return BPC.outV3(AMT, Q96, LIQ, 3000, v3.token0() == address(inTok), 0);
    }

    function _v3(uint256 attested) internal view returns (Route memory) {
        return _route(Leg({
            pool: address(v3), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: v3.token0() == address(inTok), stable: false,
            amountIn: AMT, expectedOut: attested, auxId: bytes32(0)
        }));
    }

    /// The V4 mock pays 1:1 what it is given.
    function _v4(uint256 attested) internal view returns (Route memory) {
        return _route(Leg({
            pool: address(uint160(uint256(_pid()))), hooks: address(0), kind: BPC.KIND_V4, fee: FEE4,
            tickSpacing: TS4, zeroForOne: address(inTok) < address(outTok), stable: false,
            amountIn: AMT, expectedOut: attested, auxId: bytes32(uint256(uint160(address(outTok))))
        }));
    }

    function _route(Leg memory lg) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = lg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(inTok), tokenOut: address(outTok), amountIn: AMT, expectedOut: lg.expectedOut, legs: legs
        });
        r = Route({
            hops: hops, totalOut: lg.expectedOut, singleOut: lg.expectedOut, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _err(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// The guard leaves an honest leg of either shape alone (and the V4 mock returns what the
    /// callback returned, as the PoolManager does).
    function test_HonestV3AndV4LegsSettleUnderTheGuard() public {
        Route memory r3 = _v3(_q3());
        Route memory r4 = _v4(AMT);
        uint256 b = outTok.balanceOf(user);
        vm.prank(user);
        router.swapExactIn(r3, AMT, 1, user, block.timestamp + 1);
        vm.prank(user);
        router.swapExactIn(r4, AMT, 1, user, block.timestamp + 1);
        assertGt(outTok.balanceOf(user), b, "the honest legs delivered nothing");
    }

    /// V3: the donation lands while the Router pays the pool from inside the swap callback.
    function test_V3_ADonationInsideTheCallbackIsNotTheLegsOutput() public {
        uint256 q = _q3();
        outTok.mint(address(inTok), q);
        inTok.arm(address(v3), address(outTok), q);
        Route memory r = _v3(2 * q);
        vm.prank(user);
        vm.expectRevert(_err(20));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// V4: the donation lands while the Router pays the PoolManager between sync and settle.
    function test_V4_ADonationInsideTheSettleIsNotTheLegsOutput() public {
        outTok.mint(address(inTok), AMT);
        inTok.arm(address(mgr), address(outTok), AMT);
        Route memory r = _v4(2 * AMT);
        vm.prank(user);
        vm.expectRevert(_err(20));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }
}

/// DEX-11 on the Gate (kind 9). The wrapper's declaration is not a price: it is the recipient's
/// tokenOut delta across the adapter's exec, read after the Router has paid the input inside the
/// V3 callback (BlazePhoenixGateWrapper.swap, steps 1-4). A donation that lands while the Router
/// pays the wrapper is inside the Router's window and outside the wrapper's, so G1 refuses it.
/// A donation inside exec is inside both windows and raises the declaration with the delta: that
/// escape is the `declared` row's (SHARED_QUANTITIES), and a kind-9 leg writes nothing to the Hub.
contract LegDeltaDonationOnGateTest is Test {
    uint8 constant FAM = 1;
    uint24 constant KEY = uint24(uint256(FAM) << 16 | 1);
    uint256 constant AMT = 1_000e18;

    BlazePhoenixGate gate;
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockGateVenue venue;
    BlazePhoenixGateWrapper w;
    HookedIn inTok;
    MockERC20 outTok;
    address user = address(0xA11CE);

    function setUp() public {
        inTok = new HookedIn();
        outTok = new MockERC20("OUT", "OUT");
        gate = new BlazePhoenixGate(address(this));
        MockGateRegistry reg = new MockGateRegistry();
        venue = new MockGateVenue(address(inTok), address(outTok));
        reg.add(address(venue));
        inTok.mint(address(venue), 1_000_000e18);
        outTok.mint(address(venue), 1_000_000e18);
        venue.sync();
        MockGateAdapter adapter = new MockGateAdapter(gate, reg);
        gate.proposeAdapter(FAM, address(adapter));
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(FAM);
        w = BlazePhoenixGateWrapper(gate.create(address(inTok), address(outTok), KEY, abi.encode(address(venue))));
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        uint24[] memory fees = new uint24[](1);
        fees[0] = KEY;
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, 5, gate.WRAPPER_INIT_HASH(), fees, new int24[](0));
        router = new BlazePhoenixRouter(
            address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2)
        );
        inTok.mint(user, AMT);
        vm.prank(user);
        inTok.approve(address(router), type(uint256).max);
    }

    function _route(uint256 attested) internal view returns (Route memory r) {
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: address(w), hooks: address(0), kind: BPC.KIND_EXTERNAL, fee: KEY, tickSpacing: 0,
            zeroForOne: address(inTok) < address(outTok), stable: false, amountIn: AMT, expectedOut: attested,
            auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(inTok), tokenOut: address(outTok), amountIn: AMT, expectedOut: attested, legs: l});
        r = Route({hops: hs, totalOut: attested, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _err(uint16 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// Control: the honest kind-9 leg settles under the guard (the wrapper declares what the
    /// Router measured).
    function test_Gate_HonestLegSettlesUnderTheGuard() public {
        Route memory r = _route(venue.quoteSell(AMT));
        vm.prank(user);
        uint256 out = router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
        assertGt(out, 0, "the honest kind-9 leg delivered nothing");
        assertEq(outTok.balanceOf(user), out, "the user receives what the Router measured");
    }

    /// Control: the same over-attested leg fails its floor when nothing is donated.
    function test_Gate_TheOverAttestedLegFailsItsFloorWithoutTheDonation() public {
        Route memory r = _route(2 * venue.quoteSell(AMT));
        vm.prank(user);
        vm.expectRevert(_err(5));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }

    /// The donation lands while the Router pays the wrapper the input (the V3 callback), before
    /// the wrapper reads the recipient's balance: the Router's delta exceeds the declaration.
    function test_Gate_ADonationInsideTheCallbackIsNotTheLegsOutput() public {
        uint256 q = venue.quoteSell(AMT);
        outTok.mint(address(inTok), q);
        inTok.arm(address(w), address(outTok), q);
        Route memory r = _route(2 * q);
        vm.prank(user);
        vm.expectRevert(_err(20));
        router.swapExactIn(r, AMT, 1, user, block.timestamp + 1);
    }
}
