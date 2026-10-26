// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  KIND 9 (KIND_EXTERNAL) FAILS CLOSED WHERE THE CORE CANNOT READ IT, AND
//  EXECUTES WHERE IT SPEAKS THE V3 ABI (gate-1021, phase 1).
//
//  theta gives kind 9 no attribute, and the Core's header calls that
//  "fail-closed for free". It was not, at three sites [conferido 13fff68]:
//    * provenShape re-labelled any kind without slot0 as V2 or Solidly, so the
//      operator's seedPool registered a declared kind 9 as a pair;
//    * registryDepth18 read every kind that is neither reserve- nor singleton-
//      shaped as a V3 pool;
//    * the Quoter's _priceLeg forced its last arm to KIND_SOLIDLY, so an
//      unknown kind was priced on the Solidly curve.
//  Each test below is red at 13fff68 and names the quantity it pins. The kind
//  is written as the literal 9 so this file compiles against the unfixed tree.
//
//  Oracle: the mocks' own state (reserves, slot0) and the Router's settlement;
//  never the code under test.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

contract KindFailsClosedPlanStub {
    bytes internal blob;
    function setPlan(RoutePlan memory p) external { blob = abi.encode(p); }
    function findBestRoutePlan(address, address, uint256) external view returns (RoutePlan memory) {
        return abi.decode(blob, (RoutePlan));
    }
}

