// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE QUOTER READS ONLY ITS OWN PAYLOAD.
//
//  The exact pass dry-runs a concentrated or V4 leg by letting the venue call
//  back into the Quoter, which reverts with the two deltas; the catch decodes
//  them as the quote. Red at f909422: the catch accepted ANY 64-byte revert as
//  that payload, so a venue whose own revert data happened to be two words was
//  read as a quote it never made (the deltas were never produced by our
//  callback). The callbacks now revert with a tagged custom error,
//  QuoteDeltas(int256,int256), and the catch reads only an exact 68-byte
//  payload under that tag; anything else is no quote and the leg falls back to
//  the plan-time approximation.
//
//  What the tag does NOT do, stated so no test pretends otherwise: it does not
//  authenticate a hostile venue. A pool can call the callback itself with any
//  deltas (the QuoterV2 trust model; the preview is advisory and execution
//  measures its own delivery). The property here is narrower: bytes that did
//  not come out of our callback are never decoded as deltas.
//
//  Observable, as in QuoterExactRefusalBranches: at scale 1 a refusal returns
//  EXACTLY the planted DECOY_OUT; a measurement returns the venue's Q_OUT.
//  Oracle: the constants planted by the test, never the Quoter's own math.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {EchoConcPool, MockSolverQ, MockHubQ, MockV4ManagerQ} from "./QuoterExactRefusalBranches.t.sol";

/// @dev A concentrated venue whose swap reverts with whatever bytes it holds,
///      without ever calling the Quoter back.
contract BlobRevertConcPool {
    bytes internal blob;
    function setBlob(bytes memory b) external { blob = b; }
    function swap(address, bool, int256, uint160, bytes calldata) external view returns (int256, int256) {
        bytes memory b = blob;
        assembly { revert(add(b, 32), mload(b)) }
    }
}

/// @dev A V4 manager whose unlock reverts with whatever bytes it holds,
///      without ever calling the Quoter back.
contract BlobRevertV4Manager {
    bytes internal blob;
    function setBlob(bytes memory b) external { blob = b; }
    function unlock(bytes calldata) external view returns (bytes memory) {
        bytes memory b = blob;
        assembly { revert(add(b, 32), mload(b)) }
    }
}

