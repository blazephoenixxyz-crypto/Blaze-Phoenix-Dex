// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  THE SWAP EVENTS ARE THE MEASURED FILL.
//
//  `Swap`, `ExecutionProof` and `Fee` are what the SDK, the API and every indexer read
//  (Router:271-305): the SDK's `execute` decodes `Swap`, the API pins the topic0 of
//  `ExecutionProof`. Until this file, `Swap` was pinned in one file and `Fee` in none, so a
//  field could drift from the fill it reports and no test would turn red. This file asserts
//  every field against an oracle that is not the code under test: the balance deltas the test
//  itself measures around the call.
//
//    Swap.user               == the payer (the pranked caller)
//    Swap.amountIn           == what left the payer, measured (ETH on the native door)
//    Swap.amountOut          == what arrived at the recipient, measured
//    Swap.legs               == the number of legs the test built into the route
//    ExecutionProof.realized == Swap.amountOut: a parity pin between two producers that read
//                               the same quantity today (rule 1: pinned, not fused)
//    ExecutionProof.floorUsed <= realized (no output-side fee here), blockNumber == block.number
//    Fee.toT1 + Fee.toT2     == Fee.amount; per token, the shares are each treasury's measured
//                               delta; hop 0's fee is 28 bps of what the payer handed over,
//                               rounded up
//
//  Matrix: {1, 2 hops} x {V2, V3, V4, Solidly, Algebra} x {ERC20 pull, Permit2, native in}
//  x {1e9 wei, 1e21, 1e23 (10% of a V2 reserve)}, every swap on fresh tokens and pools; plus
//  the V4 native-currency legs (WETH in, unwrapped for the manager; WETH out, re-wrapped from
//  the manager's ETH; and the native door into a native leg), and a taxed tokenOut, the one
//  regime where what the Router sends (`net`) and what arrives (`delivered`) differ.
//
//  Mutants that turn this file red (.github/scripts/mutants.py, [morf-P3-*]):
//    Swap.amountOut <- net (Router:1666)      test_TheEventsAreTheMeasuredFill_TaxedTokenOut
//    Swap.legs <- 0                           test_TheEventsAreTheMeasuredFill_V2_Erc20
//    Fee(token, fee, t2, t1) (Router:798)     test_TheEventsAreTheMeasuredFill_V3_Erc20
//  Pins of behaviour that exists at cb1d7d9: green there, so the evidence is the mutants.
// =============================================================================
import {Test, Vm} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {PathologicalERC20} from "./mocks/PathologicalERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";
import {MockV4ManagerNative, MockWETH9} from "./RouterV4NativeEth.t.sol";

