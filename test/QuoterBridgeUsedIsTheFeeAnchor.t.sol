// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  BRIDGE-02 (external report, mohaseenbasha, 2026-09-04) — `pv.bridgeUsed`
//  names the bridge the fee is charged in.
//
//  The Router anchors the protocol fee on `feeHop`: the first hop whose INPUT
//  token is a registered bridge (`hub.isBridgeToken`, in hop order); a multi-hop
//  route with no bridged input is charged on every hop. The preview's
//  `bridgeUsed` field, documented as "where the fee is charged", used to name
//  hop 0's OUTPUT token instead. The two agree only when the first intermediate
//  token happens to be the bridge the Router anchors on — one topology of four.
//
//  The oracle here is the rule stated in the Router's own words with the hub as
//  the only producer, never the Quoter: each case names the expected address
//  as a literal chosen from which tokens the test registered as bridges.
//  RED on main 0752733 for the three cases where the topologies differ.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

contract QuoterBridgeUsedIsTheFeeAnchorTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixQuoter quoter;

    address constant A = address(0xA11CE);
    address constant B = address(0xB0B);
    address constant C = address(0xCA11);
    address constant D = address(0xD00D);
    uint256 constant AMT = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        // The solver is never consulted by previewRoute; any contract address satisfies the
        // constructor's code check without giving the preview a planner to lean on.
        quoter = new BlazePhoenixQuoter(address(hub), address(this));
    }

    function _leg(uint256 amountIn) private pure returns (Leg[] memory ls) {
        ls = new Leg[](1);
        ls[0] = Leg({
            pool: address(uint160(0xF001)), hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: true, stable: false,
            amountIn: amountIn, expectedOut: amountIn, auxId: bytes32(0)
        });
    }

    function _route(address[] memory path) private pure returns (Route memory r) {
        Hop[] memory hs = new Hop[](path.length - 1);
        for (uint256 h; h < hs.length; ++h) {
            hs[h] = Hop({tokenIn: path[h], tokenOut: path[h + 1], amountIn: AMT, expectedOut: AMT, legs: _leg(AMT)});
        }
        r.hops = hs;
        r.totalOut = AMT;
        r.singleOut = AMT;
    }

    function _path3(address a, address b, address c) private pure returns (address[] memory p) {
        p = new address[](3); p[0] = a; p[1] = b; p[2] = c;
    }

    /// The input token itself is a bridge: the Router anchors on hop 0, in that token.
    function test_TokenInIsABridge_TheAnchorIsHopZero() public {
        hub.addBridge(A);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(_route(_path3(A, B, C)), 0);
        assertEq(pv.topology, 1, "two hops classify as a one-bridge route");
        assertEq(pv.bridgeUsed, A, "the fee is anchored on hop 0, whose input is the bridge");
    }

    /// Only the intermediate token is a bridge: hop 1's input, which is also hop 0's output.
    function test_OnlyTheIntermediateIsABridge_TheAnchorIsHopOne() public {
        hub.addBridge(B);
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(_route(_path3(A, B, C)), 0);
        assertEq(pv.bridgeUsed, B, "the fee is anchored on hop 1, whose input is the bridge");
    }

    /// No hop has a bridged input: the fee is charged on every hop and no single bridge is named.
    function test_NoBridgeInAnyInput_NoAnchorIsNamed() public {
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(_route(_path3(A, B, C)), 0);
        assertEq(pv.topology, 1, "topology is the hop count, whatever the regime");
        assertEq(pv.bridgeUsed, address(0), "a route charged on every hop names no bridge");
    }

    /// Three hops with the bridge two hops in: the anchor is the first bridged INPUT, hop 2's.
    function test_ThreeHops_TheAnchorIsTheFirstBridgedInput() public {
        hub.addBridge(C);
        address[] memory p = new address[](4);
        p[0] = A; p[1] = B; p[2] = C; p[3] = D;
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(_route(p), 0);
        assertEq(pv.topology, 2, "three hops classify as a two-bridge route");
        assertEq(pv.bridgeUsed, C, "the first hop whose input is a bridge is hop 2");
    }

    /// A single hop is charged once, on whichever side is the bridge; no bridge is named.
    function test_SingleHop_NamesNoBridge() public {
        hub.addBridge(A);
        address[] memory p = new address[](2);
        p[0] = A; p[1] = B;
        BlazePhoenixQuoter.Preview memory pv = quoter.previewRoute(_route(p), 0);
        assertEq(pv.topology, 0, "one hop is direct");
        assertEq(pv.bridgeUsed, address(0), "a direct route names no bridge");
    }
}
