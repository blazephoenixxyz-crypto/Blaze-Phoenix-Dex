// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// MONTE CARLO: THE PREVIEW NEVER PROMISES MORE THAN THE BALANCE DELTA.
//
// Pre-registered in docs/prereg/mc-1113.tsv. tools/fuzz-coverage/prereg.py binds this file to
// it: the constants, the seed rule, PREREG_TAG, PREREG_LOCK and the rule line are checked
// verbatim, and every log of this test must carry the PREREG_LOCK line it emits. The seeds are
// derived, never chosen: seed_i = sha256(PREREG_TAG || uint256 i).
//
// THE RULE IS EXACT: netOut <= delivered + ABS_TOL_WEI, with ABS_TOL_WEI = 0 derived from
// src/BlazePhoenixQuoter.sol:436-440 (R-C: the safety buffer rounds up, so netOut understates).
// Delivered is the balanceOf delta of tokenOut at the user (I2), never the router's return
// value. The fidelity side (delivered against netOut + safetyBuffer) is logged, not asserted:
// the owner decides that tolerance.
//
// World: the one of test/PreviewExecutionParity.t.sol (Hub, Solver, Quoter, Router and two
// MockV2Pair seated by Origin.wire), with both directions recorded so B->A and C->A route.
// Classes (i mod 4): A->B and B->A (1 hop), A->C and C->A (2 hops over the bridge B).
//
// Sharding: CI sets MC_SHARDS and MC_SHARD and each shard takes a contiguous slice of the
// N_SAMPLES (contiguous, so every shard sees the four classes); a local run takes the first
// LOCAL_SAMPLES.
//
// Red first: red under the mutants mc-1 and mc-2 in .github/scripts/mutants.py (the Quoter
// publishes afterFee + 0.5% as netOut). Green at HEAD is for CI to confirm: no forge was run
// where this file was written.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {Origin} from "./mocks/MockOriginFactory.sol";

