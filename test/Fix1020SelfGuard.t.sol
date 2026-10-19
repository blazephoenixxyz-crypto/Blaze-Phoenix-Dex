// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// SELF (20/10) - THE ROUTER CODE REFUSES TO EXECUTE A SWAP ANYWHERE BUT AT ITS OWN ADDRESS.
//
// An EOA can delegate to the Router (EIP-7702 designator 0xef0100 || router). The Router code then
// runs with address(this) == the EOA, so every balance it measures and every transfer it makes is
// the EOA's. 2.0.0 already keeps those balances out of the swap (test/Fix1019H11.t.sol: P1 input
// scaling, P2 toutStart baseline, P3 bridgeBase), but nothing in 2.0.0 needs to RUN in a delegated
// frame: a 7702 account CALLS swapExactIn at the Router's address (Router "7702 integrators call
// swapExactIn"). So `_execute`, which every door reaches, compares address(this) with the address
// the Router was deployed at (immutable SELF, in the code) and refuses RouterE(18) anywhere else.
//
// One delegated test per door, plus a direct-call twin per door that must still settle (a guard
// that fired at the Router's own address would kill these, not pass them):
//   swapExactIn            reachable in a delegated frame with no further condition.
//   swapExactInWithPermit2 reads `permit2` from the EOA's storage: zero by default, so the door is
//                          already fail-closed there. The test writes the Router's value into the
//                          EOA's slot (what a previous delegate could have left behind) so the door
//                          reaches _execute; the guard is what refuses it then.
//   swapExactInNative      same, with `weth`.
//   swapBestExactIn        the Solver is an immutable (in the code), so reachable; the execution
//                          goes through the self-call `this.selfExecutePrePulled`, where `this` is
//                          the EOA and msg.sender == address(this) holds, and then into _execute.
//
// Delegation is a real EIP-7702 authorisation (vm.signAndAttachDelegation, prague), proven per test
// by reading the immutable hub() through the EOA. Each delegated call is built BEFORE the cheatcodes
// (prank -> expectRevert -> call), and on the unguarded tree each one settles, so the red is "did
// not revert", not a revert for another reason.
//
// Not covered here: the callbacks (uniswapV3SwapCallback and siblings, unlockCallback), receive()
// and fallback in a delegated frame. They are not swap doors and do not reach _execute.
//
// forge test --match-path test/Fix1020SelfGuard.t.sol -vv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter, IPermit2} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

/// @dev WETH9-shaped mock: deposit() mints the caller's balance 1:1.
contract SelfGuardWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable {
        this.mint(msg.sender, msg.value);
    }
}

/// @dev Solver stand-in: one V2 leg tIn -> out through a fixed pair.
contract SelfGuardSolver {
    address public pair;
    address public out;
    constructor(address p, address o) { pair = p; out = o; }

    function findBestRoutePlan(address tIn, address, uint256 amountIn)
        external view returns (RoutePlan memory plan)
    {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pair, hooks: address(0), kind: BPC.KIND_V2, fee: 30,
            tickSpacing: 0, zeroForOne: tIn < out, stable: false,
            amountIn: amountIn, expectedOut: 1, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: tIn, tokenOut: out, amountIn: amountIn, expectedOut: 1, legs: legs });
        plan.best = Route({
            hops: hops, totalOut: 1, singleOut: 1, singleOutFloor: 0, expectedImpactBps: 0,
            confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }
}

