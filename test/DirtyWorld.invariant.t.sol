// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The dirty world (2026-10-20): one invariant campaign over a hostile, already
//  dirty deployment, asserting two meta-invariants after every handler call.
//
//  A. CUSTODY. The Router moves only what the current call brought in.
//     A1  the Router and a 7702-delegated EOA pointing at the Router hold, for
//         every token and for ETH, at least what they were seeded with (plus
//         what was donated to them); a third party's call never lowers it.
//     A2  no recipient gains more of tokenOut than the venues gave up in it.
//     C   a door or a callback reached at the delegated EOA never settles: the
//         EOA is not a Router, whatever code it points at.
//  B. TRUTH.
//     B1  Solver door: when previewPlanExact promises exactOut > 0, the best
//         door with userMinOut = exactOut settles and delivers >= exactOut.
//     B2  hand plan (a Quoter wired to a replay Solver): a preview ABOVE the
//         plan's own claim is a number execution honours, or it is not shown.
//     B3  hostile venues: what settles never delivers under userMinOut.
//     B4  caller-attested routes: what settles keeps at least 1/4 of the
//         attested total (the per-leg floor is 80 % of the bound, 0.8^3 > 1/4).
//
//  The world: tokens A, B, X (bridge), C, F (fee-on-transfer), W (WETH);
//  V2 pairs A/X (x2), X/C, F/X, W/A; V3 pools A/X, X/C and a self-alias X/X;
//  three V4 pools A/B on one manager: honest static, dynamic-fee with a
//  beforeSwap hook that charges the Router more than anyone else, and a static
//  pool whose afterSwap hook is paused and unpaused (code swap). Router and
//  victim are pre-seeded with every token and with ETH; the victim is an EOA
//  delegated (EIP-7702) to the Router, approves the Router for A, and has the
//  Router's permit2/weth slots mirrored so every door reaches _execute.
//
//  Config (inline below): runs = 16, depth = 32 (512 calls), fail_on_revert
//  false, the repo's pinned fuzz seed. Handlers never revert (try/catch).
//
//  forge test --match-path test/DirtyWorld.invariant.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockV4HookedManager} from "./mocks/MockV4HookedManager.sol";

contract DWWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { this.mint(msg.sender, msg.value); }
}

/// beforeSwap fee override that discriminates by caller: the Router pays `feeRouter`,
/// everyone else (the Quoter's dry-run included) pays `feeOthers`.
contract DWFeeHook {
    address public router;
    uint24 public feeRouter;
    uint24 public feeOthers;
    function set(address r, uint24 fr, uint24 fo) external { router = r; feeRouter = fr; feeOthers = fo; }
    function beforeSwapFee(address sender) external view returns (uint24) {
        return sender == router ? feeRouter : feeOthers;
    }
}

/// The admitted mover (IDWMoverHook): BEFORE_SWAP only, listed with its codehash pinned at
/// registration; its admin changes what it does through storage alone.
contract DWMoverHook {
    uint256 public frontBps;
    function setFront(uint256 bps) external { frontBps = bps; }
    function frontRun(uint256 amountIn) external view returns (uint256) { return amountIn * frontBps / 10_000; }
}

/// afterSwap hook: two runtimes, so pausing is a codehash change against the Hub's pin.
contract DWAfterHook { function version() external pure returns (uint256) { return 1; } }
contract DWAfterHookSwapped { function version() external pure returns (uint256) { return 2; } }

/// V3-shaped contract with token0 == token1 (test/Fix1019CycleResidualAndSelfHop.t.sol's
/// F19AliasPool): quotes at `liquidity`, fills at `swapLiquidity`.
contract DWAliasPool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint128 public swapLiquidity;
    constructor(address t, uint24 _fee) { token0 = t; token1 = t; fee = _fee; }
    function setState(uint160 sp, uint128 l) external { sqrtPriceX96 = sp; liquidity = l; }
    function setSwapLiquidity(uint128 l) external { swapLiquidity = l; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact-out unsupported");
        uint256 amtIn = uint256(amountSpecified);
        uint256 amtOut = BPC.outV3(amtIn, sqrtPriceX96, swapLiquidity, fee, zeroForOne, 0);
        if (amtOut == 0) amtOut = 1;
        amount0 = zeroForOne ? int256(amtIn) : -int256(amtOut);
        amount1 = zeroForOne ? -int256(amtOut) : int256(amtIn);
        uint256 balBefore = MockERC20(token0).balanceOf(address(this));
        DWV3Cb(msg.sender).uniswapV3SwapCallback(amount0, amount1, "");
        require(MockERC20(token0).balanceOf(address(this)) - balBefore >= amtIn, "insufficient input");
        MockERC20(token0).transfer(recipient, amtOut);
    }
}