contract MonteCarloPreviewParityTest is Test {
    string internal constant PREREG_TAG = "mc-1113";
    bytes32 internal constant PREREG_LOCK = 0x5e671a82a476fcc46f978db343b4a621201b6644372c65f0a3a737dce56b6f0d;
    uint256 internal constant N_SAMPLES = 4096;
    uint256 internal constant ABS_TOL_WEI = 0;
    uint256 internal constant AMOUNT_LO = 1000;
    uint256 internal constant AMOUNT_HI = 500_000e18;
    /// The slice a local run takes when MC_SHARDS is unset (not registered: a smoke size).
    uint256 internal constant LOCAL_SAMPLES = 8;

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockV2Pair ab;
    MockV2Pair bc;

    address user = address(0x5E4);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0x7451), address(0x7452)
        );

        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        tC = new MockERC20("C", "C");
        ab = _pair(tA, tB);
        bc = _pair(tB, tC);

        hub.setRoles(address(this), address(solver), address(quoter));
        _record(ab, tA, tB);
        _record(bc, tB, tC);
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(address(tB));

        MockERC20[3] memory ts = [tA, tB, tC];
        for (uint256 i; i < 3; i++) {
            ts[i].mint(user, 1e24);
            vm.prank(user);
            ts[i].approve(address(router), type(uint256).max);
        }
    }

    function _pair(MockERC20 x, MockERC20 y) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(x), address(y));
        // rizki-3107: the swap door seats only a pair a wired factory derives.
        Origin.wire(hub, address(p), address(x), address(y), BPC.KIND_V2, 30);
        x.mint(address(p), 1_000_000e18);
        y.mint(address(p), 1_000_000e18);
        p.setReserves(uint112(1_000_000e18), uint112(1_000_000e18));
    }

    /// Both directions. The Hub keys a pair by its sorted tokens, so the reverse record lands on
    /// the same row; it is recorded anyway so the world does not lean on that detail.
    function _record(MockV2Pair p, MockERC20 x, MockERC20 y) private {
        for (uint256 i; i < 5; i++) {
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(x), address(y), 1e18, 1e18, 1_000_000e18);
            hub.recordSwap(address(p), BPC.KIND_V2, 30, address(0),
                address(y), address(x), 1e18, 1e18, 1_000_000e18);
        }
    }

    function _seed(uint256 i) internal pure returns (uint256) {
        return uint256(sha256(abi.encodePacked(PREREG_TAG, i)));
    }

    /// The registered amount rule: log-spread over 10..79 bits, folded into [AMOUNT_LO, AMOUNT_HI].
    function _amount(uint256 s) internal pure returns (uint256) {
        return AMOUNT_LO + ((s >> 8) % (uint256(1) << (10 + s % 70))) % (AMOUNT_HI - AMOUNT_LO + 1);
    }

    function _class(uint256 c) internal view returns (address, address) {
        if (c == 0) return (address(tA), address(tB));
        if (c == 1) return (address(tA), address(tC));
        if (c == 2) return (address(tB), address(tA));
        return (address(tC), address(tA));
    }

    /// One sample: preview, execute as the user, measure the balance delta, apply the rule, undo.
    /// hops = 0 means the preview declined (a revert, !canExecute or netOut == 0): skipped, never
    /// counted as measured. A revert of the swap after an executable preview fails the test.
    function _sample(uint256 c, uint256 amt) internal returns (uint256 hops, uint256 gap) {
        (address tin, address tout) = _class(c);
        BlazePhoenixQuoter.Preview memory pv;
        try quoter.previewPlan(tin, tout, amt) returns (BlazePhoenixQuoter.Preview memory p, Route memory, bool) {
            pv = p;
        } catch {
            return (0, 0);
        }
        if (!pv.canExecute || pv.netOut == 0) return (0, 0);

        uint256 snap = vm.snapshotState();
        uint256 before = MockERC20(tout).balanceOf(user);
        vm.prank(user);
        router.swapBestExactIn(tin, tout, amt, 1, user, block.timestamp + 1);
        uint256 got = MockERC20(tout).balanceOf(user) - before;
        assertLe(pv.netOut, got + ABS_TOL_WEI, "MC: the preview promised more than the balance delta");
        uint256 fair = pv.netOut + pv.safetyBuffer;
        gap = got > fair ? got - fair : fair - got;
        hops = pv.hops;
        vm.revertToStateAndDelete(snap);
    }

    /// The registered sample: N_SAMPLES seeds over the four classes (a shard of them in CI).
    function testMC_SampledNeverOverpromise() public {
        emit log_named_bytes32("PREREG_LOCK", PREREG_LOCK);
        uint256 shards = vm.envOr("MC_SHARDS", uint256(0));
        uint256 lo;
        uint256 hi = LOCAL_SAMPLES;
        if (shards != 0) {
            uint256 shard = vm.envOr("MC_SHARD", uint256(0));
            require(shard < shards && shards <= N_SAMPLES, "MC: need MC_SHARD < MC_SHARDS <= N_SAMPLES");
            lo = N_SAMPLES * shard / shards;
            hi = N_SAMPLES * (shard + 1) / shards;
        }
        uint256[4] memory perClass;
        uint256[3] memory perHops;
        uint256 skipped;
        uint256 maxGap;
        for (uint256 i = lo; i < hi; i++) {
            (uint256 hops, uint256 gap) = _sample(i % 4, _amount(_seed(i)));
            if (hops == 0) {
                skipped++;
                continue;
            }
            perClass[i % 4]++;
            if (hops < 3) perHops[hops]++;
            if (gap > maxGap) maxGap = gap;
        }
        emit log_named_uint("MC first sample", lo);
        emit log_named_uint("MC samples", hi - lo);
        emit log_named_uint("MC skipped (declined by the preview)", skipped);
        emit log_named_uint("MC max fee-model gap, wei (logged, not asserted: owner decides)", maxGap);
        for (uint256 c; c < 4; c++) {
            assertGt(perClass[c], 0, "MC: a class was never measured (absent is not zero)");
        }
        assertGt(perHops[1], 0, "MC: no 1-hop route was measured");
        assertGt(perHops[2], 0, "MC: no 2-hop route was measured");
    }

    /// The registered extremes: AMOUNT_LO, AMOUNT_LO + 1, AMOUNT_HI - 1 and AMOUNT_HI per class.
    function testMC_ExtremesNeverOverpromise() public {
        emit log_named_bytes32("PREREG_LOCK", PREREG_LOCK);
        uint256[4] memory amts = [AMOUNT_LO, AMOUNT_LO + 1, AMOUNT_HI - 1, AMOUNT_HI];
        bool hi1;
        bool hi2;
        uint256 maxGap;
        for (uint256 c; c < 4; c++) {
            for (uint256 j; j < 4; j++) {
                (uint256 hops, uint256 gap) = _sample(c, amts[j]);
                if (j == 3 && hops == 1) hi1 = true;
                if (j == 3 && hops == 2) hi2 = true;
                if (gap > maxGap) maxGap = gap;
            }
        }
        emit log_named_uint("MC extremes max fee-model gap, wei (logged, not asserted: owner decides)", maxGap);
        assertTrue(hi1, "MC: no 1-hop route was measured at AMOUNT_HI (absent is not zero)");
        assertTrue(hi2, "MC: no 2-hop route was measured at AMOUNT_HI (absent is not zero)");
    }
}
