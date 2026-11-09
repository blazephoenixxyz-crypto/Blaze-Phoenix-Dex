// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  SIZE AND HOT-PATH GAS, PINNED.
//
//  Two ledgers of bytes and one ledger of gas, each a gate under
//  FORGE_SNAPSHOT_CHECK=true, plus the project's size gate on the contracts
//  DeployedSizeGate.t.sol does not deploy.
//
//  SIZE (SizeLedgerTest). Every contract and library under src/ that goes to a
//  chain, twelve rows named as `forge build --sizes` names them (the CI
//  size-guard reads the same names):
//  - the runtime ledger: the code each row leaves at its address;
//  - the initcode ledger: the bytes each deployment sends, constructor arguments
//    included (what EIP-3860 limits; `forge build --sizes` prints the creation
//    code alone);
//  - the project gate: runtime < PROJECT_GATE (24 000, imported from
//    DeployedSizeGate.t.sol, the suite's one producer of that number) on the
//    seven rows that file does not assert: Core, Gate, GateWrapper and the four
//    adapters.
//  Every row is deployed from the initcode it records, so the two ledgers
//  measure one deployment. The GateWrapper is the Gate's own CREATE2 of its
//  creation code (the address is recomputed from the recorded bytes); a library
//  row is a copy deployed from its creation code, held to the length of the
//  linked library the other contracts call.
//  The numbers are the release profile's, the one the CI size guard builds
//  (FOUNDRY_PROFILE=release).
//  EIP-3860 (initcode at most 2 x EIP-170) is logged per row, not asserted: the
//  ledger already pins every initcode byte, and a gate there would have no
//  mutant within reach to prove it.
//
//  HOT PATH (HotPathGasLedgerTest). A small trade on a curated pair: the seeded
//  QuoteWorld (three curated A/B rows, fresh, so the Solver's freshness gate
//  skips the discovery sweep), A -> B, one hop, 1 % of AB1's A reserve. Three
//  doors, one window each:
//  - previewPlan, the quote (`view`: the call frame alone);
//  - swapExactIn of the route that quote serves, with the quote's own floor;
//  - swapBestExactIn, which solves inside the transaction, with the same floor.
//  A swap window is one top-level call read by `vm.snapshotGasLastFrame`; in
//  isolation mode (`isolate = true` in foundry.toml, asserted in setUp) that call
//  is its own transaction, intrinsic gas and cold accounts included: `_tx` entries.
//
//  THE BUDGET IS THE SNAPSHOT. One group per test, named after it, written to
//  snapshots/<test>.json, so a partial run (--match-test) rewrites only the
//  groups it ran. With FORGE_SNAPSHOT_CHECK=true any entry that moves, up or
//  down, fails the run while every assert still passes; a change meant to move
//  a number regenerates its file in the same commit. No ceiling is set by hand.
//  The mutants that prove each gate are the `gas-1106 G7` entries of
//  .github/scripts/mutants.py.
//
//  FOUNDRY_PROFILE=release forge test --match-path test/gas/SizeAndGasGates.t.sol
//  FORGE_SNAPSHOT_CHECK=true FOUNDRY_PROFILE=release forge test --match-path test/gas/SizeAndGasGates.t.sol
// =============================================================================

import {EIP_170_LIMIT, PROJECT_GATE} from "../DeployedSizeGate.t.sol";
import {AdapterHarness} from "../adapters/AdapterHarness.sol";
import {MockCurveNGFactory, MockCurveNGPool} from "../adapters/mocks/MockCurveNG.sol";
import {QuoteWorld} from "../QuoteWorld.sol";
import {BlazePhoenixCore} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixMath} from "../../src/BlazePhoenixMath.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../../src/BlazePhoenixGate.sol";
import {BlazePhoenixAdapterCurveNG} from "../../src/adapters/BlazePhoenixAdapterCurveNG.sol";
import {BlazePhoenixAdapterCurveCryptoNG} from "../../src/adapters/BlazePhoenixAdapterCurveCryptoNG.sol";
import {BlazePhoenixAdapterBalancerV2} from "../../src/adapters/BlazePhoenixAdapterBalancerV2.sol";
import {BlazePhoenixAdapterBalancerV3} from "../../src/adapters/BlazePhoenixAdapterBalancerV3.sol";