interface DWV3Cb {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// The hand plan: findBestRoutePlan replays whatever route was last set.
contract DWReplaySolver {
    bytes public plan;
    function set(bytes calldata p) external { plan = p; }
    function findBestRoutePlan(address, address, uint256) external view returns (RoutePlan memory rp) {
        rp.best = abi.decode(plan, (Route));
    }
}

struct DWWorld {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    BlazePhoenixQuoter quoterHP;
    DWReplaySolver replay;
    MockV4HookedManager mgr;
    MockPermit2 permit2;
    MockERC20 A;
    MockERC20 B;
    MockERC20 X;
    MockERC20 C;
    MockERC20 F;
    DWWETH W;
    MockV2Pair pAX;
    MockV2Pair pAX2;
    MockV2Pair pXC;
    MockV2Pair pFX;
    MockV2Pair pWA;
    MockV3Pool qAX;
    MockV3Pool qXC;
    DWAliasPool aliasX;
    address victim;
}

contract DirtyWorldHandler is Test {
    uint24  constant DYN = 0x800000;
    int24   constant TS = 60;
    uint24  constant FEE_S = 3000;
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ3 = uint128(1e27);
    address public constant HOOK_DYN = address(uint160(0xD0D0080)); // BEFORE_SWAP only
    address public constant HOOK_AFT = address(uint160(0xAF70040)); // AFTER_SWAP only
    address public constant HOOK_MOV = address(uint160(0xA0FE0080)); // BEFORE_SWAP only, static fee
    address public constant RECIP = address(uint160(0xC0FFEE00));
    uint256 constant NK = 11; // route kinds

    DWWorld internal w;
    bytes32 public pidS;
    bytes32 public pidD;
    bytes32 public pidH;
    MockERC20[6] internal toks;
    address[9] internal venues;
    uint256 internal nonce;
    bool public pausedAft;

    // seeds (A1)
    mapping(address => uint256) public seedR;
    mapping(address => uint256) public seedV;
    uint256 public seedREth;
    uint256 public seedVEth;

    // ghosts
    mapping(uint256 => uint256) public settledKind;
    mapping(uint256 => uint256) public revertedKind;
    mapping(uint256 => uint256) public settledDoor;
    uint256 public a2Breaches;
    bytes public lastA2;
    uint256 public b3Breaches;
    bytes public lastB3;
    uint256 public b4Breaches;
    bytes public lastB4;
    uint256 public b1Checked;
    uint256 public b1Settled;
    uint256 public b1Broken;
    uint256 public b1NoRoute;
    bytes public lastB1;
    uint256 public b2Checked;
    uint256 public b2Settled;
    uint256 public b2AtClaim;
    uint256 public b2Broken;
    bytes public lastB2;
    uint256 public delegatedCalls;
    uint256 public delegationLive;
    uint256 public delegatedSettled;
    uint256 public delegatedErr18;
    uint256 public delegatedOther;
    bytes public lastDelegated;
    uint256 public mvChecked;
    uint256 public mvSettled;
    uint256 public mvRefused;
    uint256 public mvNoRoute;
    uint256 public mvBroken;
    uint256 public mvShort;
    uint256 public mvNotLive;
    uint256 public lastMvGot;
    uint256 public lastMvExact;
    bytes public lastMv;
    uint256 public callbackCalls;
    uint256 public callbackSettled;
    bytes public lastCallback;

    constructor(DWWorld memory world) {
        w = world;
        toks = [w.A, w.B, w.X, w.C, w.F, MockERC20(address(w.W))];
        venues = [address(w.pAX), address(w.pAX2), address(w.pXC), address(w.pFX), address(w.pWA),
                  address(w.qAX), address(w.qXC), address(w.aliasX), address(w.mgr)];
        (address t0, address t1) = BPC.sortTokens(address(w.A), address(w.B));
        pidS = BPC.computeV4PoolId(t0, t1, FEE_S, TS, address(0));
        pidD = BPC.computeV4PoolId(t0, t1, DYN, TS, HOOK_DYN);
        pidH = BPC.computeV4PoolId(t0, t1, FEE_S, TS, HOOK_AFT);
        for (uint256 i; i < 6; ++i) {
            seedR[address(toks[i])] = toks[i].balanceOf(address(w.router));
            seedV[address(toks[i])] = toks[i].balanceOf(w.victim);
        }
        seedREth = address(w.router).balance;
        seedVEth = w.victim.balance;
    }

    function token(uint256 i) external view returns (address) { return address(toks[i]); }
    function router() external view returns (address) { return address(w.router); }
    function victim() external view returns (address) { return w.victim; }

    // ------------------------------------------------------------------ builders

    function _v2(MockV2Pair p, address tin, address tout, uint256 amt) internal pure returns (Leg memory) {
        return Leg({pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: tin < tout, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)});
    }

