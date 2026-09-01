// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  RefusalsNeverDriven — drives the TAKEN side of the refusal guards that an
//  inventory found exercised on one side only, and pairs EVERY fired guard
//  with a control that passes just under (or exactly at) the threshold, so
//  each test proves the BOUNDARY and not merely "something reverted".
//
//  Guards driven (located by CONDITION, not line — the file moves):
//    G1  _v3Callback        `owed > maxAmt`                      -> RouterE(8)
//    G2  _v3Callback        `owed == 0`                          -> RouterE(8)
//    G3  unlockCallback     `owedDelta > 0 || receivedDelta < 0` -> RouterE(8)
//    G4  unlockCallback     `owe > amt`                          -> RouterE(8)
//    G5  _execV4Amt         `mgr == address(0)`                  -> RouterE(8)
//    G6  _execPairAmt       mid-route `realIn == 0` (100% tax)   -> RouterE(8)
//    G7  _execute aggregate `totalReceived == 0`                 -> RouterE(8)
//    G8  hop loop           `legs == 0 || legs > MAX_LEGS(5)`    -> RouterE(3)
//    G9  classic + Permit2 doors `amountIn > uint128.max`        -> RouterE(3)
//
//  Several of these guards share RouterE(8). Every expectRevert here asserts
//  the EXACT revert bytes, and every fire case is paired with a control whose
//  setup differs ONLY at the guarded quantity (amt vs amt+1; 0 vs 1 wei;
//  manager unset vs set; 100% tax vs 99.9% tax; 5 legs vs 6), which is what
//  pins the revert to the intended site rather than a sibling with the same
//  code.
//
//  V4 note: the pre-existing HostileV4Manager (RouterAdversarialV4FromV1)
//  swallows the callback revert and re-reverts with a STRING — reusing it
//  would destroy the revert code under test. BubblingV4Manager below is the
//  same shape but bubbles the exact inner revert bytes.
//
//  forge test --match-contract RefusalsNeverDriven -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

// ─── Local interfaces (names distinct from the mocks' own) ───────────────────

interface IERC20RT {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IV3CallbackRT {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

// ─── G2 mock: a V3-shaped pool whose demanded input is configurable ─────────
//
// MockV3Pool covers demand == amt (default) and amt+1 (setOverDemand). To hit
// the `owed == 0` guard the pool must call the callback with NO positive
// delta at all — and for the 1-wei boundary control it must demand exactly 1.
contract DemandV3Pool {
    address public token0;
    address public token1;
    uint24  public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    /// 0 = demand exactly amtIn (honest), 1 = demand ZERO (fires owed==0),
    /// 2 = demand exactly 1 wei (the boundary just above zero).
    uint8 public demandMode;

    constructor(address _token0, address _token1, uint24 _fee) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        fee = _fee;
    }

    function setState(uint160 _sqrtPriceX96, uint128 _liquidity) external {
        sqrtPriceX96 = _sqrtPriceX96;
        liquidity = _liquidity;
    }

    function setDemandMode(uint8 m) external { demandMode = m; }

    function slot0()
        external view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 /*sqrtPriceLimitX96*/, bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified > 0, "DemandV3Pool: exact-out unsupported");
        uint256 amtIn = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne, 0);
        require(amtOut > 0, "DemandV3Pool: zero out");

        address tokenIn  = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        uint256 demand = demandMode == 1 ? 0 : (demandMode == 2 ? 1 : amtIn);

        amount0 = zeroForOne ? int256(demand) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(demand);

        uint256 balBefore = IERC20RT(tokenIn).balanceOf(address(this));
        // Typed external call: an inner revert (the Router's guard) BUBBLES.
        IV3CallbackRT(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(
            IERC20RT(tokenIn).balanceOf(address(this)) - balBefore >= demand,
            "DemandV3Pool: insufficient input"
        );
        IERC20RT(tokenOut).transfer(recipient, amtOut);
    }
}

