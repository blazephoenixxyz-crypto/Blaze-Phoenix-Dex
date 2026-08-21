// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  EQUATION BENCH — measurement harness, not a correctness test.
//
//  Measures, for the SAME swap from the SAME state:
//    path A  swapExactIn(route,...)        max calldata / min execution
//    path B  swapBestExactIn(tIn,tOut,...) min calldata / max execution
//  reporting execution gas (gasleft delta around the external call, all
//  relevant accounts vm.cool-ed first to approximate a fresh tx) and exact
//  calldata bytes (total / zero / nonzero), plus the raw calldata hex so an
//  off-chain script can feed it to the L2 fee oracles (getL1Fee etc).
//
//  Also profiles path B: solve-phase gas, call census (staticcalls by
//  target+selector) via vm.startStateDiffRecording, and the storage-slot
//  intersection between the solve phase and the execution phase (the
//  repeated reads a transient cache could serve).
//
//  Machine-readable log lines, prefix "BENCH|" — parsed by a python script.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {
    BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan, PoolInfo
} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract EquationBenchTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockERC20 bridgeToken;
    address user = address(0xBEEF);
    address[] pools;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        tokenIn = new MockERC20("IN", "IN");
        tokenOut = new MockERC20("OUT", "OUT");
        bridgeToken = new MockERC20("BRIDGE", "BR");
    }

    // ─── fixture helpers ────────────────────────────────────────────────────

    function _seedPool(address a, address b, uint256 ra, uint256 rb) internal returns (MockV2Pair p) {
        p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), ra);
        MockERC20(b).mint(address(p), rb);
        (address t0, ) = a < b ? (a, b) : (b, a);
        p.setReserves(uint112(a == t0 ? ra : rb), uint112(a == t0 ? rb : ra));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), a, b);
        pools.push(address(p));
    }

    function _coolAll() internal {
        vm.cool(address(router));
        vm.cool(address(hub));
        vm.cool(address(solver));
        vm.cool(address(tokenIn));
        vm.cool(address(tokenOut));
        vm.cool(address(bridgeToken));
        for (uint256 i; i < pools.length; ++i) vm.cool(pools[i]);
    }

    function _countBytes(bytes memory cd) internal pure returns (uint256 z, uint256 nz) {
        for (uint256 i; i < cd.length; ++i) {
            if (cd[i] == 0) z++; else nz++;
        }
    }

    // ─── measured paths ─────────────────────────────────────────────────────

    /// Path A: plan computed OFF the measured window (simulates off-chain quote),
    /// then the route travels as calldata.
    function _measExact(string memory tag, uint256 amountIn, bool dumpCd) internal {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);
        bytes memory cd = abi.encodeCall(
            BlazePhoenixRouter.swapExactIn,
            (plan.best, amountIn, 1, user, block.timestamp + 1)
        );
        (uint256 z, uint256 nz) = _countBytes(cd);
        tokenIn.mint(user, amountIn);
        vm.prank(user);
        (bool okA, ) = address(tokenIn).call(abi.encodeWithSignature("approve(address,uint256)", address(router), amountIn));
        require(okA, "approve");
        _coolAll();
        vm.prank(user);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = address(router).call(cd);
        uint256 gasUsed = g0 - gasleft();
        require(ok, "swapExactIn failed");
        uint256 delivered = abi.decode(ret, (uint256));
        uint256 nHops = plan.best.hops.length;
        uint256 nLegs;
        for (uint256 h; h < nHops; ++h) nLegs += plan.best.hops[h].legs.length;
        console2.log(string.concat("BENCH|meas|", tag, "|exactIn"));
        console2.log("BENCH|gas", gasUsed);
        console2.log("BENCH|cd_total", cd.length);
        console2.log("BENCH|cd_zero", z);
        console2.log("BENCH|cd_nonzero", nz);
        console2.log("BENCH|delivered", delivered);
        console2.log("BENCH|hops", nHops);
        console2.log("BENCH|legs", nLegs);
        if (dumpCd) { console2.log(string.concat("BENCH|cdhex|", tag, "|exactIn")); console2.logBytes(cd); }
    }

    /// Path B: everything on-chain in one call.
    function _measBest(string memory tag, uint256 amountIn, bool dumpCd) internal {
        bytes memory cd = abi.encodeCall(
            BlazePhoenixRouter.swapBestExactIn,
            (address(tokenIn), address(tokenOut), amountIn, 1, user, block.timestamp + 1)
        );
        (uint256 z, uint256 nz) = _countBytes(cd);
        tokenIn.mint(user, amountIn);
        vm.prank(user);
        (bool okA, ) = address(tokenIn).call(abi.encodeWithSignature("approve(address,uint256)", address(router), amountIn));
        require(okA, "approve");
        _coolAll();
        vm.prank(user);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = address(router).call(cd);
        uint256 gasUsed = g0 - gasleft();
        require(ok, "swapBestExactIn failed");
        uint256 delivered = abi.decode(ret, (uint256));
        console2.log(string.concat("BENCH|meas|", tag, "|bestExactIn"));
        console2.log("BENCH|gas", gasUsed);
        console2.log("BENCH|cd_total", cd.length);
        console2.log("BENCH|cd_zero", z);
        console2.log("BENCH|cd_nonzero", nz);
        console2.log("BENCH|delivered", delivered);
        if (dumpCd) { console2.log(string.concat("BENCH|cdhex|", tag, "|bestExactIn")); console2.logBytes(cd); }
    }

    /// Solve phase alone, cold — the part path B pays and path A exports off-chain.
    function _measSolve(string memory tag, uint256 amountIn) internal {
        _coolAll();
        uint256 g0 = gasleft();
        solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);
        uint256 gasUsed = g0 - gasleft();
        console2.log(string.concat("BENCH|solve|", tag), gasUsed);
        // warm second call — the cold-access premium is the difference
        uint256 g1 = gasleft();
        solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);
        uint256 gasWarm = g1 - gasleft();
        console2.log(string.concat("BENCH|solve_warm|", tag), gasWarm);
    }

    function _runScenario(string memory tag, uint256 amountIn) internal {
        uint256 snap = vm.snapshotState();
        _measExact(tag, amountIn, true);
        require(vm.revertToState(snap), "revert snap");
        _measBest(tag, amountIn, true);
        require(vm.revertToState(snap), "revert snap2");
        _measSolve(tag, amountIn);
    }

    // ─── scenarios ──────────────────────────────────────────────────────────

    function test_Bench_S1_1hop_1leg() public {
        _seedPool(address(tokenIn), address(tokenOut), 1_000_000e18, 1_600_000e18);
        _runScenario("S1", 10_000e18);
    }

    function test_Bench_S3_1hop_3legs() public {
        for (uint256 i; i < 3; ++i)
            _seedPool(address(tokenIn), address(tokenOut), 100_000e18 * (i + 1), 160_000e18 * (i + 1));
        _runScenario("S3", 10_000e18);
    }

    function test_Bench_S5_1hop_5legs() public {
        for (uint256 i; i < 5; ++i)
            _seedPool(address(tokenIn), address(tokenOut), 100_000e18 * (i + 1), 160_000e18 * (i + 1));
        _runScenario("S5", 10_000e18);
    }

    function test_Bench_H2_2hops_1leg_each() public {
        hub.addBridge(address(bridgeToken));
        _seedPool(address(tokenIn), address(bridgeToken), 1_000_000e18, 1_000_000e18);
        _seedPool(address(bridgeToken), address(tokenOut), 1_000_000e18, 1_600_000e18);
        _runScenario("H2", 10_000e18);
    }

    function test_Bench_H2L4_2hops_2legs_each() public {
        hub.addBridge(address(bridgeToken));
        _seedPool(address(tokenIn), address(bridgeToken), 500_000e18, 500_000e18);
        _seedPool(address(tokenIn), address(bridgeToken), 800_000e18, 800_000e18);
        _seedPool(address(bridgeToken), address(tokenOut), 500_000e18, 800_000e18);
        _seedPool(address(bridgeToken), address(tokenOut), 800_000e18, 1_280_000e18);
        _runScenario("H2L4", 10_000e18);
    }

    // ─── profile: call census + repeated reads (S5, the probe-heaviest) ─────

    function _censusLog(string memory phase, VmSafe.AccountAccess[] memory recs) internal {
        for (uint256 i; i < recs.length; ++i) {
            VmSafe.AccountAccess memory r = recs[i];
            if (r.kind == VmSafe.AccountAccessKind.StaticCall || r.kind == VmSafe.AccountAccessKind.Call) {
                bytes4 sel;
                if (r.data.length >= 4) sel = bytes4(r.data);
                console2.log(string.concat(
                    "BENCH|call|", phase,
                    "|kind=", r.kind == VmSafe.AccountAccessKind.StaticCall ? "S" : "C"
                ));
                console2.log("BENCH|call_target", r.account);
                console2.log("BENCH|call_sel");
                console2.logBytes4(sel);
            }
        }
    }

    /// slots read in a record set, deduped, as (account, slot) pairs
    function _readSlots(VmSafe.AccountAccess[] memory recs)
        internal pure returns (address[] memory accts, bytes32[] memory slots, uint256 n)
    {
        uint256 cap;
        for (uint256 i; i < recs.length; ++i) cap += recs[i].storageAccesses.length;
        accts = new address[](cap);
        slots = new bytes32[](cap);
        for (uint256 i; i < recs.length; ++i) {
            for (uint256 j; j < recs[i].storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory sa = recs[i].storageAccesses[j];
                if (sa.isWrite) continue;
                bool seen;
                for (uint256 k; k < n; ++k) {
                    if (accts[k] == sa.account && slots[k] == sa.slot) { seen = true; break; }
                }
                if (!seen) { accts[n] = sa.account; slots[n] = sa.slot; n++; }
            }
        }
    }

    function test_Profile_S5_census_and_overlap() public {
        for (uint256 i; i < 5; ++i)
            _seedPool(address(tokenIn), address(tokenOut), 100_000e18 * (i + 1), 160_000e18 * (i + 1));
        uint256 amountIn = 10_000e18;

        // Phase 1: solve
        vm.startStateDiffRecording();
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);
        VmSafe.AccountAccess[] memory solveRecs = vm.stopAndReturnStateDiff();
        _censusLog("solve", solveRecs);

        // Phase 2: execute the SAME plan (what swapBestExactIn does after solving)
        tokenIn.mint(user, amountIn);
        vm.prank(user);
        (bool okA, ) = address(tokenIn).call(abi.encodeWithSignature("approve(address,uint256)", address(router), amountIn));
        require(okA, "approve");
        vm.startStateDiffRecording();
        vm.prank(user);
        router.swapExactIn(plan.best, amountIn, 1, user, block.timestamp + 1);
        VmSafe.AccountAccess[] memory execRecs = vm.stopAndReturnStateDiff();
        _censusLog("exec", execRecs);

        // Overlap: slots the execution re-reads that the solve already read
        (address[] memory aS, bytes32[] memory sS, uint256 nS) = _readSlots(solveRecs);
        (address[] memory aE, bytes32[] memory sE, uint256 nE) = _readSlots(execRecs);
        uint256 overlap;
        for (uint256 i; i < nE; ++i) {
            for (uint256 j; j < nS; ++j) {
                if (aE[i] == aS[j] && sE[i] == sS[j]) {
                    console2.log("BENCH|overlap_slot", aE[i]);
                    console2.logBytes32(sE[i]);
                    overlap++;
                    break;
                }
            }
        }
        console2.log("BENCH|slots_solve", nS);
        console2.log("BENCH|slots_exec", nE);
        console2.log("BENCH|slots_overlap", overlap);
    }

    // ─── component costs, measured in isolation (for the attribution) ───────

    function test_Components_S5() public {
        for (uint256 i; i < 5; ++i)
            _seedPool(address(tokenIn), address(tokenOut), 100_000e18 * (i + 1), 160_000e18 * (i + 1));

        _coolAll();
        uint256 g0 = gasleft();
        hub.getActivePools(address(tokenIn), address(tokenOut));
        console2.log("BENCH|comp|getActivePools_cold", g0 - gasleft());
        uint256 g1 = gasleft();
        hub.getActivePools(address(tokenIn), address(tokenOut));
        console2.log("BENCH|comp|getActivePools_warm", g1 - gasleft());

        _coolAll();
        uint256 g2 = gasleft();
        hub.discoverFor(address(tokenIn), address(tokenOut));
        console2.log("BENCH|comp|discoverFor_cold", g2 - gasleft());
        uint256 g3 = gasleft();
        hub.discoverFor(address(tokenIn), address(tokenOut));
        console2.log("BENCH|comp|discoverFor_warm", g3 - gasleft());

        _coolAll();
        uint256 g4 = gasleft();
        MockV2Pair(pools[0]).getReserves();
        console2.log("BENCH|comp|getReserves_cold", g4 - gasleft());
        uint256 g5 = gasleft();
        MockV2Pair(pools[0]).getReserves();
        console2.log("BENCH|comp|getReserves_warm", g5 - gasleft());

        uint256 g6 = gasleft();
        tokenOut.balanceOf(pools[0]);
        console2.log("BENCH|comp|balanceOf_warm", g6 - gasleft());
    }
}

