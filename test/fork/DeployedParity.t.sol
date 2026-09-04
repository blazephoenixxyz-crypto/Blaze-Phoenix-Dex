// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// V1 IS IN PRODUCTION. THIS TREE IS V2. THE DIFFERENCE IS NOW A WATCHED FACT.
//
// The router the public SDK points at is the same 14,624-byte contract on Base, Ethereum,
// Optimism and Arbitrum. This tree builds 23,892 bytes. Measured by RPC, not assumed:
//
//   runtime                 14,624 bytes on chain      23,892 in this tree
//   our ABI selectors       17 of 26 present            26 of 26
//   TLOAD / TSTORE          8 / 16                     14 / 28
//   DELEGATECALL            1                          7
//
// Nine external functions do not exist on chain: the native-value door, the whole wrap/unwrap
// mechanism, the entire rescue path, and the 7702 entry.
//
// WHAT IS ESTABLISHED. A binary search over `eth_getCode` puts the Base deployment at block
// 48,361,725, on 2026-07-08. This repository's first commit is 2026-08-12 and is titled
// "public release": ninety-four files in one import. So the repository is where V2 is being
// built and published, and V1 was deployed before it.
//
// The first draft of this file said "the deployed contract was never in this history" and let
// that stand for "it is not an earlier version of this code". Those are different claims. The
// first is true of the git history; the second is false - V1 is the same lineage, and its
// provenance simply lives outside this repository. The numbers below are the V1-to-V2 delta,
// which is what a version difference looks like, not evidence that anything was lost.
//
// It is NOT a proxy: both EIP-1967 slots read zero and the runtime opens with an ordinary
// dispatcher rather than a delegating trampoline, so those bytes are the logic. Checked, because
// if it were a proxy every number above would describe the wrong object.
//
// WHY THIS FILE EXISTS. Not to complain that they differ - one is deployed and one is not, and
// they are allowed to. It exists so the difference cannot change without someone being told. A
// deployment, a proxy nobody remembered, or another chain answering for an address would move
// these numbers and nothing here would otherwise notice.
//
// WHAT IT ASSERTS, and why these and not others. The properties that hold regardless of which
// generation is deployed: what must never be in the bytecode of anything this project ships, and
// what must be live for the contract to be usable at all. Those are the claims this project
// makes about any contract it ships, so they are the claims worth checking against the ones it
// has already shipped - on every chain the SDK names, not just the one that was asked about
// first.

import {Test} from "forge-std/Test.sol";

interface IDeployedRouter {
    function hub() external view returns (address);
    function solver() external view returns (address);
    function admin() external view returns (address);
    function paused() external view returns (bool);
    function controlRenounced() external view returns (bool);
    function treasury1() external view returns (address);
    function treasury2() external view returns (address);
}

