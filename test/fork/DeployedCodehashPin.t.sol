// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  Assumption A10 of the assumption book: "the deployed bytecode is `main`".
//  Nothing enforced it, and it already failed once (a researcher audited the
//  production bytecode via Sourcify and reported a defect `main` no longer
//  had; FLOOR_HARD_MAX_LOSS_BPS was 2500 on chain and 2000 in `main`).
//
//  This test turns the assumption into a MEASUREMENT: for every chain in
//  test/fork/deployed-codehash.json it forks the chain and asserts that each
//  deployed contract's `extcodehash` equals the hash pinned in the table.
//  A pinned hash that no longer matches means somebody redeployed, or the
//  table is stale — either way a human has to look. The table is the single
//  place where "what is on chain" is written down; the known gap between the
//  deployed build and `main` becomes a number in the table's `builtFrom`
//  field instead of an assumption.
//
//  Table shape (chain aliases are foundry.toml rpc_endpoints):
//  {
//    "base": { "builtFrom": "<commit>", "contracts": [
//      { "name": "BlazePhoenixRouter", "addr": "0x..", "codehash": "0x.." }, ... ] },
//    "optimism": { ... }
//  }
//  First run with an empty "codehash" prints the live value to pin.
//
//  Without the table (or the RPC key) the test SKIPS loudly. A skip is not a
//  pass: the fork lane requires a positive count of passed tests.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";

contract DeployedCodehashPinTest is Test {
    string constant TABLE = "test/fork/deployed-codehash.json";

    function _chain(string memory json, string memory alias_) private returns (uint256 checked) {
        string memory root = string.concat(".", alias_);
        if (!vm.keyExistsJson(json, root)) return 0;
        vm.createSelectFork(alias_);
        uint256 n = vm.parseJsonStringArray(json, string.concat(root, ".contracts[*].name")).length;
        for (uint256 i; i < n; ++i) {
            string memory p = string.concat(root, ".contracts[", vm.toString(i), "]");
            string memory name = vm.parseJsonString(json, string.concat(p, ".name"));
            address addr = vm.parseJsonAddress(json, string.concat(p, ".addr"));
            bytes32 live = addr.codehash;
            string memory pinned = vm.parseJsonString(json, string.concat(p, ".codehash"));
            console2.log(alias_, name, addr);
            console2.logBytes32(live);
            if (bytes(pinned).length == 0) {
                console2.log("  (no hash pinned yet: pin the value above)");
                continue;
            }
            assertEq(live, vm.parseBytes32(pinned), string.concat("A10 drift: ", alias_, " ", name));
            unchecked { ++checked; }
        }
    }

    function test_A10_DeployedCodehashMatchesThePinnedTable() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        string memory json;
        try vm.readFile(TABLE) returns (string memory s) { json = s; }
        catch { console2.log("A10: no table at", TABLE, "- nothing measured"); vm.skip(true); return; }
        uint256 checked = _chain(json, "mainnet") + _chain(json, "base") + _chain(json, "optimism")
            + _chain(json, "arbitrum") + _chain(json, "robinhood");
        // Until the first hashes are pinned this measures nothing and says so
        // (a skip, never a pass): the printed live values are what to pin.
        if (checked == 0) { console2.log("A10: no hash pinned yet on any chain; pin the values printed above"); vm.skip(true); }
    }
}