contract SizeLedgerTest is AdapterHarness {
    /// The rows: the ten contracts and two libraries under src/ (ExtAdapterBase is abstract,
    /// everything else there is an interface).
    uint256 internal constant SHIPPED = 12;

    /// Rows [0, ALREADY_GATED) are the five DeployedSizeGate.t.sol deploys and holds under
    /// PROJECT_GATE (Hub, Solver, Router, Quoter, Math), in its order; the rest are the seven
    /// this file holds there.
    uint256 internal constant ALREADY_GATED = 5;

    /// EIP-3860: MAX_INITCODE_SIZE = 2 * MAX_CODE_SIZE, the latter being EIP-170's limit.
    uint256 internal constant EIP_3860_LIMIT = 2 * EIP_170_LIMIT;

    /// The Curve NG family and its first venue slot, as the adapter tests key them. Any family
    /// would do: a wrapper's size does not depend on which one it serves.
    uint8 internal constant FAMILY = 1;
    uint24 internal constant VENUE_KEY = uint24(FAMILY) << 16 | 1;

    struct Row {
        string name;
        uint256 initcode;
        address deployed;
    }

    function test_Size_RuntimeLedger() public {
        Row[SHIPPED] memory s = _ship();
        for (uint256 i; i < SHIPPED; ++i) {
            vm.snapshotValue("test_Size_RuntimeLedger", s[i].name, s[i].deployed.code.length);
        }
    }

    function test_Size_InitcodeLedger() public {
        Row[SHIPPED] memory s = _ship();
        for (uint256 i; i < SHIPPED; ++i) {
            vm.snapshotValue("test_Size_InitcodeLedger", s[i].name, s[i].initcode);
            emit log_named_int(string.concat(s[i].name, ": initcode bytes to EIP-3860"),
                int256(EIP_3860_LIMIT) - int256(s[i].initcode));
        }
    }

    function test_Size_RuntimeUnderProjectGate_CoreGateWrapperAndAdapters() public {
        Row[SHIPPED] memory s = _ship();
        for (uint256 i = ALREADY_GATED; i < SHIPPED; ++i) {
            uint256 size = s[i].deployed.code.length;
            assertGt(size, 0, string.concat(s[i].name, ": nothing was deployed, so nothing was measured"));
            // Signed, so a row over the gate prints its overshoot (DeployedSizeGate's `_margin`).
            emit log_named_int(string.concat(s[i].name, ": bytes to the project gate"),
                int256(PROJECT_GATE) - int256(size));
            assertLt(size, PROJECT_GATE, string.concat(s[i].name, " is at or over the project's own size gate"));
        }
    }

    // ─── the twelve rows ─────────────────────────────────────────────────────

    function _ship() internal returns (Row[SHIPPED] memory s) {
        _tokens();
        // The harness's Gate is replaced by one deployed from the bytes the ledger records:
        // the Solver and the adapters take its address, and the wrapper row is its CREATE2.
        gate = BlazePhoenixGate(_row(s, 6, "BlazePhoenixGate",
            bytes.concat(type(BlazePhoenixGate).creationCode, abi.encode(address(this)))));

        address hub = _row(s, 0, "BlazePhoenixHub",
            bytes.concat(type(BlazePhoenixHub).creationCode, abi.encode(address(this))));
        address solver = _row(s, 1, "BlazePhoenixSolver",
            bytes.concat(type(BlazePhoenixSolver).creationCode, abi.encode(hub, address(gate))));
        _row(s, 2, "BlazePhoenixRouter", bytes.concat(type(BlazePhoenixRouter).creationCode,
            abi.encode(hub, solver, address(this), makeAddr("treasury 1"), makeAddr("treasury 2"))));
        _row(s, 3, "BlazePhoenixQuoter",
            bytes.concat(type(BlazePhoenixQuoter).creationCode, abi.encode(hub, solver)));
        _row(s, 4, "BlazePhoenixMath", type(BlazePhoenixMath).creationCode);
        assertEq(s[4].deployed.code.length, address(BlazePhoenixMath).code.length,
            "the Math row is the linked Math's code");
        _row(s, 5, "BlazePhoenixCore", type(BlazePhoenixCore).creationCode);
        assertEq(s[5].deployed.code.length, address(BlazePhoenixCore).code.length,
            "the Core row is the linked Core's code");

        MockCurveNGFactory factory = new MockCurveNGFactory();
        address ng = _row(s, 8, "BlazePhoenixAdapterCurveNG", bytes.concat(
            type(BlazePhoenixAdapterCurveNG).creationCode, abi.encode(address(gate), address(factory))));
        _row(s, 9, "BlazePhoenixAdapterCurveCryptoNG", bytes.concat(
            type(BlazePhoenixAdapterCurveCryptoNG).creationCode,
            abi.encode(address(gate), makeAddr("curve crypto ng factory"))));
        _row(s, 10, "BlazePhoenixAdapterBalancerV2", bytes.concat(
            type(BlazePhoenixAdapterBalancerV2).creationCode,
            abi.encode(address(gate), makeAddr("balancer v2 vault"),
                [makeAddr("balancer v2 factory"), address(0), address(0), address(0)])));
        _row(s, 11, "BlazePhoenixAdapterBalancerV3", bytes.concat(
            type(BlazePhoenixAdapterBalancerV3).creationCode,
            abi.encode(address(gate), makeAddr("balancer v3 vault"),
                [makeAddr("balancer v3 factory"), address(0)], [bytes32(0), bytes32(0)])));

        // The wrapper: the Gate deploys it, through an accepted Curve NG adapter, by CREATE2 of
        // its creation code (no constructor arguments).
        _accept(FAMILY, ng);
        address w = gate.create(address(t0), address(t1), VENUE_KEY, abi.encode(_curvePool(factory)));
        bytes memory wInit = type(BlazePhoenixGateWrapper).creationCode;
        assertEq(w, vm.computeCreate2Address(BlazePhoenixCore.v3Salt(address(t0), address(t1), VENUE_KEY),
            keccak256(wInit), address(gate)), "the wrapper row is the recorded initcode, deployed by the Gate");
        s[7] = Row("BlazePhoenixGateWrapper", wInit.length, w);
    }

    /// Deploys `initcode` by CREATE and records row `i`.
    function _row(Row[SHIPPED] memory s, uint256 i, string memory name, bytes memory initcode)
        private returns (address a)
    {
        assembly ("memory-safe") { a := create(0, add(initcode, 0x20), mload(initcode)) }
        assertTrue(a != address(0), string.concat(name, ": the recorded initcode did not deploy"));
        s[i] = Row(name, initcode.length, a);
    }

    /// A plain two-coin pool the Curve NG factory knows, for the wrapper's `create`.
    function _curvePool(MockCurveNGFactory factory) private returns (address pool) {
        address[] memory coins = new address[](2);
        (coins[0], coins[1]) = (address(t0), address(t1));
        pool = address(new MockCurveNGPool(coins, new uint256[](2)));
        factory.register(pool, coins, new uint8[](2), false);
    }
}

