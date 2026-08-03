// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  Reference copy of BlazePhoenixSolver as it existed BEFORE the gas
//  optimisation (three redundant probe quotes in _buildHop). Used only by the
//  differential-equivalence fuzz test to prove the optimisation is observably
//  identical. NOT part of the protocol build.
// =============================================================================
pragma solidity 0.8.28;

import {
    BlazePhoenixCore as BPC,
    PoolInfo, Route, Hop, Leg, RoutePlan, QuoteCtx
} from "../../src/BlazePhoenixCore.sol";

interface IHubROld {
    function getActivePools(address tA, address tB) external view returns (PoolInfo[] memory);
    function discoverFor(address tA, address tB) external view returns (PoolInfo[] memory);
    function getPsi(bytes32 key) external view returns (uint256);
    function getSlot(bytes32 key) external view returns (uint256);
    function keyOf(address pool, address tA, address tB) external pure returns (bytes32);
    function bridge(uint8 i) external view returns (address);
    function bridgeCount() external view returns (uint8);
    function isBridgeToken(address t) external view returns (bool);
    function v4PoolManager() external view returns (address);
    function v4EntryCount() external view returns (uint256);
}

contract BlazePhoenixSolverOld {
    uint8   internal constant MAX_LEGS             = 5;
    uint8   internal constant MAX_LEGS_PER_STAGE   = 3;
    uint8   internal constant MAX_CANDIDATES       = 5;
    uint16  internal constant LEG_SAFETY_BPS       = 5;
    uint16  internal constant MEDIAN_FILTER_BPS    = 200;
    uint16  internal constant MAX_LOSS_BPS         = 2_500;

    error SolverE(uint16 code);
    IHubROld public immutable hub;

    constructor(address hub_) { hub = IHubROld(hub_); }

    function findBestRoutePlan(address tIn, address tOut, uint256 amountIn)
        external view returns (RoutePlan memory plan)
    {
        if (tIn == address(0) || tOut == address(0) || tIn == tOut || amountIn == 0)
            revert SolverE(4);
        Route memory direct = _planDirect(tIn, tOut, amountIn);
        Route memory viaB1;
        Route memory viaB2;
        uint8 bc = hub.bridgeCount();
        if (bc > 0) {
            address b0 = hub.bridge(0);
            if (b0 != address(0) && b0 != tIn && b0 != tOut) viaB1 = _planViaBridge(tIn, tOut, amountIn, b0);
        }
        if (bc > 1) {
            address b1 = hub.bridge(1);
            if (b1 != address(0) && b1 != tIn && b1 != tOut) viaB2 = _planViaBridge(tIn, tOut, amountIn, b1);
        }
        Route memory best; Route memory second; uint256 bestU; uint256 secondU;
        (bestU, secondU, best, second) = _rank(direct, viaB1, viaB2);
        if (bestU == 0) revert SolverE(5);
        plan.best = best; plan.fallbackRoute = second; plan.hasFallback = (secondU > 0);
    }

    function _rank(Route memory a, Route memory b, Route memory c)
        private pure returns (uint256 bestU, uint256 secU, Route memory bestR, Route memory secR)
    {
        if (a.totalOut > 0) { bestU = a.totalOut; bestR = a; }
        if (b.totalOut > bestU) { secU = bestU; secR = bestR; bestU = b.totalOut; bestR = b; }
        else if (b.totalOut > secU) { secU = b.totalOut; secR = b; }
        if (c.totalOut > bestU) { secU = bestU; secR = bestR; bestU = c.totalOut; bestR = c; }
        else if (c.totalOut > secU) { secU = c.totalOut; secR = c; }
    }

    function _planDirect(address tIn, address tOut, uint256 amountIn)
        private view returns (Route memory route)
    {
        PoolInfo[] memory cands = _topKPools(tIn, tOut, MAX_CANDIDATES);
        if (cands.length == 0) return route;
        Hop memory hop = _buildHop(tIn, tOut, amountIn, cands, MAX_LEGS);
        if (hop.expectedOut == 0) return route;
        return _assembleRoute(hop);
    }

    function _planViaBridge(address tIn, address tOut, uint256 amountIn, address bridge_)
        private view returns (Route memory route)
    {
        PoolInfo[] memory candsA = _topKPools(tIn, bridge_, MAX_LEGS_PER_STAGE);
        if (candsA.length == 0) return route;
        Hop memory hopA = _buildHop(tIn, bridge_, amountIn, candsA, MAX_LEGS_PER_STAGE);
        if (hopA.expectedOut == 0 || hopA.legs.length == 0) return route;
        uint256 legsA = hopA.legs.length;
        if (legsA >= MAX_LEGS) return route;
        uint8 budgetB = uint8(MAX_LEGS - legsA);
        if (budgetB == 0) return route;
        PoolInfo[] memory candsB = _topKPools(bridge_, tOut, budgetB);
        if (candsB.length == 0) return route;
        Hop memory hopB = _buildHop(bridge_, tOut, hopA.expectedOut, candsB, budgetB);
        if (hopB.expectedOut == 0 || hopB.legs.length == 0) return route;
        uint256 totalLegs = hopA.legs.length + hopB.legs.length;
        if (totalLegs > MAX_LEGS) return route;
        Hop[] memory hops = new Hop[](2);
        hops[0] = hopA; hops[1] = hopB;
        return _assembleRouteMulti(hops, tIn, tOut, amountIn, hopB.expectedOut);
    }

    // ─── ORIGINAL three-pass _buildHop (verbatim) ───
    function _buildHop(
        address tIn, address tOut, uint256 amountIn,
        PoolInfo[] memory cands, uint8 budget
    ) private view returns (Hop memory hop) {
        uint256 n = cands.length;
        if (n == 0) return hop;
        if (n > budget) {
            PoolInfo[] memory t = new PoolInfo[](budget);
            for (uint256 i; i < budget; ) { t[i] = cands[i]; unchecked { ++i; } }
            cands = t; n = budget;
        }
        if (n == 1) return _singleLeg(tIn, tOut, amountIn, cands[0]);

        uint256 probe = amountIn / 100;
        if (probe == 0) probe = amountIn;

        uint256[] memory rates = new uint256[](n);
        uint256 nValid;
        uint256 anchorRate;
        uint256 maxBal;
        for (uint256 i; i < n; ) {
            uint256 o = _quote(cands[i], tIn, probe);
            if (o > 0) {
                uint256 r = BPC.mulDiv(o, 1e18, probe);
                rates[i] = r;
                unchecked { ++nValid; }
                uint256 b = BPC.balanceOf(tOut, cands[i].pool);
                if (b > maxBal) { maxBal = b; anchorRate = r; }
            }
            unchecked { ++i; }
        }
        if (nValid == 0) return hop;

        for (uint256 i = 1; i < n; ) {
            uint256 key = rates[i];
            uint256 j = i;
            while (j > 0 && rates[j - 1] > key) { rates[j] = rates[j - 1]; unchecked { --j; } }
            rates[j] = key;
            unchecked { ++i; }
        }
        uint256 firstNonZero = n - nValid;
        uint256 medianIdx = firstNonZero + (nValid / 2);
        if (medianIdx >= n) medianIdx = n - 1;
        uint256 median = rates[medianIdx];
        if (median == 0) return hop;

        uint256 base = maxBal > 0 ? anchorRate : median;
        uint256 hi = BPC.mulDiv(base, BPC.BPS + MEDIAN_FILTER_BPS, BPC.BPS);
        uint256 lo = BPC.mulDiv(base, BPC.BPS - MEDIAN_FILTER_BPS, BPC.BPS);

        PoolInfo[] memory kept = new PoolInfo[](n);
        uint256 nKept;
        for (uint256 i; i < n; ) {
            uint256 o = _quote(cands[i], tIn, probe);
            if (o > 0) {
                uint256 r = BPC.mulDiv(o, 1e18, probe);
                if (r >= lo && r <= hi) { kept[nKept] = cands[i]; unchecked { ++nKept; } }
            }
            unchecked { ++i; }
        }
        if (nKept == 0) return hop;
        if (nKept == 1) return _singleLeg(tIn, tOut, amountIn, kept[0]);

        PoolInfo[] memory final_ = new PoolInfo[](nKept);
        for (uint256 i; i < nKept; ) { final_[i] = kept[i]; unchecked { ++i; } }
        cands = final_;
        n = nKept;

        uint256[] memory psis = new uint256[](n);
        uint256 sumPsi;
        uint256[] memory rawDepth = new uint256[](n);
        uint256[] memory maxByKind = new uint256[](256);
        for (uint256 i; i < n; ) {
            ( , uint256 d) = _quoteWithDepth(cands[i], tIn, probe);
            if (d == 0) d = 1;
            rawDepth[i] = d;
            if (d > maxByKind[cands[i].kind]) maxByKind[cands[i].kind] = d;
            unchecked { ++i; }
        }
        for (uint256 i; i < n; ) {
            uint256 mx = maxByKind[cands[i].kind];
            uint256 w = mx == 0 ? 1 : BPC.mulDiv(rawDepth[i], 10000, mx);
            if (w == 0) w = 1;
            psis[i] = w;
            sumPsi += w;
            unchecked { ++i; }
        }
        Leg[] memory tmpLegs = new Leg[](n);
        uint256 legCount;
        uint256 totalOut;
        uint256 allocated;
        for (uint256 i; i < n; ) {
            uint256 share;
            if (i == n - 1) {
                share = allocated >= amountIn ? 0 : amountIn - allocated;
            } else {
                share = BPC.mulDiv(amountIn, psis[i], sumPsi);
            }
            allocated += share;
            if (share == 0) { unchecked { ++i; } continue; }
            uint256 outL = _quote(cands[i], tIn, share);
            if (outL == 0) { unchecked { ++i; } continue; }
            tmpLegs[legCount] = Leg({
                pool: cands[i].pool, hooks: cands[i].hooks, kind: cands[i].kind,
                fee: cands[i].fee, tickSpacing: cands[i].tickSpacing,
                zeroForOne: cands[i].token0 == tIn, stable: cands[i].stable,
                amountIn: share, expectedOut: outL,
                auxId: (cands[i].kind == BPC.KIND_STABLE || cands[i].kind == BPC.KIND_CURVE_CRYPTO || cands[i].kind == BPC.KIND_V4)
                    ? bytes32(uint256(uint160(cands[i].token0 == tIn ? cands[i].token1 : cands[i].token0)))
                    : bytes32(0)
            });
            totalOut += outL;
            unchecked { ++legCount; ++i; }
        }
        if (legCount == 0) return hop;

        Leg[] memory legs = new Leg[](legCount);
        for (uint256 i; i < legCount; ) { legs[i] = tmpLegs[i]; unchecked { ++i; } }

        if (legCount >= 3) {
            uint256 shave = legCount * LEG_SAFETY_BPS;
            if (shave > BPC.BPS) shave = BPC.BPS;
            totalOut = 0;
            for (uint256 i; i < legCount; ) {
                legs[i].expectedOut = BPC.mulDiv(legs[i].expectedOut, BPC.BPS - shave, BPC.BPS);
                totalOut += legs[i].expectedOut;
                unchecked { ++i; }
            }
        }
        hop = Hop({ tokenIn: tIn, tokenOut: tOut, amountIn: amountIn, expectedOut: totalOut, legs: legs });
    }

    function _singleLeg(address tIn, address tOut, uint256 amountIn, PoolInfo memory cand)
        private view returns (Hop memory hop)
    {
        uint256 out_ = _quote(cand, tIn, amountIn);
        if (out_ == 0) return hop;
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: cand.pool, hooks: cand.hooks, kind: cand.kind,
            fee: cand.fee, tickSpacing: cand.tickSpacing,
            zeroForOne: cand.token0 == tIn, stable: cand.stable,
            amountIn: amountIn, expectedOut: out_,
            auxId: (cand.kind == BPC.KIND_STABLE || cand.kind == BPC.KIND_CURVE_CRYPTO || cand.kind == BPC.KIND_V4)
                ? bytes32(uint256(uint160(cand.token0 == tIn ? cand.token1 : cand.token0)))
                : bytes32(0)
        });
        hop = Hop({ tokenIn: tIn, tokenOut: tOut, amountIn: amountIn, expectedOut: out_, legs: legs });
    }

    function _quoteWithDepth(PoolInfo memory cand, address tIn, uint256 amt)
        private view returns (uint256 out, uint256 depth)
    {
        QuoteCtx memory c = QuoteCtx({
            kind: cand.kind, pool: cand.pool, zeroForOne: cand.token0 == tIn,
            fee: cand.fee, tickSpacing: cand.tickSpacing, stable: cand.stable,
            tokenIn: tIn, tokenOther: cand.token0 == tIn ? cand.token1 : cand.token0,
            hooks: cand.hooks, v4Manager: cand.kind == BPC.KIND_V4 ? hub.v4PoolManager() : address(0)
        });
        (out, depth) = BPC.universalQuote(c, amt);
    }

    function _quote(PoolInfo memory cand, address tIn, uint256 amt) private view returns (uint256) {
        QuoteCtx memory c = QuoteCtx({
            kind: cand.kind, pool: cand.pool, zeroForOne: cand.token0 == tIn,
            fee: cand.fee, tickSpacing: cand.tickSpacing, stable: cand.stable,
            tokenIn: tIn, tokenOther: cand.token0 == tIn ? cand.token1 : cand.token0,
            hooks: cand.hooks, v4Manager: cand.kind == BPC.KIND_V4 ? hub.v4PoolManager() : address(0)
        });
        (uint256 out, ) = BPC.universalQuote(c, amt);
        return out;
    }

    function _topKPools(address tA, address tB, uint8 keep)
        private view returns (PoolInfo[] memory out)
    {
        PoolInfo[] memory reg = hub.getActivePools(tA, tB);
        PoolInfo[] memory dis = hub.discoverFor(tA, tB);
        uint256 rn = reg.length; uint256 dn = dis.length;
        PoolInfo[] memory merged = new PoolInfo[](rn + dn);
        uint256 n;
        for (uint256 i; i < rn; ) { merged[n] = reg[i]; unchecked { ++n; ++i; } }
        for (uint256 i; i < dn; ) {
            bool dup;
            for (uint256 j; j < rn; ) { if (dis[i].pool == reg[j].pool) { dup = true; break; } unchecked { ++j; } }
            if (!dup) { merged[n] = dis[i]; unchecked { ++n; } }
            unchecked { ++i; }
        }
        if (n == 0) return new PoolInfo[](0);
        PoolInfo[] memory active = new PoolInfo[](n);
        for (uint256 i; i < n; ) { active[i] = merged[i]; unchecked { ++i; } }
        uint256[] memory ps = new uint256[](n);
        for (uint256 i; i < n; ) {
            bytes32 key = hub.keyOf(active[i].pool, active[i].token0, active[i].token1);
            uint256 p = hub.getPsi(key);
            ps[i] = p == 0 ? 1 : p;
            unchecked { ++i; }
        }
        uint256 k = n < keep ? n : keep;
        out = new PoolInfo[](k);
        for (uint256 ki; ki < k; ) {
            uint256 bestI = ki;
            for (uint256 j = ki + 1; j < n; ) { if (ps[j] > ps[bestI]) bestI = j; unchecked { ++j; } }
            if (bestI != ki) {
                (active[ki], active[bestI]) = (active[bestI], active[ki]);
                (ps[ki], ps[bestI]) = (ps[bestI], ps[ki]);
            }
            out[ki] = active[ki];
            unchecked { ++ki; }
        }
    }

    function _assembleRoute(Hop memory hop) private view returns (Route memory route) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = hop;
        uint256 legs = hop.legs.length;
        uint256 totalImpactBps;
        for (uint256 i; i < legs; ) {
            uint256 d;
            if (hop.legs[i].kind == BPC.KIND_V2 || hop.legs[i].kind == BPC.KIND_SOLIDLY || hop.legs[i].kind == BPC.KIND_BALANCER_V2) {
                (uint256 r0, uint256 r1) = BPC.getReserves(hop.legs[i].pool);
                uint256 rIn = hop.legs[i].zeroForOne ? r0 : r1;
                d = BPC.impactV2Bps(hop.legs[i].amountIn, rIn);
            } else if (hop.legs[i].kind == BPC.KIND_V3 || hop.legs[i].kind == BPC.KIND_ALGEBRA) {
                uint128 liq = BPC.getLiquidity(hop.legs[i].pool);
                uint160 sp = BPC.getSqrtPriceX96(hop.legs[i].pool);
                d = BPC.impactV3Bps(hop.legs[i].amountIn, sp, liq, uint24(hop.legs[i].fee), hop.legs[i].zeroForOne);
            } else { d = 50; }
            totalImpactBps += d;
            unchecked { ++i; }
        }
        if (legs > 0) totalImpactBps = totalImpactBps / legs;
        uint256 floorBps = BPC.ironFloorBps(totalImpactBps, legs, 0);
        uint256 floorOut = BPC.mulDiv(hop.expectedOut, floorBps, BPC.BPS);
        route = Route({
            hops: hops, totalOut: hop.expectedOut, singleOut: hop.expectedOut,
            singleOutFloor: floorOut, expectedImpactBps: totalImpactBps, confidenceWad: 0,
            estGas: _estGas(hop), hasSurplus: hop.expectedOut > floorOut, isV4Bundle: false
        });
    }

    function _assembleRouteMulti(Hop[] memory hops, address tIn, address tOut, uint256 amountIn, uint256 finalOut)
        private view returns (Route memory route)
    {
        tIn; tOut; amountIn;
        uint256 totalImpactBps; uint256 totalLegs;
        for (uint256 h; h < hops.length; ) {
            uint256 legs = hops[h].legs.length;
            uint256 hopImpact;
            for (uint256 i; i < legs; ) {
                uint256 d;
                Leg memory L = hops[h].legs[i];
                if (L.kind == BPC.KIND_V2 || L.kind == BPC.KIND_SOLIDLY || L.kind == BPC.KIND_BALANCER_V2) {
                    (uint256 r0, uint256 r1) = BPC.getReserves(L.pool);
                    uint256 rIn = L.zeroForOne ? r0 : r1;
                    d = BPC.impactV2Bps(L.amountIn, rIn);
                } else if (L.kind == BPC.KIND_V3 || L.kind == BPC.KIND_ALGEBRA) {
                    uint128 liq2 = BPC.getLiquidity(L.pool);
                    uint160 sp2 = BPC.getSqrtPriceX96(L.pool);
                    d = BPC.impactV3Bps(L.amountIn, sp2, liq2, uint24(L.fee), L.zeroForOne);
                } else { d = 50; }
                hopImpact += d;
                unchecked { ++i; }
            }
            if (legs > 0) hopImpact = hopImpact / legs;
            totalImpactBps += hopImpact;
            totalLegs += legs;
            unchecked { ++h; }
        }
        uint256 floorBps = BPC.ironFloorBps(totalImpactBps, totalLegs, 0);
        uint256 floorOut = BPC.mulDiv(finalOut, floorBps, BPC.BPS);
        route = Route({
            hops: hops, totalOut: finalOut, singleOut: finalOut, singleOutFloor: floorOut,
            expectedImpactBps: totalImpactBps, confidenceWad: 0,
            estGas: _estGas(hops[0]) + _estGas(hops[1]), hasSurplus: finalOut > floorOut, isV4Bundle: false
        });
    }

    function _estGas(Hop memory hop) private pure returns (uint256 g) {
        g = 30_000;
        uint256 n = hop.legs.length;
        for (uint256 i; i < n; ) {
            uint8 k = hop.legs[i].kind;
            uint256 base = 90_000;
            if (k == BPC.KIND_V3 || k == BPC.KIND_ALGEBRA) base = 110_000;
            else if (k == BPC.KIND_STABLE || k == BPC.KIND_CURVE_CRYPTO) base = 140_000;
            else if (k == BPC.KIND_V4) base = 180_000;
            g += base;
            unchecked { ++i; }
        }
    }
}
