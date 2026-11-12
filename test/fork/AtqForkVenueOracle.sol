// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixGate} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../../src/BlazePhoenixCore.sol";

interface IERC20Atq {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IConcPoolAtq {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

struct AtqPoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct AtqSwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
struct AtqModParams { int24 tickLower; int24 tickUpper; int256 liquidityDelta; bytes32 salt; }

interface IV4ManagerAtq {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(AtqPoolKey memory key, AtqSwapParams memory params, bytes calldata hookData) external returns (int256);
    function initialize(AtqPoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(AtqPoolKey memory key, AtqModParams memory params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @notice THE VENUE IS THE ORACLE. A fork harness that asks one real pool, at a pinned block,
///         the two questions a quote answers, and holds the protocol to the pool's own answer:
///
///   P1  never above   Core.outV3 declares its one acceptable direction of error: "EXACT for
///                     what fits inside [the range] and STRICTLY BELOW for the rest - never
///                     above". So for every concentrated leg of a previewed route,
///                     leg.expectedOut <= what the REAL pool pays for leg.amountIn. The harness
///                     swaps that input on the pool itself (its own callback, no protocol code
///                     in the frame) and compares to the wei.
///                     Held green where the code holds it today: a V4 leg is promised its
///                     walked book, and a V3-shaped leg the one-range figure, exact while the
///                     pool's own swap stays in the range it started in (its `liquidity()` is
///                     the same before and after). A V3-shaped swap that leaves its range for
///                     a book of another depth is counted apart (`nAcross`): Core.quote says
///                     "NO boundary clamp, for now" there, and the whole sentence of outV3 is
///                     asserted only by `_verdictNeverAbove`, in the red file.
///   P2  promise kept  `canExecute` is a promise: the previewed route, executed in the same
///                     block with the previewed floor, settles, and the recipient's MEASURED
///                     balance delta is the returned amount and is not below the floor. A
///                     refusal anywhere is typed (a selector, never a Panic or empty data).
///
///   M2  nothing kept  after a settled swap the Router holds, of either token, exactly what
///                     it booked as owed fees (`owed`): unspent input at a price limit goes
///                     back to the payer, never strands.
///   W   the walk      `Core.v4WalkRank` declares `lo <= rank <= hi` on every return and
///                     `rank <= truth <= hi` always, `lo` being the promise whatever the bar.
///                     `truth` here is the venue's own swap of the same input (PoolManager,
///                     or the V3-shaped pool itself when the pool id is zero). Where the walk
///                     finished (`hi == rank`) the two bounds leave no room: exact to the wei.
///
///         Each stack registers ONE factory with ONE tier, so the route can only be the target
///         pool: the verdict is about that venue and not about the Solver's choice. Sizes run
///         from dust to far past the whole book, so the top rungs drive the real pool to its
///         price limit (MIN/MAX_SQRT_RATIO) - `nCorner` proves the corner was reached.
abstract contract AtqForkVenueOracle is Test {
    uint160 internal constant MIN_P1 = 4_295_128_740;
    uint160 internal constant MAX_M1 = 1461446703485210103287273052203988822378723970341;
    uint8 internal constant KIND_V2 = 0;
    uint8 internal constant KIND_V3 = 1;
    uint8 internal constant KIND_V4 = 4;
    uint8 internal constant KIND_SOLIDLY = 5;
    uint8 internal constant KIND_ALGEBRA = 6;
    uint8 internal constant KIND_V4_NATIVE = 8;
    uint8 internal constant MODE_CALL_GENERIC = 0;
    uint8 internal constant MODE_CALL_V3 = 1;
    uint8 internal constant MODE_CALL_SOLIDLY = 2;
    uint8 internal constant MODE_CALL_V3CL = 3;
    uint8 internal constant MODE_CREATE2_V3 = 5;
    bytes32 internal constant UNIV3_INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant T1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant T2 = address(0x7e52222222222222222222222222222222222222);

    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    BlazePhoenixQuoter internal quoter;
    address internal wnative;
    address internal v4mgr;
    address internal user;
    bool internal live;

    // The Router's own input domain ends at uint128; a V4 delta at int128. Two rungs far past
    // any real book, so that the venue's own swap stops at its price limit and not at the input.
    uint256 internal constant CORNER_MID = 1e30 + 3;
    uint256 internal constant CORNER_IN = 1e38 + 7;
    bool internal toCorner;

    // What the ladder measured. Counters, not thresholds: every law below is "zero offenders".
    uint256 internal nCells;      // (direction, size) points asked
    uint256 internal nLegs;       // concentrated legs measured against their pool
    uint256 internal nAbove;      // P1 offenders: quote above what the pool pays, inside one range (or a V4 leg)
    uint256 internal nAcross;     // V3-shaped quotes above the pool on a swap that left its range for another depth
    uint256 internal worstOverNum; // largest (quote - paid), with its paid, among those
    uint256 internal worstOverDen;
    uint256 internal nExact;      // legs whose quote equals the pool's payment to the wei
    uint256 internal nCorner;     // oracle swaps that left the real pool AT its price limit
    uint256 internal nSettled;    // P2: executions that settled
    uint256 internal nBroken;     // P2 offenders: canExecute, then refused
    uint256 internal nShort;      // P2 offenders: settled below the floor / delta != return
    uint256 internal nUntyped;    // refusals with no selector (Panic, empty)
    uint256 internal nKept;       // M2 offenders: the Router kept more (or less) than it booked
    uint256 internal nRefund;     // settled swaps that returned unspent input to the payer
    uint256 internal nRefusedPreview;
    uint256 internal nCut;        // cells whose plan took LESS than the order (the capacity clamp fired)
    uint256 internal firstAboveQuote;
    uint256 internal firstAbovePaid;
    uint256 internal firstAboveAmt;
    uint256 internal worstGapNum; // largest (paid - quote), with its paid, among non-offenders
    uint256 internal worstGapDen;

    // oracle swap context
    address private _cbPool;
    address private _cbToken;

    receive() external payable {}

    function _fork(string memory aliasOrUrl, uint256 blockNumber) internal returns (bool) {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return false; }
        vm.createSelectFork(aliasOrUrl, blockNumber);
        user = makeAddr("atq-fork-user");
        live = true;
        return true;
    }

    /// @dev dRPC serves every chain under the same key; an explicit *_FORK_URL wins (local archive).
    function _drpc(string memory chain, string memory envOverride) internal view returns (string memory) {
        string memory o = vm.envOr(envOverride, string(""));
        if (bytes(o).length != 0) return o;
        return string.concat("https://lb.drpc.live/", chain, "/", vm.envOr("DRPC_KEY", string("")));
    }

    function _stack(address wnative_, address v4mgr_) internal {
        wnative = wnative_;
        v4mgr = v4mgr_;
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), v4mgr_);
        solver = new BlazePhoenixSolver(address(hub), address(new BlazePhoenixGate(address(this))));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        router.setWeth(wnative_);
    }