contract EquationBenchTransport is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    address[] pools;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        tokenIn = new MockERC20("IN", "IN");
        tokenOut = new MockERC20("OUT", "OUT");
        for (uint256 i; i < 5; ++i) {
            MockV2Pair p = new MockV2Pair(address(tokenIn), address(tokenOut));
            tokenIn.mint(address(p), 100_000e18 * (i + 1));
            tokenOut.mint(address(p), 160_000e18 * (i + 1));
            (address t0, ) = address(tokenIn) < address(tokenOut) ? (address(tokenIn), address(tokenOut)) : (address(tokenOut), address(tokenIn));
            p.setReserves(
                uint112(address(tokenIn) == t0 ? 100_000e18 * (i + 1) : 160_000e18 * (i + 1)),
                uint112(address(tokenIn) == t0 ? 160_000e18 * (i + 1) : 100_000e18 * (i + 1))
            );
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(tokenIn), address(tokenOut));
            pools.push(address(p));
        }
    }

    function test_Transport_S5() public {
        uint256 amountIn = 10_000e18;
        bytes memory cd = abi.encodeCall(
            BlazePhoenixSolver.findBestRoutePlan, (address(tokenIn), address(tokenOut), amountIn)
        );
        // warm everything first
        solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);

        // raw staticcall, NO caller-side decode
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = address(solver).staticcall(cd);
        uint256 gasRaw = g0 - gasleft();
        require(ok);
        console2.log("BENCH|transport|raw_call_gas", gasRaw);
        console2.log("BENCH|transport|returndata_bytes", ret.length);

        // typed call WITH decode
        uint256 g1 = gasleft();
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenIn), address(tokenOut), amountIn);
        uint256 gasTyped = g1 - gasleft();
        console2.log("BENCH|transport|typed_call_gas", gasTyped);
        console2.log("BENCH|transport|decode_overhead", gasTyped - gasRaw);
        console2.log("BENCH|transport|fallback_legs", plan.hasFallback ? plan.fallbackRoute.hops.length : 0);

        // re-encode cost: what selfExecutePrePulled pays to push Route back through calldata
        uint256 g2 = gasleft();
        bytes memory enc = abi.encodeCall(
            BlazePhoenixRouter.selfExecutePrePulled,
            (plan.best, amountIn, 1, address(0xBEEF), block.timestamp + 1, address(0xBEEF))
        );
        uint256 gasEnc = g2 - gasleft();
        console2.log("BENCH|transport|reencode_gas", gasEnc);
        console2.log("BENCH|transport|reencode_bytes", enc.length);
    }
}