contract HotPathGasLedgerTest is QuoteWorld {
    /// The input of every window: 1 % of AB1's A reserve (QuoteWorld). An input, not a budget.
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        assertTrue(vm.isIsolateMode(), "the windows need isolate: each top-level call is its own transaction");
    }

    function test_Gas_HotPathLedger_PreviewPlan_OneHop() public {
        _world(true);
        (BlazePhoenixQuoter.Preview memory pv, , ) = quoter.previewPlan(address(A), address(B), AMOUNT);
        vm.snapshotGasLastFrame("test_Gas_HotPathLedger_PreviewPlan_OneHop", "previewPlan");
        _isHotPath(pv);
    }

    function test_Gas_HotPathLedger_SwapExactIn_OneHop() public {
        _world(true);
        BlazePhoenixQuoter.Preview memory pv = _quote();
        _fund();
        vm.prank(user);
        uint256 out = router.swapExactIn(pv.route, AMOUNT, pv.effectiveMinOut, user, block.timestamp + 1);
        vm.snapshotGasLastFrame("test_Gas_HotPathLedger_SwapExactIn_OneHop", "swapExactIn_tx");
        _delivered(out, pv);
    }

    /// The door solves with the Solver's `findBestRoutePlan`, the call behind `previewPlan`, on
    /// the state the quote read: the one hop `_quote` asserts is the one it executes.
    function test_Gas_HotPathLedger_SwapBestExactIn_OneHop() public {
        _world(true);
        BlazePhoenixQuoter.Preview memory pv = _quote();
        _fund();
        vm.prank(user);
        uint256 out = router.swapBestExactIn(address(A), address(B), AMOUNT, pv.effectiveMinOut, user, block.timestamp + 1);
        vm.snapshotGasLastFrame("test_Gas_HotPathLedger_SwapBestExactIn_OneHop", "swapBestExactIn_tx");
        _delivered(out, pv);
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _quote() private view returns (BlazePhoenixQuoter.Preview memory pv) {
        (pv, , ) = quoter.previewPlan(address(A), address(B), AMOUNT);
        _isHotPath(pv);
    }

    /// The quote is executable (so the Quoter also ran its hook screen on the route) and one hop.
    function _isHotPath(BlazePhoenixQuoter.Preview memory pv) private pure {
        assertTrue(pv.canExecute, "the quote is executable");
        assertEq(pv.hops, 1, "the quote is one hop");
    }

    /// AMOUNT of A to the user, who approves the Router for it.
    function _fund() private {
        A.mint(user, AMOUNT);
        vm.prank(user);
        A.approve(address(router), AMOUNT);
    }

    function _delivered(uint256 out, BlazePhoenixQuoter.Preview memory pv) private view {
        assertGe(out, pv.effectiveMinOut, "the door met the quote's floor");
        assertEq(B.balanceOf(user), out, "the recipient holds what the door returned");
    }
}
