// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  PcTraceProbe — records what the SHIPPED binary executes.
//
//  Every coverage figure in this repository is measured on the coverage build,
//  a different binary from the one that deploys. This probe records an
//  opcode-level trace of real swaps through the Router built under the
//  RELEASE profile, with `vm.startDebugTraceRecording`, and writes it under
//  out/pc-trace/ for `.github/scripts/assurance/pc_trace.py`, which replays
//  the program counter against the release artefacts and reports which
//  instructions of the code that ships were actually executed.
//
//  Opt-in: the recording returns hundreds of thousands of words through a
//  cheatcode and is not part of the ordinary suite. Record with
//
//      PC_TRACE=1 FOUNDRY_PROFILE=release forge test --match-contract PcTraceProbe -vvv
//
//  and read with `python3 .github/scripts/assurance/pc_trace.py --check`.
//
//  Ground truth the reader must re-find: a second Router is deployed here and
//  never called; its address is declared `never` in the trace header, and the
//  reader fails if any frame ran its code. The one that is called must cross
//  the reentrancy lock (a TLOAD and two distinct TSTORE sites) or the reader
//  refuses the trace as not being the swap it claims.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

contract PcTraceProbeTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    BlazePhoenixRouter neverCalled;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockV2Pair pair;
    address user = address(0xBEEF);

    string constant DIR = "out/pc-trace";

    // address -> small index, so a step line is a few bytes instead of a 42-char address
    address[] seen;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        pair = new MockV2Pair(address(tokenIn), address(tokenOut));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        neverCalled = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2)
        );
        tokenIn.mint(address(pair), 10_000e18);
        tokenOut.mint(address(pair), 10_000e18);
        pair.setReserves(10_000e18, 10_000e18);
        tokenIn.mint(user, 3_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _buildRoute(uint256 amountIn, uint256 claimedTotalOut) private view returns (Route memory route) {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: zeroForOne, stable: false,
            amountIn: amountIn, expectedOut: claimedTotalOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, expectedOut: claimedTotalOut, legs: legs
        });
        route = Route({
            hops: hops, totalOut: claimedTotalOut, singleOut: claimedTotalOut,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    function _netIn(uint256 a) internal pure returns (uint256) { return a - (a * 28) / 10_000; }

    function _idx(address a) private returns (uint256) {
        for (uint256 i; i < seen.length; ++i) if (seen[i] == a) return i;
        seen.push(a);
        return seen.length - 1;
    }

    function _header(string memory path) private {
        vm.writeFile(path, "");
        vm.writeLine(path, string.concat("# router ", vm.toString(address(router))));
        vm.writeLine(path, string.concat("# hub ", vm.toString(address(hub))));
        vm.writeLine(path, string.concat("# pair ", vm.toString(address(pair))));
        vm.writeLine(path, string.concat("# never ", vm.toString(address(neverCalled))));
    }

    function _dump(string memory path, Vm.DebugStep[] memory steps) private {
        for (uint256 i; i < steps.length; ++i) {
            Vm.DebugStep memory s = steps[i];
            uint256 op = uint256(s.opcode);
            uint256 a = _idx(s.contractAddr);
            if (op == 0x56 || op == 0x57 || op == 0xf1 || op == 0xf2 || op == 0xf4 || op == 0xfa) {
                uint256 s0 = s.stack.length > 0 ? s.stack[0] : type(uint256).max;
                uint256 s1 = s.stack.length > 1 ? s.stack[1] : type(uint256).max;
                vm.writeLine(path, string.concat(
                    vm.toString(a), " ", vm.toString(op), " ", vm.toString(uint256(s.depth)),
                    " ", vm.toString(s0), " ", vm.toString(s1)));
            } else {
                vm.writeLine(path, string.concat(
                    vm.toString(a), " ", vm.toString(op), " ", vm.toString(uint256(s.depth))));
            }
        }
        for (uint256 i; i < seen.length; ++i) {
            vm.writeLine(path, string.concat("# addr ", vm.toString(i), " ", vm.toString(seen[i])));
        }
        vm.writeLine(path, string.concat("# steps ", vm.toString(steps.length)));
    }

    /// One honest V2 swap through `swapExactIn`, the calldata door. The delivered
    /// amount is asserted so a trace of a reverted call can never be mistaken for one.
    function test_Trace_SwapExactIn_V2() public {
        if (!vm.envOr("PC_TRACE", false)) { vm.skip(true); return; }
        vm.createDir(DIR, true);
        string memory path = string.concat(DIR, "/swapExactIn_v2.txt");
        _header(path);

        uint256 amountIn = 1_000e18;
        uint256 realQuote = BPC.outV2(_netIn(amountIn), 10_000e18, 10_000e18, 30);
        Route memory route = _buildRoute(amountIn, realQuote);

        vm.startDebugTraceRecording();
        vm.prank(user);
        uint256 delivered = router.swapExactIn(route, amountIn, 1, user, block.timestamp + 1);
        Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();
        assertGt(delivered, 0, "the traced swap must deliver");
        _dump(path, steps);
    }
}