    function _one24(uint24 v) internal pure returns (uint24[] memory a) { a = new uint24[](1); a[0] = v; }
    function _oneSp(int24 v) internal pure returns (int24[] memory a) { a = new int24[](1); a[0] = v; }
    function _no24() internal pure returns (uint24[] memory a) { a = new uint24[](0); }
    function _noSp() internal pure returns (int24[] memory a) { a = new int24[](0); }

    // ─── the ladder ──────────────────────────────────────────────────────────────────────

    /// @dev Both directions, `rungs` sizes each: unit * step^k + k (never a round number).
    function _ladder(address a, address b, uint256 unitA, uint256 unitB, uint256 step, uint256 rungs) internal {
        _direction(a, b, unitA, step, rungs);
        _direction(b, a, unitB, step, rungs);
    }

    function _direction(address tIn, address tOut, uint256 unit, uint256 step, uint256 rungs) internal {
        uint256 amt = unit;
        for (uint256 k; k < rungs; ++k) {
            _cell(tIn, tOut, amt + k);
            amt *= step;
        }
        if (toCorner) { _cell(tIn, tOut, CORNER_MID); _cell(tIn, tOut, CORNER_IN); }
    }

    function _cell(address tIn, address tOut, uint256 amt) internal {
        ++nCells;
        uint256 snap = vm.snapshotState();
        try quoter.previewPlan(tIn, tOut, amt) returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool) {
            (uint256 q, uint256 p, uint256 a) = _measureLegs(pv.route, tIn, tOut);
            if (a != 0 && a < amt) ++nCut;
            (uint8 st, uint256 got) = _execute(pv, tIn, tOut, amt);
            console2.log(string.concat(
                "cell in=", vm.toString(amt), " legs=", vm.toString(pv.legs), " legIn=", vm.toString(a),
                " quote=", vm.toString(q), " paid=", vm.toString(p),
                " exec=", vm.toString(st), " got=", vm.toString(got), " floor=", vm.toString(pv.effectiveMinOut)));
        } catch (bytes memory e) {
            ++nRefusedPreview;
            if (!_typed(e)) ++nUntyped;
            console2.log(string.concat("cell in=", vm.toString(amt), " preview refused ", vm.toString(e)));
        }
        // revertToState also rewinds THIS contract's storage: the tally crosses it in memory.
        uint256[20] memory t = _tally();
        vm.revertToState(snap);
        _restore(t);
    }

