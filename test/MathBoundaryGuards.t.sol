// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// D10 GUARDS AT THE BOUNDARY BETWEEN THE SOLVER AND `BlazePhoenixMath`.
//
// G1  ONE CALL PER HOP, TO THE LINKED ADDRESS. The address is a PUSH20 the linker writes at the
//     call site (no storage, no setter). Each hop built over two or more candidates enters the
//     library once, through `select`; a lone candidate never enters it. Measured on the trace.
// G2  THE CODE IS PINNED AT DEPLOY. The constructor refuses (SolverE(6)) unless the code at the
//     linked address is the library this Solver was compiled against: no code, one byte changed
//     or another contract's code all refuse.
// G3  THE ANSWER HAS EXACTLY THE CANONICAL LENGTH. The ABI decoder accepts a longer returndata,
//     so the hop compares the length with the encoding of what it decoded (SolverE(7)).
//
// The meta-guard - the whole answer compared, to the wei, with the Solver of 59ecf3f - is
// test/MathBoundarySameAnswer.t.sol.

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixMath} from "../src/BlazePhoenixMath.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";

/// Stands at the library's address and answers with the real library's answer (run from
/// `real`, in the caller's context) followed by `pad` zero bytes.
contract PaddedMath {
    address immutable real;
    uint256 immutable pad;

    constructor(address r, uint256 p) { real = r; pad = p; }

    fallback() external {
        address r = real;
        uint256 p = pad;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), r, 0, calldatasize(), 0, 0)
            let n := returndatasize()
            returndatacopy(0, 0, n)
            if iszero(ok) { revert(0, n) }
            calldatacopy(n, calldatasize(), p)
            return(0, add(n, p))
        }
    }
}

contract MathBoundaryGuardsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    address tA;
    address tB;

    uint256 constant AMT = 50_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        hub.setRoles(address(this), address(solver), address(this));
        tA = address(new MockERC20("A", "A"));
        tB = address(new MockERC20("B", "B"));
    }

    function _v2(address a, address b, uint256 ra, uint256 rb) internal {
        MockV2Pair p = new MockV2Pair(a, b);
        MockERC20(a).mint(address(p), ra);
        MockERC20(b).mint(address(p), rb);
        (uint256 r0, uint256 r1) = p.token0() == a ? (ra, rb) : (rb, ra);
        p.setReserves(uint112(r0), uint112(r1));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), a, b);
    }

    /// Three books on the pair: one hop, built over three candidates.
    function _threeBooks() internal {
        _v2(tA, tB, 400_000e18, 400_000e18);
        _v2(tA, tB, 300_000e18, 301_000e18);
        _v2(tA, tB, 200_000e18, 199_000e18);
    }

    /// One bridge with `perSide` books on each side of it.
    function _bridge(uint256 perSide) internal {
        address x = address(new MockERC20("X", "X"));
        hub.addBridge(x);
        for (uint256 i; i < perSide; ++i) {
            _v2(tA, x, 500_000e18 * (i + 1), 500_000e18 * (i + 1));
            _v2(x, tB, 500_000e18 * (i + 1), 502_000e18 * (i + 1));
        }
    }

    /// The solve, traced: how many delegatecalls entered the library, each through `select`.
    function _selects() internal returns (uint256 k) {
        vm.startStateDiffRecording();
        solver.findBestRoutePlan(tA, tB, AMT);
        VmSafe.AccountAccess[] memory recs = vm.stopAndReturnStateDiff();
        for (uint256 i; i < recs.length; ++i) {
            if (recs[i].kind != VmSafe.AccountAccessKind.DelegateCall) continue;
            if (bytes4(recs[i].data) == BlazePhoenixMath.select.selector) {
                assertEq(recs[i].account, address(BlazePhoenixMath), "select runs at the linked address");
                ++k;
            } else {
                assertTrue(recs[i].account != address(BlazePhoenixMath), "the Solver enters the library only through select");
            }
        }
    }

    // ─── G1 ──────────────────────────────────────────────────────────────────

    /// The direct hop and both stages of the bridge route each have two or more candidates:
    /// three hops built, three calls (the bridge's second stage takes no second pass here:
    /// constant-product books leave no capacity upside, so its rank is its promise).
    function test_D10_G1_OneLibraryCallPerHopBuilt() public {
        _threeBooks();
        _bridge(2);
        assertEq(_selects(), 3, "one select per hop built over two or more candidates");
    }

    /// The bridge stages have one candidate each: they are quoted without the library, and only
    /// the direct hop calls it.
    function test_D10_G1_ALoneCandidateNeverEntersTheLibrary() public {
        _threeBooks();
        _bridge(1);
        assertEq(_selects(), 1, "a hop over one candidate does not call the library");
    }

    // ─── G2 ──────────────────────────────────────────────────────────────────

    function _refusesToDeploy(string memory why) internal {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(6)));
        new BlazePhoenixSolver(address(hub), address(0));
        emit log_named_string("refused", why);
    }

    function test_D10_G2_TheLibraryCompiledAgainstIsWhatDeploys() public {
        assertEq(address(BlazePhoenixMath).codehash, keccak256(type(BlazePhoenixMath).runtimeCode),
            "precondition: the linked address holds the library");
        BlazePhoenixSolver s = new BlazePhoenixSolver(address(hub), address(0));
        assertGt(address(s).code.length, 0, "the Solver deploys over its own library");
    }

    function test_D10_G2_NoCodeAtTheLinkedAddressRefusesToDeploy() public {
        vm.etch(address(BlazePhoenixMath), "");
        _refusesToDeploy("no code at the linked address");
    }

    function test_D10_G2_OneByteChangedRefusesToDeploy() public {
        bytes memory code = address(BlazePhoenixMath).code;
        code[code.length / 2] = code[code.length / 2] ^ 0x01;
        vm.etch(address(BlazePhoenixMath), code);
        _refusesToDeploy("one byte of the library changed");
    }

    function test_D10_G2_AnotherContractsCodeRefusesToDeploy() public {
        address real = address(0xD10A);
        vm.etch(real, address(BlazePhoenixMath).code);
        vm.etch(address(BlazePhoenixMath), address(new PaddedMath(real, 0)).code);
        _refusesToDeploy("a forwarder that answers exactly what the library answers");
    }

    // ─── G3 ──────────────────────────────────────────────────────────────────

    /// The real library moves to `real`; a forwarder takes its address, after the Solver was
    /// deployed (G2 is a deploy-time pin, G3 is checked on every call).
    function _forwarder(uint256 pad) internal {
        address real = address(0xD10A);
        vm.etch(real, address(BlazePhoenixMath).code);
        vm.etch(address(BlazePhoenixMath), address(new PaddedMath(real, pad)).code);
    }

    /// Control: a forwarder that pads nothing gives the plan the library gives.
    function test_D10_G3_AnExactAnswerIsTheSamePlan() public {
        _threeBooks();
        RoutePlan memory want = solver.findBestRoutePlan(tA, tB, AMT);
        _forwarder(0);
        RoutePlan memory got = solver.findBestRoutePlan(tA, tB, AMT);
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(want)), "the forwarder alone changes nothing");
    }

    function test_D10_G3_AWordPastTheAnswerIsRefused() public {
        _threeBooks();
        _forwarder(32);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(7)));
        solver.findBestRoutePlan(tA, tB, AMT);
    }

    function test_D10_G3_OneBytePastTheAnswerIsRefused() public {
        _threeBooks();
        _forwarder(1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixSolver.SolverE.selector, uint16(7)));
        solver.findBestRoutePlan(tA, tB, AMT);
    }
}
