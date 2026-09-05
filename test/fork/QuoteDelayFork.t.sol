// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// A quote taken through the ABI against LIVE Base liquidity, executed 0..10 s later — with and
// without someone else trading the same pools in between. Guarantees asserted: time alone never
// breaks a quote inside its deadline; a settlement never delivers below the attested floor; a
// stale quote is either settled inside the floor or refused with RouterE(5), never a third way.
// Needs DRPC_KEY (skips without it).
//
// forge test --match-path test/fork/QuoteDelayFork.t.sol -vv
import {Test, console2} from "forge-std/Test.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

interface IERC20QD { function approve(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

contract QuoteDelayForkTest is Test {
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router; BlazePhoenixQuoter quoter;
    address user = address(0xBEEF);
    address whale = address(0xB16);

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base");
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
        deal(BASE_USDC, user, 100_000e6);
        deal(BASE_USDC, whale, 10_000_000e6);
        vm.prank(user); IERC20QD(BASE_USDC).approve(address(router), type(uint256).max);
        vm.prank(whale); IERC20QD(BASE_USDC).approve(address(router), type(uint256).max);
    }

    function _routerCode(bytes memory ret) private pure returns (uint16 code, bool isR) {
        if (ret.length == 36 && bytes4(ret) == BlazePhoenixRouter.RouterE.selector) { assembly { code := mload(add(ret, 36)) } isR = true; }
    }

    /// One quote, one delay, one drift size (whale trades `driftUsdc` through the same route first).
    function _run(uint256 delay, uint256 driftUsdc) private returns (bool ok, uint16 code, uint256 ratioBps) {
        uint256 snap = vm.snapshotState();
        uint256 amountIn = 1_000e6;
        (BlazePhoenixQuoter.Preview memory pv, bytes memory call) =
            quoter.previewAndEncode(BASE_USDC, BASE_WETH, amountIn, user, block.timestamp + 30);
        assertTrue(pv.canExecute, "live Base: the quote exists");
        if (driftUsdc > 0) {
            (BlazePhoenixQuoter.Preview memory wv, ) = quoter.previewAndEncode(BASE_USDC, BASE_WETH, driftUsdc, whale, block.timestamp + 30);
            vm.prank(whale);
            router.swapExactIn(wv.route, driftUsdc, 1, whale, block.timestamp + 30);
        }
        vm.warp(block.timestamp + delay);
        vm.roll(block.number + (delay + 1) / 2);
        vm.prank(user);
        bytes memory ret;
        (ok, ret) = address(router).call(call);
        if (ok) {
            uint256 delivered = abi.decode(ret, (uint256));
            assertGe(delivered, pv.effectiveMinOut, "a settlement delivered below the attested floor");
            ratioBps = delivered * 10_000 / pv.netOut;
        } else {
            bool isR; (code, isR) = _routerCode(ret);
            assertTrue(isR, "refused, but not with a selector of ours");
        }
        vm.revertToState(snap);
    }

    function test_LiveBase_TimeAloneNeverBreaksAQuote() public {
        uint256[4] memory delays = [uint256(0), 3, 6, 10];
        for (uint256 i; i < 4; ++i) {
            (bool ok, , uint256 r) = _run(delays[i], 0);
            assertTrue(ok, "no drift: the quote must settle at any delay inside the deadline");
            console2.log("delay s", delays[i], "delivered/predicted bps", r);
            assertGe(r, 10_000, "no drift: delivery below the preview's net prediction");
        }
    }

    function test_LiveBase_StaleQuoteUnderDrift_SettlesInsideTheFloorOrRefusesWithCode5() public {
        uint256[5] memory drifts = [uint256(10_000e6), 50_000e6, 200_000e6, 1_000_000e6, 5_000_000e6];
        uint256 settled; uint256 refused5;
        for (uint256 i; i < 5; ++i) {
            (bool ok, uint16 code, uint256 r) = _run(10, drifts[i]);
            if (ok) { ++settled; console2.log("drift USDC", drifts[i] / 1e6, "settled, delivered/predicted bps", r); }
            else { assertEq(code, 5, "a stale quote was refused, but not by the floor"); ++refused5; console2.log("drift USDC", drifts[i] / 1e6, "refused by the floor"); }
        }
        console2.log("settled", settled, "refused(5)", refused5);
        assertEq(settled + refused5, 5, "no third way");
    }
}