    function _tally() private view returns (uint256[20] memory t) {
        t[0] = nLegs; t[1] = nAbove; t[2] = nExact; t[3] = nCorner; t[4] = nSettled; t[5] = nBroken;
        t[6] = nShort; t[7] = nUntyped; t[8] = nKept; t[9] = nRefund; t[10] = nRefusedPreview;
        t[11] = firstAboveQuote; t[12] = firstAbovePaid; t[13] = firstAboveAmt; t[14] = worstGapNum; t[15] = worstGapDen; t[16] = nCut;
        t[17] = nAcross; t[18] = worstOverNum; t[19] = worstOverDen;
    }

    function _restore(uint256[20] memory t) private {
        nLegs = t[0]; nAbove = t[1]; nExact = t[2]; nCorner = t[3]; nSettled = t[4]; nBroken = t[5];
        nShort = t[6]; nUntyped = t[7]; nKept = t[8]; nRefund = t[9]; nRefusedPreview = t[10];
        firstAboveQuote = t[11]; firstAbovePaid = t[12]; firstAboveAmt = t[13]; worstGapNum = t[14]; worstGapDen = t[15]; nCut = t[16];
        nAcross = t[17]; worstOverNum = t[18]; worstOverDen = t[19];
    }

    /// @dev P1 on every concentrated leg of a one-hop route; each on its own snapshot.
    function _measureLegs(Route memory rt, address tIn, address tOut) internal returns (uint256 q, uint256 p, uint256 a) {
        if (rt.hops.length != 1) return (0, 0, 0);
        Leg[] memory legs = rt.hops[0].legs;
        for (uint256 i; i < legs.length; ++i) {
            Leg memory l = legs[i];
            if (l.amountIn == 0) continue;
            if (l.kind != KIND_V3 && l.kind != KIND_ALGEBRA && l.kind != KIND_V4 && l.kind != KIND_V4_NATIVE) continue;
            (uint256 paid, uint160 spAfter, bool crossed) = _paidLeg(l, tIn, tOut);
            ++nLegs;
            q += l.expectedOut;
            p += paid;
            a += l.amountIn;
            if (spAfter == (l.zeroForOne ? MIN_P1 : MAX_M1)) ++nCorner;
            if (l.expectedOut > paid && crossed) {
                ++nAcross;
                uint256 over = l.expectedOut - paid;
                if (paid != 0 && over * (worstOverDen == 0 ? 1 : worstOverDen) > worstOverNum * paid) {
                    worstOverNum = over; worstOverDen = paid;
                }
            } else if (l.expectedOut > paid) {
                if (nAbove == 0) { firstAboveQuote = l.expectedOut; firstAbovePaid = paid; firstAboveAmt = l.amountIn; }
                ++nAbove;
            } else {
                if (l.expectedOut == paid) ++nExact;
                uint256 gap = paid - l.expectedOut;
                // gap/paid > worst  <=>  gap * worstDen > worstNum * paid  (no division, no literal)
                if (paid != 0 && gap * (worstGapDen == 0 ? 1 : worstGapDen) > worstGapNum * paid) {
                    worstGapNum = gap; worstGapDen = paid;
                }
            }
        }
    }

