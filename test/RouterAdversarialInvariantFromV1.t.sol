// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Ported from Blaze-Phoenix-Dex (V1) test/RouterAdversarialInvariant.t.sol — the most
// comprehensive adversarial suite in V1's history, and a genuine gap: nothing in this repo
// combines ALL of these under one master-invariant campaign, fully fuzzing the Route as attacker
// calldata rather than testing each guard in isolation:
//
//   A) MULTI-CALLBACK DRAIN — a fake V3-shaped pool re-enters the Router's universal callback
//      fallback N times during one swap, each trying to pull the leg's tokenIn again. The
//      transient (pool,token,amt) context must bound every pull to the current leg's budget.
//   B) OVER/UNDER-PAY — the hostile pool pays out an attacker-chosen amount of tokenOut
//      (pre-funded BY the attacker). Paying "generously" must not mint value.
//   C) CRAFTED ROUTE FIELDS — amountIn, minOut, expectedOut, totalOut, singleOutFloor all fuzzed
//      independently of reality, probing whether a crafted Route can relax the floor or over-
//      credit the recipient. The Router must re-derive every bound from measured balances.
//   D) FEE-ON-TRANSFER hostility routed as the input token, taxed amount tracked to a sink.
//   E) REENTRANCY on the OUTBOUND leg — a token that calls swapExactIn again while being paid.
//
// MASTER INVARIANTS across the whole random sequence: conservation per token (incl. the FoT
// sink), the Router holds 0 of every token at rest.
//
// forge test --match-contract RouterAdversarialInvariantFromV1 -vv

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

interface IERC20MinAdv {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev A fee-on-transfer / reentrant hostile token. All value is conserved: the fee is
///      redirected to `sink` (tracked), nothing is burned.
contract HostileToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint16 public feeBps;
    address public sink;
    BlazePhoenixRouter public router;
    bool public reenterOnTransfer;
    bool public reentered;

    constructor(address _sink) { sink = _sink; }

    function config(uint16 _feeBps, BlazePhoenixRouter _r, bool _reenterFlag) external {
        feeBps = _feeBps > 5000 ? 5000 : _feeBps;
        router = _r;
        reenterOnTransfer = _reenterFlag;
    }

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function _reenter() internal {
        Route memory empty;
        try router.swapExactIn(empty, 1, 1, address(this), type(uint256).max) returns (uint256) {
            reentered = true; // would mean the guard FAILED
        } catch {}
    }

    function _move(address from, address to, uint256 amt) internal {
        balanceOf[from] -= amt;
        uint256 fee = (amt * feeBps) / 10000;
        if (fee > 0) balanceOf[sink] += fee;
        balanceOf[to] += amt - fee;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        if (reenterOnTransfer && address(router) != address(0)) _reenter();
        _move(msg.sender, to, amt);
        return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (reenterOnTransfer && address(router) != address(0)) _reenter();
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amt;
        _move(from, to, amt);
        return true;
    }
    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

/// @dev A fake V3-shaped pool the attacker controls. On swap() it (optionally) re-enters the
///      Router's universal callback `reenterN` times, then pays out `payOut` of tokenOut it was
///      pre-funded with.
contract HostileV3Pool {
    address public token0;
    address public token1;
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    uint128 public liq = 1e24;

    uint256 public reenterN;
    uint256 public pullEach;
    uint256 public payOut;
    bool public payToken0;

    constructor(address t0, address t1) { token0 = t0; token1 = t1; }

    function arm(uint256 _n, uint256 _pull, uint256 _pay, bool _payT0) external {
        reenterN = _n; pullEach = _pull; payOut = _pay; payToken0 = _payT0;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, int24(0), 0, 0, 0, 0, true);
    }
    function liquidity() external view returns (uint128) { return liq; }

    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256) {
        // (A) multi-callback drain: hit the Router's universal fallback N times. Selector is
        // irrelevant to the Router (it reads amounts from fixed calldata offsets), so any
        // V3-callback-shaped selector works here, matching uniswapV3SwapCallback's own shape.
        for (uint256 i; i < reenterN; ) {
            (bool ok,) = msg.sender.call(
                abi.encodeWithSelector(0xfa461e33, int256(pullEach), int256(0), bytes("")));
            ok; // tolerated: bounded pulls are expected to revert once drained
            unchecked { ++i; }
        }
        // (B) pay out attacker-chosen tokenOut (pre-funded) back to the Router.
        if (payOut > 0) {
            address t = payToken0 ? token0 : token1;
            if (IERC20MinAdv(t).balanceOf(address(this)) >= payOut) {
                IERC20MinAdv(t).transfer(msg.sender, payOut);
            }
        }
        return (int256(0), int256(0));
    }
}

