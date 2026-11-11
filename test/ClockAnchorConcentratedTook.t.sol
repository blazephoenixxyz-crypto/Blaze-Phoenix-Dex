// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE REGISTRY'S INPUT ON A CONCENTRATED LEG IS WHAT THE VENUE WAS PAID, NOT WHAT IT SAYS.
//
// RED at ecd7ada (fin1111-relogio): `Router._recordHits` handed the registry
// `mulDiv(leg.amountIn, hopScale[h], 1e18)` as the leg's input: the Router's send, priced by
// the plan. RED again at d4f88f3 on the V3 cases: `_execV3Amt` then handed the registry the
// in-side the pool RETURNS from `swap` (`a0`/`a1` positive), a number the pool owns. The
// registry's input is now the amount `_v3Callback` paid and saw land in the pool (its RouterE(13)
// check), left in the amount slot for `_execV3Amt`; a pool that never called back took nothing.
// `test/ClockAnchorMeasuredDelivery.t.sol` pins the pair family (a taxed input token pays the
// pair less than the send). This file pins the two concentrated channels of the same producer,
// `_execScaled`'s `took` (the per-leg `legTook` that `_recordHits` hands the registry):
//   - V3: a pool's return value is its claim; the callback's payment is the measurement. A
//     pool here asks for `demandBps` of the order in its callback and returns `claimBps` of it,
//     paying the honest out of the whole order so the leg floor stays out of the way;
//   - V4: the manager's unlock callback hands back what it owed and settled (`abi.encode(recv,
//     owe)`), and a position that runs out of liquidity settles LESS than the order.
// An honest V3 pool that runs out of liquidity inside the swap is NOT a case here: measured at
// ecd7ada, the Router refuses it with RouterE(5) (the in-frame leg quote reads `slot0` and
// `liquidity` only, the delivery falls short of it), so the return value and the payment can
// only differ through the pool's own claim. Reported as 3958 (Thomas van Oorschot), input side.
//
// THE ORACLE IS NOT THE CODE UNDER TEST. The expected input is the venue's own tokenIn balance
// delta, read before and after the swap; `Volume.amtIn` must equal it (or the log must be
// absent when that delta is zero). Neither the Router's `took` nor the registry's depth is
// asked.
//
// NOT VACUOUS: each positive case asserts the venue's receipt is strictly below the Router's
// send, so the send, the claim and the receipt are different numbers; the `Volume` log is
// asserted found; the delivery is asserted non-zero. The no-callback case asserts the pool got
// nothing AND the Router still delivered, so the absent log is a decision, not a revert.
//
// DIMENSIONS COVERED: the V3 channel (claim above the payment; claim above the budget; no
// callback at all; a fuzz over demand × claim); the V4 channel (liquidity exhausted on the
// singleton). The pair family, two legs, two hops and the fee-on-transfer vectors live in
// ClockAnchorMeasuredDelivery.t.sol.

import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IV3CallbackMin {
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external;
}

/// A V3-shaped pool whose word and whose hand differ: it asks the callback for `demandBps` of
/// the order (and checks that much landed), returns `claimBps` of the order as its in-side, and
/// pays the honest out of the WHOLE order at a single tick (no crossing). With `skipCallback`
/// it pays out without ever asking for input.
contract ClaimingV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint256 public demandBps = 10_000;
    uint256 public claimBps = 10_000;
    bool public skipCallback;

    constructor(address a, address b, uint24 f, uint160 sp, uint128 l) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
        sqrtPriceX96 = sp;
        liquidity = l;
    }

    function set(uint256 demand, uint256 claim, bool skip) external {
        demandBps = demand;
        claimBps = claim;
        skipCallback = skip;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "ClaimingV3Pool: exact-in only");
        uint256 amtIn = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, liquidity, fee, zeroForOne, 0);
        require(amtOut > 0, "ClaimingV3Pool: zero out");
        address tokenIn = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;
        if (!skipCallback) {
            uint256 demand = amtIn * demandBps / 10_000;
            (int256 d0, int256 d1) = zeroForOne
                ? (int256(demand), -int256(amtOut)) : (-int256(amtOut), int256(demand));
            uint256 before = IERC20Min(tokenIn).balanceOf(address(this));
            IV3CallbackMin(msg.sender).uniswapV3SwapCallback(d0, d1, data);
            require(IERC20Min(tokenIn).balanceOf(address(this)) - before >= demand, "ClaimingV3Pool: unpaid");
        }
        IERC20Min(tokenOut).transfer(recipient, amtOut);
        uint256 claim = amtIn * claimBps / 10_000;
        (amount0, amount1) = zeroForOne
            ? (int256(claim), -int256(amtOut)) : (-int256(amtOut), int256(claim));
    }
}

