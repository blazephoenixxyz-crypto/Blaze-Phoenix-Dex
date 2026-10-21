// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  #52 (seal 2026-10-21) - ONE DERIVATION OF A V4-NATIVE LEG'S KEY.
//
//  The Router derives the native side of a KIND_V4_NATIVE leg by asking WHICH side is
//  the canonical WETH (`BPC.nativeMapVerified`) and refuses the leg with RouterE(8) when
//  neither is, or when WETH is unwired. The Quoter used to derive it from `zeroForOne`
//  alone (`BPC.v4LegCurrencies`), with no WETH at all - so a native leg between two
//  tokens that are not WETH, naming the pool its orientation derives, was previewed as
//  executable while the Router refused it. Property: the preview's key verdict is the
//  Router's key verdict, for every native leg, including the malformed ones.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PricedV4Manager, FixedPlanSolver} from "./RouteIntegrityV4.t.sol";

contract Seal1021NativeParityTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    PricedV4Manager mgr;
    MockERC20 w; MockERC20 a; MockERC20 b;
    address user = address(0xBEEF);
    uint24 constant FEE = 3000; int24 constant TS = 60; uint128 constant LIQ = 1e30;

    function setUp() public {
        mgr = new PricedV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        router = new BlazePhoenixRouter(address(hub), address(0xBEEF), address(this), address(0xFEE1), address(0xFEE2));
        FixedPlanSolver solver = new FixedPlanSolver();
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        w = new MockERC20("Wrapped Ether", "WETH"); a = new MockERC20("A", "A"); b = new MockERC20("B", "B");
        router.setWeth(address(w));
        MockERC20[3] memory ts = [w, a, b];
        for (uint256 i; i < 3; ++i) {
            ts[i].mint(user, 100e18);
            ts[i].mint(address(mgr), 1_000e18);
            vm.prank(user); ts[i].approve(address(router), type(uint256).max);
        }
    }

    function _seed(bytes32 pid) internal {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.setSlot(base, bytes32(uint256(BPC.Q96)));
        mgr.setSlot(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));
        mgr.setRate(pid, 1000);
    }

    function _pid(address x, address y) internal pure returns (bytes32) {
        (address c0, address c1) = BPC.sortTokens(x, y);
        return BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));
    }

    function _route(address tIn, address tOther, bool zfo, bytes32 named, uint256 amt) internal pure returns (Route memory route) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({ pool: address(uint160(uint256(named))), hooks: address(0), kind: BPC.KIND_V4_NATIVE, fee: FEE,
                        tickSpacing: TS, zeroForOne: zfo, stable: false, amountIn: amt, expectedOut: amt,
                        auxId: bytes32(uint256(uint160(tOther))) });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: tOther, amountIn: amt, expectedOut: amt, legs: legs });
        route = Route({ hops: hops, totalOut: amt, singleOut: amt, singleOutFloor: 0, expectedImpactBps: 0,
                        confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false });
    }

    /// True when the Router refuses the leg's KEY (RouterE(8) native map, RouterE(11) key
    /// self-consistency). Any other outcome - success, or a later failure of the mock's
    /// settlement - means the key was accepted.
    function _routerRefusesKey(Route memory r) internal returns (bool) {
        uint256 amt = r.hops[0].amountIn;
        vm.prank(user);
        try router.swapExactIn(r, amt, 1, user, block.timestamp + 1) returns (uint256) {
            return false;
        } catch (bytes memory err) {
            return keccak256(err) == keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)))
                || keccak256(err) == keccak256(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(11)));
        }
    }

    /// RED on the tree before the fix: A -> B, neither side WETH, `zeroForOne` true and the
    /// pool the orientation derives, pid(native, B). The Router refuses it with RouterE(8).
    function test_NativeLegWithoutWeth_PreviewAgreesWithRouter() public {
        uint256 amt = 1e18;
        bytes32 named = _pid(address(0), address(b));
        _seed(named);
        Route memory r = _route(address(a), address(b), true, named, amt);
        bool exec = quoter.previewRoute(r, 1).canExecute;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        assertFalse(exec, "the preview endorsed a native leg the Router refuses with RouterE(8)");
    }

    /// The honest native leg (WETH -> B, native side = currency0) is still executable in the
    /// preview: the fix must not refuse what the Router accepts.
    function test_HonestNativeLeg_StaysExecutable() public {
        uint256 amt = 1e18;
        bytes32 named = _pid(address(0), address(b));
        _seed(named);
        Route memory r = _route(address(w), address(b), true, named, amt);
        assertTrue(quoter.previewRoute(r, 1).canExecute, "an honest native leg is executable");
        assertFalse(_routerRefusesKey(r), "and the Router accepts its key");
    }

    /// A native leg with no WETH side maps to the EMPTY key (native, native). A leg naming
    /// exactly that pool passes the direction and poolId checks, so only the explicit
    /// "no WETH side" refusal stands between it and an endorsement the Router reverts (8).
    function test_NativeLegNamingTheEmptyKey_IsRefused() public {
        uint256 amt = 1e18;
        bytes32 named = _pid(address(0), address(0));
        _seed(named);
        Route memory r = _route(address(a), address(b), true, named, amt);
        assertFalse(quoter.previewRoute(r, 1).canExecute, "the preview endorsed the empty native key");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    /// The execution-grade preview dry-runs a V4 leg on the key `_simV4` derives. The pool
    /// pays 2x; the plan says 1x. On a well-formed native leg the dry-run speaks (about 2x);
    /// on a leg the Router refuses it must stay silent, so the figure falls back to the plan
    /// and never prices the pool the leg's orientation happens to point at.
    function _exact(address tIn, address tOther, bytes32 named) internal returns (uint256 exactOut) {
        uint256 amt = 1e18;
        mgr.setRate(named, 2000);
        FixedPlanSolver s = new FixedPlanSolver();
        s.setPlan(_route(tIn, tOther, true, named, amt));
        BlazePhoenixQuoter q = new BlazePhoenixQuoter(address(hub), address(s));
        (, exactOut) = q.previewPlanExact(tIn, tOther, amt);
    }

    function test_ExactPreview_HonestNativeLeg_IsDryRun() public {
        bytes32 named = _pid(address(0), address(b));
        _seed(named);
        assertGt(_exact(address(w), address(b), named), 15e17, "the dry-run spoke for an honest native leg");
    }

    function test_ExactPreview_NativeLegWithoutWeth_IsNotDryRun() public {
        bytes32 named = _pid(address(0), address(b));
        _seed(named);
        assertLe(_exact(address(a), address(b), named), 1e18, "a leg the Router refuses was priced on the pool");
    }

    function test_ExactPreview_EmptyNativeKey_IsNotDryRun() public {
        bytes32 named = _pid(address(0), address(0));
        _seed(named);
        assertLe(_exact(address(a), address(b), named), 1e18, "the empty native key was priced");
    }

    /// Fuzz over EVERY shape of a native leg - either side WETH or neither, both directions,
    /// WETH wired or not, the pool named by the orientation derivation or by the
    /// WETH-verified one (including the (native, native) key of a leg with no WETH side).
    /// No case is excluded. Two-sided: what the Router refuses by key the preview never
    /// endorses, and a well-formed native leg (WETH wired, exactly one side WETH, the
    /// direction that puts the native side first) is endorsed and its key accepted.
    /// (Equality is too strong: the Router refuses some shapes - e.g. tokenIn == auxId -
    /// for reasons of its own before the key is asked.)
    function testFuzz_NativeKeyVerdictIsTheRouters(uint8 inSel, uint8 otherSel, bool zfo, bool wired, bool byOrientation) public {
        MockERC20[3] memory ts = [w, a, b];
        address tIn = address(ts[inSel % 3]);
        address tOther = address(ts[otherSel % 3]);
        if (!wired) router.setWeth(address(0));
        address weth = wired ? address(w) : address(0);
        address x; address y;
        if (byOrientation) {
            (x, y) = zfo ? (address(0), tOther) : (tIn, address(0));
        } else {
            (x, y) = BPC.nativeMapVerified(tIn, tOther, weth);
        }
        bytes32 named = _pid(x, y);
        _seed(named);
        Route memory r = _route(tIn, tOther, zfo, named, 1e18);
        bool exec = quoter.previewRoute(r, 1).canExecute;
        bool refused = _routerRefusesKey(r);
        if (refused) assertFalse(exec, "the preview endorsed a native leg whose key the Router refuses");
        if (wired && ((tIn == address(w)) != (tOther == address(w))) && zfo == (tIn == address(w))) {
            assertTrue(exec, "the preview refused a well-formed native leg");
            assertFalse(refused, "the Router refused a well-formed native leg's key");
        }
    }
}