    function _v3(address pool, bool z, uint256 amt, uint256 exp) internal pure returns (Leg memory) {
        return Leg({pool: pool, hooks: address(0), kind: BPC.KIND_V3, fee: 3000, tickSpacing: 0,
            zeroForOne: z, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
    }

    function _v4(bytes32 pid, uint24 fee, address hooks, uint256 amt, uint256 exp) internal view returns (Leg memory) {
        (address c0,) = BPC.sortTokens(address(w.A), address(w.B));
        return Leg({pool: address(uint160(uint256(pid))), hooks: hooks, kind: BPC.KIND_V4, fee: fee,
            tickSpacing: TS, zeroForOne: address(w.A) == c0, stable: false, amountIn: amt,
            expectedOut: exp, auxId: bytes32(uint256(uint160(address(w.B))))});
    }

    function _hop(address tin, address tout, uint256 amt, uint256 exp, Leg memory l) internal pure returns (Hop memory) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        return Hop({tokenIn: tin, tokenOut: tout, amountIn: amt, expectedOut: exp, legs: ls});
    }

    function _wrap(Hop[] memory hs, uint256 out, uint256 floor_, bool surplus) internal pure returns (Route memory) {
        return Route({hops: hs, totalOut: out, singleOut: out, singleOutFloor: floor_, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: surplus, isV4Bundle: false});
    }

    function _one(Hop memory h, uint256 out, bool surplus) internal pure returns (Route memory) {
        Hop[] memory hs = new Hop[](1);
        hs[0] = h;
        return _wrap(hs, out, 0, surplus);
    }

    function _netOfFee(uint256 b) internal pure returns (uint256) {
        return b - BPC.mulDivUp(b, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
    }

    function _q3(MockV3Pool p, address tIn, uint256 amt) internal view returns (uint256) {
        return BPC.outV3(amt, Q96, LIQ3, 3000, p.token0() == tIn, 0);
    }

    /// The route menu. `attest` != 0 marks a caller-attested route (B4).
    function _build(uint256 kind, uint256 amt, uint256 lev) internal view returns (Route memory r, uint256 attest) {
        address A = address(w.A);
        address X = address(w.X);
        address C = address(w.C);
        if (kind == 0) {
            // A -> X, the hop-0 legs DECLARE amt * lev against a pull of amt (H11 P1 lever)
            r = _one(_hop(A, X, amt * lev, 0, _v2(w.pAX, A, X, amt * lev)), 0, false);
        } else if (kind == 1) {
            // A -> X -> C through the bridge (H11 P3 lever: the Router holds X)
            Hop[] memory hs = new Hop[](2);
            hs[0] = _hop(A, X, amt, 0, _v2(w.pAX, A, X, amt));
            hs[1] = _hop(X, C, amt, 0, _v2(w.pXC, X, C, amt));
            r = _wrap(hs, 0, 0, false);
        } else if (kind == 2) {
            r = _one(_hop(A, address(w.B), amt, amt / 2, _v4(pidS, FEE_S, address(0), amt, amt / 2)), amt / 2, true);
        } else if (kind == 3) {
            r = _one(_hop(A, address(w.B), amt, amt / 2, _v4(pidD, DYN, HOOK_DYN, amt, amt / 2)), amt / 2, true);
        } else if (kind == 4) {
            r = _one(_hop(A, address(w.B), amt, amt / 2, _v4(pidH, FEE_S, HOOK_AFT, amt, amt / 2)), amt / 2, true);
        } else if (kind == 5) {
            // cycle A -> X -> A, hop 0 commits half the pull (H9 lever)
            uint256 x0 = amt / 2;
            Hop[] memory hs = new Hop[](2);
            hs[0] = _hop(A, X, x0, 0, _v2(w.pAX, A, X, x0));
            hs[1] = _hop(X, A, x0, 0, _v2(w.pAX2, X, A, x0));
            r = _wrap(hs, 0, 0, false);
        } else if (kind == 6) {
            // self-hop A -> X -> X -> C through the alias, alias leg attested (H3 lever)
            uint256 b = _q3(w.qAX, A, amt);
            uint256 fair = _q3(w.qXC, X, _netOfFee(b));
            Hop[] memory hs = new Hop[](3);
            hs[0] = _hop(A, X, amt, 0, _v3(address(w.qAX), w.qAX.token0() == A, amt, 0));
            hs[1] = _hop(X, X, b, 0, _v3(address(w.aliasX), true, b, b));
            hs[2] = _hop(X, C, b, 0, _v3(address(w.qXC), w.qXC.token0() == X, b, 0));
            r = _wrap(hs, fair, 1, false);
            attest = fair;
        } else if (kind == 7) {
            r = _one(_hop(address(w.F), X, amt, 0, _v2(w.pFX, address(w.F), X, amt)), 0, false);
        } else if (kind == 8) {
            r = _one(_hop(address(w.W), A, amt, 0, _v2(w.pWA, address(w.W), A, amt)), 0, false);
        } else if (kind == 9) {
            r = _one(_hop(X, address(w.F), amt, 0, _v2(w.pFX, X, address(w.F), amt)), 0, false);
        } else {
            // honest attested A -> X -> C on the V3 pools (B4 on a route that settles)
            uint256 b = _q3(w.qAX, A, amt);
            uint256 fair = _q3(w.qXC, X, _netOfFee(b));
            Hop[] memory hs = new Hop[](2);
            hs[0] = _hop(A, X, amt, 0, _v3(address(w.qAX), w.qAX.token0() == A, amt, 0));
            hs[1] = _hop(X, C, b, 0, _v3(address(w.qXC), w.qXC.token0() == X, b, 0));
            r = _wrap(hs, fair, 1, false);
            attest = fair;
        }
    }

    // ------------------------------------------------------------------ plumbing

    function _payer() internal returns (address p) {
        p = address(uint160(uint256(keccak256(abi.encode("dw.payer", ++nonce)))));
    }

    function _venueBals(address t) internal view returns (uint256[9] memory b) {
        for (uint256 i; i < 9; ++i) b[i] = MockERC20(t).balanceOf(venues[i]);
    }

    function _produced(address t, uint256[9] memory b0) internal view returns (uint256 p) {
        for (uint256 i; i < 9; ++i) {
            uint256 b1 = MockERC20(t).balanceOf(venues[i]);
            if (b0[i] > b1) p += b0[i] - b1;
        }
    }

    /// door: 0 classic, 1 permit2, 2 native, 3 best (tIn -> tOut of the route's ends).
    function _call(uint256 door, address target, Route memory r, uint256 amt, uint256 minOut, address payer)
        internal returns (bool ok, uint256 got, bytes memory err)
    {
        BlazePhoenixRouter t = BlazePhoenixRouter(payable(target));
        address tIn = r.hops[0].tokenIn;
        uint256 dl = block.timestamp + 1;
        if (door == 2) {
            vm.deal(payer, amt);
            vm.prank(payer);
            try t.swapExactInNative{value: amt}(r, minOut, RECIP, dl) returns (uint256 o) { return (true, o, ""); }
            catch (bytes memory e) { return (false, 0, e); }
        }
        MockERC20(tIn).mint(payer, amt);
        if (door == 1) {
            vm.prank(payer);
            MockERC20(tIn).approve(address(w.permit2), amt);
            IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: tIn, amount: amt}), nonce: nonce, deadline: dl});
            vm.prank(payer);
            try t.swapExactInWithPermit2(r, amt, minOut, RECIP, dl, p, "") returns (uint256 o) { return (true, o, ""); }
            catch (bytes memory e) { return (false, 0, e); }
        }
        vm.prank(payer);
        MockERC20(tIn).approve(target, amt);
        vm.prank(payer);
        if (door == 3) {
            address tOut = r.hops[r.hops.length - 1].tokenOut;
            try t.swapBestExactIn(tIn, tOut, amt, minOut, RECIP, dl) returns (uint256 o) { return (true, o, ""); }
            catch (bytes memory e) { return (false, 0, e); }
        }
        try t.swapExactIn(r, amt, minOut, RECIP, dl) returns (uint256 o) { return (true, o, ""); }
        catch (bytes memory e) { return (false, 0, e); }
    }

    function _err18(bytes memory e) internal pure returns (bool) {
        return keccak256(e) == keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(18)));
    }

    // ------------------------------------------------------------------ handlers

    /// Explicit doors at the Router: every route kind, classic / permit2 / native.
    function swapExplicit(uint256 kindSeed, uint256 doorSeed, uint256 amtSeed, uint256 levSeed, uint256 minSeed)
        external
    {
        uint256 kind = kindSeed % NK;
        uint256 amt = 1e15 + amtSeed % 1e19;
        (Route memory r, uint256 attest) = _build(kind, amt, 1 + levSeed % 3);
        uint256 door = doorSeed % 3;
        if (door == 2 && kind != 8) door = 0;
        uint256 minOut = minSeed % 2 == 0 ? 1 : amt / 2;
        address tOut = r.hops[r.hops.length - 1].tokenOut;
        uint256[9] memory vb = _venueBals(tOut);
        uint256 rb = MockERC20(tOut).balanceOf(RECIP);
        (bool ok, uint256 got,) = _call(door, address(w.router), r, amt, minOut, _payer());
        if (!ok) { revertedKind[kind]++; return; }
        settledKind[kind]++;
        settledDoor[door]++;
        uint256 gain = MockERC20(tOut).balanceOf(RECIP) - rb;
        uint256 produced = _produced(tOut, vb);
        if (gain > produced) { a2Breaches++; lastA2 = abi.encode(kind, door, amt, gain, produced); }
        if (got < minOut || (tOut != address(w.F) && gain < minOut)) {
            b3Breaches++; lastB3 = abi.encode(kind, door, amt, got, gain, minOut);
        }
        if (attest != 0 && got < attest / 4) { b4Breaches++; lastB4 = abi.encode(kind, door, amt, got, attest); }
    }

    function _bestPair(uint256 s) internal view returns (address, address) {
        if (s == 0) return (address(w.A), address(w.B));
        if (s == 1) return (address(w.B), address(w.A));
        if (s == 2) return (address(w.A), address(w.C));
        if (s == 3) return (address(w.C), address(w.A));
        if (s == 4) return (address(w.A), address(w.X));
        return (address(w.X), address(w.C));
    }

    /// Solver door against the canonical Quoter's execution-grade promise (B1).
    function swapBest(uint256 pairSeed, uint256 amtSeed) external {
        (address tIn, address tOut) = _bestPair(pairSeed % 6);
        uint256 amt = 1e15 + amtSeed % 1e19;
        uint256 exactOut;
        try w.quoter.previewPlanExact(tIn, tOut, amt) returns (Route memory, uint256 e) { exactOut = e; }
        catch { b1NoRoute++; return; }
        if (exactOut == 0) { b1NoRoute++; return; }
        b1Checked++;
        uint256[9] memory vb = _venueBals(tOut);
        uint256 rb = MockERC20(tOut).balanceOf(RECIP);
        address payer = _payer();
        MockERC20(tIn).mint(payer, amt);
        vm.prank(payer);
        MockERC20(tIn).approve(address(w.router), amt);
        vm.prank(payer);
        try w.router.swapBestExactIn(tIn, tOut, amt, exactOut, RECIP, block.timestamp + 1) returns (uint256 got) {
            b1Settled++;
            settledDoor[3]++;
            uint256 gain = MockERC20(tOut).balanceOf(RECIP) - rb;
            uint256 produced = _produced(tOut, vb);
            if (gain > produced) { a2Breaches++; lastA2 = abi.encode(uint256(100), uint256(3), amt, gain, produced); }
            if (got < exactOut || gain < exactOut) { b1Broken++; lastB1 = abi.encode(tIn, tOut, amt, exactOut, got, gain); }
        } catch (bytes memory e) {
            b1Broken++;
            lastB1 = abi.encode(tIn, tOut, amt, exactOut, e);
        }
    }

    /// Hand plan through the afterSwap-hook pool (paused or live), claim = amt / 4 (B2).
    function handPlan(uint256 amtSeed) external {
        uint256 amt = 1e15 + amtSeed % 1e19;
        uint256 claim = amt / 4;
        Route memory r = _one(
            _hop(address(w.A), address(w.B), amt, claim, _v4(pidH, FEE_S, HOOK_AFT, amt, claim)), claim, true);
        w.replay.set(abi.encode(r));
        Route memory q;
        uint256 exactOut;
        try w.quoterHP.previewPlanExact(address(w.A), address(w.B), amt) returns (Route memory q_, uint256 e) {
            q = q_;
            exactOut = e;
        } catch { return; }
        if (exactOut <= claim) { b2AtClaim++; return; }
        b2Checked++;
        address payer = _payer();
        w.A.mint(payer, amt);
        vm.prank(payer);
        w.A.approve(address(w.router), amt);
        vm.prank(payer);
        try w.router.swapExactIn(q, amt, exactOut, RECIP, block.timestamp + 1) returns (uint256 got) {
            b2Settled++;
            if (got < exactOut) { b2Broken++; lastB2 = abi.encode(pausedAft, amt, claim, exactOut, got); }
        } catch (bytes memory e) {
            b2Broken++;
            lastB2 = abi.encode(pausedAft, amt, claim, exactOut, e);
        }
    }

    /// Every door, reached at the 7702-delegated EOA instead of the Router (C).
    function swapDelegated(uint256 kindSeed, uint256 doorSeed, uint256 amtSeed) external {
        delegatedCalls++;
        (bool s, bytes memory d) = w.victim.staticcall(abi.encodeWithSignature("hub()"));
        if (s && d.length == 32 && abi.decode(d, (address)) == address(w.hub)) delegationLive++;
        uint256 door = doorSeed % 4;
        uint256 kind = door == 2 ? 8 : (door == 3 ? 0 : kindSeed % NK);
        uint256 amt = 1e15 + amtSeed % 1e19;
        (Route memory r,) = _build(kind, amt, 1);
        (bool ok,, bytes memory e) = _call(door, w.victim, r, amt, 1, _payer());
        if (ok) { delegatedSettled++; lastDelegated = abi.encode(kind, door, amt); }
        else if (_err18(e)) delegatedErr18++;
        else { delegatedOther++; lastDelegated = e; }
    }

    /// The Router's callback surfaces, called by a stranger at the Router or at the EOA (C, A1).
    function pokeCallbacks(uint256 sel, uint256 tgt, uint256 amtSeed) external {
        address target = tgt % 2 == 0 ? address(w.router) : w.victim;
        uint256 amt = 1e15 + amtSeed % 1e19;
        address caller = _payer();
        vm.deal(caller, 1 ether);
        (address c0, address c1) = BPC.sortTokens(address(w.A), address(w.B));
        bytes memory valid = abi.encode(c0, c1, FEE_S, TS, address(0), true, amt, bytes(""));
        bytes memory data;
        uint256 value;
        uint256 k = sel % 7;
        if (k == 0) data = abi.encodeWithSignature("unlockCallback(bytes)", hex"deadbeef");
        else if (k == 1) data = abi.encodeWithSignature("unlockCallback(bytes)", valid);
        else if (k == 2) { data = abi.encodeWithSignature("unlockCallback(bytes)", valid); caller = address(w.mgr); }
        else if (k == 3) data = abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", int256(amt), -int256(amt), "");
        else if (k == 4) data = abi.encodeWithSignature("uniswapV2Call(address,uint256,uint256,bytes)", caller, amt, uint256(0), hex"01");
        else if (k == 5) value = 1;
        else { value = 1; data = abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", int256(amt), -int256(amt), ""); }
        callbackCalls++;
        vm.prank(caller);
        (bool ok,) = target.call{value: value}(data);
        if (ok) { callbackSettled++; lastCallback = abi.encode(k, target); }
    }

    /// The world moves: pause/unpause, hook fee, fee-on-transfer rate, donations.
    /// B5, the admitted hook turned by storage (B -> C, whose only venue is the mover's pool).
    /// In one state: the preview never shows more than execution delivers; execution never
    /// delivers under userMinOut (one wei above what it can deliver reverts); the preview's
    /// promise settles for real. Execution refusing outright (the floor) is a revert, allowed.
    function swapMover(uint256 amtSeed) external {
        uint256 amt = 1e15 + amtSeed % 1e19;
        address tIn = address(w.B);
        address tOut = address(w.C);
        // the admission stands: codehash unchanged, so the auto-pause never fired
        if (!w.hub.isHookLive(HOOK_MOV) || w.hub.hookPaused(HOOK_MOV)) { mvNotLive++; return; }
        uint256 exactOut;
        try w.quoter.previewPlanExact(tIn, tOut, amt) returns (Route memory, uint256 e) { exactOut = e; }
        catch { mvNoRoute++; return; }
        if (exactOut == 0) { mvNoRoute++; return; }
        mvChecked++;
        address payer = _payer();
        w.B.mint(payer, amt);
        vm.prank(payer);
        w.B.approve(address(w.router), type(uint256).max);
        // what execution delivers in this very state when nothing is promised
        uint256 snap = vm.snapshotState();
        bool ok;
        uint256 got;
        vm.prank(payer);
        try w.router.swapBestExactIn(tIn, tOut, amt, 1, RECIP, block.timestamp + 1) returns (uint256 g) {
            ok = true;
            got = g;
        } catch {}
        vm.revertToState(snap);
        lastMvGot = got;
        lastMvExact = exactOut;
        if (!ok) { mvRefused++; return; }
        if (exactOut > got) { mvBroken++; lastMv = abi.encode(amt, exactOut, got); }
        // one wei above what execution can deliver: a revert, never a short settle
        vm.prank(payer);
        try w.router.swapBestExactIn(tIn, tOut, amt, got + 1, RECIP, block.timestamp + 1) returns (uint256 g) {
            mvShort++;
            lastMv = abi.encode(amt, got, g);
        } catch {}
        // the preview's promise, for real
        uint256[9] memory vb = _venueBals(tOut);
        uint256 rb = MockERC20(tOut).balanceOf(RECIP);
        vm.prank(payer);
        try w.router.swapBestExactIn(tIn, tOut, amt, exactOut, RECIP, block.timestamp + 1) returns (uint256 g) {
            mvSettled++;
            settledDoor[3]++;
            uint256 gain = MockERC20(tOut).balanceOf(RECIP) - rb;
            uint256 produced = _produced(tOut, vb);
            if (gain > produced) { a2Breaches++; lastA2 = abi.encode(uint256(200), uint256(3), amt, gain, produced); }
            if (g < exactOut || gain < exactOut) { mvBroken++; lastMv = abi.encode(amt, exactOut, g, gain); }
        } catch (bytes memory e) {
            mvBroken++;
            lastMv = abi.encode(amt, exactOut, e);
        }
    }

    function toggle(uint256 sel, uint256 val) external {
        uint256 k = sel % 6;
        if (k == 0) {
            pausedAft = !pausedAft;
            vm.etch(HOOK_AFT, pausedAft ? type(DWAfterHookSwapped).runtimeCode : type(DWAfterHook).runtimeCode);
        } else if (k == 1) {
            uint24[4] memory fees = [uint24(500), uint24(3000), uint24(20_000), uint24(60_000)];
            DWFeeHook(HOOK_DYN).set(address(w.router), fees[val % 4], 500);
        } else if (k == 2) {
            uint16[3] memory bps = [uint16(0), uint16(100), uint16(500)];
            w.F.setFeeOnTransferBps(bps[val % 3]);
        } else if (k == 5) {
            // the mover's admin turns the knob: storage only, the pinned codehash stands
            uint256[4] memory fr = [uint256(0), uint256(5_000), uint256(20_000), uint256(100_000)];
            DWMoverHook(HOOK_MOV).setFront(fr[val % 4]);
        } else {
            MockERC20 t = toks[val % 6];
            uint256 amt = 1e18 + (val >> 8) % 1e20;
            if (k == 3) { t.mint(address(w.router), amt); seedR[address(t)] += amt; }
            else { t.mint(w.victim, amt); seedV[address(t)] += amt; }
        }
    }
}