contract GateKindFailsClosedTest is Test {
    uint8 constant KIND9 = 9;
    uint160 constant Q96 = uint160(uint256(1) << 96);

    BlazePhoenixHub hub;
    MockERC20 t0;
    MockERC20 t1;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
    }

    function _pair() internal returns (MockV2Pair p) {
        p = new MockV2Pair(address(t0), address(t1));
        p.setReserves(1_000e18, 1_000e18);
        t0.mint(address(p), 1_000e18);
        t1.mint(address(p), 1_000e18);
    }

    // ─── provenShape: a kind with no readable shape is refused, not re-labelled ───

    /// Quantity: Core.provenShape(pool, kind).ok for a kind outside A_RESERVES | A_CONC_POOL.
    /// RED at 13fff68: a reserve-shaped pool declared kind 9 came back ok = true, k = V2.
    function test_GateK9_ProvenShape_RefusesKindExternal() public {
        MockV2Pair p = _pair();
        (bool ok, ) = BPC.provenShape(address(p), KIND9);
        assertFalse(ok, "provenShape: kind 9 has no reader and must not be re-labelled as a pair");
        (ok, ) = BPC.provenShape(address(p), 3);
        assertFalse(ok, "provenShape: a tombstone has no reader either");
        (bool okV2, uint8 k) = BPC.provenShape(address(p), BPC.KIND_V2);
        assertTrue(okV2 && k == BPC.KIND_V2, "the neighbour: a declared V2 pair is still proven");
    }

    /// The operator's door inherits it through the same producer: no kind-9 row is written.
    function test_GateK9_SeedPool_RefusesKindExternal() public {
        MockV2Pair p = _pair();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(4)));
        hub.seedPool(address(p), KIND9, 0, address(0), address(t0), address(t1));
    }

    // ─── registryDepth18: only a pool-read concentrated kind reaches the L reader ───

    /// Quantity: Core.registryDepth18 for a kind outside every reader.
    /// RED at 13fff68: a pool answering slot0/liquidity, declared kind 9, measured as V3.
    function test_GateK9_RegistryDepth18_IsZeroForKindExternal() public {
        MockV3Pool p = new MockV3Pool(address(t0), address(t1), 3000);
        p.setState(Q96, uint128(1e24));
        t0.mint(address(p), 1_000e18);
        t1.mint(address(p), 1_000e18);
        assertGt(BPC.registryDepth18(address(p), BPC.KIND_V3, address(t0), address(t1), address(0), bytes32(0)), 0,
            "the neighbour: the same pool declared V3 has depth");
        assertEq(BPC.registryDepth18(address(p), KIND9, address(t0), address(t1), address(0), bytes32(0)), 0,
            "registryDepth18: kind 9 has no depth producer and must measure 0");
    }

    // ─── addFactory: the Gate enters by the V3 salt slot, and only there ───

    /// Quantity: Hub.addFactory admission of (kind 9, MODE_CREATE2_V3): bit 9 of KINDS_ROUTABLE
    /// and of KINDS_V3_SALT.
    /// RED at 13fff68: HubE(5), kind 9 was outside KINDS_ROUTABLE and the V3 salt slot.
    function test_GateK9_AddFactory_AdmitsKindExternalInTheV3SaltSlot() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = uint24(1 << 16 | 1);
        hub.addFactory(address(0x6A7E), KIND9, 5, keccak256("wrapper"), fees, new int24[](0));
    }

    /// Kind 9 derives by the Gate's CREATE2 only: a lookup or V3-CL row cannot carry it.
    function test_GateK9_AddFactory_RefusesKindExternalOutsideTheV3SaltSlot() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = uint24(1 << 16 | 1);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(address(0x6A7E), KIND9, 0, bytes32(0), fees, new int24[](0));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(address(0x6A7E), KIND9, 7, keccak256("wrapper"), fees, new int24[](0));
    }

    // ─── Router: kind 9 executes through _execV3Amt and its callback ───

    /// Quantity: the Router's execution dispatch for kind 9 asks BPC.gateWrapperLive first. A
    /// plain V3 pool labelled kind 9 is refused (RouterE(19)); the same pool settles as kind 1.
    /// History: at 13fff68 this was RouterE(8) (no arm); phase 2 gave kind 9 the V3 arm and this
    /// pool settled as kind 9 - the calldata's label was the identity. The derivation closes it.
    function test_GateK9_Router_RefusesAPoolThatIsNotAWrapper() public {
        BlazePhoenixRouter router =
            new BlazePhoenixRouter(address(hub), address(0xD0D0), address(this), address(0xFEE1), address(0xFEE2));
        MockV3Pool p = new MockV3Pool(address(t0), address(t1), 3000);
        p.setState(Q96, uint128(1e27));
        t1.mint(address(p), 1_000_000e18);
        address user = address(0xA11CE);
        uint256 amt = 1_000e18;
        t0.mint(user, amt);
        vm.prank(user);
        t0.approve(address(router), type(uint256).max);
        uint256 exp = BPC.outV3(amt, Q96, uint128(1e27), 3000, true, 0);
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: address(p), hooks: address(0), kind: KIND9, fee: 3000, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: exp, auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: amt, expectedOut: exp, legs: l});
        Route memory r = Route({hops: hs, totalOut: exp, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(19)));
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        r.hops[0].legs[0].kind = BPC.KIND_V3;
        vm.prank(user);
        uint256 out = router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
        assertGt(out, 0, "the same pool settles as kind 1");
        assertEq(t1.balanceOf(user), out, "the user receives what the Router measured");
        assertEq(t0.balanceOf(address(router)), 0, "the Router keeps no input");
        assertEq(t1.balanceOf(address(router)), 0, "the Router keeps no output");
    }

    // ─── Quoter: an unknown kind is priced by its own kind, which has no arm ───

    /// Quantity: Quoter._priceLeg for a kind outside every arm, read through previewPlanExact.
    /// RED at 13fff68: an unknown kind on a Solidly pair was priced on the Solidly curve. Since
    /// phase 2 kind 9 has its own arm (the wrapper's adapter, test/BlazePhoenixGate.t.sol), so
    /// the unknown kind here is tombstone 3.
    function test_GateK9_QuoterPriceLeg_UnknownKindQuotesZero() public {
        KindFailsClosedPlanStub stub = new KindFailsClosedPlanStub();
        BlazePhoenixQuoter quoter = new BlazePhoenixQuoter(address(hub), address(stub));
        MockSolidlyPair p = new MockSolidlyPair(address(t0), address(t1), false);
        p.setReserves(1_000_000e18, 1_000_000e18);
        t0.mint(address(p), 1_000_000e18);
        t1.mint(address(p), 1_000_000e18);
        uint256 x = 100e18;
        uint256 claim = p.getAmountOut(x, address(t0));
        stub.setPlan(_onePlan(address(p), BPC.KIND_SOLIDLY, x, claim));
        (Route memory rs, ) = quoter.previewPlanExact(address(t0), address(t1), x);
        assertGt(rs.hops[0].legs[0].expectedOut, 0, "the neighbour: the Solidly leg is priced");
        stub.setPlan(_onePlan(address(p), 3, x, claim));
        (Route memory r3, ) = quoter.previewPlanExact(address(t0), address(t1), x);
        assertEq(r3.hops[0].legs[0].expectedOut, 0, "_priceLeg: an unknown kind has no quote producer and must price 0");
        stub.setPlan(_onePlan(address(p), KIND9, x, claim));
        (Route memory r9, ) = quoter.previewPlanExact(address(t0), address(t1), x);
        assertEq(r9.hops[0].legs[0].expectedOut, 0, "_priceLeg: a pair is not a Gate wrapper, kind 9 on it prices 0");
    }

    function _onePlan(address pool, uint8 kind, uint256 x, uint256 claim) internal view returns (RoutePlan memory p) {
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({pool: pool, hooks: address(0), kind: kind, fee: 30, tickSpacing: 0,
            zeroForOne: address(t0) < address(t1), stable: false, amountIn: x, expectedOut: claim, auxId: bytes32(0)});
        Hop[] memory hs = new Hop[](1);
        hs[0] = Hop({tokenIn: address(t0), tokenOut: address(t1), amountIn: x, expectedOut: claim, legs: l});
        p.best = Route({hops: hs, totalOut: claim, singleOut: claim, singleOutFloor: BPC.mulDiv(claim, 9_600, BPC.BPS),
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }
}
