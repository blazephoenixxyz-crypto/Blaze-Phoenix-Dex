// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The input probe is sized at what the Router pays the pool: the leg's input.
//
// RED at 6e5067b. `_inputTaxed` ran the pool backwards on the leg's priced OUTPUT (a positive
// amount of the output token), so the pool paid the probe ~`amountIn` less its fee twice. A tax
// charged per quantum (floor(x * bps / 1e4), the shape of every integer fee-on-transfer) rounds
// to zero below Q = ceil(1e4 / bps): for a leg input just past Q the probe's payment was still
// below it and untaxed, while the Router's payment was taxed and refused with RouterE(13). The
// exact doors promised an output the Router refuses (bounty uid 5389). The probe now asks the
// pool for exactly the leg's input (a negative amount, exact output), and the Router never pays
// a hop-0 leg more than its `amountIn` (`scaleNum` is capped at `scaleDen`), so a payment the
// probe finds untaxed is untaxed at the Router too.
//
// Declared limit, pinned and not covered: a token that also taxes the pool's payment TO the
// probe (both directions) hands the probe less than the leg's input, so a window of about one
// quantum, [Q, Q + tax(Q)), can still be promised. The Router measures its own payment and
// refuses there (RouterE(13), or its floor RouterE(5) when the pull is taxed too): it fails
// closed and nothing is lost (the residual test).
//
// Matrix: range {Q - 1 (control), Q .. Q + ~0.8 % in steps of 1 wei, bps 1 / 30 / 100,
//               fuzz bps 1..9999 x amountIn 1..1e30}
//       x vector {tax only on the transfer to the pool: V3 hop 0, Algebra hop 0, bridge on hop 1
//                 (V2 then V3), the encode door; a reverse book that pays part of the input;
//                 a tax in both directions (the residual)}
//       x dimension {unit sweep, fuzz 2 hops}.
// The Router is the oracle at every point, asserted by selector and code.
// Mutants (.github/scripts/mutants.py, caixa-1123 quoter-inputtax-probe): the probe sized at
// `leg.expectedOut`, and the probe run with a positive (exact input) amount; both turn the
// bps-1 sweeps red.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// A token that taxes only what is sent TO a marked pool, per quantum: floor(amt * bps / 1e4).
contract PoolTaxToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint16 public bps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public taxedTo;

    constructor(string memory n, string memory s) { name = n; symbol = s; }

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; totalSupply += amt; }
    function setBps(uint16 b) external { bps = b; }
    function setTaxedTo(address p) external { taxedTo[p] = true; }

    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { _move(msg.sender, to, amt); return true; }
    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) { require(a >= amt, "allowance"); allowance[f][msg.sender] = a - amt; }
        _move(f, to, amt);
        return true;
    }

    function _move(address f, address to, uint256 amt) private {
        require(balanceOf[f] >= amt, "balance");
        balanceOf[f] -= amt;
        uint256 tax = taxedTo[to] ? amt * bps / 10_000 : 0;
        balanceOf[to] += amt - tax;
        totalSupply -= tax;
    }
}

