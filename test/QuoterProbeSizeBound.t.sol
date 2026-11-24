// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The input probe asks a pool only a size it can sign.
//
// `Quoter._inputTaxed` runs a concentrated leg backwards for exactly the leg's input: it calls
// `swap(this, !zfo, -int256(sizeIn), limit, "")`, a negative amount, exact output. An explicit
// `int256(uint256)` does not revert in 0.8; past `type(int256).max` it reinterprets the bits as a
// negative number, so the negation is a POSITIVE amount, exact input of a garbage size, the other
// question (and at 2^255 exactly the negation overflows: Panic 0x11). So `_inputTaxed` returns
// "no measurement" for such a size, and no measurement is not a tax.
//
// Reachable: `previewRouteExact` takes the caller's route and amountIn, and a concentrated leg
// whose pool refuses the dry-run is priced on the plan's own claim (`_priceLeg`, capped at
// ratio 1), whatever the leg's input. The caller is promised its own claim; the Router measures
// the fill. The probe must not turn that input into a question the pool answers differently.
//
// The pool here refuses every dry-run and answers "taxed" to a positive amount in the probe's
// (inverse) direction: under the guard it is asked only a negative amount, so its answer cannot
// move the scalar.
//
// Matrix: range {int256.max (control, asked, refused), int256.max + 1 = 2^255, 2^255 ..
//               uint256.max (fuzz)}
//       x vector {a pool that refuses the dry-run and answers a positive inverse size as taxed}
//       x door {previewRouteExact}. Mutants: «Quoter:718», «Quoter probe size», and the probe
//       run with a positive amount (caixa-1123 quoter-inputtax-probe b) on the control.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Refuses every dry-run; answers a positive amount in the probe's direction (exact input,
/// backwards) with the probe's own verdict, "taxed".
contract PositiveSizeTaxedPool {
    address public immutable token0;
    address public immutable token1;
    bool public immutable probeDir;

    constructor(address tIn, address other) {
        (token0, token1) = tIn < other ? (tIn, other) : (other, tIn);
        probeDir = tIn != token0; // !zfo
    }

    function swap(address, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external view returns (int256, int256)
    {
        if (amountSpecified > 0 && zeroForOne == probeDir) revert BlazePhoenixQuoter.InputProbe(true);
        revert("no dry-run");
    }
}

contract QuoterProbeSizeBoundTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    PositiveSizeTaxedPool pool;

    uint256 constant CLAIM = 1e18;
    uint256 constant I256_MAX = uint256(type(int256).max);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(this), address(solver), address(quoter)); // the preview asks the seated Router whether it is live
        vm.mockCall(address(this), abi.encodeWithSignature("paused()"), abi.encode(false)); // the seated Router (this test) answers: live
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        pool = new PositiveSizeTaxedPool(address(tA), address(tB));
    }

    function _route(uint256 amountIn) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 0, zeroForOne: address(tA) == pool.token0(), stable: false,
            amountIn: amountIn, expectedOut: CLAIM, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: amountIn,
            expectedOut: CLAIM, legs: legs});
        r = Route({hops: hops, totalOut: CLAIM, singleOut: CLAIM, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _exactOut(uint256 amountIn) internal returns (uint256 out, uint256 legIn) {
        (Route memory r, uint256 o) = quoter.previewRouteExact(_route(amountIn), amountIn);
        return (o, r.hops[0].legs[0].amountIn);
    }

    /// One wei past what a signed amount holds (2^255, whose negation overflows): the probe is
    /// not asked, so neither a Panic nor the pool's answer to a positive size moves the scalar.
    function test_AnInputOneWeiPastInt256MaxIsNotProbed() public {
        (uint256 out, uint256 legIn) = _exactOut(I256_MAX + 1);
        assertEq(legIn, I256_MAX + 1, "precondition: the leg keeps its input");
        assertGt(out, 0, "a size past int256.max was asked of the pool");
    }

    function testFuzz_AnInputPastInt256MaxIsNotProbed(uint256 amountIn) public {
        amountIn = bound(amountIn, I256_MAX + 1, type(uint256).max);
        (uint256 out, uint256 legIn) = _exactOut(amountIn);
        assertEq(legIn, amountIn, "precondition: the leg keeps its input");
        assertGt(out, 0, "a size past int256.max was asked of the pool as a positive amount");
    }

    /// Control: at int256.max the size is signable, asked as exact output (negative), and
    /// refused: no measurement, not a tax. The pool's "taxed" answer is reserved for positive
    /// sizes.
    function test_Control_AnInputAtInt256MaxIsAskedAndRefused() public {
        (uint256 out, uint256 legIn) = _exactOut(I256_MAX);
        assertEq(legIn, I256_MAX, "precondition: the leg keeps its input");
        assertGt(out, 0, "a refused probe read as a tax");
    }
}