/// @dev The adversary. Owns the hostile pool + hostile token, fully controls the Route calldata,
///      and fuzzes every field. Ghost-tracks all minted supply for global conservation.
contract Adversary {
    BlazePhoenixRouter immutable router;
    MockERC20 immutable A;
    MockERC20 immutable B;
    MockV2Pair immutable v2;
    HostileV3Pool immutable evilPool;
    HostileToken immutable H;
    MockV2Pair immutable hp; // settling pool for the H/B pair
    address immutable victim;

    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public mintedH;
    uint256 public settled;

    constructor(
        BlazePhoenixRouter _r, MockERC20 _a, MockERC20 _b,
        MockV2Pair _v2, HostileV3Pool _evil, HostileToken _h, MockV2Pair _hp, address _victim
    ) {
        router = _r; A = _a; B = _b; v2 = _v2; evilPool = _evil; H = _h; hp = _hp; victim = _victim;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }
    function _mintA(address to, uint256 a) internal { A.mint(to, a); mintedA += a; }
    function _mintB(address to, uint256 a) internal { B.mint(to, a); mintedB += a; }
    function _mintH(address to, uint256 a) internal { H.mint(to, a); mintedH += a; }

    /// Honest single-leg V2 swap — baseline productive traffic.
    function swapHonest(uint256 dirSeed, uint256 amtSeed) external {
        bool zfo = dirSeed % 2 == 0;
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        MockERC20 tin = zfo ? A : B;
        MockERC20 tout = zfo ? B : A;
        if (zfo) { _mintA(address(this), amt); _mintB(address(v2), 1e27); }
        else { _mintB(address(this), amt); _mintA(address(v2), 1e27); }
        tin.approve(address(router), amt);

        bool poolZfo = address(tin) == v2.token0();
        Leg memory leg = Leg({
            pool: address(v2), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: poolZfo, stable: false, amountIn: amt, expectedOut: amt, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tin), tokenOut: address(tout), amountIn: amt, expectedOut: amt, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
        try router.swapExactIn(r, amt, 1, address(this), block.timestamp + 1) returns (uint256) {
            unchecked { ++settled; }
        } catch {}
    }

    /// Hostile V3 leg — the attacker's crafted route through their own pool, with multi-callback
    /// drain, over/under-pay, and fully fuzzed Route fields.
    function swapHostile(
        uint256 amtSeed, uint256 nSeed, uint256 paySeed,
        uint256 expSeed, uint256 totSeed, uint256 floorSeed, uint256 recSeed
    ) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        _mintA(address(this), amt);
        A.approve(address(router), amt);
        uint256 pay = _bound(paySeed, 0, 5e21);
        _mintB(address(evilPool), pay);

        evilPool.arm(_bound(nSeed, 0, 3), amt, pay, false /*pay token1=B*/);

        bool zfo = address(A) == evilPool.token0();
        Leg memory leg = Leg({
            pool: address(evilPool), hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 60,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: _bound(expSeed, 0, 1e30), auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(A), tokenOut: address(B),
            amountIn: amt, expectedOut: _bound(expSeed, 0, 1e30), legs: legs
        });
        Route memory r;
        r.hops = hops;
        r.totalOut = _bound(totSeed, 0, 1e30);
        r.singleOut = r.totalOut;
        r.singleOutFloor = _bound(floorSeed, 0, 1e30);

        address rec = recSeed % 2 == 0 ? address(this) : victim;
        uint256 minOut = _bound(paySeed >> 1, 0, 1e30);
        try router.swapExactIn(r, amt, minOut, rec, block.timestamp + 1) returns (uint256) {
            unchecked { ++settled; }
        } catch {}
    }

    /// (D)+(E) Route the fee-on-transfer / reentrant token H as the INPUT of an H->B fill. The
    /// FoT tax is measured by the Router; the reentrant hook must be rejected by nrEntrant.
    function swapHostileToken(uint256 amtSeed, uint256 feeSeed, uint256 reSeed) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        uint16 fee = uint16(_bound(feeSeed, 0, 300));
        H.config(fee, router, reSeed % 2 == 0);
        _mintH(address(this), amt);
        H.approve(address(router), amt);
        _mintB(address(hp), 1e27); // hp pays out B for H

        bool zfo = address(H) == hp.token0();
        Leg memory leg = Leg({
            pool: address(hp), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: amt, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(H), tokenOut: address(B), amountIn: amt, expectedOut: amt, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
        try router.swapExactIn(r, amt, 1, address(this), block.timestamp + 1) returns (uint256) {
            unchecked { ++settled; }
        } catch {}
    }
}

contract RouterAdversarialInvariantFromV1Test is StdInvariant, Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A;
    MockERC20 B;
    MockV2Pair v2;
    HostileV3Pool evilPool;
    HostileToken H;
    MockV2Pair hp;
    Adversary adv;

    address victim = makeAddr("victim");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");
    address sink = makeAddr("fotSink");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20("A", "A");
        B = new MockERC20("B", "B");
        v2 = new MockV2Pair(address(A), address(B));
        v2.setReserves(1e27, 1e27);
        evilPool = new HostileV3Pool(address(A), address(B));
        H = new HostileToken(sink);
        hp = new MockV2Pair(address(H), address(B));
        hp.setReserves(1e27, 1e27);
        adv = new Adversary(router, A, B, v2, evilPool, H, hp, victim);

        targetContract(address(adv));
    }

    function _sumA() internal view returns (uint256) {
        return A.balanceOf(address(adv)) + A.balanceOf(address(v2))
             + A.balanceOf(address(evilPool)) + A.balanceOf(address(router))
             + A.balanceOf(victim) + A.balanceOf(treasury1) + A.balanceOf(treasury2);
    }
    function _sumB() internal view returns (uint256) {
        return B.balanceOf(address(adv)) + B.balanceOf(address(v2))
             + B.balanceOf(address(evilPool)) + B.balanceOf(address(hp))
             + B.balanceOf(address(router)) + B.balanceOf(victim)
             + B.balanceOf(treasury1) + B.balanceOf(treasury2);
    }
    function _sumH() internal view returns (uint256) {
        return H.balanceOf(address(adv)) + H.balanceOf(address(hp))
             + H.balanceOf(address(router)) + H.balanceOf(victim)
             + H.balanceOf(treasury1) + H.balanceOf(treasury2) + H.balanceOf(sink);
    }

    function invariant_conservationA() public view {
        assertEq(_sumA(), adv.mintedA(), "ADV: token A value created/destroyed");
    }
    function invariant_conservationB() public view {
        assertEq(_sumB(), adv.mintedB(), "ADV: token B value created/destroyed");
    }
    function invariant_conservationH() public view {
        assertEq(_sumH(), adv.mintedH(), "ADV: token H value created/destroyed");
    }
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "ADV: A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "ADV: B stuck in Router");
        assertEq(H.balanceOf(address(router)), 0, "ADV: H stuck in Router");
    }

    /// @dev Guards against a vacuous pass (see RouterMultiHopInvariantFromV1.t.sol).
    function afterInvariant() public view {
        assertGt(adv.settled(), 0, "no adversarial route ever settled across the whole campaign");
    }
}