contract QuoterReadsOnlyItsOwnPayloadTest is Test {
    /// A foreign custom error with the same two-word shape as the tag.
    error ForeignTwoWords(int256 a, int256 b);
    /// The Quoter's tag, re-declared from its signature so the test does not
    /// read the selector from the code under test.
    error QuoteDeltas(int256 d0, int256 d1);

    BlazePhoenixQuoter quoter;
    MockSolverQ solverMock;
    MockHubQ hubMock;
    MockERC20 tokA;
    MockERC20 tokB;

    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SP = 60;
    uint256 constant AMT = 1e18;
    uint256 constant DECOY_OUT = 4_242e18;
    uint256 constant Q_OUT = 777e18;

    function setUp() public {
        tokA = new MockERC20("A", "A");
        tokB = new MockERC20("B", "B");
        solverMock = new MockSolverQ();
        hubMock = new MockHubQ();
        quoter = new BlazePhoenixQuoter(address(hubMock), address(solverMock));
    }

    // --- builders (same shapes as QuoterExactRefusalBranches) ---------------

    function _leg(uint8 kind_, address pool_) internal pure returns (Leg memory l) {
        l = Leg({
            pool: pool_, hooks: address(0), kind: kind_, fee: POOL_FEE, tickSpacing: TICK_SP,
            zeroForOne: true, stable: false, amountIn: AMT, expectedOut: DECOY_OUT, auxId: bytes32(0)
        });
    }

    function _v4Leg() internal view returns (Leg memory l) {
        l = _leg(BPC.KIND_V4, address(0));
        l.auxId = bytes32(uint256(uint160(address(tokB))));
        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokB));
        l.zeroForOne = address(tokA) == c0;
        l.pool = address(uint160(uint256(BPC.computeV4PoolId(c0, c1, l.fee, l.tickSpacing, l.hooks))));
    }

    function _exact(Leg memory l) internal returns (uint256) {
        Leg[] memory ls = new Leg[](1);
        ls[0] = l;
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(tokA), tokenOut: address(tokB), amountIn: AMT, expectedOut: 0, legs: ls});
        solverMock.setBest(Route({
            hops: hs, totalOut: 0, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        }));
        (Route memory back,) = quoter.previewPlanExact(address(tokA), address(tokB), AMT);
        return back.totalOut;
    }

    /// Both words carry the receive amount in the sign each venue family uses
    /// for "the quoter receives", so the payload reads as Q_OUT whichever side
    /// the leg's direction picks.
    function _concWords() internal pure returns (int256, int256) { return (-int256(Q_OUT), -int256(Q_OUT)); }
    function _v4Words() internal pure returns (int256, int256) { return (int256(Q_OUT), int256(Q_OUT)); }

    function _conc(bytes memory blob) internal returns (uint256) {
        BlobRevertConcPool pool = new BlobRevertConcPool();
        pool.setBlob(blob);
        return _exact(_leg(BPC.KIND_V3, address(pool)));
    }

    function _v4(bytes memory blob) internal returns (uint256) {
        BlobRevertV4Manager mgr = new BlobRevertV4Manager();
        mgr.setBlob(blob);
        hubMock.setV4PoolManager(address(mgr));
        return _exact(_v4Leg());
    }

    // --- the property --------------------------------------------------------

    /// RED at f909422: a pool's own two-word revert was decoded as a quote of Q_OUT.
    function test_Conc_UntaggedTwoWordRevert_IsNoQuote() public {
        (int256 a, int256 b) = _concWords();
        assertEq(_conc(abi.encode(a, b)), DECOY_OUT, "an untagged two-word pool revert is not a quote");
    }

    /// RED at f909422: same, on the V4 dry-run.
    function test_V4_UntaggedTwoWordRevert_IsNoQuote() public {
        (int256 a, int256 b) = _v4Words();
        assertEq(_v4(abi.encode(a, b)), DECOY_OUT, "an untagged two-word manager revert is not a quote");
    }

    /// Watches the tag check: same length as the payload, another selector.
    function test_Conc_ForeignTwoWordError_IsNoQuote() public {
        (int256 a, int256 b) = _concWords();
        assertEq(_conc(abi.encodeWithSelector(ForeignTwoWords.selector, a, b)), DECOY_OUT,
            "a foreign error of the payload's length is not a quote");
    }

    /// Watches the length check: the right tag with a trailing word.
    function test_Conc_TaggedPayloadOfTheWrongLength_IsNoQuote() public {
        (int256 a, int256 b) = _concWords();
        assertEq(_conc(abi.encodePacked(abi.encodeWithSelector(QuoteDeltas.selector, a, b), uint256(1))), DECOY_OUT,
            "a tagged payload that is not exactly the tag and two words is not a quote");
    }

    /// Fuzz: no untagged revert data of any length or content is ever read as
    /// a quote, on either dry-run.
    function testFuzz_NoUntaggedRevert_IsAQuote(bytes memory blob) public {
        vm.assume(blob.length < 4 || bytes4(blob) != QuoteDeltas.selector);
        assertEq(_conc(blob), DECOY_OUT, "untagged conc revert read as a quote");
        assertEq(_v4(blob), DECOY_OUT, "untagged V4 revert read as a quote");
    }

    /// Fuzz over the two words: whatever a foreign two-word error says, it is no quote.
    function testFuzz_ForeignTwoWordError_IsNeverAQuote(int256 a, int256 b) public {
        bytes memory blob = abi.encodeWithSelector(ForeignTwoWords.selector, a, b);
        assertEq(_conc(blob), DECOY_OUT, "foreign conc error read as a quote");
        assertEq(_v4(blob), DECOY_OUT, "foreign V4 error read as a quote");
    }

    // --- the neighbouring legitimate path still prices -----------------------

    /// Control: a pool that answers through the callback is still priced, on
    /// both dry-runs, so the refusals above are the tag and not a broken decode.
    function test_CallbackRoundTrip_IsStillPriced() public {
        EchoConcPool pool = new EchoConcPool();
        pool.setQuoteOut(int256(Q_OUT));
        assertEq(_exact(_leg(BPC.KIND_V3, address(pool))), Q_OUT, "a callback-delivered conc quote must be read");

        MockV4ManagerQ mgr = new MockV4ManagerQ();
        mgr.setQuoteOut(int256(Q_OUT));
        (address c0, address c1) = BPC.sortTokens(address(tokA), address(tokB));
        mgr.setExpectedKey(c0, c1, POOL_FEE, TICK_SP, address(0));
        hubMock.setV4PoolManager(address(mgr));
        assertEq(_exact(_v4Leg()), Q_OUT, "a callback-delivered V4 quote must be read");
    }
}