    /// @dev The pool's own answer for one leg, on its own snapshot. `crossed`: a V3-shaped pool
    ///      whose active liquidity is not what it was before its own swap - the swap left the
    ///      range it started in for a book of another depth. A pool with no `liquidity()` reads
    ///      zero twice, and a refused swap moves nothing: both stay under the strict law.
    function _paidLeg(Leg memory l, address tIn, address tOut) private returns (uint256 paid, uint160 spAfter, bool crossed) {
        uint256 s = vm.snapshotState();
        if (l.kind == KIND_V3 || l.kind == KIND_ALGEBRA) {
            uint256 liq0 = _liqConc(l.pool);
            (paid, spAfter) = _paidConc(l, tIn);
            crossed = _liqConc(l.pool) != liq0;
        } else {
            (paid, spAfter) = _paidV4(l, tIn, tOut);
        }
        vm.revertToState(s);
    }

    function _liqConc(address pool) internal view returns (uint256 liq) {
        (bool ok, bytes memory r) = pool.staticcall(abi.encodeWithSignature("liquidity()"));
        if (ok && r.length >= 32) liq = abi.decode(r, (uint256));
    }

    /// @return st 0 = not promised, 1 = settled, 2 = promised and refused
    function _execute(BlazePhoenixQuoter.Preview memory pv, address tIn, address tOut, uint256 amt)
        internal returns (uint8 st, uint256 got)
    {
        if (!pv.canExecute) return (0, 0);
        deal(tIn, user, amt);
        if (tIn == wnative) vm.deal(wnative, wnative.balance + amt); // dealt wrapped units are backed, so an unwrap can pay
        uint256 before = IERC20Atq(tOut).balanceOf(user);
        vm.startPrank(user);
        IERC20Atq(tIn).approve(address(router), amt);
        try router.swapExactIn(pv.route, amt, pv.effectiveMinOut, user, block.timestamp + 600) returns (uint256 out) {
            got = IERC20Atq(tOut).balanceOf(user) - before;
            ++nSettled;
            st = 1;
            if (got != out || got < pv.effectiveMinOut) ++nShort;
            if (IERC20Atq(tIn).balanceOf(address(router)) != router.owed(tIn, 0) + router.owed(tIn, 1)
                || IERC20Atq(tOut).balanceOf(address(router)) != router.owed(tOut, 0) + router.owed(tOut, 1)) ++nKept;
            if (IERC20Atq(tIn).balanceOf(user) != 0) ++nRefund;
        } catch (bytes memory e) {
            ++nBroken;
            st = 2;
            if (!_typed(e)) ++nUntyped;
            console2.log(string.concat("  promised, refused: ", vm.toString(e)));
        }
        vm.stopPrank();
    }

    function _typed(bytes memory e) internal pure returns (bool) {
        if (e.length < 4) return false;
        bytes4 s;
        assembly { s := mload(add(e, 0x20)) }
        return s != 0x4e487b71; // Panic(uint256)
    }

    /// @dev P1, the settled half of P2, M2 and typed refusals as "zero offenders", plus the
    ///      anti-vacuity floor. `pastCapacity`: some rung had to be larger than the plan took.
    ///      "canExecute, then refused" is counted and printed here and asserted in _verdictStrict.
    function _verdict(string memory tag, bool pastCapacity) internal view {
        console2.log(string.concat(tag, ": cells=", vm.toString(nCells), " legs=", vm.toString(nLegs),
            " exact=", vm.toString(nExact), " above=", vm.toString(nAbove), " across=", vm.toString(nAcross),
            " corner=", vm.toString(nCorner), " cut=", vm.toString(nCut)));
        console2.log(string.concat(tag, ": settled=", vm.toString(nSettled), " broken=", vm.toString(nBroken),
            " short=", vm.toString(nShort), " untyped=", vm.toString(nUntyped),
            " kept=", vm.toString(nKept), " refunds=", vm.toString(nRefund),
            " previewRefused=", vm.toString(nRefusedPreview)));
        console2.log(string.concat(tag, ": widest gap below the pool = ", vm.toString(worstGapNum), " of ", vm.toString(worstGapDen)));
        console2.log(string.concat(tag, ": widest quote above the pool across a range boundary = ", vm.toString(worstOverNum),
            " above a payment of ", vm.toString(worstOverDen)));
        assertGt(nLegs, 0, string.concat(tag, ": no concentrated leg was measured against its pool"));
        assertGt(nSettled, 0, string.concat(tag, ": nothing settled, the ladder proved nothing"));
        if (pastCapacity) assertGt(nCut + nCorner, 0, string.concat(tag, ": no rung outgrew the plan or drove the venue to its price limit"));
        assertEq(nAbove, 0, string.concat(tag, ": a quote above what the pool pays; first: quote ",
            vm.toString(firstAboveQuote), " paid ", vm.toString(firstAbovePaid), " for ", vm.toString(firstAboveAmt)));
        assertEq(nUntyped, 0, string.concat(tag, ": a refusal with no selector"));
        assertEq(nShort, 0, string.concat(tag, ": settled below the previewed floor, or delta != return"));
        assertEq(nKept, 0, string.concat(tag, ": the Router holds a balance it did not book as owed"));
    }

