// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The fork oracle's skip guard: DRPC_KEY is asked for only where it is used.
// RED before the guard took the URL into account: every fork row skipped without DRPC_KEY,
// even when AVAX_FORK_URL / BSC_FORK_URL / ARBITRUM_FORK_URL named a local archive.
// Offline: no fork is created, the guard is asked directly.
// Matrix: alias / dRPC URL / explicit http, https, ws, wss URL / prefix one byte short.
// Mutant: _needsDrpcKey always true (the old guard).

import {AtqForkVenueOracle} from "./fork/AtqForkVenueOracle.sol";

contract AtqForkUrlGuardTest is AtqForkVenueOracle {
    function test_AnAliasOrADrpcUrlNeedsTheKey() public pure {
        assertTrue(_needsDrpcKey("base"), "an alias resolves through foundry.toml");
        assertTrue(_needsDrpcKey("arbitrum"), "an alias resolves through foundry.toml");
        assertTrue(_needsDrpcKey(""), "an empty endpoint is not an archive");
        assertTrue(_needsDrpcKey("https://lb.drpc.live/bsc/"), "a dRPC URL carries the key");
        assertTrue(_needsDrpcKey("https:/"), "a prefix one byte short is not a URL");
    }

    function test_AnExplicitUrlRunsWithoutTheKey() public pure {
        assertFalse(_needsDrpcKey("http://127.0.0.1:8545"), "a local archive was skipped");
        assertFalse(_needsDrpcKey("https://archive.example/avax"), "an explicit archive was skipped");
        assertFalse(_needsDrpcKey("ws://127.0.0.1:8546"), "a ws archive was skipped");
        assertFalse(_needsDrpcKey("wss://archive.example/bsc"), "a wss archive was skipped");
    }
}