// ─── G6 mock: an ERC20 taxed ONLY on transfers from one chosen address ──────
//
// MockERC20's fee-on-transfer taxes EVERY transfer, so a 100% tax would zero
// the hop-0 OUTPUT delivery (pool -> Router) and die in the per-leg floor
// (RouterE 5) before ever reaching the mid-route guard. Taxing only
// `from == taxedFrom` (the Router) lets hop 0 deliver intact and puts the
// entire tax on the mid-route Router -> pool push — the exact seam the
// `realIn == 0` guard watches.
contract RouterTaxToken {
    string  public name = "RouterTax";
    string  public symbol = "RTX";
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public taxedFrom;
    uint16  public taxBps;

    function mint(address to, uint256 amt) external { totalSupply += amt; balanceOf[to] += amt; }
    function setTax(address from_, uint16 bps) external { taxedFrom = from_; taxBps = bps; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _t(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (from != msg.sender) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) {
                require(a >= amt, "RouterTaxToken: allowance");
                allowance[from][msg.sender] = a - amt;
            }
        }
        return _t(from, to, amt);
    }

    function _t(address from, address to, uint256 amt) private returns (bool) {
        require(balanceOf[from] >= amt, "RouterTaxToken: balance");
        balanceOf[from] -= amt;
        uint256 delivered = amt;
        if (from == taxedFrom && taxBps > 0) delivered = amt - (amt * taxBps) / 10_000;
        balanceOf[to] += delivered;
        return true;
    }
}

// ─── G3/G4 mock: a settling V4 manager that BUBBLES callback reverts ────────
//
// ABI mirrors the Router's IV4PoolManager. Honest by default (1:1 fill of the
// exact leg amount — which IS the `owe == amt` boundary); armable to return
// an arbitrary packed BalanceDelta. Unlike HostileV4Manager, a revert inside
// unlockCallback is re-raised byte-for-byte, so the Router's exact RouterE
// code surfaces to the test instead of a wrapper string.
contract BubblingV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    bool   public useOverride;
    int128 public d0Ov;
    int128 public d1Ov;

    function arm(bool _use, int128 _d0, int128 _d1) external { useOverride = _use; d0Ov = _d0; d1Ov = _d1; }

    function _pack(int128 d0, int128 d1) internal pure returns (int256) {
        return int256((uint256(uint128(d0)) << 128) | uint256(uint128(d1)));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        if (!ok) {
            // Bubble the EXACT revert bytes — the whole point of this mock.
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
        return ret;
    }

    function swap(V4PoolKey calldata, SwapParams calldata p, bytes calldata) external returns (int256) {
        if (useOverride) return _pack(d0Ov, d1Ov);
        uint256 amt = uint256(-p.amountSpecified);
        int128 owe  = -int128(int256(amt));
        int128 recv = int128(int256(amt));
        return p.zeroForOne ? _pack(owe, recv) : _pack(recv, owe);
    }

    function sync(address) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(address currency, address to, uint256 amount) external {
        IERC20RT(currency).transfer(to, amount);
    }
}

