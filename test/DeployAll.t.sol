// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployAll} from "../script/DeployAll.s.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

/// @notice Verifies DeployAll._deploy on a BARE local chain — no fork, no RPC.
///         Proves the two properties the script promises:
///           1. it RUNS on a chain where none of the venue constants exist
///              (probe-gating SKIPs every codeless factory instead of
///              reverting), and
///           2. it is FAIL-CLOSED: nothing codeless ever reaches the registry
///              (factoryCount stays 0).
contract DeployAllTest is Test {
    // Base bridge tokens (mirror the script's constants).
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Any nonempty runtime code — the probe only checks extcodesize > 0.
    bytes constant DUMMY_CODE = hex"600160005260206000f3";

    function test_Deploy_Base_BareChain_FailClosed() public {
        vm.chainId(8453); // Base

        // Give ONLY the bridge tokens code, so both take the ADD path
        // (bridges warn-skip when codeless; here we want them registered).
        vm.etch(BASE_WETH, DUMMY_CODE);
        vm.etch(BASE_USDC, DUMMY_CODE);

        DeployAll script = new DeployAll();
        // The REAL Hub pins its admin at construction and msg.sender-gates
        // initialize() and every curator call. Without a broadcast, the
        // effective sender of every hub call inside _deploy is the script
        // contract itself — so the script must be its own admin here (in
        // run(), the broadcaster DEPLOYER_ADDRESS plays this role).
        (address hub, address solver, address router, address quoter) =
            script._deploy(address(script));

        // ── the full stack deployed ──
        assertTrue(hub    != address(0), "hub zero");
        assertTrue(solver != address(0), "solver zero");
        assertTrue(router != address(0), "router zero");
        assertTrue(quoter != address(0), "quoter zero");

        // ── the Hub is initialized: a second initialize reverts HubE(1) ──
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 1));
        BlazePhoenixHub(hub).initialize(address(this), address(0));

        // ── fail-closed: every factory constant is codeless on a bare chain,
        //    so probe-gating skipped them ALL — the registry stayed empty ──
        assertEq(BlazePhoenixHub(hub).factoryCount(), 0, "codeless factory registered");

        // ── the etched bridges DID pass the probe and were registered ──
        assertEq(BlazePhoenixHub(hub).bridgeCount(), 2, "bridges not registered");
    }

    function test_Deploy_UnsupportedChain_Reverts() public {
        vm.chainId(999_999);
        DeployAll script = new DeployAll();
        vm.expectRevert(bytes("DeployAll: unsupported chain"));
        script._deploy(address(script));
    }
}
