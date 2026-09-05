// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  ONE FEE, ONE PLACE — measured from outside the Router.
//
//  The rule (Router._execute, 2026-08-22; both regimes named 2026-09-05): ANCHORED — a bridge
//  coin is some hop's input, and the fee is charged exactly once, there (or on the output of a
//  direct route into a bridge coin); EXHAUSTION — no bridge coin is any hop's input, and every
//  hop pays on its own measured input. The second is immunity by exhaustion: a single charge
//  on hop 0 would let a value-less prefix hop carry the fee spot onto dust.
//
//  Nothing here reads the Router's own numbers. The fee token is derived from the rule and
//  the bridge list; the fee base is measured from the POOLS' balance deltas (what left the
//  Router into the fee hop) and from the recipient's; the fee paid is the treasuries' delta;
//  the count is the number of Fee events. The property is asserted over every route shape
//  the Router accepts — hops 1..3, bridge in none / first / middle / last position, one or two
//  legs per hop — on fuzzed amounts. A bug in any of the three seals (the regime fallback,
//  the single producer of the hop's commitment, the run-time ledger) moves one of these
//  numbers, and the detection study (docs/assurance/fee-seal-detection.json) says how often.
//
//  forge test --match-path test/FeeSeals.t.sol
// =============================================================================
import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract FeeSealsTest is Test {
    bytes32 constant FEE_SIG = keccak256("Fee(address,uint256,uint256,uint256)");
    uint256 constant RESERVE = 1e24;

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    address user = address(0xBEEF);
    address t1 = address(0xFEE1);
    address t2 = address(0xFEE2);
    MockERC20[5] tok;                 // 0..3 plain, 4 = the bridge coin W
    mapping(address => mapping(address => MockV2Pair[2])) pools;   // two pools per pair, for two legs

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        router = new BlazePhoenixRouter(address(hub), address(0x5011), address(this), t1, t2);
        string[5] memory names = ["A", "B", "C", "D", "W"];
        for (uint256 i; i < 5; ++i) tok[i] = new MockERC20(names[i], names[i]);
        hub.addBridge(address(tok[4]));
        for (uint256 i; i < 5; ++i) {
            for (uint256 j = i + 1; j < 5; ++j) {
                for (uint256 k; k < 2; ++k) {
                    MockV2Pair p = new MockV2Pair(address(tok[i]), address(tok[j]));
                    tok[i].mint(address(p), RESERVE); tok[j].mint(address(p), RESERVE);
                    (address a0, ) = address(tok[i]) < address(tok[j]) ? (address(tok[i]), address(tok[j])) : (address(tok[j]), address(tok[i]));
                    a0; p.setReserves(uint112(RESERVE), uint112(RESERVE));
                    pools[address(tok[i])][address(tok[j])][k] = p;
                    pools[address(tok[j])][address(tok[i])][k] = p;
                }
            }
        }
    }

    // ── the shapes: a path of token indices, hops = path.length - 1
    function _path(uint8 shape) private pure returns (uint8[] memory p) {
        // 0 A>B  1 W>A  2 A>W  3 A>C>B  4 W>A>B  5 A>W>B  6 A>C>W  7 A>C>D>B  8 A>W>C>B  9 A>C>W>B
        if (shape == 0) { p = new uint8[](2); p[0]=0; p[1]=1; }
        else if (shape == 1) { p = new uint8[](2); p[0]=4; p[1]=0; }
        else if (shape == 2) { p = new uint8[](2); p[0]=0; p[1]=4; }
        else if (shape == 3) { p = new uint8[](3); p[0]=0; p[1]=2; p[2]=1; }
        else if (shape == 4) { p = new uint8[](3); p[0]=4; p[1]=0; p[2]=1; }
        else if (shape == 5) { p = new uint8[](3); p[0]=0; p[1]=4; p[2]=1; }
        else if (shape == 6) { p = new uint8[](3); p[0]=0; p[1]=2; p[2]=4; }
        else if (shape == 7) { p = new uint8[](4); p[0]=0; p[1]=2; p[2]=3; p[3]=1; }
        else if (shape == 8) { p = new uint8[](4); p[0]=0; p[1]=4; p[2]=2; p[3]=1; }
        else { p = new uint8[](4); p[0]=0; p[1]=2; p[2]=4; p[3]=1; }
    }

    function _leg(MockV2Pair p, address tIn, uint256 amt) private view returns (Leg memory) {
        (uint112 r0, uint112 r1, ) = p.getReserves();
        bool zfo = p.token0() == tIn;
        uint256 q = BPC.outV2(amt, zfo ? r0 : r1, zfo ? r1 : r0, 30);
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
                    zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: q, auxId: bytes32(0)});
    }

    function _route(uint8[] memory path, uint256 amountIn, bool twoLegs) private view returns (Route memory r) {
        uint256 n = path.length - 1;
        Hop[] memory hops = new Hop[](n);
        uint256 amt = amountIn;
        for (uint256 h; h < n; ++h) {
            address tIn = address(tok[path[h]]); address tOut = address(tok[path[h + 1]]);
            Leg[] memory legs = new Leg[](twoLegs ? 2 : 1);
            uint256 expected;
            if (twoLegs) {
                legs[0] = _leg(pools[tIn][tOut][0], tIn, amt / 2);
                legs[1] = _leg(pools[tIn][tOut][1], tIn, amt - amt / 2);
                expected = legs[0].expectedOut + legs[1].expectedOut;
            } else {
                legs[0] = _leg(pools[tIn][tOut][0], tIn, amt);
                expected = legs[0].expectedOut;
            }
            hops[h] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: expected, legs: legs});
            amt = expected;   // the next hop's declared input: proportions only, the Router rescales
        }
        r = Route({hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0, expectedImpactBps: 0,
                   confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// The RULE, written independently of the Router: which token pays, on which side — and in
    /// the exhaustion regime (no bridge coin as any hop's input) EVERY hop pays on its own input.
    function _feeSpot(uint8[] memory path) private view returns (address feeToken, uint256 feeHop, bool onOut, bool exhaustion) {
        uint256 n = path.length - 1;
        for (uint256 h; h < n; ++h) if (hub.isBridgeToken(address(tok[path[h]]))) return (address(tok[path[h]]), h, false, false);
        if (n == 1 && hub.isBridgeToken(address(tok[path[1]]))) return (address(tok[path[1]]), 0, true, false);
        return (address(tok[path[0]]), 0, false, n > 1);
    }

    function _poolBal(uint8[] memory path, uint256 h, address t) private view returns (uint256) {
        address a = address(tok[path[h]]); address b = address(tok[path[h + 1]]);
        return MockERC20(t).balanceOf(address(pools[a][b][0])) + MockERC20(t).balanceOf(address(pools[a][b][1]));
    }

    function _treasury(address t) private view returns (uint256) {
        return MockERC20(t).balanceOf(t1) + MockERC20(t).balanceOf(t2);
    }

    function _feeEvents(Vm.Log[] memory logs) private pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics[0] == FEE_SIG) ++n;
    }

    struct Snap {
        uint256[5] treas;      // treasuries' balance per token, before
        uint256 feePool;       // fee token in the fee hop's pools, before
        uint256 prevPool;      // fee token in the previous hop's pools, before
        uint256 userIn;
        uint256 userOut;
        uint256[4] hopPool;    // hop h's input token in hop h-1's pools, before (h >= 1)
    }

    function _snap(uint8[] memory path, address feeToken, uint256 feeHop, bool onOut) private view returns (Snap memory b) {
        for (uint256 i; i < 5; ++i) b.treas[i] = _treasury(address(tok[i]));
        b.feePool = onOut ? 0 : _poolBal(path, feeHop, feeToken);
        b.prevPool = feeHop == 0 ? 0 : _poolBal(path, feeHop - 1, feeToken);
        b.userIn = MockERC20(address(tok[path[0]])).balanceOf(user);
        b.userOut = MockERC20(address(tok[path[path.length - 1]])).balanceOf(user);
        for (uint256 h = 1; h < path.length - 1; ++h) b.hopPool[h] = _poolBal(path, h - 1, address(tok[path[h]]));
    }

    /// Every shape, one or two legs, fuzzed amounts: settles, pays as the regime says, in the
    /// rule's token(s), exactly ceil(28 bps) of a base measured from the pools — and nothing else.
    function testFuzz_OneFeeOnePlace_EveryShape(uint8 shape, bool twoLegs, uint256 amountSeed) public {
        shape = uint8(bound(shape, 0, 9));
        uint256 amountIn = bound(amountSeed, 1e12, 1e21);
        uint8[] memory path = _path(shape);
        (address feeToken, uint256 feeHop, bool onOut, bool exhaustion) = _feeSpot(path);
        tok[path[0]].mint(user, amountIn);
        vm.prank(user); MockERC20(address(tok[path[0]])).approve(address(router), amountIn);
        Snap memory b = _snap(path, feeToken, feeHop, onOut);
        Route memory route = _route(path, amountIn, twoLegs);   // built BEFORE the prank: its pool reads are external calls

        vm.recordLogs();
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        if (exhaustion) _checkExhaustion(path, amountIn, b, logs);
        else _checkAnchored(path, amountIn, feeToken, feeHop, onOut, b, logs, delivered);
        for (uint256 i; i < 5; ++i) assertEq(tok[i].balanceOf(address(router)), 0, "the Router holds nothing");
    }

    /// immunity by exhaustion: one Fee event per hop, each ceil(28 bps) of that hop's measured input
    function _checkExhaustion(uint8[] memory path, uint256 amountIn, Snap memory b, Vm.Log[] memory logs) private view {
        uint256 n = path.length - 1;
        assertEq(_feeEvents(logs), n, "exhaustion regime: one Fee event per hop");
        for (uint256 h; h < n; ++h) {
            address th = address(tok[path[h]]);
            uint256 baseH = h == 0 ? amountIn : b.hopPool[h] - _poolBal(path, h - 1, th);
            assertEq(_treasury(th) - b.treas[_idx(th)], BPC.mulDivUp(baseH, BPC.PROTOCOL_FEE_BPS, BPC.BPS),
                "exhaustion regime: hop h pays ceil(28 bps) of what entered it");
        }
        address tOut = address(tok[path[n]]);
        assertEq(_treasury(tOut), b.treas[_idx(tOut)], "exhaustion regime: nothing charged on the output");
    }

    /// anchored: exactly one Fee event, in the rule's token, ceil(28 bps) of the base the pools measured
    function _checkAnchored(uint8[] memory path, uint256 amountIn, address feeToken, uint256 feeHop, bool onOut, Snap memory b, Vm.Log[] memory logs, uint256 delivered) private view {
        assertEq(_feeEvents(logs), 1, "anchored regime: a settled swap emits exactly one Fee event");
        uint256 fee = _treasury(feeToken) - b.treas[_idx(feeToken)];
        for (uint256 i; i < 5; ++i) {
            if (address(tok[i]) != feeToken) assertEq(_treasury(address(tok[i])), b.treas[i], "a fee was paid in a token the rule does not name");
        }
        assertGt(fee, 0, "a settled swap paid no fee");
        uint256 base;
        if (onOut) {
            base = delivered + fee;
            assertEq(MockERC20(address(tok[path[path.length - 1]])).balanceOf(user) - b.userOut, delivered, "delivered is the recipient's delta");
        } else if (feeHop == 0) {
            uint256 spent = b.userIn - MockERC20(address(tok[path[0]])).balanceOf(user);   // pulled minus swept back
            uint256 intoPools = _poolBal(path, 0, feeToken) - b.feePool;
            assertEq(spent, intoPools + fee, "hop 0: what the user spent is what the pools got plus the fee");
            base = amountIn;   // pulled and committed: both the test's own numbers, equal here
        } else {
            uint256 outOfPrev = b.prevPool - _poolBal(path, feeHop - 1, feeToken);   // the bridge coin hop f-1 paid out
            uint256 intoFeeHop = _poolBal(path, feeHop, feeToken) - b.feePool;
            // one wei of the split's rounding is swept back to the payer, never kept
            assertApproxEqAbs(outOfPrev, intoFeeHop + fee, 1, "hop f: the bridge coin hop f-1 produced is what hop f got plus the fee");
            base = outOfPrev;
        }
        assertEq(fee, BPC.mulDivUp(base, BPC.PROTOCOL_FEE_BPS, BPC.BPS), "the fee is ceil(28 bps) of the measured base");
    }

    function _idx(address t) private view returns (uint256) {
        for (uint256 i; i < 5; ++i) if (address(tok[i]) == t) return i;
        revert("unknown token");
    }

    /// Immunity by exhaustion, pinned from the outside: a route through no bridge coin pays on
    /// every hop, each on the input that hop measured — the policy `ExhaustionRegimePreviewParity`
    /// ties to the preview, asserted here against the pools rather than the preview.
    function test_NoBridgeThreeHops_PaysOnEveryHop_ImmunityByExhaustion() public {
        uint8[] memory path = _path(7);
        uint256 amountIn = 1e20;
        Route memory route = _route(path, amountIn, false);
        tok[0].mint(user, amountIn);
        vm.prank(user); tok[0].approve(address(router), amountIn);
        uint256 cBefore = tok[2].balanceOf(address(pools[address(tok[0])][address(tok[2])][0]));
        uint256 dBefore = tok[3].balanceOf(address(pools[address(tok[2])][address(tok[3])][0]));
        vm.recordLogs();
        vm.prank(user);
        router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        assertEq(_feeEvents(vm.getRecordedLogs()), 3, "three hops, no bridge: three fees");
        uint256 cIn = cBefore - tok[2].balanceOf(address(pools[address(tok[0])][address(tok[2])][0]));
        uint256 dIn = dBefore - tok[3].balanceOf(address(pools[address(tok[2])][address(tok[3])][0]));
        assertEq(_treasury(address(tok[0])), BPC.mulDivUp(amountIn, 28, 10_000), "hop 0 pays 28 bps of its input, in A");
        assertEq(_treasury(address(tok[2])), BPC.mulDivUp(cIn, 28, 10_000), "hop 1 pays 28 bps of the C it received, in C");
        assertEq(_treasury(address(tok[3])), BPC.mulDivUp(dIn, 28, 10_000), "hop 2 pays 28 bps of the D it received, in D");
        assertEq(_treasury(address(tok[1])), 0, "nothing charged on the output");
    }
}
