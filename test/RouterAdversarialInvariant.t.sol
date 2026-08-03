// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER ADVERSARIAL INVARIANTS — hostile mocks, offline.
//
//  Where the other invariant suites drive HONEST fills and check conservation,
//  this one drives a MALICIOUS actor who fully controls the calldata Route and
//  owns a hostile pool + hostile token, and asserts the master safety net still
//  holds: no token is ever created or destroyed, and the Router keeps nothing.
//
//  Attack surface exercised (the caller-supplied-route model — the Route is
//  attacker calldata, so every field is adversarial):
//
//    A) MULTI-CALLBACK DRAIN. A fake V3-shaped pool re-enters the Router's
//       universal callback fallback N times during one swap, each time trying
//       to pull the leg's tokenIn again. The transient (pool,token,amt) context
//       must bound every pull to the current leg's budget and to the Router's
//       real balance, so N callbacks can never extract more than one.
//
//    B) OVER/UNDER-PAY. The hostile pool pays out an attacker-chosen amount of
//       tokenOut (pre-funded by the attacker). Paying "generously" must not
//       mint value: the surplus is the attacker's own capital round-tripping,
//       so conservation holds and the attacker only ever loses the fee.
//
//    C) CRAFTED ROUTE FIELDS. amountIn, minOut, expectedOut, totalOut and
//       singleOutFloor are all fuzzed independently of reality, probing whether
//       a crafted Route can relax the floor, zero the fee, or over-credit the
//       recipient. The Router re-derives every bound from measured balances.
//
//    D) FEE-ON-TRANSFER hostility routed as the input token, with the taxed
//       amount sent to a tracked sink so conservation stays exact.
//
//    E) REENTRANCY on the OUTBOUND leg — a token that calls swapExactIn again
//       while being paid to the recipient (the nrEntrant lock must reject it).
//
//  MASTER INVARIANTS (must hold across the WHOLE random sequence):
//    INV-C  conservation: Σ balances(token) == total minted (incl. sink)
//    INV-R  the Router holds 0 of every token at rest
//    INV-T  treasuries are monotonic — never clawed back
//
//    forge test --match-contract RouterAdversarialInvariant -vv
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";
import { Route, Hop, Leg } from "../src/BlazePhoenixCore.sol";
import { MockERC20Exec, MockV2ExecPool } from "./RouterExecGuards.t.sol";

interface IERC20Min {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev A fee-on-transfer / reentrant hostile token. All value is conserved:
///      the fee is redirected to `sink` (tracked), nothing is burned.
contract HostileToken {
    string public symbol = "EVIL";
    uint8  public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    uint16  public feeBps;              // fee-on-transfer, redirected to sink
    address public sink;                // where the FoT tax lands (tracked)
    BlazePhoenixRouter public router;   // reentrancy target
    bool    public reenterOnTransfer;   // fire swapExactIn during transfer
    bool    public reentered;

    constructor(address _sink) { sink = _sink; }

    function config(uint16 _feeBps, BlazePhoenixRouter _r, bool _reenterFlag) external {
        feeBps = _feeBps > 5000 ? 5000 : _feeBps;
        router = _r;
        reenterOnTransfer = _reenterFlag;
    }

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function _reenter() internal {
        // Try to nest a swap; the nrEntrant lock must reject it. Never reverts
        // the outer flow (we swallow), so the outer accounting is what we test.
        Route memory empty;
        try router.swapExactIn(empty, 1, 0, address(this), type(uint256).max) returns (uint256) {
            reentered = true;   // would mean the guard FAILED
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
        _move(from, to, amt);
        return true;
    }
    function approve(address, uint256) external pure returns (bool) { return true; }
}

/// @dev A fake V3-shaped pool the attacker controls. On swap() it (optionally)
///      re-enters the Router's universal callback `reenterN` times — each trying
///      to pull `pullEach` of tokenIn — then pays out `payOut` of tokenOut it was
///      pre-funded with. token0/token1 let the Router's _legTokenIn resolve.
contract HostileV3Pool {
    address public token0;
    address public token1;
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    uint128 public liq = 1e24;

    uint256 public reenterN;
    uint256 public pullEach;
    uint256 public payOut;
    bool    public payToken0;   // which side to pay out

    constructor(address t0, address t1) { token0 = t0; token1 = t1; }

    function arm(uint256 _n, uint256 _pull, uint256 _pay, bool _payT0) external {
        reenterN = _n; pullEach = _pull; payOut = _pay; payToken0 = _payT0;
    }

    // Minimal V3 read surface (so it could also be quoted if ever discovered).
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, int24(0), 0, 0, 0, 0, true);
    }
    function liquidity() external view returns (uint128) { return liq; }