    /// @dev A venue the plan cannot use: every preview refuses, and every refusal carries a selector.
    function _verdictRefusedTyped(string memory tag) internal view {
        console2.log(string.concat(tag, ": cells=", vm.toString(nCells), " previewRefused=", vm.toString(nRefusedPreview),
            " untyped=", vm.toString(nUntyped), " legs=", vm.toString(nLegs), " above=", vm.toString(nAbove)));
        assertGt(nCells, 0, string.concat(tag, ": no cell was asked"));
        assertEq(nAbove, 0, string.concat(tag, ": a quote above what the pool pays"));
        assertEq(nUntyped, 0, string.concat(tag, ": a refusal with no selector"));
        assertEq(nRefusedPreview + nLegs, nCells, string.concat(tag, ": a plan with no concentrated leg came back"));
    }

    /// @dev P1 as Core.outV3 words it - "never above, whatever the liquidity distribution ahead":
    ///      no leave for a swap that crosses into another depth.
    function _verdictNeverAbove(string memory tag) internal view {
        assertGt(nLegs, 0, string.concat(tag, ": no concentrated leg was measured against its pool"));
        assertEq(nAcross, 0, string.concat(tag, ": a quote above what the pool pays, on a swap that left its range; widest: ",
            vm.toString(worstOverNum), " above a payment of ", vm.toString(worstOverDen)));
    }

    /// @dev P2 whole: a preview that said canExecute settles in the same block.
    function _verdictStrict(string memory tag) internal view {
        assertGt(nSettled + nBroken, 0, string.concat(tag, ": no preview said canExecute"));
        assertEq(nBroken, 0, string.concat(tag, ": canExecute, then the same-block execution refused"));
    }

    // ─── the oracle: the pool itself ─────────────────────────────────────────────────────

    /// @dev A pool that refuses the swap (already at its price limit) pays nothing.
    function _paidConc(Leg memory l, address tIn) internal returns (uint256 paid, uint160 spAfter) {
        try this.oracleSwapConc(l.pool, tIn, l.zeroForOne, l.amountIn) returns (uint256 p, uint160 sp) { return (p, sp); }
        catch { return (0, _spotConc(l.pool)); }
    }

    function oracleSwapConc(address pool, address tIn, bool zfo, uint256 amt) external returns (uint256, uint160) {
        require(msg.sender == address(this), "atq: self only");
        return _swapConc(pool, tIn, zfo, amt);
    }

    function _swapConc(address pool, address tIn, bool zfo, uint256 amt) internal returns (uint256 paid, uint160 spAfter) {
        deal(tIn, address(this), amt);
        _cbPool = pool;
        _cbToken = tIn;
        (int256 a0, int256 a1) = IConcPoolAtq(pool).swap(address(this), zfo, int256(amt), zfo ? MIN_P1 : MAX_M1, "");
        _cbPool = address(0);
        int256 o = zfo ? a1 : a0;
        if (o < 0) paid = uint256(-o);
        spAfter = _spotConc(pool);
    }

    function _spotConc(address pool) internal view returns (uint160 sp) {
        (bool ok, bytes memory r) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || r.length < 32) (ok, r) = pool.staticcall(abi.encodeWithSignature("globalState()"));
        if (ok && r.length >= 32) sp = uint160(abi.decode(r, (uint256)));
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external { _pay(d0, d1); }
    function algebraSwapCallback(int256 d0, int256 d1, bytes calldata) external { _pay(d0, d1); }
    function pancakeV3SwapCallback(int256 d0, int256 d1, bytes calldata) external { _pay(d0, d1); }

    function _pay(int256 d0, int256 d1) private {
        require(msg.sender == _cbPool, "atq: not the pool under measurement");
        IERC20Atq(_cbToken).transfer(msg.sender, uint256(d0 > 0 ? d0 : d1));
    }

