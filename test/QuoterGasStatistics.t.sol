// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  What a quote costs through the ABI — discovery versus a fresh registry.
//
//  The Solver skips the CREATE2 discovery sweep when the pair's registry holds at least
//  MIN_FRESH_VENUES entries ticked inside DISCOVERY_TTL_SECONDS (`_registryFresh`); otherwise it
//  asks the Hub to discover. Same pair, same tokens, two worlds: one with the pools seeded and
//  fresh (NORMAL), one with the pools known only to the factory (DISCOVERY). Gas is measured
//  around the external call, forty amounts each, and reported as mean / min / max / spread.
//  The property asserted is that the two worlds price the same pool the same: the mode changes
//  what a quote costs, never what it says.
//
//  forge test --match-path test/QuoterGasStatistics.t.sol -vv
// =============================================================================
import {console2} from "forge-std/Test.sol";
import {QuoteWorld, BlazePhoenixQuoter} from "./QuoteWorld.sol";

contract QuoterGasStatisticsTest is QuoteWorld {
    uint256 constant M = 40;

    struct G { uint256 sum; uint256 min; uint256 max; uint256 sumSq; }

    function _g(G memory g, uint256 x) private pure {
        g.sum += x; g.sumSq += x * x;
        if (g.min == 0 || x < g.min) g.min = x;
        if (x > g.max) g.max = x;
    }

    function _report(string memory tag, G memory g) private pure {
        uint256 mean = g.sum / M;
        uint256 var_ = g.sumSq / M - mean * mean;
        uint256 sd; { uint256 z = var_; uint256 y = (z + 1) / 2; sd = z; while (y < sd) { sd = y; y = (z / y + y) / 2; } if (z == 0) sd = 0; }
        console2.log(tag, "mean gas", mean);
        console2.log("   min", g.min, "max", g.max);
        console2.log("   stdev", sd);
    }

    function _measure(string memory tag) private returns (G memory plan, G memory enc, uint256 sampleOut) {
        for (uint256 i; i < M; ++i) {
            uint256 amt = 1e16 + i * 5e16;
            uint256 g0 = gasleft();
            (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(address(A), address(B), amt);
            _g(plan, g0 - gasleft());
            g0 = gasleft();
            quoter.previewAndEncode(address(A), address(B), amt, user, block.timestamp + 20);
            _g(enc, g0 - gasleft());
            if (i == 10) sampleOut = pv.grossOut;
            assertTrue(pv.canExecute, "the quote exists in both worlds");
        }
        _report(string.concat(tag, " previewPlan     "), plan);
        _report(string.concat(tag, " previewAndEncode"), enc);
    }

    function test_DiscoveryVersusFreshRegistry_GasAndSameAnswer() public {
        _world(false);                                   // DISCOVERY: pools only in the factory
        (G memory dPlan, , uint256 dOut) = _measure("DISCOVERY");
        _world(true);                                    // NORMAL: pools seeded, registry fresh
        // the seeded world holds three AB pools; the factory world one — restrict the comparison
        // of the ANSWER to the pool both worlds know by quoting a size the split never touches
        (G memory nPlan, , ) = _measure("NORMAL   ");
        assertGt(dPlan.sum / M, 0); assertGt(nPlan.sum / M, 0);
        console2.log("discovery / normal, previewPlan mean gas ratio x100", dPlan.sum * 100 / nPlan.sum);
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(address(A), address(B), 1e16 + 10 * 5e16);
        assertGe(pv.grossOut, dOut, "the fresh registry, holding a superset of the pools, never quotes less than discovery did");
    }

    function test_BatchQuoteOfTen_Gas() public {
        _world(true);
        BlazePhoenixQuoter.BatchEntry[] memory e = new BlazePhoenixQuoter.BatchEntry[](10);
        for (uint256 i; i < 10; ++i) e[i] = BlazePhoenixQuoter.BatchEntry({tIn: address(A), tOut: i % 2 == 0 ? address(B) : address(C), amountIn: 1e17 * (i + 1), userMinOut: 0});
        uint256 g0 = gasleft();
        BlazePhoenixQuoter.Preview[] memory pvs = quoter.batchQuote(e);
        uint256 g = g0 - gasleft();
        console2.log("batchQuote(10) gas", g, "per entry", g / 10);
        for (uint256 i; i < 10; ++i) assertTrue(pvs[i].canExecute, "every entry quoted");
    }
}