contract DirtyWorldInvariantTest is Test {
    uint24  constant DYN = 0x800000;
    int24   constant TS = 60;
    uint24  constant FEE_S = 3000;
    uint128 constant LIQ4 = 1e26;
    address constant handlerMov = address(uint160(0xA0FE0080)); // DirtyWorldHandler.HOOK_MOV
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint128 constant LIQ3 = uint128(1e27);
    uint128 constant THIN = uint128(1e17);
    uint256 constant R = 1e24;     // every V2 pair, R / R
    uint256 constant SEED = 5e20;  // Router and victim, per token (>> 3 x max amount)

    DirtyWorldHandler handler;
    DWWorld w;
    uint256 victimPk;

    function setUp() public {
        vm.setEvmVersion("prague");
        address hookDyn = address(uint160(0xD0D0080));
        address hookAft = address(uint160(0xAF70040));
        vm.etch(hookDyn, type(DWFeeHook).runtimeCode);
        vm.etch(hookAft, type(DWAfterHook).runtimeCode);

        w.mgr = new MockV4HookedManager();
        w.hub = new BlazePhoenixHub(address(this));
        w.hub.initialize(address(this), address(w.mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(w.hub));
        w.router = new BlazePhoenixRouter(address(w.hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        w.quoter = new BlazePhoenixQuoter(address(w.hub), address(solver));
        w.hub.setRoles(address(w.router), address(solver), address(w.quoter));
        w.replay = new DWReplaySolver();
        w.quoterHP = new BlazePhoenixQuoter(address(w.hub), address(w.replay));
        w.permit2 = new MockPermit2();
        w.W = new DWWETH();
        w.router.setPermit2(address(w.permit2));
        w.router.setWeth(address(w.W));
        DWFeeHook(hookDyn).set(address(w.router), 20_000, 500);

        w.A = new MockERC20("A", "A");
        w.B = new MockERC20("B", "B");
        w.X = new MockERC20("X", "X");
        w.C = new MockERC20("C", "C");
        w.F = new MockERC20("F", "F");
        w.F.setFeeOnTransferBps(100);

        w.pAX = _pair(w.A, w.X);
        w.pAX2 = _pair(w.A, w.X);
        w.pXC = _pair(w.X, w.C);
        w.pFX = _pair(w.F, w.X);
        w.pWA = _pair(MockERC20(address(w.W)), w.A);
        MockV2Factory factory = new MockV2Factory();
        w.hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        factory.setPair(address(w.A), address(w.X), address(w.pAX));
        factory.setPair(address(w.X), address(w.C), address(w.pXC));
        w.hub.addBridge(address(w.X));

        w.qAX = new MockV3Pool(address(w.A), address(w.X), 3000);
        w.qAX.setState(Q96, LIQ3);
        w.qXC = new MockV3Pool(address(w.X), address(w.C), 3000);
        w.qXC.setState(Q96, LIQ3);
        w.aliasX = new DWAliasPool(address(w.X), 3000);
        w.aliasX.setState(Q96, LIQ3);
        w.aliasX.setSwapLiquidity(THIN);
        w.X.mint(address(w.qAX), R);
        w.C.mint(address(w.qXC), R);
        w.X.mint(address(w.aliasX), R);

        (address t0, address t1) = BPC.sortTokens(address(w.A), address(w.B));
        _v4Pool(t0, t1, FEE_S, address(0), FEE_S);
        _v4Pool(t0, t1, DYN, hookDyn, 500);
        _v4Pool(t0, t1, FEE_S, hookAft, FEE_S);
        // the admitted mover on B/C (its only venue), wide range around tick 0
        vm.etch(handlerMov, type(DWMoverHook).runtimeCode);
        {
            (address m0, address m1) = BPC.sortTokens(address(w.B), address(w.C));
            bytes32 pidM = BPC.computeV4PoolId(m0, m1, FEE_S, TS, handlerMov);
            w.mgr.initialize(pidM, w.mgr.sqrtAt(0), 0, FEE_S);
            w.mgr.addPosition(pidM, -6000, 6000, TS, LIQ4);
            w.hub.addV4(m0, m1, FEE_S, TS, handlerMov);
            assertTrue(w.hub.isHookLive(handlerMov), "setup: the mover is admitted with its codehash pinned");
        }
        w.C.mint(address(w.mgr), R);
        w.A.mint(address(w.mgr), R);
        w.B.mint(address(w.mgr), R);

        (address v, uint256 pk) = makeAddrAndKey("dw.victim");
        w.victim = v;
        victimPk = pk;
        vm.etch(v, abi.encodePacked(hex"ef0100", address(w.router)));
        assertEq(address(BlazePhoenixRouter(payable(v)).hub()), address(w.hub), "setup: the EOA runs the Router code");
        _mirror(address(w.permit2));
        _mirror(address(w.W));

        MockERC20[6] memory ts = [w.A, w.B, w.X, w.C, w.F, MockERC20(address(w.W))];
        for (uint256 i; i < 6; ++i) {
            ts[i].mint(address(w.router), SEED);
            ts[i].mint(v, SEED);
        }
        vm.deal(address(w.router), 100 ether);
        vm.deal(v, 100 ether);
        vm.prank(v);
        w.A.approve(address(w.router), type(uint256).max);

        handler = new DirtyWorldHandler(w);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](7);
        sels[6] = DirtyWorldHandler.swapMover.selector;
        sels[0] = DirtyWorldHandler.swapExplicit.selector;
        sels[1] = DirtyWorldHandler.swapBest.selector;
        sels[2] = DirtyWorldHandler.handPlan.selector;
        sels[3] = DirtyWorldHandler.swapDelegated.selector;
        sels[4] = DirtyWorldHandler.pokeCallbacks.selector;
        sels[5] = DirtyWorldHandler.toggle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function _pair(MockERC20 a, MockERC20 b) internal returns (MockV2Pair p) {
        (address t0, address t1) = BPC.sortTokens(address(a), address(b));
        p = new MockV2Pair(t0, t1);
        a.mint(address(p), R);
        b.mint(address(p), R);
        p.setReserves(uint112(R), uint112(R));
    }

    function _v4Pool(address t0, address t1, uint24 fee, address hooks, uint24 lpFee) internal {
        bytes32 pid = BPC.computeV4PoolId(t0, t1, fee, TS, hooks);
        w.mgr.initialize(pid, w.mgr.sqrtAt(60), 60, lpFee);
        w.mgr.addPosition(pid, 0, 120, TS, LIQ4);
        w.hub.addV4(t0, t1, fee, TS, hooks);
    }

    /// test/Fix1020SelfGuard.t.sol's mirror: copy a Router storage slot holding `v` into the EOA.
    function _mirror(address v) internal {
        bytes32 val = bytes32(uint256(uint160(v)));
        for (uint256 i; i < 64; ++i) {
            if (vm.load(address(w.router), bytes32(i)) == val) {
                vm.store(w.victim, bytes32(i), val);
                return;
            }
        }
        revert("slot not found");
    }

    // ------------------------------------------------------------------ the meta-invariants

    function _checkAll() internal view {
        // A1
        address rt = handler.router();
        address v = handler.victim();
        for (uint256 i; i < 6; ++i) {
            address t = handler.token(i);
            assertGe(MockERC20(t).balanceOf(rt), handler.seedR(t), "A1: the Router's own balance went down");
            assertGe(MockERC20(t).balanceOf(v), handler.seedV(t), "A1: the delegated EOA's balance went down");
            // hypothesis: every seed is non-zero, or A1 watches nothing
            assertGt(handler.seedR(t), 0, "hyp: a Router token seed is zero (A1 vacuous)");
            assertGt(handler.seedV(t), 0, "hyp: a delegated-EOA token seed is zero (A1 vacuous)");
        }
        assertGe(rt.balance, handler.seedREth(), "A1: the Router's ETH went down");
        assertGe(v.balance, handler.seedVEth(), "A1: the delegated EOA's ETH went down");
        assertGt(handler.seedREth(), 0, "hyp: the Router's ETH seed is zero (A1 vacuous)");
        assertGt(handler.seedVEth(), 0, "hyp: the delegated EOA's ETH seed is zero (A1 vacuous)");
        // A2
        assertEq(handler.a2Breaches(), 0, "A2: a recipient got more than the venues produced");
        // C
        assertEq(handler.delegatedSettled(), 0, "C: a door settled at the delegated EOA");
        assertEq(handler.callbackSettled(), 0, "C: a stranger's callback call settled");
        // B
        assertEq(handler.mvNotLive(), 0, "B5: the admitted mover lost its admission (the pin moved)");
        assertEq(handler.mvBroken(), 0, "B5: the preview showed more than execution delivers (admitted hook turned by storage)");
        assertEq(handler.mvShort(), 0, "B5: execution settled under userMinOut (admitted hook turned by storage)");
        assertEq(handler.b1Broken(), 0, "B1: the Solver door did not honour previewPlanExact");
        assertEq(handler.b2Broken(), 0, "B2: a hand-plan preview above its claim was not honoured");
        assertEq(handler.b3Breaches(), 0, "B3: a settle delivered under userMinOut");
        assertEq(handler.b4Breaches(), 0, "B4: an attested route settled under a quarter of its attestation");
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 32
    function invariant_DirtyWorld() public view {
        _checkAll();
    }

    function afterInvariant() public view {
        assertEq(handler.delegationLive(), handler.delegatedCalls(),
            "vacuity: the EOA stopped running the Router code inside the campaign");
    }

    // ------------------------------------------------------------------ the world is live on the base

    /// A scripted walk through every handler and route kind, with the invariants checked at
    /// the end: it proves the campaign is not vacuous (each door settles, each B-check is
    /// reached, the EOA really runs the Router code) and is a deterministic witness.
    function test_DirtyWorld_ScriptedWalkIsLiveAndClean() public {
        for (uint256 k; k < 11; ++k) handler.swapExplicit(k, 0, 1e18, 1, 0);
        handler.swapExplicit(0, 0, 1e18, 2, 0);       // P1 lever: declared 3x the pull
        handler.swapExplicit(0, 1, 1e18, 0, 0);       // permit2
        handler.swapExplicit(7, 1, 1e18, 0, 0);       // permit2 + FoT
        handler.swapExplicit(8, 2, 1e18, 0, 0);       // native
        for (uint256 p; p < 6; ++p) handler.swapBest(p, 1e18);
        handler.handPlan(1e18);                        // live hook: preview above claim, honoured
        handler.toggle(0, 0);                          // pause the afterSwap hook
        handler.handPlan(1e18);                        // paused: preview stays at the claim
        handler.swapExplicit(4, 0, 1e18, 0, 0);       // paused leg refused
        for (uint256 d; d < 4; ++d) handler.swapDelegated(1, d, 1e18);
        for (uint256 c; c < 14; ++c) handler.pokeCallbacks(c, c / 7, 1e18);
        handler.toggle(3, 7);                          // donate
        handler.swapExplicit(1, 0, 1e18, 0, 0);

        uint256[8] memory mustSettle = [uint256(0), 1, 2, 3, 5, 7, 8, 10];
        for (uint256 i; i < 8; ++i) {
            assertGt(handler.settledKind(mustSettle[i]), 0, string.concat("live: route kind did not settle ", vm.toString(mustSettle[i])));
        }
        assertEq(handler.settledKind(6), 0, "live: the self-hop settled");
        assertGt(handler.revertedKind(4), 0, "live: the paused afterSwap leg was not refused");
        assertGt(handler.settledDoor(1), 0, "live: permit2 door");
        assertGt(handler.settledDoor(2), 0, "live: native door");
        assertGt(handler.b1Settled(), 0, "live: B1 never reached a settle");
        assertEq(handler.b1Checked(), handler.b1Settled(), "live: a Solver-door promise did not settle");
        assertEq(handler.b2Checked(), 1, "live: B2 checked the live hook only");
        assertEq(handler.b2Settled(), 1, "live: B2 settle");
        assertEq(handler.b2AtClaim(), 1, "live: the paused hook preview stayed at the claim");
        assertEq(handler.delegationLive(), 4, "live: the EOA runs the Router code");
        assertEq(handler.delegatedErr18(), 4, "live: every door at the EOA reverts RouterE(18)");
        assertEq(handler.callbackCalls(), 14, "live: callbacks poked");
        _checkAll();
    }

    /// B5 witness: the admitted mover, knob at 0 then turned up through storage (codehash and
    /// admission unchanged). The preview follows the turn (it dry-runs through the manager), the
    /// turn really bites (execution delivers less than at knob 0), and B5 holds at every setting.
    function test_DirtyWorld_AdmittedHookTurnedByStorage() public {
        bytes32 h0 = handlerMov.codehash;
        uint256 s0 = vm.snapshotState();
        handler.toggle(5, 0);
        handler.swapMover(1e18);
        uint256 got0 = handler.lastMvGot();
        vm.revertToState(s0);
        handler.toggle(5, 3);                          // front-run 10x the swap, by storage
        assertEq(handlerMov.codehash, h0, "the knob moved the code");
        handler.swapMover(1e18);
        uint256 got1 = handler.lastMvGot();
        assertGt(got1, 0, "live: the turned mover never settled");
        assertLt(got1, got0, "live: the storage knob did not bite");
        assertLe(handler.lastMvExact(), got1, "B5: the preview showed more than the turned mover delivers");
        assertLt(handler.lastMvExact(), got0, "the preview did not follow the turn");
        handler.toggle(5, 1);
        handler.swapMover(3e18);
        handler.toggle(5, 2);
        handler.swapMover(7e18);
        assertEq(handler.mvChecked(), 3, "live: B5 not reached");
        assertEq(handler.mvSettled(), 3, "live: the preview's promise did not settle");
        _checkAll();
    }
}