    function _v4Key(Leg memory l, address tIn, address tOut) internal view returns (AtqPoolKey memory k) {
        address a = tIn; address b = tOut;
        if (l.kind == KIND_V4_NATIVE) { if (a == wnative) a = address(0); if (b == wnative) b = address(0); }
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = AtqPoolKey(c0, c1, l.fee, l.tickSpacing, l.hooks);
    }

    function _paidV4(Leg memory l, address tIn, address tOut) internal returns (uint256 paid, uint160 spAfter) {
        return _swapV4(_v4Key(l, tIn, tOut), l.zeroForOne, l.amountIn);
    }

    function _v4Id(AtqPoolKey memory k) internal pure returns (bytes32) { return keccak256(abi.encode(k)); }

    function _v4Spot(AtqPoolKey memory k) internal view returns (uint160) {
        return uint160(uint256(IV4ManagerAtq(v4mgr).extsload(keccak256(abi.encode(_v4Id(k), uint256(6))))));
    }

    function _swapV4(AtqPoolKey memory k, bool zfo, uint256 amt) internal returns (uint256 paid, uint160 spAfter) {
        address cIn = zfo ? k.currency0 : k.currency1;
        if (cIn == address(0)) vm.deal(address(this), amt); else deal(cIn, address(this), amt);
        paid = _v4Do(0, k, zfo, amt, 0, 0, 0);
        spAfter = _v4Spot(k);
    }