contract Fix1020SelfGuardTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tA;
    MockERC20 tB;
    SelfGuardWETH weth;
    MockV2Pair pairAB;
    MockV2Pair pairWB;
    MockPermit2 permit2;

    address victim;
    uint256 victimPk;
    address attacker = makeAddr("attacker");

    uint256 constant R = 1_000_000e18;
    uint256 constant X = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tA = new MockERC20("A", "A");
        tB = new MockERC20("B", "B");
        weth = new SelfGuardWETH();
        pairAB = _pair(tA, tB);
        pairWB = _pair(MockERC20(address(weth)), tB);
        SelfGuardSolver solver = new SelfGuardSolver(address(pairAB), address(tB));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2"));
        permit2 = new MockPermit2();
        router.setPermit2(address(permit2));
        router.setWeth(address(weth));
        (victim, victimPk) = makeAddrAndKey("victim");
        tA.mint(attacker, 10 * X);
        vm.deal(attacker, 10 * X);
    }

    function _pair(MockERC20 a, MockERC20 b) private returns (MockV2Pair p) {
        p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), R);
        b.mint(address(p), R);
        p.setReserves(uint112(R), uint112(R));
    }

    /// The victim EOA signs a real EIP-7702 authorisation to the Router. Proven, not assumed: an
    /// immutable read through the EOA must answer with the Router's hub.
    function _delegate() private {
        vm.setEvmVersion("prague");
        vm.signAndAttachDelegation(address(router), victimPk);
        assertEq(address(BlazePhoenixRouter(payable(victim)).hub()), address(hub),
            "the delegated EOA does not run the Router code");
    }

    /// Copies the Router's storage word holding `v` into the same slot of the EOA, so a door that
    /// reads a control-set address (permit2, weth) sees it in the delegated frame too.
    function _mirror(address v) private {
        bytes32 w = bytes32(uint256(uint160(v)));
        for (uint256 i; i < 64; ++i) {
            if (vm.load(address(router), bytes32(i)) == w) {
                vm.store(victim, bytes32(i), w);
                return;
            }
        }
        revert("slot not found");
    }

    function _routeFrom(MockERC20 tin, MockV2Pair p) private view returns (Route memory r) {
        Leg[] memory l = new Leg[](1);
        l[0] = Leg({
            pool: address(p), hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(tin) < address(tB), stable: false, amountIn: X, expectedOut: 0,
            auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tin), tokenOut: address(tB), amountIn: X,
            expectedOut: 0, legs: l});
        r = Route({
            hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
    }

    function _permit() private view returns (IPermit2.PermitTransferFrom memory p) {
        p = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: address(tA), amount: X}),
            nonce: 0, deadline: block.timestamp + 1
        });
    }

    function _err18() private pure returns (bytes memory) {
        return abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(18));
    }

    // ─── delegated frame: every door refuses RouterE(18) ──────────────────────────────────────

    function test_SELF_1020_ClassicDoorRefusesADelegatedFrame() public {
        _delegate();
        vm.prank(attacker);
        tA.approve(victim, X);
        Route memory r = _routeFrom(tA, pairAB);
        BlazePhoenixRouter target = BlazePhoenixRouter(payable(victim));

        vm.prank(attacker);
        vm.expectRevert(_err18());
        target.swapExactIn(r, X, 1, attacker, block.timestamp + 1);
    }

    function test_SELF_1020_Permit2DoorRefusesADelegatedFrame() public {
        _delegate();
        _mirror(address(permit2));
        vm.prank(attacker);
        tA.approve(address(permit2), X);
        Route memory r = _routeFrom(tA, pairAB);
        IPermit2.PermitTransferFrom memory p = _permit();
        BlazePhoenixRouter target = BlazePhoenixRouter(payable(victim));

        vm.prank(attacker);
        vm.expectRevert(_err18());
        target.swapExactInWithPermit2(r, X, 1, attacker, block.timestamp + 1, p, "");
    }

    function test_SELF_1020_NativeDoorRefusesADelegatedFrame() public {
        _delegate();
        _mirror(address(weth));
        Route memory r = _routeFrom(MockERC20(address(weth)), pairWB);
        BlazePhoenixRouter target = BlazePhoenixRouter(payable(victim));

        vm.prank(attacker);
        vm.expectRevert(_err18());
        target.swapExactInNative{value: X}(r, 1, attacker, block.timestamp + 1);
    }

    function test_SELF_1020_BestDoorRefusesADelegatedFrame() public {
        _delegate();
        vm.prank(attacker);
        tA.approve(victim, X);
        BlazePhoenixRouter target = BlazePhoenixRouter(payable(victim));

        vm.prank(attacker);
        vm.expectRevert(_err18());
        target.swapBestExactIn(address(tA), address(tB), X, 1, attacker, block.timestamp + 1);
    }

    // ─── the Router's own address: the same four calls settle ─────────────────────────────────

    function test_SELF_1020_ClassicDoorStillSettlesAtTheRouter() public {
        vm.prank(attacker);
        tA.approve(address(router), X);
        Route memory r = _routeFrom(tA, pairAB);
        vm.prank(attacker);
        uint256 out = router.swapExactIn(r, X, 1, attacker, block.timestamp + 1);
        assertGt(out, 0, "the classic door settles at the Router");
        assertEq(tB.balanceOf(attacker), out, "the recipient gets the output");
    }

    function test_SELF_1020_Permit2DoorStillSettlesAtTheRouter() public {
        vm.prank(attacker);
        tA.approve(address(permit2), X);
        Route memory r = _routeFrom(tA, pairAB);
        IPermit2.PermitTransferFrom memory p = _permit();
        vm.prank(attacker);
        uint256 out = router.swapExactInWithPermit2(r, X, 1, attacker, block.timestamp + 1, p, "");
        assertGt(out, 0, "the Permit2 door settles at the Router");
        assertEq(tB.balanceOf(attacker), out, "the recipient gets the output");
    }

    function test_SELF_1020_NativeDoorStillSettlesAtTheRouter() public {
        Route memory r = _routeFrom(MockERC20(address(weth)), pairWB);
        vm.prank(attacker);
        uint256 out = router.swapExactInNative{value: X}(r, 1, attacker, block.timestamp + 1);
        assertGt(out, 0, "the native door settles at the Router");
        assertEq(tB.balanceOf(attacker), out, "the recipient gets the output");
    }

    function test_SELF_1020_BestDoorStillSettlesAtTheRouter() public {
        vm.prank(attacker);
        tA.approve(address(router), X);
        vm.prank(attacker);
        uint256 out = router.swapBestExactIn(address(tA), address(tB), X, 1, attacker, block.timestamp + 1);
        assertGt(out, 0, "the best door settles at the Router");
        assertEq(tB.balanceOf(attacker), out, "the recipient gets the output");
    }
}