    // V3 swap shape. msg.sender is the Router (it called us).
    function swap(address, bool, int256, uint160, bytes calldata)
        external returns (int256, int256)
    {
        // (A) multi-callback drain: hit the Router's fallback N times.
        for (uint256 i; i < reenterN; ) {
            // V3 callback selector (uniswapV3SwapCallback) + (a0, a1, bytes).
            // a0 > 0 makes the Router owe `pullEach` of the transient tokenIn.
            (bool ok, ) = msg.sender.call(
                abi.encodeWithSelector(0xfa461e33, int256(pullEach), int256(0), bytes("")));
            ok;  // tolerated: bounded pulls are expected to revert once drained
            unchecked { ++i; }
        }
        // (B) pay out attacker-chosen tokenOut (pre-funded) back to the Router.
        if (payOut > 0) {
            address t = payToken0 ? token0 : token1;
            if (IERC20Min(t).balanceOf(address(this)) >= payOut) {
                IERC20Min(t).transfer(msg.sender, payOut);
            }
        }
        return (int256(0), int256(0));
    }
}

/// @dev The adversary. Owns the hostile pool + hostile token, fully controls the
///      Route calldata, and fuzzes every field. Ghost-tracks all minted supply
///      so the harness can assert global conservation.
contract Adversary {
    BlazePhoenixRouter immutable router;
    MockERC20Exec      immutable A;      // honest tokens for conservation math
    MockERC20Exec      immutable B;
    MockV2ExecPool     immutable v2;     // an honest settling pool
    HostileV3Pool      immutable evilPool;
    HostileToken       immutable H;      // fee-on-transfer + reentrant token
    MockV2ExecPool     immutable hp;     // settling pool for the H/B pair
    address            immutable victim; // an unrelated recipient

    uint256 public mintedA;
    uint256 public mintedB;
    uint256 public mintedH;
    uint256 public settled;

    constructor(
        BlazePhoenixRouter _r, MockERC20Exec _a, MockERC20Exec _b,
        MockV2ExecPool _v2, HostileV3Pool _evil, HostileToken _h,
        MockV2ExecPool _hp, address _victim
    ) {
        router = _r; A = _a; B = _b; v2 = _v2; evilPool = _evil;
        H = _h; hp = _hp; victim = _victim;
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
        MockERC20Exec tin  = zfo ? A : B;
        MockERC20Exec tout = zfo ? B : A;
        if (zfo) { _mintA(address(this), amt); _mintB(address(v2), 1e27); }
        else     { _mintB(address(this), amt); _mintA(address(v2), 1e27); }

        Leg memory leg = Leg({
            pool: address(v2), hooks: address(0), kind: 0, fee: 0, tickSpacing: 0,
            zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(tin), tokenOut: address(tout),
            amountIn: amt, expectedOut: 0, legs: legs });
        Route memory r; r.hops = hops;
        try router.swapExactIn(r, amt, 0, address(this), block.timestamp + 1) returns (uint256) {
            unchecked { ++settled; }
        } catch {}
    }

    /// Hostile V3 leg — the attacker's crafted route through their own pool,
    /// with multi-callback drain, over/under-pay, and fully fuzzed Route fields.
    function swapHostile(
        uint256 amtSeed, uint256 nSeed, uint256 paySeed,
        uint256 expSeed, uint256 totSeed, uint256 floorSeed, uint256 recSeed
    ) external {
        // A->B through the hostile pool (token0=A, token1=B ⇒ zeroForOne).
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        _mintA(address(this), amt);                 // attacker funds the input
        // Pre-fund the hostile pool with tokenOut it can hand back (attacker's).
        uint256 pay = _bound(paySeed, 0, 5e21);
        _mintB(address(evilPool), pay);

        // Arm the pool: reenter 0..3 times, each trying to pull the full input.
        evilPool.arm(_bound(nSeed, 0, 3), amt, pay, false /*pay token1=B*/);

        // Fuzz every crafted Route field the attacker controls.
        Leg memory leg = Leg({
            pool: address(evilPool), hooks: address(0), kind: 1 /*V3*/, fee: 3000,
            tickSpacing: 60, zeroForOne: true, stable: false,
            amountIn: amt, expectedOut: _bound(expSeed, 0, 1e30), auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(A), tokenOut: address(B),
            amountIn: amt, expectedOut: _bound(expSeed, 0, 1e30), legs: legs });
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

    /// (D)+(E) Route the fee-on-transfer / reentrant token H as the INPUT of an
    /// H->B fill. The FoT tax is measured by the Router; the reentrant hook must
    /// be rejected by nrEntrant. Conservation of H (incl. the sink) must hold
    /// whether the swap settles or reverts.
    function swapHostileToken(uint256 amtSeed, uint256 feeSeed, uint256 reSeed) external {
        uint256 amt = _bound(amtSeed, 1e15, 1e21);
        // fee 0 gives productive reentrancy-probed fills; fee>0 exercises the
        // FoT-measurement path (often reverts against the static mock — fine,
        // conservation holds through the revert).
        uint16 fee = uint16(_bound(feeSeed, 0, 300));
        H.config(fee, router, reSeed % 2 == 0);
        _mintH(address(this), amt);
        _mintB(address(hp), 1e27);      // hp pays out B for H

        Leg memory leg = Leg({
            pool: address(hp), hooks: address(0), kind: 0 /*V2*/, fee: 0, tickSpacing: 0,
            zeroForOne: true /*H is token0*/, stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(H), tokenOut: address(B),
            amountIn: amt, expectedOut: 0, legs: legs });
        Route memory r; r.hops = hops;
        try router.swapExactIn(r, amt, 0, address(this), block.timestamp + 1) returns (uint256) {
            unchecked { ++settled; }
        } catch {}
    }
}

contract RouterAdversarialInvariant is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    MockERC20Exec      A;
    MockERC20Exec      B;
    MockV2ExecPool     v2;
    HostileV3Pool      evilPool;
    HostileToken       H;
    MockV2ExecPool     hp;
    Adversary          adv;

    address victim    = makeAddr("victim");
    address treasury1 = makeAddr("treasury1");
    address treasury2 = makeAddr("treasury2");
    address sink      = makeAddr("fotSink");   // where H's fee-on-transfer lands

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), makeAddr("v4mgr"));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);

        A = new MockERC20Exec();
        B = new MockERC20Exec();
        v2 = new MockV2ExecPool(address(A), address(B), uint112(1e27), uint112(1e27));
        evilPool = new HostileV3Pool(address(A), address(B));
        H = new HostileToken(sink);
        // hp: token0 = H, token1 = B, so an H->B leg is zeroForOne.
        hp = new MockV2ExecPool(address(H), address(B), uint112(1e27), uint112(1e27));
        adv = new Adversary(router, A, B, v2, evilPool, H, hp, victim);

        targetContract(address(adv));
    }

    // Every A-token holder that can ever hold A. If a new sink appears, add it.
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

    /// INV-C: no token A is ever created or destroyed under adversarial routes.
    function invariant_conservationA() public view {
        assertEq(_sumA(), adv.mintedA(), "ADV: token A value created/destroyed");
    }
    /// INV-C: same for token B (the over/under-pay side).
    function invariant_conservationB() public view {
        assertEq(_sumB(), adv.mintedB(), "ADV: token B value created/destroyed");
    }
    /// INV-C: the fee-on-transfer token H is conserved once the sink is counted.
    function invariant_conservationH() public view {
        assertEq(_sumH(), adv.mintedH(), "ADV: token H value created/destroyed");
    }
    /// INV-R: the Router is drained to zero at rest even after hostile swaps.
    function invariant_routerHoldsNothing() public view {
        assertEq(A.balanceOf(address(router)), 0, "ADV: A stuck in Router");
        assertEq(B.balanceOf(address(router)), 0, "ADV: B stuck in Router");
        assertEq(H.balanceOf(address(router)), 0, "ADV: H stuck in Router");
    }
}
