// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  G7 draw base midtail-3 idx 4 (block 53,653,191): 0x532f...42e4 -> WETH, 8,806,943.08 tokens.
//  G7 lines: 8, exec `RouterE(5)` at bb4cdbb (netOut 14.5838 WETH, effectiveMinOut 13.1649 WETH,
//  one hop on four legs; leg 4, the V3 1 % pool 0xba3f...46f7, pays 6.3692 WETH).
//
//  Stack: the G7 base deploy itself (tools/g7-gas-campaign/G7Deploy.s.sol `_base`).
//  Pinned here, end to end on the tree under test:
//    door : whenever `Quoter.previewAndEncode` returns bytes for the draw, the Router settles
//           them and the user receives at least effectiveMinOut. A door that refuses is green.
//  Run with DRPC_KEY set, this file only (match-path).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {G7Deploy} from "../../tools/g7-gas-campaign/G7Deploy.s.sol";

interface IERC20G7Mt3 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract G7ErrBaseMidtail3BytesSettleTest is Test, G7Deploy {
    uint256 internal constant BLK = 53_653_191;
    uint256 internal constant AMT = 8_806_943_082_115_096_830_699_110;
    address internal constant TIN = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal user = address(0xD1A6);

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(string.concat("https://lb.drpc.live/base/", vm.envString("DRPC_KEY")), BLK);
        _base(address(this));
    }

    function _encodeAndSubmit(uint256 amt)
        internal returns (BlazePhoenixQuoter.Preview memory pv, bool hasBytes, bool settled, uint256 got)
    {
        bytes memory call;
        (pv, call) = quoter.previewAndEncode(TIN, WETH, amt, user, block.timestamp + 600);
        emit log_named_uint("amountIn", amt);
        emit log_named_uint("netOut", pv.netOut);
        emit log_named_uint("effectiveMinOut", pv.effectiveMinOut);
        emit log_named_uint("canExecute", pv.canExecute ? 1 : 0);
        if (call.length == 0) return (pv, false, false, 0);
        hasBytes = true;
        deal(TIN, user, amt);
        uint256 before = IERC20G7Mt3(WETH).balanceOf(user);
        vm.startPrank(user);
        IERC20G7Mt3(TIN).approve(address(router), amt);
        bytes memory ret;
        (settled, ret) = address(router).call(call);
        vm.stopPrank();
        got = IERC20G7Mt3(WETH).balanceOf(user) - before;
        if (!settled) emit log_named_bytes("revert", ret);
        emit log_named_uint("delivered", got);
    }

    /// @dev The draw: executable bytes settle at or above their own floor.
    function test_draw_executableBytesSettleAtTheFloor() public {
        (BlazePhoenixQuoter.Preview memory pv, bool hasBytes, bool settled, uint256 got) = _encodeAndSubmit(AMT);
        if (!hasBytes) return;
        assertTrue(settled, "door returned bytes the Router refuses");
        assertGe(got, pv.effectiveMinOut, "delivered under the floor");
    }

    /// @dev Range: a tenth and a hundredth of the draw obey the same rule.
    function test_range_executableBytesSettleAtTheFloor() public {
        for (uint256 d = 10; d <= 100; d *= 10) {
            (BlazePhoenixQuoter.Preview memory pv, bool hasBytes, bool settled, uint256 got) = _encodeAndSubmit(AMT / d);
            if (!hasBytes) continue;
            assertTrue(settled, "door returned bytes the Router refuses");
            assertGe(got, pv.effectiveMinOut, "delivered under the floor");
        }
    }
}