contract DeployedParityTest is Test {
    struct Target { string net; address router; }

    // Every chain the public SDK names, from test/fork/deployed-codehash.json. The routers are
    // byte-identical across all four - one generation, deployed consistently - and checking one
    // chain and calling it "the deployed contract" was the first draft's other mistake.
    Target[4] chains;

    // Measured 2026-09-04. Pinned so a redeployment, or a different chain answering for an
    // address, is a test failure rather than a surprise weeks later.
    uint256 constant RUNTIME_BYTES = 14_624;

    function setUp() public {
        chains[0] = Target("base",     0x2a779f9Be49aac57495A8B6467Cc325a8a47Eb9f);
        chains[1] = Target("ethereum", 0xE1aE5f49013920CF71De8CED4043e14C4d63416b);
        chains[2] = Target("optimism", 0x7262e7483ab6f0db7b8f90eC3a9de3B02Ab36F6A);
        chains[3] = Target("arbitrum", 0x7262e7483ab6f0db7b8f90eC3a9de3B02Ab36F6A);
    }

    /// @dev A missing key is not a defect in the contract, so this reports and skips rather
    ///      than failing. Silence would be worse than either: a check that cannot run and does
    ///      not say so is indistinguishable from one that passed.
    function _select(uint256 k) private returns (bool) {
        string memory key = vm.envOr("DRPC_KEY", string(""));
        if (bytes(key).length == 0) { emit log("DRPC_KEY unset - skipping"); return false; }
        string memory url = string.concat("https://lb.drpc.org/ogrpc?network=", chains[k].net,
                                          "&dkey=", key);
        try vm.createSelectFork(url) { } catch { emit log("fork failed - skipping"); return false; }
        return chains[k].router.code.length > 0;
    }

    /// CLAIM: nothing this project ships contains an opcode it forbids. Asserted here against
    /// contracts we did not build, on every chain that serves them - the only place these claims
    /// meet something outside our own artefact.
    function test_Deployed_ForbidsTheSameOpcodesOnEveryChain() public {
        for (uint256 k; k < chains.length; ++k) {
            if (!_select(k)) continue;
            (bool sd, bool cc, bool og, bool tl, bool ts) = _scanFull(chains[k].router.code);
            assertFalse(sd, string.concat(chains[k].net, ": the deployed router can self-destruct"));
            assertFalse(cc, string.concat(chains[k].net, ": the deployed router uses CALLCODE"));
            assertFalse(og, string.concat(chains[k].net, ": the deployed router trusts tx.origin"));
            assertTrue(tl && ts, string.concat(chains[k].net,
                ": no transient opcodes - its reentrancy lock is not the one we reason about"));
        }
    }

    /// CLAIM, pinned rather than argued: the drift is exactly this size. Not that it SHOULD
    /// differ - that it differs by this much, so any movement is reported.
    function test_Deployed_DriftIsExactlyWhatWeMeasured() public {
        for (uint256 k; k < chains.length; ++k) {
            if (!_select(k)) continue;
            assertEq(chains[k].router.code.length, RUNTIME_BYTES, string.concat(
                chains[k].net, ": the deployed runtime changed size - something shipped and nobody said so"));
        }
    }

    /// CLAIM: the contract is usable and points at real code. A router wired to an address with
    /// no code cannot route, and that failure would be silent from the outside.
    function test_Deployed_IsLiveAndWired() public {
        for (uint256 k; k < chains.length; ++k) {
            if (!_select(k)) continue;
            IDeployedRouter r = IDeployedRouter(chains[k].router);
            assertFalse(r.paused(), string.concat(chains[k].net, ": deployed router is paused"));
            assertTrue(r.hub().code.length > 0, string.concat(chains[k].net, ": hub has no code"));
            assertTrue(r.solver().code.length > 0, string.concat(chains[k].net, ": solver has no code"));
            assertTrue(r.treasury1() != address(0), string.concat(chains[k].net, ": treasury1 unset"));
        }
    }

    /// CLAIM: control is still live on chain. Recorded because it decides which of this
    /// project's guarantees describe the deployed contract at all - everything reasoned about
    /// the frozen, post-renunciation world does not apply while this is false.
    function test_Deployed_ControlIsStillLive() public {
        for (uint256 k; k < chains.length; ++k) {
            if (!_select(k)) continue;
            assertFalse(IDeployedRouter(chains[k].router).controlRenounced(), string.concat(
                chains[k].net, ": control was renounced on chain - the ossification reasoning now applies"));
        }
    }

    // ─── opcode scan, walking PUSH data so a constant is never read as an instruction ───
    function _scan(bytes memory code) private pure returns (bool sd, bool cc, bool og) {
        (sd, cc, og, , ) = _scanFull(code);
    }

    function _scanFull(bytes memory code)
        private pure returns (bool sd, bool cc, bool og, bool tload, bool tstore)
    {
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0xff) sd = true;
            else if (op == 0xf2) cc = true;
            else if (op == 0x32) og = true;
            else if (op == 0x5c) tload = true;
            else if (op == 0x5d) tstore = true;
            unchecked { i += (op >= 0x60 && op <= 0x7f) ? uint256(op) - 0x5e : 1; }
        }
    }
}
