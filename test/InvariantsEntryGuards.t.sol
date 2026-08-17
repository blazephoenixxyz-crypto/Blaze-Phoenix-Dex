// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  ENTRY-GUARD INVARIANTS — INV-6 and INV-4, pinned by name.
//
//  INV-6: "a swap with a zero minimum output does not execute, rejected at
//          EVERY entry point."
//
//  That claim is about the whole surface, so testing one entry point does not
//  test it. The Router exposes exactly four swap entry points, and each raises
//  RouterE(10) for a zero userMinOut:
//
//      swapExactIn            -> via _checkedSwap, line ~296
//      swapExactInWithPermit2 -> inline,           line ~307
//      swapExactInNative      -> inline,           line ~357
//      swapBestExactIn        -> inline,           line ~394
//
//  Each test below asserts the SPECIFIC error, not merely "it reverted". That
//  distinction matters: every one of these functions has other guards that also
//  revert (unset WETH, zero amountIn, oversized amountIn), and a test that
//  accepted any revert would pass while the minOut guard was missing entirely —
//  it would be measuring the wrong rejection. The ordering of prior guards is
//  therefore set up so RouterE(10) is the one that can fire.
//
//  INV-4: "the fee rate, the fee split and the floor constants have no setter."
//
//  PROTOCOL_FEE_BPS (28), LEG_FLOOR_BPS (8_000) and the Core FLOOR_* constants
//  are `internal constant`, so the compiler already guarantees this. The probe
//  below is a REGRESSION SENTINEL, not a discovery: it turns red the day one of
//  them is promoted to storage with a setter, which is exactly the change that
//  would quietly convert an immutable guarantee into a governance knob. The
//  Router has no receive() and no fallback, so an unknown selector reverts and
//  a successful call means the function genuinely appeared.
//
//  Run: forge test --match-contract InvariantsEntryGuards -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {Route} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract InvariantsEntryGuardsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 weth;
    MockERC20 tokenOut;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address recipient = address(0xCAFE);

    /// The guard's error, as declared in the Router: `error RouterE(uint16 code)`.
    /// 10 = userMinOut == 0 with amountIn > 0 (BP-04).
    function _expectZeroMinOutRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(10)));
    }

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        // Solver may be a stub: every minOut guard fires before the solver is
        // consulted, which is itself part of what these tests pin down.
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), treasury1, treasury2);

        weth = new MockERC20("WETH", "WETH");
        tokenOut = new MockERC20("OUT", "OUT");

        // The native entry point checks WETH is wired BEFORE it checks minOut,
        // so without this the test would observe RouterE(3) and prove nothing.
        router.setWeth(address(weth));
    }

    // ── INV-6, one test per entry point ──────────────────────────────────────

    function test_INV6_swapExactIn_rejectsZeroMinOut() public {
        Route memory r;
        _expectZeroMinOutRevert();
        router.swapExactIn(r, 1e18, 0, recipient, block.timestamp + 1);
    }

    function test_INV6_swapExactInWithPermit2_rejectsZeroMinOut() public {
        Route memory r;
        IPermit2.PermitTransferFrom memory permit;
        // amountIn must stay within uint128 or the size guard fires first.
        permit.permitted.amount = 1e18;
        _expectZeroMinOutRevert();
        router.swapExactInWithPermit2(r, 1e18, 0, recipient, block.timestamp + 1, permit, "");
    }

    function test_INV6_swapExactInNative_rejectsZeroMinOut() public {
        Route memory r;
        vm.deal(address(this), 1 ether);
        _expectZeroMinOutRevert();
        router.swapExactInNative{value: 1 ether}(r, 0, recipient, block.timestamp + 1);
    }

    function test_INV6_swapBestExactIn_rejectsZeroMinOut() public {
        _expectZeroMinOutRevert();
        router.swapBestExactIn(address(weth), address(tokenOut), 1e18, 0, recipient, block.timestamp + 1);
    }

    /// The guard is conditional on amountIn > 0 on the two classic entry points,
    /// which is deliberate: a zero-amount call is a no-op, not a swap that could
    /// strip a user. Pinning it stops the condition being "simplified" into an
    /// unconditional check that would break callers, or dropped altogether.
    function test_INV6_zeroAmountIsNotTreatedAsAZeroMinOutSwap() public {
        Route memory r;
        // Not RouterE(10): with amountIn == 0 there is nothing to protect.
        try router.swapExactIn(r, 0, 0, recipient, block.timestamp + 1) returns (uint256 outAmt) {
            assertEq(outAmt, 0, "a zero-amount swap must deliver nothing");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == BlazePhoenixRouter.RouterE.selector) {
                uint16 code;
                assembly { code := mload(add(err, 0x24)) }
                assertTrue(code != 10, "zero amountIn must not be rejected as a zero-minOut swap");
            }
        }
    }

    // ── INV-4 — the fee and the floors are constants, not settings ───────────

    function test_INV4_noSetterForFeeOrFloorConstants() public {
        string[8] memory probes = [
            "setFee(uint16)",
            "setFee(uint256)",
            "setProtocolFee(uint16)",
            "setProtocolFeeBps(uint16)",
            "setFloor(uint16)",
            "setLegFloor(uint16)",
            "setLegFloorBps(uint16)",
            "setMinQuoteCoverage(uint16)"
        ];
        for (uint256 i = 0; i < probes.length; i++) {
            (bool ok, ) = address(router).call(abi.encodeWithSignature(probes[i], uint16(1)));
            assertFalse(ok, string.concat("INV-4 broken: Router grew a setter -> ", probes[i]));
        }
    }

    /// The admin surface that DOES exist is a different claim, and leaving it
    /// unpinned would let this file read as "the Router has no setters at all",
    /// which is false. These four are the documented control surface; INV-4 is
    /// about the economics, not about routing configuration.
    function test_INV4_documentedControlSurfaceStillExists() public {
        (bool a, ) = address(router).call(abi.encodeWithSignature("setAdmin(address)", address(this)));
        (bool b, ) = address(router).call(abi.encodeWithSignature("setWeth(address)", address(weth)));
        (bool c, ) = address(router).call(abi.encodeWithSignature("setPaused(bool)", false));
        (bool d, ) = address(router).call(
            abi.encodeWithSignature("setTreasuries(address,address)", treasury1, treasury2));
        assertTrue(a && b && c && d, "the documented control surface changed shape");
    }
}
