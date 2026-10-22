// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// THE FALLBACK'S VALUE GUARD, OBSERVED ON ITS OWN.
//
// `fallback() external payable` (src/BlazePhoenixRouter.sol) is the door every
// V3-shaped callback comes through, and it opens with two guards that answer the same code:
//         if (msg.value > 0) revert RouterE(3);
//         if (msg.data.length < 4 + 64) revert RouterE(3);
// The length guard has its own mutants and tests. The value guard had no fixture: the suite's
// only ETH transfer to the Router carries EMPTY calldata, which Solidity routes to `receive()`,
// not to the fallback, and every call that does reach the fallback is a mock callback without
// value. This file sends ETH WITH calldata long enough to pass the length guard, so the value
// guard is the one that must close the door.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract FallbackValueGuardIsObservedAloneTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)
        );
        hub.setRoles(address(router), address(solver), address(this));
    }

    /// The `RouterE(n)` code carried by a raw call's revert data. `RouterE(uint16)` is a custom
    /// error with one argument: 4 selector bytes + one 32-byte word. The selector is the top
    /// four bytes of the first word; the code is the word starting at data offset 4.
    function _routerECode(bytes memory ret) internal pure returns (uint256) {
        if (ret.length < 36) return type(uint256).max;
        uint256 sel;
        uint256 code;
        assembly {
            sel := mload(add(ret, 32))
            code := mload(add(ret, 36))
        }
        if (bytes4(bytes32(sel)) != BlazePhoenixRouter.RouterE.selector) return type(uint256).max;
        return code;
    }

    function _callDoor(uint256 value, bytes memory data) internal returns (uint256 code) {
        vm.deal(address(this), value);
        (bool ok, bytes memory ret) = address(router).call{value: value}(data);
        assertFalse(ok, "premise: the door must close (this test does not measure a success)");
        code = _routerECode(ret);
    }

    /// ETH with calldata of at least 68 bytes: the length guard lets it through, so only the
    /// value guard (:1997) can refuse it with RouterE(3).
    function test_EthWithLongCalldata_IsRefusedByTheValueGuard() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(0), uint256(0)); // 4+64
        assertGe(data.length, 4 + 64, "premise: the calldata passes the length guard");
        uint256 code = _callDoor(1 wei, data);
        assertEq(code, 3, "with ETH attached, the door must close with RouterE(3)");
    }

    /// CONTROL, and a positive control of the decoder: empty calldata with ETH reaches
    /// `receive()`, not the fallback, and must also close with RouterE(3). Without it a broken
    /// `_routerECode` would go unnoticed above.
    function test_Control_EmptyCalldataWithEth_ReachesReceiveAndCloses() public {
        uint256 code = _callDoor(1 ether, "");
        assertEq(code, 3, "empty calldata with ETH also closes with RouterE(3)");
    }
}
