// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The input probe asks a pool only a size it can sign.
//
// `Quoter._inputTaxed` runs a concentrated leg backwards on the leg's output: it calls
// `swap(this, !zfo, int256(sizeOut), limit, "")`, a positive amount, exact input. An explicit
// `int256(uint256)` does not revert in 0.8; past `type(int256).max` it reinterprets the bits as a
// negative amount, and a negative amount is the other question: exact OUTPUT of a garbage size.
// So `_inputTaxed` returns "no measurement" for such a size, and no measurement is not a tax.
//
// Reachable: `previewRouteExact` takes the caller's route, and a concentrated leg whose pool
// refuses the dry-run is priced on the plan's own claim (`_priceLeg`, capped at ratio 1), so at
// legIn == leg.amountIn its output is the caller's `expectedOut`, whatever its size. The caller
// is promised its own claim; the Router measures the fill. The probe must not turn that claim
// into a question the pool answers differently.
//
// The pool here refuses every dry-run and answers "taxed" to any negative amount: under the guard
// it is never asked a negative amount, so its answer cannot move the scalar.
//
// Matrix: range {int256.max (control, asked, refused), int256.max + 1, 2^255 .. uint256.max (fuzz)}
//       x vector {a pool that refuses the dry-run and answers a negative size as taxed}
//       x door {previewRouteExact}. Mutant: «Quoter:671».

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Refuses every dry-run; answers a negative amount (exact output) with the probe's own verdict,
/// "taxed".
contract NegativeSizeTaxedPool {
    address public immutable token0;
    address public immutable token1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function swap(address, bool, int256 amountSpecified, uint160, bytes calldata)
        external pure returns (int256, int256)
    {
        if (amountSpecified < 0) revert BlazePhoenixQuoter.InputProbe(true);
        revert("no dry-run");
    }
}

contract QuoterProbeSizeBoundTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixQuoter quoter;
    MockERC20 tA;
    MockERC20 tB;
    NegativeSizeTaxedPool pool;

    uint256 constant AMOUNT_IN = 1e18;
    uint256 constant I256_MAX = uint256(type(int256).max);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(0x7001), address(solver), address(quoter));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        pool = new NegativeSizeTaxedPool(address(tA), address(tB));
    }

    function _route(uint256 claimedOut) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({pool: address(pool), hooks: address(0), kind: BPC.KIND_V3, fee: 3000,
            tickSpacing: 0, zeroForOne: address(tA) == pool.token0(), stable: false,
            amountIn: AMOUNT_IN, expectedOut: claimedOut, auxId: bytes32(0)});
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tA), tokenOut: address(tB), amountIn: AMOUNT_IN,
            expectedOut: claimedOut, legs: legs});
        r = Route({hops: hops, totalOut: claimedOut, singleOut: claimedOut, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _exactOut(uint256 claimedOut) internal returns (uint256 out, uint256 legOut) {
        (Route memory r, uint256 o) = quoter.previewRouteExact(_route(claimedOut), AMOUNT_IN);
        return (o, r.hops[0].legs[0].expectedOut);
    }

    /// One wei past what a signed amount holds: the probe is not asked, so the pool's answer to a
    /// negative size cannot zero the scalar.
    function test_AnOutputOneWeiPastInt256MaxIsNotProbed() public {
        (uint256 out, uint256 legOut) = _exactOut(I256_MAX + 1);
        assertEq(legOut, I256_MAX + 1, "precondition: the refused leg is priced on its own claim");
        assertGt(out, 0, "a size past int256.max was asked of the pool as a negative amount");
    }

    function testFuzz_AnOutputPastInt256MaxIsNotProbed(uint256 claimedOut) public {
        claimedOut = bound(claimedOut, I256_MAX + 1, type(uint256).max);
        (uint256 out, uint256 legOut) = _exactOut(claimedOut);
        assertEq(legOut, claimedOut, "precondition: the refused leg is priced on its own claim");
        assertGt(out, 0, "a size past int256.max was asked of the pool as a negative amount");
    }

    /// Control: at int256.max the size is signable, asked as exact input, and refused: no
    /// measurement, not a tax. The pool's "taxed" answer is reserved for negative sizes.
    function test_Control_AnOutputAtInt256MaxIsAskedAndRefused() public {
        (uint256 out, uint256 legOut) = _exactOut(I256_MAX);
        assertEq(legOut, I256_MAX, "precondition: the refused leg is priced on its own claim");
        assertGt(out, 0, "a refused probe read as a tax");
    }
}