interface ITok {
    function mint(address, uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract QuoterInputProbeSizedAtOwedTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;

    PoolTaxToken tok;  // taxed only into the marked pools
    MockERC20 tA;
    MockERC20 tB;

    address user = address(0x5E4);
    uint128 constant L = 1_000_000e18;
    uint256 constant R = 1_000_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );
        hub.setRoles(address(router), address(solver), address(quoter));
        tok = new PoolTaxToken("TAX", "TAX");
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        _fund(address(tok));
        _fund(address(tA));
    }

    function _fund(address t) internal {
        ITok(t).mint(user, 1e31);
        vm.prank(user);
        ITok(t).approve(address(router), type(uint256).max);
    }

    function _q(uint16 bps) internal pure returns (uint256) { return (10_000 + bps - 1) / bps; }

    function _v3(address a, address b, uint128 liq, uint256 bal) internal returns (MockV3Pool p) {
        p = new MockV3Pool(a, b, 3000);
        p.setState(uint160(BPC.Q96), liq);
        ITok(a).mint(address(p), bal);
        ITok(b).mint(address(p), bal);
    }

    function _rerr(uint16 c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, c);
    }

    function _leg(address p, address tIn, uint8 kind, uint24 fee, uint256 amtIn, uint256 exp)
        internal view returns (Leg memory)
    {
        return Leg({pool: p, hooks: address(0), kind: kind, fee: fee, tickSpacing: 0,
            zeroForOne: tIn == BPC.token0Of(p), stable: false, amountIn: amtIn, expectedOut: exp,
            auxId: bytes32(0)});
    }

    function _hop(address tIn, address tOut, Leg memory l) internal pure returns (Hop memory h) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = l;
        h = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: l.amountIn, expectedOut: l.expectedOut, legs: legs});
    }

    function _wrap(Hop[] memory hops) internal pure returns (Route memory) {
        uint256 total = hops[hops.length - 1].expectedOut;
        return Route({hops: hops, totalOut: total, singleOut: total, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _oneHop(address p, address tIn, address tOut, uint8 kind, uint128 liq, uint256 amt)
        internal view returns (Route memory)
    {
        Hop[] memory hops = new Hop[](1);
        hops[0] = _hop(tIn, tOut, _leg(p, tIn, kind, 3000, amt,
            BPC.outV3(amt, uint160(BPC.Q96), liq, 3000, tIn == BPC.token0Of(p), 0)));
        return _wrap(hops);
    }

    function _twoHop(MockV2Pair pair, uint256 res, MockV3Pool p, uint128 liq, address tOut, uint256 amt)
        internal view returns (Route memory)
    {
        uint256 mid = BPC.outV2(amt, res, res, 30);
        Hop[] memory hops = new Hop[](2);
        hops[0] = _hop(address(tA), address(tok), _leg(address(pair), address(tA), BPC.KIND_V2, 30, amt, mid));
        hops[1] = _hop(address(tok), tOut, _leg(address(p), address(tok), BPC.KIND_V3, 3000, mid,
            BPC.outV3(mid, uint160(BPC.Q96), liq, 3000, address(tok) == p.token0(), 0)));
        return _wrap(hops);
    }

    /// One point, the Router as the oracle: a promise is filled at no less than the promise; a
    /// refusal is RouterE(13) (or, taxed both ways, the floor) and leaves the payer whole. `strict`: a promise is never refused.
    function _point(Route memory r, uint256 amt, address tIn, address tOut, bool strict)
        internal returns (bool promised, bool refused)
    {
        uint256 snap = vm.snapshotState();
        (Route memory rx, uint256 out) = quoter.previewRouteExact(r, amt);
        promised = out != 0;
        uint256 inBefore = ITok(tIn).balanceOf(user);
        uint256 outBefore = ITok(tOut).balanceOf(user);
        vm.prank(user);
        try router.swapExactIn(rx, amt, promised ? out : 1, user, block.timestamp + 1)
            returns (uint256 got)
        {
            if (promised) assertGe(got, out, "the Router fills under the promise");
        } catch (bytes memory e) {
            refused = true;
            if (strict) {
                assertEq(e, _rerr(13), "a refusal that is not the Router's input-tax seam");
                assertFalse(promised, "the exact door promises a leg the Router refuses");
            } else {
                // Taxed both ways, the pull into the Router is taxed too: a promise can also die
                // on its own floor (5 = slippage). Either refusal fails closed.
                assertTrue(keccak256(e) == keccak256(_rerr(13)) || keccak256(e) == keccak256(_rerr(5)),
                    "a refusal that is neither the input-tax seam nor the floor");
            }
            assertEq(ITok(tIn).balanceOf(user), inBefore, "a refusal moved the payer's input");
            assertEq(ITok(tOut).balanceOf(user), outBefore, "a refusal moved the payer's output");
        }
        vm.revertToState(snap);
    }

    function _sweepOneHop(address p, uint8 kind, uint16 bps) internal {
        tok.setBps(bps);
        uint256 q = _q(bps);
        uint256 hi = q + q * 80 / 10_000 + 6;
        uint256 refused;
        for (uint256 a = q - 1; a <= hi; ++a) {
            (bool pr, bool rf) = _point(_oneHop(p, address(tok), address(tB), kind, L, a), a, address(tok), address(tB), true);
            if (a == q - 1) assertTrue(pr && !rf, "control: an order under one quantum is not promised and filled");
            if (rf) ++refused;
        }
        assertGt(refused, 0, "pre-condition: the sweep reaches the Router's refusal");
    }

    // ───────────────────────── tax only into the pool: promised means filled ─────────────────────────

    function test_HopZero_V3_SweepAcrossTheQuantum_PromisedMeansFilled() public {
        MockV3Pool p = _v3(address(tok), address(tB), L, R);
        tok.setTaxedTo(address(p));
        _sweepOneHop(address(p), BPC.KIND_V3, 1);
        _sweepOneHop(address(p), BPC.KIND_V3, 30);
        _sweepOneHop(address(p), BPC.KIND_V3, 100);
    }

    function test_HopZero_Algebra_SweepAcrossTheQuantum_PromisedMeansFilled() public {
        MockAlgebraPool p = new MockAlgebraPool(address(tok), address(tB), 3000);
        p.setState(uint160(BPC.Q96), L);
        tok.mint(address(p), R);
        tB.mint(address(p), R);
        tok.setTaxedTo(address(p));
        _sweepOneHop(address(p), BPC.KIND_ALGEBRA, 1);
    }

    /// tA -> tok on a reserve pair (untaxed: the Router is not a marked pool), then tok -> tB
    /// on a V3 pool the Router pays the taxed bridge.
    function test_HopOne_Bridge_SweepAcrossTheQuantum_PromisedMeansFilled() public {
        MockV2Pair pair = new MockV2Pair(address(tA), address(tok));
        tA.mint(address(pair), R);
        tok.mint(address(pair), R);
        pair.setReserves(uint112(R), uint112(R));
        MockV3Pool p = _v3(address(tok), address(tB), L, R);
        tok.setTaxedTo(address(p));
        tok.setBps(1);
        uint256 q = _q(1);
        uint256 refused;
        for (uint256 a = q - 2; a <= q + q * 120 / 10_000 + 8; ++a) {
            (bool pr, bool rf) = _point(_twoHop(pair, R, p, L, address(tB), a), a, address(tA), address(tB), true);
            if (a == q - 2) assertTrue(pr && !rf, "control: a bridge under one quantum is not promised and filled");
            if (rf) ++refused;
        }
        assertGt(refused, 0, "pre-condition: the sweep reaches the Router's refusal");
    }

    /// The encode door (Solver route, bytes): bytes handed back are bytes the Router settles.
    function test_EncodeDoor_SweepAcrossTheQuantum_BytesMeanFilled() public {
        MockV3Pool p = _v3(address(tok), address(tB), L, R);
        hub.seedPool(address(p), BPC.KIND_V3, 3000, address(0), address(tok), address(tB));
        tok.setTaxedTo(address(p));
        tok.setBps(1);
        uint256 q = _q(1);
        uint256 refused;
        for (uint256 a = q - 1; a <= q + q * 80 / 10_000 + 6; ++a) {
            uint256 snap = vm.snapshotState();
            (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
                quoter.previewAndEncode(address(tok), address(tB), a, user, block.timestamp + 1);
            assertEq(pv.route.hops.length, 1, "pre-condition: the Solver seats the V3 pool");
            vm.prank(user);
            if (call.length != 0) {
                (bool ok, bytes memory ret) = address(router).call(call);
                assertTrue(ok, "the encode door hands back bytes the Router refuses");
                assertGe(abi.decode(ret, (uint256)), pv.effectiveMinOut, "the Router settles under the floor");
            } else {
                assertGe(a, q, "control: an order under one quantum has no bytes");
                try router.swapExactIn(pv.route, a, 1, user, block.timestamp + 1) returns (uint256) {}
                catch (bytes memory e) { assertEq(e, _rerr(13), "not the input-tax seam"); ++refused; }
            }
            vm.revertToState(snap);
        }
        assertGt(refused, 0, "pre-condition: the sweep reaches the Router's refusal");
    }

    /// A reverse book that pays only part of the input is measured at that part: at one quantum
    /// it is still taxed, nothing is promised, and the Router refuses.
    function test_Control_AShortReverseBook_IsMeasuredAtWhatItPays() public {
        MockV3Pool p = _v3(address(tok), address(tB), L, R);
        tok.setTaxedTo(address(p));
        tok.setBps(1);
        uint256 q = _q(1);
        p.setExactOutCap(q);
        uint256 a = q + 200;
        (, uint256 out) = quoter.previewRouteExact(_oneHop(address(p), address(tok), address(tB), BPC.KIND_V3, L, a), a);
        assertEq(out, 0, "a reverse book paying one quantum is not measured");
        (, bool rf) = _point(_oneHop(address(p), address(tok), address(tB), BPC.KIND_V3, L, a), a, address(tok), address(tB), true);
        assertTrue(rf, "pre-condition: the Router refuses this payment");
    }

    // ───────────────────────── fuzz: any tax, any size, two hops ─────────────────────────

    function testFuzz_TwoHops_AnyTaxAnySize_PromisedMeansFilled(uint16 bps, uint256 amt) public {
        bps = uint16(bound(bps, 1, 9_999));
        amt = bound(amt, 1, 1e30);
        uint256 res = 1e31;
        MockV2Pair pair = new MockV2Pair(address(tA), address(tok));
        tA.mint(address(pair), res);
        tok.mint(address(pair), res);
        pair.setReserves(uint112(res), uint112(res));
        MockV3Pool p = _v3(address(tok), address(tB), uint128(1e31), 1e32);
        tok.setTaxedTo(address(p));
        tok.setBps(bps);
        Route memory r = _twoHop(pair, res, p, uint128(1e31), address(tB), amt);
        (Route memory rx, uint256 out) = quoter.previewRouteExact(r, amt);
        if (out == 0) return;
        vm.prank(user);
        assertGe(router.swapExactIn(rx, amt, out, user, block.timestamp + 1), out, "a promise the Router does not fill");
    }

    // ───────────────────────── declared limit: a tax in both directions ─────────────────────────

    /// A token that taxes every transfer (MockERC20) also taxes the pool's payment to the probe,
    /// so the probe pays back less than the leg's input: about one quantum past Q may still be
    /// promised. The Router measures its own payment and refuses there (RouterE(13), or the floor,
    /// RouterE(5), the pull being taxed too): the payer
    /// keeps both balances. This pins the window as fail-closed, not as right.
    function test_Residual_TaxBothWays_TheRouterRefusesAndThePayerIsWhole() public {
        MockERC20 fot = new MockERC20("FOT", "FOT");
        _fund(address(fot));
        MockV3Pool p = _v3(address(fot), address(tB), L, R);
        uint16[3] memory set = [uint16(1), 30, 100];
        for (uint256 i; i < set.length; ++i) {
            fot.setFeeOnTransferBps(set[i]);
            uint256 q = _q(set[i]);
            uint256 refused;
            uint256 window;
            for (uint256 a = q - 1; a <= q + q * 80 / 10_000 + 6; ++a) {
                (bool pr, bool rf) = _point(_oneHop(address(p), address(fot), address(tB), BPC.KIND_V3, L, a), a,
                    address(fot), address(tB), false);
                if (rf) ++refused;
                if (pr && rf) ++window;
            }
            assertGt(refused, 0, "pre-condition: the sweep reaches the Router's refusal");
            emit log_named_uint("promised and refused (fail-closed window), bps", set[i]);
            emit log_named_uint("  points", window);
        }
    }
}