contract RefusalsNeverDrivenTest is Test {
    BlazePhoenixHub hub;          // uninitialized — V2/V3/doors harness
    BlazePhoenixRouter router;
    MockPermit2 permit2;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;

    // V4 harness: one hub WITH a manager, one WITHOUT — the G5 minimal pair.
    BubblingV4Manager mgrV4;
    BlazePhoenixHub hubV4;        // initialized: v4PoolManager = mgrV4
    BlazePhoenixRouter routerV4;
    BlazePhoenixHub hubNoV4;      // never initialized: v4PoolManager = 0
    BlazePhoenixRouter routerNoV4;
    MockERC20 vA;
    MockERC20 vB;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user = address(0xBEEF);

    address constant V4_PID_ADDR = address(uint160(uint256(keccak256("pid"))));

    uint256 constant RESERVE = 10_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), treasury1, treasury2
        );
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));

        tokenIn.mint(address(pair), RESERVE);
        tokenOut.mint(address(pair), RESERVE);
        pair.setReserves(uint112(RESERVE), uint112(RESERVE));

        tokenIn.mint(user, 3_000e18);
        vm.startPrank(user);
        tokenIn.approve(address(router), type(uint256).max);
        tokenIn.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        // V4 side.
        mgrV4 = new BubblingV4Manager();
        hubV4 = new BlazePhoenixHub(address(this));
        hubV4.initialize(address(this), address(mgrV4));
        routerV4 = new BlazePhoenixRouter(
            address(hubV4), address(0xBEEF), address(this), treasury1, treasury2
        );
        hubNoV4 = new BlazePhoenixHub(address(this));
        routerNoV4 = new BlazePhoenixRouter(
            address(hubNoV4), address(0xBEEF), address(this), treasury1, treasury2
        );

        vA = new MockERC20("V4A", "V4A");
        vB = new MockERC20("V4B", "V4B");
        vA.mint(user, 1_000_000e18);
        vB.mint(address(mgrV4), 1_000_000e18); // output liquidity for take()
        vm.startPrank(user);
        vA.approve(address(routerV4), type(uint256).max);
        vA.approve(address(routerNoV4), type(uint256).max);
        vm.stopPrank();
    }

    // ─── Route builders ─────────────────────────────────────────────────────

    function _v2Route(address pool, address tIn, address tOut, uint256 amountIn, uint256 legAmountIn)
        private view returns (Route memory route)
    {
        bool zfo = tIn < tOut;
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zfo, stable: false,
            amountIn: legAmountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: tOut, amountIn: amountIn, expectedOut: 0, legs: legs });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _v3Route(address pool, uint256 amountIn) private view returns (Route memory route) {
        bool zfo = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 60, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _v4Route(uint256 amountIn) private view returns (Route memory route) {
        bool zfo = address(vA) < address(vB);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: V4_PID_ADDR, hooks: address(0), kind: BPC.KIND_V4, fee: 500,
            tickSpacing: 10, zeroForOne: zfo, stable: false,
            amountIn: amountIn, expectedOut: 0,
            auxId: bytes32(uint256(uint160(address(vB))))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(vA), tokenOut: address(vB),
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    /// @dev Net input a single-hop leg actually receives: the door charges
    ///      PROTOCOL_FEE_BPS (round-up) on hop 0 before scaling.
    function _netOfFee(uint256 amountIn) private pure returns (uint256) {
        return amountIn - BPC.mulDivUp(amountIn, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function _err(uint16 code) private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, code);
    }

    /// @dev Arm the V4 manager with (owedDelta, receivedDelta) as the Router
    ///      will interpret them: owed side is d0 iff zeroForOne (vA < vB).
    function _armV4(int128 dOwe, int128 dRecv) private {
        if (address(vA) < address(vB)) mgrV4.arm(true, dOwe, dRecv);
        else mgrV4.arm(true, dRecv, dOwe);
    }

    // =========================================================================
    //  G1 — _v3Callback: `owed > maxAmt` (RouterE 8)
    //  The pool can never demand more input than the leg was given.
    // =========================================================================

    function test_G1_V3Callback_OverDemand_Reverts8() public {
        MockV3Pool v3pool = new MockV3Pool(address(tokenIn), address(tokenOut), 3000);
        v3pool.setState(uint160(BPC.Q96), 1_000_000e18);
        tokenOut.mint(address(v3pool), 1_000_000e18);
        v3pool.setOverDemand(true); // demand = amt + 1: one wei past the cap

        Route memory route = _v3Route(address(v3pool), 1_000e18);
        vm.prank(user);
        vm.expectRevert(_err(8));
        router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    /// @notice Boundary control: demand == maxAmt EXACTLY (MockV3Pool's honest
    ///         mode demands precisely amountSpecified, which is the tstored
    ///         cap). One wei less than the fire case — and the swap completes.
    function test_G1_V3Callback_ExactDemand_BoundaryPasses() public {
        MockV3Pool v3pool = new MockV3Pool(address(tokenIn), address(tokenOut), 3000);
        v3pool.setState(uint160(BPC.Q96), 1_000_000e18);
        tokenOut.mint(address(v3pool), 1_000_000e18);
        // overDemand stays false: demand == amt == maxAmt.

        Route memory route = _v3Route(address(v3pool), 1_000e18);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "owed == maxAmt must pass: the guard is strictly greater-than");
    }

    // =========================================================================
    //  G2 — _v3Callback: `owed == 0` (RouterE 8)
    //  A V3-shaped pool that demands nothing is a broken/hostile pool.
    // =========================================================================

    function test_G2_V3Callback_ZeroOwed_Reverts8() public {
        DemandV3Pool pool = new DemandV3Pool(address(tokenIn), address(tokenOut), 3000);
        pool.setState(uint160(BPC.Q96), 1_000_000e18);
        tokenOut.mint(address(pool), 1_000_000e18);
        pool.setDemandMode(1); // callback deltas: (0, -amtOut) — no positive side

        Route memory route = _v3Route(address(pool), 1_000e18);
        vm.prank(user);
        vm.expectRevert(_err(8));
        router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    /// @notice Boundary control: owed == 1 wei — the smallest value past the
    ///         zero guard (and far under maxAmt). The swap completes.
    function test_G2_V3Callback_OneWeiOwed_BoundaryPasses() public {
        DemandV3Pool pool = new DemandV3Pool(address(tokenIn), address(tokenOut), 3000);
        pool.setState(uint160(BPC.Q96), 1_000_000e18);
        tokenOut.mint(address(pool), 1_000_000e18);
        pool.setDemandMode(2); // demand exactly 1 wei

        Route memory route = _v3Route(address(pool), 1_000e18);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "owed == 1 must pass: the guard fires only at exactly zero");
    }

    // =========================================================================
    //  G3 — unlockCallback: `owedDelta > 0 || receivedDelta < 0` (RouterE 8)
    //  The manager cannot make the Router receive-and-still-owe (sign guard).
    // =========================================================================

    function test_G3_V4Settle_PositiveOwedDelta_Reverts8() public {
        uint256 amountIn = 1_000e18;
        uint256 net = _netOfFee(amountIn);
        _armV4(int128(1), int128(int256(net))); // owedDelta = +1: wrong sign by one wei

        Route memory route = _v4Route(amountIn);
        vm.prank(user);
        vm.expectRevert(_err(8));
        routerV4.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
    }

    function test_G3_V4Settle_NegativeReceivedDelta_Reverts8() public {
        uint256 amountIn = 1_000e18;
        uint256 net = _netOfFee(amountIn);
        _armV4(-int128(int256(net)), int128(-1)); // receivedDelta = -1: wrong sign by one wei

        Route memory route = _v4Route(amountIn);
        vm.prank(user);
        vm.expectRevert(_err(8));
        routerV4.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
    }

    /// @notice Boundary control: owedDelta == 0 is EXACTLY at the `> 0` edge
    ///         and must pass (the Router owes nothing, receives the fill, and
    ///         the unpaid input is swept back to the payer).
    function test_G3_V4Settle_ZeroOwedDelta_BoundaryPasses() public {
        uint256 amountIn = 1_000e18;
        uint256 net = _netOfFee(amountIn);
        _armV4(int128(0), int128(int256(net)));

        uint256 userABefore = vA.balanceOf(user);
        Route memory route = _v4Route(amountIn);
        vm.prank(user);
        uint256 delivered = routerV4.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertEq(delivered, net, "owedDelta == 0 passes the sign guard and the fill lands");
        // owe == 0 means the input was never settled: the holds-nothing sweep
        // must have returned it (minus the protocol fee) to the payer.
        assertEq(vA.balanceOf(user), userABefore - (amountIn - net), "unspent input swept back");
    }

    /// @notice Near-boundary control for the received side: receivedDelta = +1
    ///         (its true boundary, 0, is unreachable END-TO-END on a passing
    ///         swap — a zero fill trips the aggregate `totalReceived == 0`
    ///         refusal later, which G7 drives deliberately).
    function test_G3_V4Settle_OneWeiReceived_BoundaryPasses() public {
        uint256 amountIn = 1_000e18;
        uint256 net = _netOfFee(amountIn);
        _armV4(-int128(int256(net)), int128(1));

        Route memory route = _v4Route(amountIn);
        vm.prank(user);
        uint256 delivered = routerV4.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertEq(delivered, 1, "receivedDelta == +1 passes the sign guard");
    }

    // =========================================================================
    //  G4 — unlockCallback: `owe > amt` (RouterE 8)
    //  Mirrors G1 on the V4 side: the pool cannot pull past this leg's budget.
    // =========================================================================

    function test_G4_V4Settle_OweAboveAmt_Reverts8() public {
        uint256 amountIn = 1_000e18;
        uint256 net = _netOfFee(amountIn); // == the amt committed to the leg
        _armV4(-int128(int256(net + 1)), int128(int256(net))); // owe = amt + 1

        Route memory route = _v4Route(amountIn);
        vm.prank(user);
        vm.expectRevert(_err(8));
        routerV4.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
    }

    /// @notice Boundary control: owe == amt EXACTLY (the manager's honest 1:1
    ///         mode demands precisely the leg amount) — one wei under the fire
    ///         case, and the full settle path runs to completion.
    function test_G4_V4Settle_OweEqualsAmt_BoundaryPasses() public {
        uint256 amountIn = 1_000e18;
        uint256 net = _netOfFee(amountIn);
        // No arm(): honest default returns owe = amt, recv = amt.

        Route memory route = _v4Route(amountIn);
        vm.prank(user);
        uint256 delivered = routerV4.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertEq(delivered, net, "owe == amt is the passing boundary: full budget, full fill");
        assertEq(vA.balanceOf(address(mgrV4)), net, "manager pulled exactly the leg budget");
    }

    // =========================================================================
    //  G5 — _execV4Amt: `mgr == address(0)` (RouterE 8)
    //  A V4 leg routed while the hub has no PoolManager wired must refuse.
    // =========================================================================

    function test_G5_V4Leg_ManagerUnset_Reverts8() public {
        Route memory route = _v4Route(1_000e18);
        vm.prank(user);
        vm.expectRevert(_err(8));
        routerNoV4.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    /// @notice Config-boundary control: the BYTE-IDENTICAL route through the
    ///         router whose hub HAS a manager settles. The only difference
    ///         between fire and control is hub.v4PoolManager() == 0.
    function test_G5_V4Leg_ManagerSet_ControlPasses() public {
        Route memory route = _v4Route(1_000e18);
        vm.prank(user);
        uint256 delivered = routerV4.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
        assertEq(delivered, _netOfFee(1_000e18), "same route, manager wired: settles in full");
    }

    // =========================================================================
    //  G6 — _execPairAmt: mid-route `realIn == 0` (RouterE 8)
    //  A 100%-tax token BETWEEN the Router and the pool: the pool measurably
    //  received nothing. Door-level zero-credit was covered; this is hop 1.
    // =========================================================================

    function _midRouteTaxSetup() private returns (RouterTaxToken fot, Route memory route) {
        fot = new RouterTaxToken();
        MockV2Pair pair1 = new MockV2Pair(address(tokenIn), address(fot));
        MockV2Pair pair2 = new MockV2Pair(address(fot), address(tokenOut));

        tokenIn.mint(address(pair1), RESERVE);
        fot.mint(address(pair1), RESERVE);
        pair1.setReserves(uint112(RESERVE), uint112(RESERVE));

        // pair2's FOT balance must EQUAL its reserve: with a 100% tax the
        // push delivers nothing, so realIn = balance - reserve = 0 exactly.
        fot.mint(address(pair2), RESERVE);
        tokenOut.mint(address(pair2), RESERVE);
        pair2.setReserves(uint112(RESERVE), uint112(RESERVE));

        uint256 amountIn = 1_000e18;
        Leg[] memory legs0 = new Leg[](1);
        legs0[0] = Leg({
            pool: address(pair1), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(tokenIn) < address(fot), stable: false,
            amountIn: amountIn, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs1 = new Leg[](1);
        legs1[0] = Leg({
            pool: address(pair2), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: address(fot) < address(tokenOut), stable: false,
            amountIn: 1e18, expectedOut: 0, auxId: bytes32(0) // h>0 rescales to the real balance
        });
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({ tokenIn: address(tokenIn), tokenOut: address(fot), amountIn: amountIn, expectedOut: 0, legs: legs0 });
        hops[1] = Hop({ tokenIn: address(fot), tokenOut: address(tokenOut), amountIn: 0, expectedOut: 0, legs: legs1 });
        route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function test_G6_MidRoute_FullTax_Reverts8() public {
        (RouterTaxToken fot, Route memory route) = _midRouteTaxSetup();
        fot.setTax(address(router), 10_000); // 100%: the pool receives ZERO

        vm.prank(user);
        vm.expectRevert(_err(8));
        router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    /// @notice Boundary control: 99.9% tax — the pool measurably receives a
    ///         sliver, realIn > 0, and the FoT-repriced floors let the honest
    ///         (if absurdly taxed) fill through. Only the last 10 bps of tax
    ///         separate this from the fire case.
    function test_G6_MidRoute_NearFullTax_BoundaryPasses() public {
        (RouterTaxToken fot, Route memory route) = _midRouteTaxSetup();
        fot.setTax(address(router), 9_990); // 99.9%: realIn == 0.1% of the push

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "realIn > 0 must execute: the guard fires only at exactly zero");
    }

    // =========================================================================
    //  G7 — _execute aggregate: `totalReceived == 0` (RouterE 8)
    //  A route whose every leg was skipped produces nothing — refuse, sweep.
    // =========================================================================

    function test_G7_AllLegsScaledToZero_Reverts8() public {
        // leg.amountIn == 0 scales every leg to zero input; _execScaled skips
        // them all; no tokenOut is ever produced.
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), 1_000, 0);
        vm.prank(user);
        vm.expectRevert(_err(8));
        router.swapExactIn(route, 1_000, 1, user, block.timestamp + 1);
    }

    /// @notice Boundary control: the smallest producible output. amountIn = 3
    ///         wei -> door fee 1 wei -> leg spends 2 -> outV2 = 1 wei exactly.
    ///         totalReceived == 1 is one wei past the guard, and it passes.
    function test_G7_OneWeiOutput_BoundaryPasses() public {
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), 3, 3);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, 3, 1, user, block.timestamp + 1);
        assertEq(delivered, 1, "totalReceived == 1 wei is the passing boundary");
    }

    // =========================================================================
    //  G8 — hop loop: `legs == 0 || legs > MAX_LEGS_PER_HOP (5)` (RouterE 3)
    // =========================================================================

    function test_G8_ZeroLegs_Reverts3() public {
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), 1_000e18, 1_000e18);
        route.hops[0].legs = new Leg[](0);
        vm.prank(user);
        vm.expectRevert(_err(3));
        router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    function test_G8_SixLegs_Reverts3() public {
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), 1_000e18, 1_000e18);
        route.hops[0].legs = new Leg[](6); // one past MAX_LEGS_PER_HOP; contents never read
        vm.prank(user);
        vm.expectRevert(_err(3));
        router.swapExactIn(route, 1_000e18, 1, user, block.timestamp + 1);
    }

    /// @notice Boundary control: exactly MAX_LEGS_PER_HOP (5) legs — across
    ///         five distinct pools of the same pair — executes end to end.
    ///         (The legs == 1 lower boundary passes all over this file.)
    function test_G8_FiveLegs_BoundaryPasses() public {
        uint256 amountIn = 1_000e18;
        bool zfo = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](5);
        for (uint256 i; i < 5; ++i) {
            MockV2Pair p = new MockV2Pair(address(tokenIn), address(tokenOut));
            tokenIn.mint(address(p), RESERVE);
            tokenOut.mint(address(p), RESERVE);
            p.setReserves(uint112(RESERVE), uint112(RESERVE));
            legs[i] = Leg({
                pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
                tickSpacing: 0, zeroForOne: zfo, stable: false,
                amountIn: amountIn / 5, expectedOut: 0, auxId: bytes32(0)
            });
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: 0, legs: legs
        });
        Route memory route = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });

        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "5 legs == MAX_LEGS_PER_HOP must execute");
    }

    // =========================================================================
    //  G9 — entry doors: `amountIn > type(uint128).max` (RouterE 3)
    //  Classic and Permit2 doors (the two whose taken side was never driven).
    // =========================================================================

    function test_G9_ClassicDoor_OverUint128_Reverts3() public {
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), 1_000e18, 1_000e18);
        vm.prank(user);
        vm.expectRevert(_err(3));
        router.swapExactIn(route, uint256(type(uint128).max) + 1, 1, user, block.timestamp + 1);
    }

    /// @notice Boundary control: amountIn == uint128.max EXACTLY passes the
    ///         door and the swap executes end to end against deep reserves.
    function test_G9_ClassicDoor_ExactUint128Max_BoundaryPasses() public {
        uint256 amountIn = type(uint128).max;
        tokenIn.mint(user, amountIn);
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), amountIn, amountIn);
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertGt(delivered, 0, "amountIn == uint128.max is the passing boundary of the door");
    }

    function test_G9_Permit2Door_OverUint128_Reverts3() public {
        // permitted.amount = max and a valid route: the ONLY RouterE(3)
        // reachable before tokens move is the uint128 door guard itself.
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), 1_000e18, 1_000e18);
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(tokenIn), amount: type(uint256).max }),
            nonce: 0,
            deadline: block.timestamp + 60
        });
        vm.prank(user);
        vm.expectRevert(_err(3));
        router.swapExactInWithPermit2(
            route, uint256(type(uint128).max) + 1, 1, user, block.timestamp + 1, p, ""
        );
    }

    /// @notice Boundary control: amountIn == uint128.max through Permit2, with
    ///         permitted.amount at the same value (also exercising the `<`
    ///         permit bound at ITS boundary). Full pull, full swap.
    function test_G9_Permit2Door_ExactUint128Max_BoundaryPasses() public {
        uint256 amountIn = type(uint128).max;
        tokenIn.mint(user, amountIn);
        Route memory route = _v2Route(address(pair), address(tokenIn), address(tokenOut), amountIn, amountIn);
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(tokenIn), amount: amountIn }),
            nonce: 0,
            deadline: block.timestamp + 60
        });
        vm.prank(user);
        uint256 delivered = router.swapExactInWithPermit2(
            route, amountIn, 1, user, block.timestamp + 1, p, ""
        );
        assertGt(delivered, 0, "uint128.max through the Permit2 door is the passing boundary");
    }
}
