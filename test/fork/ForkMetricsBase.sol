// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  FORK METRICS — shared base.
//
//  Per-chain fork suites (ForkMetrics = Ethereum, ForkL2Metrics = Arbitrum /
//  Base / Optimism) extend this. Each subclass spins up its own fork from a
//  chain-specific RPC env var, deploys Hub/Solver/Router/Quoter (the test is the
//  deployer = admin) and wires the SAME venue set as that chain's deploy script
//  (script/Deploy<Chain>.s.sol). Reusing the exact production wiring means the
//  fork tests exercise the real adapters — V2/V3 everywhere, plus the venues
//  that only exist off-mainnet: Algebra (Camelot, Arbitrum), Solidly (Aerodrome
//  on Base, Velodrome on Optimism) and Uniswap V4 (Base).
//
//  If a chain's RPC env var is unset its suite skips, so the offline suite stays
//  green. See ForkMetrics.t.sol / ForkL2Metrics.t.sol for the run commands.
// =============================================================================

import { Test, console2 } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../../src/BlazePhoenixRouter.sol";
import { BlazePhoenixQuoter } from "../../src/BlazePhoenixQuoter.sol";
import { Route, RoutePlan, Hop, Leg } from "../../src/BlazePhoenixCore.sol";

interface IERC20 {
    function approve(address s, uint256 a) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

abstract contract ForkMetricsBase is Test {
    // ── kind / mode constants (mirror the deploy scripts) ──
    uint8 constant KIND_V2 = 0; uint8 constant KIND_V3 = 1;
    uint8 constant KIND_SOLIDLY = 5; uint8 constant KIND_ALGEBRA = 6;
    uint8 constant MODE_CALL_GENERIC = 0; uint8 constant MODE_CALL_V3 = 1;
    uint8 constant MODE_CALL_SOLIDLY = 2; uint8 constant MODE_CALL_V3CL = 3;
    uint8 constant MODE_CREATE2_V3 = 5;
    // Cross-chain Uniswap V3 init-code hash (verified, identical on every chain).
    bytes32 constant UNIV3_INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    bool live;

    /// @dev Spin up a fork from <rpcVar>, optionally pinned by <blkVar>. Returns
    ///      false (suite should skip) when the RPC var is unset.
    function _startFork(string memory rpcVar, string memory blkVar) internal returns (bool) {
        string memory rpc = vm.envOr(rpcVar, string(""));
        if (bytes(rpc).length == 0) return false;
        uint256 blk = vm.envOr(blkVar, uint256(0));
        if (blk == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, blk);
        return true;
    }

    /// @dev Deploy the protocol with this contract as admin/treasury, exactly as
    ///      the deploy scripts' `_deploy` twin does (sans broadcast/env).
    function _deployCore(address v4Manager) internal {
        _deployCore(v4Manager, address(this), address(this));
    }

    /// @dev Deploy variant with distinct treasury addresses so the protocol fee
    ///      can be measured in isolation (used by the invariant suite).
    function _deployCore(address v4Manager, address t1, address t2) internal {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), v4Manager);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), t1, t2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
    }

    function _kind(uint8 k) internal pure returns (string memory) {
        if (k==0) return "V2"; if (k==1) return "V3"; if (k==2) return "CURVE";
        if (k==4) return "V4"; if (k==5) return "SOLIDLY"; if (k==6) return "ALGEBRA"; return "?";
    }

    /// @dev Best-effort ERC20 symbol() — never reverts. Handles both string and
    ///      bytes32 (MKR-style) symbols, returning "?" on anything unexpected.
    function _sym(address t) internal view returns (string memory) {
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeWithSignature("symbol()"));
        if (!ok || ret.length == 0) return "?";
        if (ret.length == 32) {
            // bytes32 symbol (e.g. MKR) — trim trailing zero bytes.
            bytes32 b = abi.decode(ret, (bytes32));
            uint256 n; while (n < 32 && b[n] != 0) ++n;
            bytes memory s = new bytes(n);
            for (uint256 i; i < n; ++i) s[i] = b[i];
            return string(s);
        }
        return abi.decode(ret, (string));
    }

    /// @dev Approve via low-level call so non-compliant tokens whose approve()
    ///      returns no bool (USDT, …) don't revert the harness.
    function _approve(address token, address spender, uint256 amt) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amt));
        ok; // result is irrelevant; the swap will revert later if it truly failed
    }

    /// @dev `deal` wrapped for try/catch: some tokens (LDO, SNX, …) use a storage
    ///      layout Foundry's stdStore can't locate, so deal reverts. Returns false
    ///      in that case so the caller can log and skip instead of failing.
    function __deal(address token, address to, uint256 amt) external { deal(token, to, amt); }
    function _fund(address token, uint256 amt) internal returns (bool) {
        try this.__deal(token, address(this), amt) { return true; } catch { return false; }
    }

    function _quoteGas(address tIn, address tOut, uint256 amt) internal view returns (uint256 used) {
        bytes memory cd = abi.encodeWithSelector(solver.findBestRoutePlan.selector, tIn, tOut, amt);
        uint256 g = gasleft();
        (bool ok,) = address(solver).staticcall(cd);
        used = g - gasleft();
        require(ok, "quote reverted");
    }

    function _report(string memory tag, address tIn, address tOut, uint256 amt) internal {
        // QUOTE gas, cold (first touch) then warm (storage now hot).
        uint256 qCold = _quoteGas(tIn, tOut, amt);
        uint256 qWarm = _quoteGas(tIn, tOut, amt);

        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, amt);
        Route memory r = plan.best;

        console2.log("==================================================");
        console2.log(tag);
        console2.log(string.concat("  pair            : ", _sym(tIn), " -> ", _sym(tOut)));
        console2.log("  amountIn        :", amt);

        // Exotic pairs may have no viable route on a given chain/block — log and
        // bail before deal/exec so the suite never reverts on a dry pair.
        if (r.hops.length == 0 || r.totalOut == 0) {
            console2.log("  >> NO ROUTE FOUND (skipping exec)");
            console2.log("  QUOTE gas cold  :", qCold);
            console2.log("  QUOTE gas warm  :", qWarm);
            return;
        }

        uint256 legs;
        for (uint256 h; h < r.hops.length; ++h) legs += r.hops[h].legs.length;

        console2.log("  hops            :", r.hops.length);
        console2.log("  legs            :", legs);
        console2.log("  quotedOut       :", r.totalOut);
        console2.log("  singleOutFloor  :", r.singleOutFloor);
        console2.log("  estGas (solver) :", r.estGas);
        console2.log("  QUOTE gas cold  :", qCold);
        console2.log("  QUOTE gas warm  :", qWarm);
        for (uint256 h; h < r.hops.length; ++h) {
            console2.log("  -- hop", h);
            for (uint256 l; l < r.hops[h].legs.length; ++l) {
                Leg memory L = r.hops[h].legs[l];
                console2.log(string.concat("     leg ", _kind(L.kind), " in:"), L.amountIn);
                console2.log("        out:", L.expectedOut);
            }
        }

        // EXEC gas, cold then warm: fund 2x and swap twice so the storage slots
        // touched by the first pass stay warm on the second (isolates the
        // cold/warm SLOAD gap). The cold swap moves the market, so the warm pass
        // RE-QUOTES to get a route valid against the new reserves — replaying the
        // stale `r` would trip the Router's quote-derived floor (RouterE(5)),
        // which is correct protocol protection, not a warm-gas signal. Realised
        // output is read off the cold pass.
        if (!_fund(tIn, amt * 2)) {
            console2.log("  >> DEAL-UNSUPPORTED (token storage layout; metrics quoted only)");
            return;
        }
        _approve(tIn, address(router), amt * 2);
        uint256 balB = IERC20(tOut).balanceOf(address(this));

        uint256 g = gasleft();
        try router.swapExactIn(r, amt, 0, address(this), block.timestamp + 1) returns (uint256 ret) {
            uint256 execCold = g - gasleft();
            uint256 realized = IERC20(tOut).balanceOf(address(this)) - balB;

            Route memory rWarm = solver.findBestRoutePlan(tIn, tOut, amt).best;
            uint256 execWarm;
            if (rWarm.hops.length > 0 && rWarm.totalOut > 0) {
                // The cold swap moved the market; the warm re-quote can itself
                // fall below its floor (single-tick quote divergence on the now
                // thinner book). It's only a gas probe — isolate its revert so a
                // warm floor-rejection never fails the report.
                uint256 g2 = gasleft();
                try router.swapExactIn(rWarm, amt, 0, address(this), block.timestamp + 1)
                    returns (uint256) { execWarm = g2 - gasleft(); }
                catch {}
            }

            console2.log("  EXEC gas cold   :", execCold);
            console2.log("  EXEC gas warm   :", execWarm);
            console2.log("  realized out    :", realized);
            console2.log("  router returned :", ret);
            if (r.totalOut > 0) console2.log("  realized/quote bps:", realized * 10000 / r.totalOut);
        } catch (bytes memory err) {
            // Decode WHICH guard fired: RouterE(5) is the output floor (the quote
            // was too optimistic for this pair/size — the floor doing its job);
            // RouterE(8) would include the holds-nothing bridge check, so we must
            // be able to tell them apart to know the bridge fix is not
            // false-reverting a legitimate multi-hop route.
            console2.log(string.concat("  >> EXEC REVERTED with ", _revName(err)));
        }
    }

    /// @dev Name the RouterE code carried in a revert, so the fork logs can tell
    ///      a legitimate floor rejection (5) from the holds-nothing guard (8).
    function _revName(bytes memory err) internal pure returns (string memory) {
        // RouterE(uint16): 4-byte selector + 32-byte code word.
        if (err.length < 4 + 32) return "non-RouterE revert";
        uint16 code;
        assembly { code := mload(add(err, 0x24)) }
        if (code == 5) return "RouterE(5) FLOOR (quote optimistic, correct protection)";
        if (code == 8) return "RouterE(8) HOLDS-NOTHING/exec (investigate if a real multi-hop)";
        if (code == 4) return "RouterE(4) deadline";
        if (code == 3) return "RouterE(3) bad input";
        return "RouterE(other)";
    }

    /// @dev Retail simulation with the CORRECT slippage binding. The user's
    ///      minOut comes from the EXACT quote (Quoter.previewPlanExact — every
    ///      concentrated leg dry-run on its own pool via revert-extraction),
    ///      NOT the Solver's optimistic single-tick search quote. minOut =
    ///      exactOut · (1 − slipBps). This is the difference between a swap that
    ///      floor-rejects (minOut bound to an inflated number) and one that
    ///      fills at a tight tolerance. It also prints solver/exact so the
    ///      single-tick optimism is visible per pair.
    function _reportExactRetail(
        string memory tag, address tIn, address tOut, uint256 amt, uint256 slipBps
    ) internal {
        console2.log("==================================================");
        console2.log(tag);
        console2.log(string.concat("  pair            : ", _sym(tIn), " -> ", _sym(tOut)));
        console2.log("  amountIn        :", amt);
        console2.log("  slippage bps    :", slipBps);

        RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, amt);
        if (plan.best.hops.length == 0 || plan.best.totalOut == 0) {
            console2.log("  >> NO ROUTE FOUND");
            return;
        }
        uint256 solverQuote = plan.best.totalOut;

        // EXACT quote: run the chosen route on the pools themselves.
        (Route memory exact, uint256 exactOut) = quoter.previewPlanExact(tIn, tOut, amt);
        if (exactOut == 0) {
            console2.log("  >> EXACT QUOTE UNAVAILABLE");
            return;
        }

        uint256 legs;
        for (uint256 h; h < exact.hops.length; ++h) legs += exact.hops[h].legs.length;
        console2.log("  hops            :", exact.hops.length);
        console2.log("  legs            :", legs);
        console2.log("  solver quote    :", solverQuote);
        console2.log("  EXACT quote     :", exactOut);
        // Solver search optimism, in bps of the exact number (10000 = perfect).
        console2.log("  solver/exact bps:", solverQuote * 10000 / exactOut);

        // Collapse detector: a search quote >20% above the exact quote means
        // the route cannot honestly fill this size (thin pools) — a fill at
        // the exact-bound minOut would execute a catastrophic route, so the
        // verdict below must not read as a win.
        bool collapsed = solverQuote > exactOut + exactOut / 5;
        if (collapsed) {
            console2.log("  !! SEARCH-QUOTE COLLAPSE: route too thin for this size");
        }

        uint256 minOut = exactOut * (10000 - slipBps) / 10000;
        console2.log("  minOut          :", minOut);

        if (!_fund(tIn, amt)) {
            console2.log("  >> DEAL-UNSUPPORTED (metrics quoted only)");
            return;
        }
        _approve(tIn, address(router), amt);
        uint256 balB = IERC20(tOut).balanceOf(address(this));

        uint256 g = gasleft();
        // Execute the EXACT-repriced route (its leg.expectedOut carry execution-
        // grade numbers, so the Router's per-leg floor is measured against truth).
        try router.swapExactIn(exact, amt, minOut, address(this), block.timestamp + 1)
            returns (uint256 ret)
        {
            uint256 gasUsed = g - gasleft();
            uint256 realized = IERC20(tOut).balanceOf(address(this)) - balB;
            console2.log("  EXEC gas        :", gasUsed);
            console2.log("  realized out    :", realized);
            console2.log("  router returned :", ret);
            console2.log("  realized/exact  :", realized * 10000 / exactOut);
            if (collapsed) {
                console2.log("  >> FILLED-BUT-COLLAPSED: execution matched a bad route; do NOT offer this pair at this size");
            } else {
                console2.log("  >> FILLED at exact-bound minOut");
            }
        } catch {
            console2.log("  >> REJECTED even at exact-bound minOut (genuinely too thin for this size)");
        }
    }

    /// @dev SANDWICH / price-manipulation probe. Quotes the victim, lets an
    ///      attacker move the real pools with a large same-direction swap, then
    ///      submits the victim's now-STALE route. The floor must protect: the
    ///      swap either reverts (stale quote-derived floor rejects the degraded
    ///      fill) or delivers >= the victim's minOut. A silent fill BELOW minOut
    ///      under manipulation would be a critical floor failure — asserted
    ///      against. minOut is bound to the exact quote, as a correct front-end
    ///      would set it.
    function _sandwich(
        string memory tag, address tIn, address tOut,
        uint256 victimAmt, uint256 atkAmt, uint256 slipBps
    ) internal {
        console2.log("==================================================");
        console2.log(tag);
        console2.log(string.concat("  pair            : ", _sym(tIn), " -> ", _sym(tOut)));
        console2.log("  victimAmt       :", victimAmt);
        console2.log("  attackerAmt     :", atkAmt);

        // 1) Victim's pre-attack route + exact-bound minOut.
        RoutePlan memory vp = solver.findBestRoutePlan(tIn, tOut, victimAmt);
        if (vp.best.hops.length == 0 || vp.best.totalOut == 0) {
            console2.log("  >> NO ROUTE (skip)"); return;
        }
        Route memory vroute = vp.best;
        uint256 quotedOut = vroute.totalOut;
        (, uint256 exactOut) = quoter.previewPlanExact(tIn, tOut, victimAmt);
        if (exactOut == 0) { console2.log("  >> NO EXACT QUOTE (skip)"); return; }
        uint256 minOut = exactOut * (10000 - slipBps) / 10000;
        console2.log("  victim quotedOut:", quotedOut);
        console2.log("  victim minOut   :", minOut);

        // 2) Attacker front-runs: a large same-direction swap moves the pools.
        if (_fund(tIn, atkAmt)) {
            _approve(tIn, address(router), atkAmt);
            RoutePlan memory ap = solver.findBestRoutePlan(tIn, tOut, atkAmt);
            if (ap.best.hops.length > 0) {
                try router.swapExactIn(ap.best, atkAmt, 0, address(this), block.timestamp + 1)
                    returns (uint256) { console2.log("  attacker moved the market"); }
                catch { console2.log("  attacker swap reverted (pools resisted)"); }
            }
        } else { console2.log("  attacker deal-unsupported; victim faces original book"); }

        // 3) Victim submits the STALE route against the moved book.
        if (!_fund(tIn, victimAmt)) { console2.log("  >> victim DEAL-UNSUPPORTED (skip)"); return; }
        _approve(tIn, address(router), victimAmt);
        uint256 balB = IERC20(tOut).balanceOf(address(this));
        try router.swapExactIn(vroute, victimAmt, minOut, address(this), block.timestamp + 1)
            returns (uint256)
        {
            uint256 got = IERC20(tOut).balanceOf(address(this)) - balB;
            console2.log("  victim realized :", got);
            console2.log("  realized/quote  :", quotedOut == 0 ? 0 : got * 10000 / quotedOut);
            // THE load-bearing assertion: the Router can never deliver below the
            // victim's minOut, even with the book manipulated against them.
            assertGe(got, minOut, "SANDWICH: delivered BELOW minOut under manipulation");
            console2.log("  >> PROTECTED (filled >= minOut despite manipulation)");
        } catch {
            console2.log("  >> PROTECTED (stale route floor-rejected under manipulation)");
        }
    }

    /// @dev RATE SWEEP diagnostic. For a pair, quotes at rising sizes and prints
    ///      the decimal-normalised rate in BPS of parity (10000 == 1:1). Both the
    ///      Solver search quote and the EXACT quote (previewPlanExact) are shown.
    ///      Separates a genuine depth limit (rate ~10000 small, degrades with
    ///      size) from a pricing bug (rate already broken at tiny size). Sizes
    ///      are in whole tokenIn units; the helper reads both tokens' decimals.
    function _rateSweep(
        string memory tag, address tIn, address tOut, uint256[5] memory whole
    ) internal {
        console2.log("==================================================");
        console2.log(tag);
        console2.log(string.concat("  pair            : ", _sym(tIn), " -> ", _sym(tOut)));
        uint8 dIn  = IERC20(tIn).decimals();
        uint8 dOut = IERC20(tOut).decimals();
        for (uint256 i; i < whole.length; ) {
            uint256 amt = whole[i] * (10 ** dIn);
            console2.log("  -- size (whole) :", whole[i]);
            RoutePlan memory p = solver.findBestRoutePlan(tIn, tOut, amt);
            if (p.best.hops.length == 0 || p.best.totalOut == 0) {
                console2.log("     NO ROUTE"); unchecked { ++i; } continue;
            }
            uint256 sQ = p.best.totalOut;
            // parity BPS: out*10^dIn*10000 / (amt*10^dOut); 10000 == 1:1. Sizes
            // are bounded (<= 500k whole units), so the products stay well
            // inside uint256.
            uint256 denom = amt * (10 ** dOut);
            uint256 sBps = (sQ * 10000 * (10 ** dIn)) / denom;
            console2.log("     solver out   :", sQ);
            console2.log("     solver rate  :", sBps);   // 10000 = parity
            (, uint256 xQ) = quoter.previewPlanExact(tIn, tOut, amt);
            if (xQ > 0) {
                uint256 xBps = (xQ * 10000 * (10 ** dIn)) / denom;
                console2.log("     EXACT out    :", xQ);
                console2.log("     EXACT rate   :", xBps);
            }
            unchecked { ++i; }
        }
    }

    /// @dev FULL MEASUREMENT: hops, legs, gas, price impact (bps AND USDC),
    ///      slippage vs quote, realised — one report per swap. Impact is read
    ///      purely on-chain: a tiny probe gives the spot rate, the real size
    ///      gives the effective rate, impact = 1 - eff/spot. USD value is a
    ///      quote to USDC (approximate for large sizes, but scaled honestly).
    function _measureUsd(
        string memory tag, address tIn, address tOut, uint256 amt, address usdc
    ) internal {
        console2.log("==================================================");
        console2.log(tag);
        console2.log(string.concat("  pair       : ", _sym(tIn), " -> ", _sym(tOut)));
        console2.log("  amountIn   :", amt);

        // Spot rate from a tiny probe (marginal price, negligible impact).
        uint256 probe = amt / 10000; if (probe == 0) probe = amt;
        uint256 spotOut;
        {
            RoutePlan memory sp = solver.findBestRoutePlan(tIn, tOut, probe);
            if (sp.best.hops.length > 0) spotOut = sp.best.totalOut;
        }

        RoutePlan memory p = solver.findBestRoutePlan(tIn, tOut, amt);
        if (p.best.hops.length == 0 || p.best.totalOut == 0) { console2.log("  >> NO ROUTE"); return; }
        Route memory r = p.best;
        uint256 legs; for (uint256 h; h < r.hops.length; ++h) legs += r.hops[h].legs.length;
        console2.log("  hops       :", r.hops.length);
        console2.log("  legs       :", legs);
        console2.log("  quotedOut  :", r.totalOut);

        (, uint256 exactOut) = quoter.previewPlanExact(tIn, tOut, amt);
        console2.log("  exactOut   :", exactOut);

        // Price impact vs spot (probe) rate, in BPS. 0 = no impact.
        if (spotOut > 0 && exactOut > 0) {
            uint256 num = exactOut * probe;   // effective (real) direction
            uint256 den = amt * spotOut;      // spot (probe) direction
            uint256 impBps = num >= den ? 0 : 10000 - (num * 10000) / den;
            console2.log("  IMPACT bps :", impBps);
        }

        console2.log("  quoteGas   :", _quoteGas(tIn, tOut, amt));

        uint256 realized;
        if (_fund(tIn, amt)) {
            _approve(tIn, address(router), amt);
            uint256 balB = IERC20(tOut).balanceOf(address(this));
            uint256 g = gasleft();
            try router.swapExactIn(r, amt, 0, address(this), block.timestamp + 1) returns (uint256) {
                console2.log("  execGas    :", g - gasleft());
                realized = IERC20(tOut).balanceOf(address(this)) - balB;
                console2.log("  realized   :", realized);
                if (r.totalOut > 0)
                    console2.log("  slip vs Q  :",
                        realized >= r.totalOut ? 0 : (r.totalOut - realized) * 10000 / r.totalOut);
            } catch { console2.log("  >> FLOOR-REJECTED (realised < floor)"); }
        } else { console2.log("  >> DEAL-UNSUPPORTED (quoted only)"); }

        // USD terms via a quote to USDC (input side, and realised or exact out).
        uint256 usdIn  = _usdcValue(tIn, amt, usdc);
        uint256 usdOut = _usdcValue(tOut, realized > 0 ? realized : exactOut, usdc);
        console2.log("  USD in  (6dec):", usdIn);
        console2.log("  USD out (6dec):", usdOut);
        if (usdIn > 0 && usdOut > 0)
            console2.log("  USD impact    :", usdIn > usdOut ? usdIn - usdOut : 0);
    }

    /// @dev USDC value of `amt` of `token` (itself if token == usdc, else the
    ///      EXACT token->USDC quote). Uses previewPlanExact, not the Solver's
    ///      optimistic single-tick search quote, so the USD figure does not
    ///      inflate on thin pools (a search quote valued 36k DAI at 150k USDC —
    ///      fantasy; the exact quote reports what the pools would truly pay).
    ///      Returns 0 when no route exists.
    function _usdcValue(address token, uint256 amt, address usdc) internal returns (uint256) {
        if (token == usdc) return amt;
        if (amt == 0) return 0;
        (, uint256 x) = quoter.previewPlanExact(token, usdc, amt);
        return x;
    }

    /// @dev BATCH / PORTFOLIO stress: buy `usdEach` (USDC, 6-dec) of every token
    ///      in `tokens`, one real swap per token, back-to-back on the SAME fork
    ///      state. Two things are proven at once:
    ///        1. ROBUSTNESS — after EVERY swap the Router must hold 0 of both the
    ///           input (USDC) and the token just bought (hard require, the same
    ///           holds-nothing invariant the adversarial suites assert offline,
    ///           now under a long run of real heterogeneous Base liquidity).
    ///        2. PROFILE — per-token hops/legs, price impact (bps), exec gas, and
    ///           the round-trip USD value, plus a portfolio aggregate.
    ///      Buy-side (USDC->token) so every entry funds from a single asset; the
    ///      USD-out is a sell-back quote (token->USDC via previewPlanExact), so the
    ///      per-token impact is a CONSERVATIVE round-trip (buy depth + sell depth).
    ///      Each token's on-chain symbol() is printed and NO-ROUTE / code-less
    ///      addresses are flagged, so the basket is self-auditing on the fork.
    /// @dev One basket row. status: 0 skip(dead/self), 1 no-route, 2 rejected, 3 ok.
    ///      `spent` is the USDC actually consumed — the Router sweeps unrouted
    ///      input back (capacity-cut partial fills), so impact must be judged
    ///      against what was spent, not what was offered.
    struct BRow { uint8 status; uint256 hops; uint256 legs; uint256 quoteGas; uint256 execGas; uint256 usdOut; uint256 impBps; uint256 spent; }
    /// @dev Portfolio aggregate (one memory word, keeps the loop off the stack).
    struct BAgg { uint256 routed; uint256 noRoute; uint256 rejected; uint256 skipped; uint256 quoteGas; uint256 execGas; uint256 usdIn; uint256 usdOut; }

    /// @dev Buy `usdEach` of one token, measure it, and enforce holds-nothing.
    ///      Isolated in its own frame so the basket loop stays off the stack
    ///      (via-IR stack-too-deep otherwise). See _basket for the doctrine.
    function _basketOne(address tok, address usdc, uint256 usdEach) internal returns (BRow memory row) {
        if (tok == usdc || tok.code.length == 0) { row.status = 0; return row; }

        RoutePlan memory p = solver.findBestRoutePlan(usdc, tok, usdEach);
        if (p.best.hops.length == 0 || p.best.totalOut == 0) { row.status = 1; return row; }

        Route memory r = p.best;
        row.hops = r.hops.length;
        for (uint256 h; h < r.hops.length; ++h) row.legs += r.hops[h].legs.length;
        row.quoteGas = _quoteGas(usdc, tok, usdEach);
        (, uint256 exactOut) = quoter.previewPlanExact(usdc, tok, usdEach);

        uint256 realized;
        row.status = 2; // rejected unless the swap lands
        if (_fund(usdc, usdEach)) {
            _approve(usdc, address(router), usdEach);
            uint256 balB = IERC20(tok).balanceOf(address(this));
            uint256 balU = IERC20(usdc).balanceOf(address(this));
            uint256 g = gasleft();
            try router.swapExactIn(r, usdEach, 0, address(this), block.timestamp + 1) returns (uint256) {
                row.execGas = g - gasleft();
                realized  = IERC20(tok).balanceOf(address(this)) - balB;
                row.spent = balU - IERC20(usdc).balanceOf(address(this));
                row.status = 3;
            } catch {}
        }

        // ── HOLDS-NOTHING after every swap: the batch conservation invariant ──
        require(IERC20(usdc).balanceOf(address(router)) == 0, "basket: Router holds USDC");
        require(IERC20(tok).balanceOf(address(router))  == 0, "basket: Router holds token");

        row.usdOut = _usdcValue(tok, realized > 0 ? realized : exactOut, usdc);
        // Impact vs USDC actually SPENT — a capacity-cut partial fill refunds
        // the unrouted input, which is not a loss.
        uint256 basis = row.spent > 0 ? row.spent : usdEach;
        row.impBps = row.usdOut >= basis ? 0 : (basis - row.usdOut) * 10000 / basis;
    }

    function _basket(string memory tag, address[] memory tokens, address usdc, uint256 usdEach)
        internal
    {
        console2.log("==================================================");
        console2.log(tag);
        console2.log("  tokens        :", tokens.length);
        console2.log("  USDC each (6d):", usdEach);
        console2.log("  --------------------------------");

        BAgg memory a;
        for (uint256 i; i < tokens.length; ++i) {
            BRow memory row = _basketOne(tokens[i], usdc, usdEach);
            string memory sym = _sym(tokens[i]);
            a.quoteGas += row.quoteGas;

            if (row.status == 0) { ++a.skipped; console2.log(string.concat("  [skip] ", sym)); continue; }
            if (row.status == 1) { ++a.noRoute; console2.log(string.concat("  [----] ", sym, "  NO ROUTE")); continue; }
            if (row.status == 3) { ++a.routed; a.execGas += row.execGas; a.usdIn += row.spent; a.usdOut += row.usdOut; }
            else { ++a.rejected; }

            console2.log(string.concat(row.status == 3 ? "  [ok  ] " : "  [rej ] ", sym));
            console2.log("        hops / legs      :", row.hops, row.legs);
            console2.log("        impact bps       :", row.impBps);
            console2.log("        execGas / usdOut :", row.execGas, row.usdOut);
            if (row.status == 3 && row.spent < usdEach)
                console2.log("        PARTIAL: spent / refunded :", row.spent, usdEach - row.spent);
        }

        console2.log("  --------------------------------");
        console2.log("  routed           :", a.routed);
        console2.log("  no-route         :", a.noRoute);
        console2.log("  floor-rejected   :", a.rejected);
        console2.log("  skipped (dead)   :", a.skipped);
        console2.log("  total quoteGas   :", a.quoteGas);
        console2.log("  total execGas    :", a.execGas);
        console2.log("  total USD in     :", a.usdIn);
        console2.log("  total USD out    :", a.usdOut);
        if (a.usdIn > a.usdOut)
            console2.log("  aggregate impact (6dec USDC):", a.usdIn - a.usdOut);
    }

    /// @dev GAS DISSECTION: print every leg of the best route for (tIn->tOut,
    ///      amt) — pool / kind / fee / spacing / split — then execute EACH LEG
    ///      IN ISOLATION (single-leg route, that leg's own amountIn) on a state
    ///      snapshot, attributing exec gas per leg. Finds which pool burns the
    ///      gas when a route's total is anomalous (e.g. a V3 stable pool whose
    ///      liquidity ladder forces hundreds of tick crossings). Snapshot-revert
    ///      between legs so each is measured against identical pool state.
    function _dissect(string memory tag, address tIn, address tOut, uint256 amt) internal {
        console2.log("==================================================");
        console2.log(tag);
        RoutePlan memory p = solver.findBestRoutePlan(tIn, tOut, amt);
        if (p.best.hops.length == 0) { console2.log("  >> NO ROUTE"); return; }
        Route memory r = p.best;

        for (uint256 h; h < r.hops.length; ++h) {
            console2.log("  hop", h);
            console2.log(string.concat("    ", _sym(r.hops[h].tokenIn), " -> ", _sym(r.hops[h].tokenOut)));
            for (uint256 l; l < r.hops[h].legs.length; ++l) {
                _dissectLeg(r.hops[h], l);
            }
        }

        // Full-route exec on the SAME snapshot base, for the total to compare.
        uint256 snap = vm.snapshotState();
        if (_fund(tIn, amt)) {
            _approve(tIn, address(router), amt);
            uint256 g = gasleft();
            try router.swapExactIn(r, amt, 0, address(this), block.timestamp + 1) returns (uint256) {
                console2.log("  FULL ROUTE execGas :", g - gasleft());
            } catch { console2.log("  FULL ROUTE >> reverted"); }
        }
        vm.revertToState(snap);
    }

    /// @dev Print + isolated-exec one leg of `hp`. Own frame to keep _dissect's
    ///      stack shallow (via-IR). Snapshot-reverts around the exec.
    function _dissectLeg(Hop memory hp, uint256 l) internal {
        Leg memory lg = hp.legs[l];
        console2.log("    leg", l);
        console2.log("      pool           :", lg.pool);
        console2.log("      kind / fee     :", lg.kind, lg.fee);
        console2.log("      tickSpacing    :", int256(lg.tickSpacing));
        console2.log("      stable         :", lg.stable);
        console2.log("      amountIn       :", lg.amountIn);
        console2.log("      expectedOut    :", lg.expectedOut);

        uint256 snap = vm.snapshotState();
        if (_fund(hp.tokenIn, lg.amountIn)) {
            _approve(hp.tokenIn, address(router), lg.amountIn);
            Route memory one = _oneLegRoute(hp, lg);
            uint256 balB = IERC20(hp.tokenOut).balanceOf(address(this));
            uint256 g = gasleft();
            try router.swapExactIn(one, lg.amountIn, 0, address(this), block.timestamp + 1) returns (uint256) {
                console2.log("      ISOLATED gas   :", g - gasleft());
                console2.log("      ISOLATED out   :", IERC20(hp.tokenOut).balanceOf(address(this)) - balB);
            } catch { console2.log("      ISOLATED       : >> reverted"); }
        } else { console2.log("      ISOLATED       : >> deal-unsupported"); }
        vm.revertToState(snap);
    }

    /// @dev Wrap a single leg as its own 1-hop Route (expectedOut = 0 so the
    ///      floor doesn't reject the isolated run; we measure, not protect).
    function _oneLegRoute(Hop memory hp, Leg memory lg) internal pure returns (Route memory one) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = lg;
        legs[0].expectedOut = 0;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: hp.tokenIn, tokenOut: hp.tokenOut,
                        amountIn: lg.amountIn, expectedOut: 0, legs: legs });
        one.hops = hops;
    }

    /// @dev Execute one swap to tick the Hub registry (recordSwap registers the
    ///      venues used), so a later quote can hit the freshness-gated discovery
    ///      short-circuit. Tolerates floor rejects / deal-unsupported tokens.
    function _warmupSwap(address tIn, address tOut, uint256 amt) internal {
        RoutePlan memory p = solver.findBestRoutePlan(tIn, tOut, amt);
        if (p.best.hops.length == 0) return;
        if (!_fund(tIn, amt)) return;
        _approve(tIn, address(router), amt);
        try router.swapExactIn(p.best, amt, 0, address(this), block.timestamp + 1) {} catch {}
    }

    /// @dev Quote gas with an EMPTY registry (full discovery) vs after a swap
    ///      registered the venues (freshness-gated discovery skip). Same pair, so
    ///      the delta is the discovery work saved. assertLe is safe — skipping can
    ///      never cost more than discovering.
    function _reportDiscoverySkip(string memory tag, address tIn, address tOut, uint256 amt) internal {
        uint256 qEmpty = _quoteGas(tIn, tOut, amt);   // empty registry → discovers
        _warmupSwap(tIn, tOut, amt);                  // recordSwap registers venues
        uint256 qFresh = _quoteGas(tIn, tOut, amt);   // fresh registry → skips discovery
        console2.log("==================================================");
        console2.log(tag);
        console2.log("  empty registry (discovers):", qEmpty);
        console2.log("  fresh registry (skips)    :", qFresh);
        if (qEmpty > qFresh) console2.log("  saved                     :", qEmpty - qFresh);
        assertLe(qFresh, qEmpty, "fresh registry must not cost more than full discovery");
    }

    /// @dev Size sweep for a single pair: prints legs / quote-gas / exec-gas /
    ///      realised out across `sizes`.
    function _sweep(string memory tag, address tIn, address tOut, uint256[5] memory sizes) internal {
        console2.log("==================================================");
        console2.log(tag);
        for (uint256 i; i < sizes.length; ++i) {
            uint256 amt = sizes[i];
            uint256 qg = _quoteGas(tIn, tOut, amt);
            RoutePlan memory plan = solver.findBestRoutePlan(tIn, tOut, amt);
            Route memory r = plan.best;
            uint256 legs; for (uint256 h; h < r.hops.length; ++h) legs += r.hops[h].legs.length;
            if (!_fund(tIn, amt)) {
                console2.log("  size:", amt);
                console2.log("     >> DEAL-UNSUPPORTED (token storage layout)");
                continue;
            }
            _approve(tIn, address(router), amt);
            uint256 balB = IERC20(tOut).balanceOf(address(this));
            uint256 g = gasleft();
            try router.swapExactIn(r, amt, 0, address(this), block.timestamp + 1) returns (uint256) {
                uint256 eg = g - gasleft();
                uint256 outv = IERC20(tOut).balanceOf(address(this)) - balB;
                console2.log("  size:", amt);
                console2.log("     legs:", legs); console2.log("     quoteGas:", qg);
                console2.log("     execGas:", eg); console2.log("     out:", outv);
            } catch {
                console2.log("  size:", amt);
                console2.log("     legs:", legs); console2.log("     quoteGas:", qg);
                console2.log("     >> FLOOR-REJECTED (realised < protocol floor)");
            }
        }
    }
}