contract ClockAnchorConcentratedTookTest is Test {
    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    uint128 internal constant LIQ = 1e18;
    uint128 internal constant DEEP = 1e27;
    uint256 internal constant ASK = 1e18;
    bytes32 internal constant VOLUME_SIG = keccak256("Volume(bytes32,uint256,uint256)");

    BlazePhoenixHub internal hub;
    BlazePhoenixRouter internal router;
    MockV4TickManager internal mgr;
    ClaimingV3Pool internal pool;
    address internal t0;
    address internal t1;
    bytes32 internal v3Key;
    bytes32 internal pid;
    bytes32 internal v4Key;
    address internal user = address(0xBEEF);

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));

        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));

        // V3: price 1:1, a book deep enough that the order barely moves it (the claim, not the
        // curve, is what this file varies).
        pool = new ClaimingV3Pool(t0, t1, FEE, uint160(1 << 96), DEEP);
        MockERC20(t0).mint(address(pool), 1e24);
        MockERC20(t1).mint(address(pool), 1e24);
        v3Key = hub.seedPool(address(pool), BPC.KIND_V3, FEE, address(0), t0, t1);

        // V4: one position [0, 60) at tick 1; a zeroForOne order larger than it walks to tick 0,
        // finds no liquidity and stops with input unsettled.
        pid = BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
        mgr.initialize(pid, mgr.sqrtAt(1), 1, FEE);
        mgr.addPosition(pid, 0, 60, TS, LIQ);
        MockERC20(t1).mint(address(mgr), 1e24);
        hub.addV4(t0, t1, FEE, TS, address(0));
        v4Key = hub.keyOf(address(uint160(uint256(pid))), t0, t1);

        vm.prank(user);
        MockERC20(t0).approve(address(router), type(uint256).max);
    }

    // ───────────────────────── fixture ─────────────────────────

    /// What the Router is left with after the protocol fee on the input.
    function _funded(uint256 ask) internal pure returns (uint256) {
        return ask - (ask * BPC.PROTOCOL_FEE_BPS + BPC.BPS - 1) / BPC.BPS;
    }

    function _route(Leg memory leg, uint256 ask, uint256 exp) internal view returns (Route memory) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: t0, tokenOut: t1, amountIn: ask, expectedOut: exp, legs: legs});
        return Route({
            hops: hops, totalOut: exp, singleOut: exp, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _v3Route(uint256 ask) internal view returns (Route memory) {
        uint256 out = BPC.outV3(_funded(ask), uint160(1 << 96), DEEP, FEE, true, 0);
        return _route(Leg({
            pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: FEE,
            tickSpacing: 0, zeroForOne: true, stable: false,
            amountIn: ask, expectedOut: out, auxId: bytes32(0)
        }), ask, out);
    }

    function _v4Route(uint256 ask) internal view returns (Route memory) {
        (, uint256 out, , , ) = mgr.specSwap(pid, _funded(ask), FEE, TS, true);
        return _route(Leg({
            pool: address(uint160(uint256(pid))), hooks: address(0), kind: BPC.KIND_V4, fee: FEE,
            tickSpacing: TS, zeroForOne: true, stable: false,
            amountIn: ask, expectedOut: out, auxId: bytes32(uint256(uint160(t1)))
        }), ask, out);
    }

    function _volIn(Vm.Log[] memory logs, bytes32 k) internal view returns (bool found, uint256 amtIn) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hub) && logs[i].topics.length == 2
                && logs[i].topics[0] == VOLUME_SIG && logs[i].topics[1] == k) {
                (amtIn, ) = abi.decode(logs[i].data, (uint256, uint256));
                return (true, amtIn);
            }
        }
    }

    /// Swap `ask` of t0 through `r` as the user; returns the venue's tokenIn receipt, the user's
    /// tokenOut delivery and the published `Volume.amtIn` under `k`.
    function _swap(Route memory r, uint256 ask, address venue, bytes32 k)
        internal returns (uint256 receipt, uint256 delivered, bool found, uint256 volIn)
    {
        MockERC20(t0).mint(user, ask);
        uint256 venueBefore = MockERC20(t0).balanceOf(venue);
        uint256 userBefore = MockERC20(t1).balanceOf(user);
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(r, ask, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        receipt = MockERC20(t0).balanceOf(venue) - venueBefore;
        delivered = MockERC20(t1).balanceOf(user) - userBefore;
        (found, volIn) = _volIn(logs, k);
    }

    function _check(uint256 ask, uint256 receipt, uint256 delivered, bool found, uint256 volIn, string memory id)
        internal
    {
        assertGt(delivered, 0, string.concat(id, ": precondition: the leg delivered nothing"));
        assertGt(receipt, 0, string.concat(id, ": precondition: the venue received nothing"));
        assertLt(receipt, _funded(ask), string.concat(id, ": precondition: the venue received the whole send"));
        assertTrue(found, string.concat(id, ": precondition: a Volume event must have been emitted"));
        assertEq(volIn, receipt, string.concat(id, ": Volume.amtIn is not the venue's receipt"));
    }

    // ───────────────────────── cases: V3 ─────────────────────────

    /// The pool asks for half the order and returns the whole of it as consumed: the row reads
    /// the half that landed.
    function test_ClockAnchor_V3RowReadsWhatThePoolWasPaidNotWhatItReturns() public {
        pool.set(5_000, 10_000, false);
        (uint256 receipt, uint256 delivered, bool found, uint256 volIn) =
            _swap(_v3Route(ASK), ASK, address(pool), v3Key);
        emit log_named_uint("send (funded)  ", _funded(ASK));
        emit log_named_uint("pool was paid  ", receipt);
        emit log_named_uint("Volume.amtIn   ", volIn);
        _check(ASK, receipt, delivered, found, volIn, "v3 claim");
    }

    /// A claim above the leg's own budget is just as weightless: the row still reads the payment.
    function test_ClockAnchor_V3ClaimAboveTheBudgetDoesNotReachTheRow() public {
        pool.set(5_000, 30_000, false);
        (uint256 receipt, uint256 delivered, bool found, uint256 volIn) =
            _swap(_v3Route(ASK), ASK, address(pool), v3Key);
        _check(ASK, receipt, delivered, found, volIn, "v3 overclaim");
    }

    /// A pool that pays out without ever calling back was paid nothing: no row moves, and the
    /// swap still delivers.
    function test_ClockAnchor_V3PoolThatNeverCalledBackIsRegisteredWithNothing() public {
        pool.set(10_000, 10_000, true);
        (uint256 receipt, uint256 delivered, bool found, uint256 volIn) =
            _swap(_v3Route(ASK), ASK, address(pool), v3Key);
        assertGt(delivered, 0, "v3 silent: precondition: the leg delivered nothing");
        assertEq(receipt, 0, "v3 silent: precondition: the pool was paid");
        assertFalse(found, "v3 silent: a Volume row was published for a pool that was paid nothing");
        assertEq(volIn, 0, "v3 silent: Volume.amtIn");
    }

    /// Across every demand and claim (the claim up to twice the order): the row follows the
    /// payment and nothing else.
    function testFuzz_ClockAnchor_V3RowFollowsThePaymentAcrossDemandAndClaim(uint256 demand, uint256 claim) public {
        demand = bound(demand, 1, 9_999);
        claim = bound(claim, 0, 20_000);
        pool.set(demand, claim, false);
        (uint256 receipt, uint256 delivered, bool found, uint256 volIn) =
            _swap(_v3Route(ASK), ASK, address(pool), v3Key);
        _check(ASK, receipt, delivered, found, volIn, "v3 fuzz");
    }

    // ───────────────────────── cases: V4 ─────────────────────────

    /// The V4 unlock callback hands back what the manager owed and settled; the registry reads
    /// that, not the Router's send.
    function test_ClockAnchor_V4LegReportsWhatTheManagerSettledNotTheSend() public {
        (uint256 receipt, uint256 delivered, bool found, uint256 volIn) =
            _swap(_v4Route(ASK), ASK, address(mgr), v4Key);
        emit log_named_uint("send (funded)  ", _funded(ASK));
        emit log_named_uint("manager settled", receipt);
        emit log_named_uint("Volume.amtIn   ", volIn);
        _check(ASK, receipt, delivered, found, volIn, "v4");
    }
}