interface IFillToken {
    function mint(address to, uint256 amt) external;
    function approve(address spender, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract SwapEventIsTheMeasuredFillTest is Test {
    enum Kind { V2, V3, V4, SOLIDLY, ALGEBRA }
    enum Door { ERC20, PERMIT2, NATIVE }

    address constant T1 = address(0xFEE1);
    address constant T2 = address(0xFEE2);
    address constant USER = address(0xBEEF);
    address constant RECIPIENT = address(0xCAFE);
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ = 1e27;
    uint256 constant DEPTH = 1_000_000e18;
    uint24 constant FEE4 = 500;
    int24 constant TS4 = 10;
    // Pinned from the source, not imported (Core:394): if the fee moves, this file says so.
    uint256 constant FEE_BPS = 28;

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockV4ManagerNative mgr;
    MockPermit2 p2;
    MockWETH9 weth;
    uint256 nonce;

    function setUp() public {
        mgr = new MockV4ManagerNative();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        hub.setRoles(address(router), address(solver), address(this));
        p2 = new MockPermit2();
        router.setPermit2(address(p2));
        weth = new MockWETH9();
        router.setWeth(address(weth));
        // WETH minted to a pool without a deposit must still unwrap, and the manager pays ETH.
        vm.deal(address(weth), 10 * DEPTH);
        vm.deal(address(mgr), 10 * DEPTH);
    }

    // ─── fixture ───

    function _token() internal returns (address) {
        return address(new PathologicalERC20("T", "T", 18));
    }

    function _plant(bytes32 pid) internal {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
    }

    /// One pool of family `k` between a and b, with DEPTH of each token, and its leg a -> b.
    function _leg(Kind k, address a, address b, uint256 amt) internal returns (Leg memory lg) {
        lg.zeroForOne = a < b;
        lg.amountIn = amt;
        if (k == Kind.V2 || k == Kind.SOLIDLY) {
            address p = k == Kind.V2 ? address(new MockV2Pair(a, b)) : address(new MockSolidlyPair(a, b, false));
            MockV2Pair(p).setReserves(uint112(DEPTH), uint112(DEPTH));
            lg.kind = k == Kind.V2 ? BPC.KIND_V2 : BPC.KIND_SOLIDLY;
            Origin.wire(hub, p, a, b, lg.kind, 30, false);
            lg.pool = p;
            lg.fee = 30;
        } else if (k == Kind.V3) {
            MockV3Pool p = new MockV3Pool(a, b, 3000);
            p.setState(Q96, LIQ);
            Origin.wire(hub, address(p), a, b, BPC.KIND_V3, 3000, false);
            lg.pool = address(p);
            lg.kind = BPC.KIND_V3;
            lg.fee = 3000;
            lg.tickSpacing = 60;
        } else if (k == Kind.ALGEBRA) {
            // The registry row as production holds it: the 0 fee sentinel, measured live.
            MockAlgebraPool p = new MockAlgebraPool(a, b, 500);
            p.setState(Q96, LIQ);
            hub.seedPool(address(p), BPC.KIND_ALGEBRA, 0, address(0), a, b);
            lg.pool = address(p);
            lg.kind = BPC.KIND_ALGEBRA;
        } else {
            (address c0, address c1) = a < b ? (a, b) : (b, a);
            bytes32 pid = BPC.computeV4PoolId(c0, c1, FEE4, TS4, address(0));
            _plant(pid);
            lg.pool = address(uint160(uint256(pid)));
            lg.kind = BPC.KIND_V4;
            lg.fee = FEE4;
            lg.tickSpacing = TS4;
            lg.auxId = bytes32(uint256(uint160(b)));
        }
        address holder = k == Kind.V4 ? address(mgr) : lg.pool;
        IFillToken(a).mint(holder, DEPTH);
        IFillToken(b).mint(holder, DEPTH);
    }

    /// A V4 leg against the NATIVE pool (ETH, tok): WETH in is unwrapped for the manager, WETH
    /// out is re-wrapped from the ETH the manager pays.
    function _nativeLeg(address tok, bool wethIsIn, uint256 amt) internal returns (Leg memory lg) {
        bytes32 pid = BPC.computeV4PoolId(address(0), tok, FEE4, TS4, address(0));
        _plant(pid);
        IFillToken(tok).mint(address(mgr), DEPTH);
        lg.pool = address(uint160(uint256(pid)));
        lg.kind = BPC.KIND_V4_NATIVE;
        lg.fee = FEE4;
        lg.tickSpacing = TS4;
        lg.zeroForOne = wethIsIn;
        lg.amountIn = amt;
        lg.auxId = bytes32(uint256(uint160(wethIsIn ? tok : address(weth))));
    }

    function _hop(address a, address b, Leg memory lg, uint256 amt) internal pure returns (Hop memory h) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = lg;
        h = Hop({tokenIn: a, tokenOut: b, amountIn: amt, expectedOut: 0, legs: legs});
    }

    /// n hops of family k on fresh tokens; the first token is WETH on the native door.
    function _route(Kind k, uint256 n, uint256 amt, bool wethFirst) internal returns (Route memory r) {
        r.hops = new Hop[](n);
        address a = wethFirst ? address(weth) : _token();
        for (uint256 h; h < n; ++h) {
            address b = _token();
            r.hops[h] = _hop(a, b, _leg(k, a, b, amt), amt);
            a = b;
        }
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IFillToken(t).balanceOf(who);
    }

    function _t(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    // ─── the measurement and the oracle ───

    /// What the test measures around one swap: the payer's spend, the recipient's receipt and
    /// each treasury's balance of every token of the chain, before the call.
    struct Ctx {
        address tIn;
        address tOut;
        uint256 nLegs;
        uint256 spent;
        uint256 got;
        address[] chain;
        uint256[] t1b;
        uint256[] t2b;
    }

    function _ctx(Route memory r) internal pure returns (Ctx memory c) {
        uint256 n = r.hops.length;
        c.tIn = r.hops[0].tokenIn;
        c.tOut = r.hops[n - 1].tokenOut;
        c.chain = new address[](n + 1);
        for (uint256 h; h < n; ++h) {
            c.chain[h] = r.hops[h].tokenIn;
            c.nLegs += r.hops[h].legs.length;
        }
        c.chain[n] = c.tOut;
        c.t1b = new uint256[](n + 1);
        c.t2b = new uint256[](n + 1);
    }

    function _payerBal(Door d, address tIn) internal view returns (uint256) {
        return d == Door.NATIVE ? USER.balance : _bal(tIn, USER);
    }

    function _before(Door d, Ctx memory c, uint256 amt) internal {
        if (d == Door.NATIVE) {
            vm.deal(USER, amt);
        } else {
            IFillToken(c.tIn).mint(USER, amt);
            vm.prank(USER);
            IFillToken(c.tIn).approve(d == Door.PERMIT2 ? address(p2) : address(router), amt);
        }
        for (uint256 i; i < c.chain.length; ++i) {
            c.t1b[i] = _bal(c.chain[i], T1);
            c.t2b[i] = _bal(c.chain[i], T2);
        }
        c.spent = _payerBal(d, c.tIn);
        c.got = _bal(c.tOut, RECIPIENT);
    }

    function _swap(Door d, Route memory r, uint256 amt) internal {
        Ctx memory c = _ctx(r);
        _before(d, c, amt);
        bytes memory data = _data(d, r, c.tIn, amt);

        vm.recordLogs();
        vm.prank(USER);
        (bool ok, bytes memory ret) = address(router).call{value: d == Door.NATIVE ? amt : 0}(data);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        Vm.Log[] memory logs = vm.getRecordedLogs();

        c.spent -= _payerBal(d, c.tIn);
        c.got = _bal(c.tOut, RECIPIENT) - c.got;
        assertEq(c.spent, amt, "fixture: the payer handed over exactly the amount");
        assertGt(c.got, 0, "fixture: the swap delivered");
        _assertSwap(logs, c);
        _assertProof(logs, c);
        _assertFees(logs, c);
    }

    function _data(Door d, Route memory r, address tIn, uint256 amt) internal returns (bytes memory) {
        uint256 dl = block.timestamp + 1;
        if (d == Door.NATIVE) return abi.encodeCall(router.swapExactInNative, (r, 1, RECIPIENT, dl));
        if (d == Door.ERC20) return abi.encodeCall(router.swapExactIn, (r, amt, 1, RECIPIENT, dl));
        return abi.encodeCall(router.swapExactInWithPermit2, (r, amt, 1, RECIPIENT, dl, _permit(tIn, amt, dl), ""));
    }

    function _permit(address tIn, uint256 amt, uint256 dl) internal returns (IPermit2.PermitTransferFrom memory) {
        return IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: tIn, amount: amt}), nonce: nonce++, deadline: dl
        });
    }

    function _assertSwap(Vm.Log[] memory logs, Ctx memory c) internal view {
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(router) || l.topics[0] != BlazePhoenixRouter.Swap.selector) continue;
            ++swaps;
            assertEq(l.topics[1], _t(USER), "Swap.user is the payer");
            assertEq(l.topics[2], _t(c.tIn), "Swap.tokenIn");
            assertEq(l.topics[3], _t(c.tOut), "Swap.tokenOut");
            (uint256 aIn, uint256 aOut, uint256 legs) = abi.decode(l.data, (uint256, uint256, uint256));
            assertEq(aIn, c.spent, "Swap.amountIn is what left the payer");
            assertEq(aOut, c.got, "Swap.amountOut is what arrived at the recipient");
            assertEq(legs, c.nLegs, "Swap.legs is the route's leg count");
        }
        assertEq(swaps, 1, "one Swap per settled swap");
    }

    /// realized is checked against the same measured receipt as Swap.amountOut: the parity pin.
    function _assertProof(Vm.Log[] memory logs, Ctx memory c) internal view {
        uint256 proofs;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(router) || l.topics[0] != BlazePhoenixRouter.ExecutionProof.selector) continue;
            ++proofs;
            assertEq(l.topics[1], _t(USER), "ExecutionProof.user is the payer");
            assertEq(l.topics[2], _t(c.tOut), "ExecutionProof.tokenOut");
            (uint256 quoted, uint256 real, uint256 floorUsed, uint256 bn) =
                abi.decode(l.data, (uint256, uint256, uint256, uint256));
            assertEq(real, c.got, "ExecutionProof.realized is what arrived = Swap.amountOut");
            assertLe(floorUsed, real, "the floor the swap cleared never exceeds the fill");
            assertGt(quoted, 0, "the in-frame quote of the last hop is published");
            assertEq(bn, block.number, "ExecutionProof.blockNumber");
        }
        assertEq(proofs, 1, "one ExecutionProof per settled swap");
    }

    function _assertFees(Vm.Log[] memory logs, Ctx memory c) internal view {
        uint256 fees;
        for (uint256 k; k < c.chain.length; ++k) {
            uint256 s1;
            uint256 s2;
            for (uint256 i; i < logs.length; ++i) {
                Vm.Log memory l = logs[i];
                if (l.emitter != address(router) || l.topics[0] != BlazePhoenixRouter.Fee.selector) continue;
                if (l.topics[1] != _t(c.chain[k])) continue;
                (uint256 amount, uint256 toT1, uint256 toT2) = abi.decode(l.data, (uint256, uint256, uint256));
                assertEq(toT1 + toT2, amount, "Fee: the two shares are the fee");
                if (k == 0) assertEq(amount, (c.spent * FEE_BPS + 9_999) / 10_000, "hop 0 pays 28 bps of the input, rounded up");
                s1 += toT1;
                s2 += toT2;
                ++fees;
            }
            assertEq(s1, _bal(c.chain[k], T1) - c.t1b[k], "Fee.toT1 is what treasury 1 received");
            assertEq(s2, _bal(c.chain[k], T2) - c.t2b[k], "Fee.toT2 is what treasury 2 received");
        }
        assertGt(fees, 0, "a settled swap paid the protocol fee");
    }

    function _matrix(Kind k, Door d) internal {
        uint256[3] memory amts = [uint256(1e9), 1_000e18, 100_000e18];
        for (uint256 n = 1; n <= 2; ++n) {
            for (uint256 i; i < amts.length; ++i) {
                _swap(d, _route(k, n, amts[i], d == Door.NATIVE), amts[i]);
            }
        }
    }

    // ─── the matrix ───

    function test_TheEventsAreTheMeasuredFill_V2_Erc20() public { _matrix(Kind.V2, Door.ERC20); }
    function test_TheEventsAreTheMeasuredFill_V2_Permit2() public { _matrix(Kind.V2, Door.PERMIT2); }
    function test_TheEventsAreTheMeasuredFill_V2_NativeIn() public { _matrix(Kind.V2, Door.NATIVE); }
    function test_TheEventsAreTheMeasuredFill_V3_Erc20() public { _matrix(Kind.V3, Door.ERC20); }
    function test_TheEventsAreTheMeasuredFill_V3_Permit2() public { _matrix(Kind.V3, Door.PERMIT2); }
    function test_TheEventsAreTheMeasuredFill_V3_NativeIn() public { _matrix(Kind.V3, Door.NATIVE); }
    function test_TheEventsAreTheMeasuredFill_V4_Erc20() public { _matrix(Kind.V4, Door.ERC20); }
    function test_TheEventsAreTheMeasuredFill_V4_Permit2() public { _matrix(Kind.V4, Door.PERMIT2); }
    function test_TheEventsAreTheMeasuredFill_V4_NativeIn() public { _matrix(Kind.V4, Door.NATIVE); }
    function test_TheEventsAreTheMeasuredFill_Solidly_Erc20() public { _matrix(Kind.SOLIDLY, Door.ERC20); }
    function test_TheEventsAreTheMeasuredFill_Solidly_Permit2() public { _matrix(Kind.SOLIDLY, Door.PERMIT2); }
    function test_TheEventsAreTheMeasuredFill_Solidly_NativeIn() public { _matrix(Kind.SOLIDLY, Door.NATIVE); }
    function test_TheEventsAreTheMeasuredFill_Algebra_Erc20() public { _matrix(Kind.ALGEBRA, Door.ERC20); }
    function test_TheEventsAreTheMeasuredFill_Algebra_Permit2() public { _matrix(Kind.ALGEBRA, Door.PERMIT2); }
    function test_TheEventsAreTheMeasuredFill_Algebra_NativeIn() public { _matrix(Kind.ALGEBRA, Door.NATIVE); }

    /// V4 native currency: WETH in is unwrapped and settled in ETH (ERC20 pull and native door);
    /// WETH out is taken in ETH and re-wrapped for the recipient.
    function test_TheEventsAreTheMeasuredFill_V4NativeCurrency() public {
        uint256[3] memory amts = [uint256(1e9), 1_000e18, 100_000e18];
        for (uint256 i; i < amts.length; ++i) {
            uint256 a = amts[i];
            address tok = _token();
            Route memory r;
            r.hops = new Hop[](1);
            r.hops[0] = _hop(address(weth), tok, _nativeLeg(tok, true, a), a);
            _swap(Door.NATIVE, r, a);
            tok = _token();
            r.hops[0] = _hop(address(weth), tok, _nativeLeg(tok, true, a), a);
            _swap(Door.ERC20, r, a);
            tok = _token();
            r.hops[0] = _hop(tok, address(weth), _nativeLeg(tok, false, a), a);
            _swap(Door.ERC20, r, a);
        }
    }

    /// The one regime where `net` (what the Router sends) and `delivered` (what arrives) differ:
    /// tokenOut taxes the transfer to the recipient. The events report what arrived.
    function test_TheEventsAreTheMeasuredFill_TaxedTokenOut() public {
        address a = _token();
        address b = _token();
        PathologicalERC20(b).setFeeOnTransferBps(100);
        uint256 amt = 1_000e18;
        Route memory r;
        r.hops = new Hop[](1);
        r.hops[0] = _hop(a, b, _leg(Kind.V2, a, b, amt), amt);
        _swap(Door.ERC20, r, amt);
    }
}