    /// @dev action 0 = exact-input swap to the price limit, 1 = modifyLiquidity. Returns the swap's output.
    function _v4Do(uint8 action, AtqPoolKey memory k, bool zfo, uint256 amt, int24 lo, int24 hi, int256 liq)
        internal returns (uint256)
    {
        return abi.decode(IV4ManagerAtq(v4mgr).unlock(abi.encode(action, k, zfo, amt, lo, hi, liq)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == v4mgr, "atq: not the manager");
        (uint8 action, AtqPoolKey memory k, bool zfo, uint256 amt, int24 lo, int24 hi, int256 liq) =
            abi.decode(data, (uint8, AtqPoolKey, bool, uint256, int24, int24, int256));
        int256 d;
        if (action == 0) d = IV4ManagerAtq(v4mgr).swap(k, AtqSwapParams(zfo, -int256(amt), zfo ? MIN_P1 : MAX_M1), "");
        else (d, ) = IV4ManagerAtq(v4mgr).modifyLiquidity(k, AtqModParams(lo, hi, liq, bytes32(0)), "");
        int128 a0 = int128(d >> 128);
        int128 a1 = int128(d);
        _square(k.currency0, a0);
        _square(k.currency1, a1);
        int128 o = zfo ? a1 : a0;
        return abi.encode(o > 0 ? uint256(uint128(o)) : uint256(0));
    }

    function _square(address c, int128 a) private {
        if (a < 0) {
            uint256 owe = uint256(uint128(-a));
            if (c == address(0)) { IV4ManagerAtq(v4mgr).settle{value: owe}(); }
            else { IV4ManagerAtq(v4mgr).sync(c); IERC20Atq(c).transfer(v4mgr, owe); IV4ManagerAtq(v4mgr).settle(); }
        } else if (a > 0) {
            IV4ManagerAtq(v4mgr).take(c, address(this), uint256(uint128(a)));
        }
    }

    // ─── W: the walk against the venue ───────────────────────────────────────────────────

    uint256 internal wCells;
    uint256 internal wNonzero;  // cells where the venue paid something
    uint256 internal wExact;    // cells where the walk finished (hi == rank): exact by the two bounds
    uint256 internal wCorner;   // cells whose real swap ended AT the venue's price limit
    uint256 internal wOrder;    // offenders: lo <= rank <= hi
    uint256 internal wAbove;    // offenders: rank <= truth
    uint256 internal wCeil;     // offenders: truth <= hi
    uint256 internal wPromise;  // offenders: lo moved with the bar, or differs from v4WalkOut
    uint256 internal wOpen;     // cells whose deep walk did NOT finish (hi > rank)
    uint256 internal wBadAmt;
    uint256 internal wBadRank;
    uint256 internal wBadTruth;
    uint256 internal wBadHi;

    /// @dev `venue` is the PoolManager with `pid != 0`, or a V3-shaped pool with `pid == 0`.
    ///      r = [lo, rank, hi, lo(bar max), rank(bar max), hi(bar max), v4WalkOut, truth].
    function _walkCell(address venue, bytes32 pid, AtqPoolKey memory k, address tIn, bool zfo, uint256 amt, uint24 fee, int24 ts)
        internal
    {
        ++wCells;
        uint256[8] memory r;
        (r[0], r[1], r[2]) = BPC.v4WalkRank(venue, pid, amt, fee, ts, zfo, 0);
        (r[3], r[4], r[5]) = BPC.v4WalkRank(venue, pid, amt, fee, ts, zfo, type(uint256).max);
        r[6] = BPC.v4WalkOut(venue, pid, amt, fee, ts, zfo);
        uint256 s = vm.snapshotState();
        uint160 spAfter;
        if (pid == bytes32(0)) (r[7], spAfter) = _swapConc(venue, tIn, zfo, amt);
        else (r[7], spAfter) = _swapV4(k, zfo, amt);
        vm.revertToState(s);
        _walkJudge(r, amt, zfo, spAfter == (zfo ? MIN_P1 : MAX_M1));
    }

    function _walkJudge(uint256[8] memory r, uint256 amt, bool zfo, bool corner) private {
        if (r[7] != 0) ++wNonzero;
        if (corner) ++wCorner;
        if (r[2] == r[1]) ++wExact; else ++wOpen;
        if (r[0] > r[1] || r[1] > r[2] || r[3] > r[4] || r[4] > r[5]) ++wOrder;
        if (r[0] != r[3] || r[0] != r[6]) ++wPromise;
        bool bad;
        if (r[1] > r[7] || r[4] > r[7]) { ++wAbove; bad = true; }
        if (r[2] < r[7] || r[5] < r[7]) { ++wCeil; bad = true; }
        if (bad && wBadAmt == 0) { wBadAmt = amt; wBadRank = r[1]; wBadTruth = r[7]; wBadHi = r[2]; }
        console2.log(string.concat("walk ", zfo ? "0>1" : "1>0", " in=", vm.toString(amt), " lo=", vm.toString(r[0]),
            " rank=", vm.toString(r[1]), " truth=", vm.toString(r[7]), r[2] == r[1] ? " closed" : " open",
            corner ? " CORNER" : ""));
    }

    function _walkLadder(address venue, bytes32 pid, AtqPoolKey memory k, address tIn, bool zfo, uint24 fee, int24 ts,
        uint256 unit, uint256 step, uint256 rungs) internal
    {
        uint256 n = toCorner ? rungs + 2 : rungs;
        for (uint256 i; i < n; ++i) {
            _walkCell(venue, pid, k, tIn, zfo, i < rungs ? unit + i : (i == rungs ? CORNER_MID : CORNER_IN), fee, ts);
            if (i < rungs) unit *= step;
        }
    }

    function _verdictWalk(string memory tag, bool mustReachCorner) internal view {
        console2.log(string.concat(tag, ": walk cells=", vm.toString(wCells), " paid=", vm.toString(wNonzero),
            " closed=", vm.toString(wExact), " open=", vm.toString(wOpen), " corner=", vm.toString(wCorner)));
        console2.log(string.concat(tag, ": order=", vm.toString(wOrder), " above=", vm.toString(wAbove),
            " ceil=", vm.toString(wCeil), " promise=", vm.toString(wPromise)));
        assertGt(wNonzero, 0, string.concat(tag, ": the venue paid nothing, the walk was compared to nothing"));
        assertGt(wExact, 0, string.concat(tag, ": no walk finished, so nothing was held exact"));
        if (mustReachCorner) assertGt(wCorner, 0, string.concat(tag, ": no rung drove the venue to its price limit"));
        assertEq(wOrder, 0, string.concat(tag, ": lo <= rank <= hi broken"));
        assertEq(wAbove, 0, string.concat(tag, ": the walk ranks above what the venue pays; first: in ",
            vm.toString(wBadAmt), " rank ", vm.toString(wBadRank), " truth ", vm.toString(wBadTruth)));
        assertEq(wCeil, 0, string.concat(tag, ": the ceiling is under what the venue pays; first: in ",
            vm.toString(wBadAmt), " hi ", vm.toString(wBadHi), " truth ", vm.toString(wBadTruth)));
        assertEq(wPromise, 0, string.concat(tag, ": the promise moved with the bar"));
    }
}
