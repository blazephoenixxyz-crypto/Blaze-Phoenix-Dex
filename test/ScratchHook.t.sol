// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PricedV4Manager} from "./RouteIntegrityV4.t.sol";
import {HookForge} from "./HookAdmissionByBits.t.sol";
contract ScratchHookTest is Test {
    function test_Scratch() public {
        PricedV4Manager mgr = new PricedV4Manager();
        BlazePhoenixHub hub = new BlazePhoenixHub(address(this)); hub.initialize(address(this), address(mgr));
        BlazePhoenixRouter router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        MockERC20 tokA = new MockERC20("A","A"); MockERC20 tokB = new MockERC20("B","B");
        (address c0, address c1) = address(tokA) < address(tokB) ? (address(tokA), address(tokB)) : (address(tokB), address(tokA));
        address user = address(0xBEEF);
        MockERC20(c0).mint(user, 100e18); MockERC20(c1).mint(address(mgr), 1_000e18);
        vm.prank(user); MockERC20(c0).approve(address(router), type(uint256).max);
        address h = new HookForge().deploy(1 << 7, (1 << 3) | (1 << 2));
        bytes32 pid = BPC.computeV4PoolId(c0, c1, 3000, 60, h);
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96))); mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(1e30)));
        uint256 rate = bound(uint256(9300), 0, 1200); uint256 minOut = bound(uint256(28424113065089315483097683), 1, 1e18);
        console2.log("rate", rate); console2.log("minOut", minOut);
        mgr.setRate(pid, rate);
        uint256 amt = 1e18; uint256 promised = BPC.v4LegOut(address(mgr), pid, amt, 3000, 60, true);
        console2.log("promised", promised);
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({ pool: address(uint160(uint256(pid))), hooks: h, kind: BPC.KIND_V4, fee: 3000, tickSpacing: 60, zeroForOne: true, stable: false, amountIn: amt, expectedOut: promised, auxId: bytes32(uint256(uint160(c1))) });
        Hop[] memory hops = new Hop[](1); hops[0] = Hop({ tokenIn: c0, tokenOut: c1, amountIn: amt, expectedOut: promised, legs: legs });
        Route memory r = Route({ hops: hops, totalOut: promised, singleOut: promised, singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false });
        vm.prank(user);
        try router.swapExactIn(r, amt, minOut, user, block.timestamp + 1) returns (uint256 got) { console2.log("settled", got); }
        catch (bytes memory err) { console2.log("revert len", err.length); if (err.length >= 36) { uint256 code; assembly { code := mload(add(err, 36)) } console2.log("selector-ish word", code); } console2.logBytes(err); }
    }
}
