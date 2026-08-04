// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Ported from Blaze-Phoenix-Dex (V1) test/HubFuzz.t.sol — only keyOf's order-independence, which
// has zero coverage anywhere in this repo's own BlazePhoenixHub.t.sol (it's exercised as a helper
// throughout, but the commutativity property itself — keyOf(pool, a, b) == keyOf(pool, b, a),
// load-bearing since recordSwap/addV4/seedPool must all resolve to the same registry slot
// regardless of which token order the caller passes — is never asserted directly).
//
// Everything else in V1's HubFuzz.t.sol is already covered here, several cases more granularly:
// initialize-once (test_Initialize_RevertsOnSecondCall/RevertsWhenCalledByNonDeployer),
// renounceControl freezing control while keeping curator powers (three dedicated
// RenounceControl_* tests, including a remove-bridge case V1 didn't have), recordSwap/seedPool
// access control, the bridge cap, every addFactory coherence guard (more granular here than V1's
// five cases), seed-then-active, tick-vs-register, and eviction-displaces-shallow. V2's addFactory
// also has an extra Algebra fee-sentinel branch V1's fuzz property didn't model — porting that
// property verbatim risked being a subtly wrong oracle for modest gain over the existing dense
// per-branch unit coverage, so it's intentionally not ported.
//
// forge test --match-contract HubFuzzFromV1 -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract HubFuzzFromV1Test is Test {
    BlazePhoenixHub hub;

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), address(0));
    }

    function testFuzz_keyOf_orderIndependent(address pool, address a, address b) public view {
        assertEq(hub.keyOf(pool, a, b), hub.keyOf(pool, b, a));
    }
}
