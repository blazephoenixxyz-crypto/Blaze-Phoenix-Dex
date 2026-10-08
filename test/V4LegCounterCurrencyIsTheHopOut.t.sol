// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A V4 leg's counter-currency must be the hop's own output token.
//
//  A V4 leg executes against (hop.tokenIn, leg.auxId), while `_recordHits`
//  derives the pool row it credits from (hop.tokenIn, hop.tokenOut). The pair
//  guard in `_execute`
//
//      if (legIn != hop.tokenIn || legOutRaw != hop.tokenOut) revert RouterE(3);
//
//  is what ties the two together: for a V4 leg `legOutRaw` is `auxId`, so the
//  guard forces `auxId == hop.tokenOut` and the row credited is the pool that
//  executed. `test/V4LegPoolIdentity.t.sol` covers a `leg.pool` that does not
//  derive from the key; this file covers the other label, `auxId`, with a pool
//  id that does derive from the real key (A, C) under a hop labelled (A, B).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

contract AuxIdMockERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) public returns (bool) {
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address from, address to, uint256 amt) public returns (bool) {
        balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
}

interface IAuxIdTransfer { function transfer(address, uint256) external returns (bool); }

/// @dev V4 manager mock: answers extsload (for depth) and counts swaps, so the
///      test can say whether anything executed.
contract AuxIdV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    mapping(bytes32 => bytes32) private st;
    uint256 public swapCalls;

    function setPool(bytes32 pid, uint160 sp, uint128 liq) external {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        st[base] = bytes32(uint256(sp));
        st[bytes32(uint256(base) + 3)] = bytes32(uint256(liq));
    }

    function extsload(bytes32 slot) external view returns (bytes32) { return st[slot]; }

    function _pack(int128 d0, int128 d1) internal pure returns (int256) {
        return int256((uint256(uint128(d0)) << 128) | uint256(uint128(d1)));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) =
            msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(ok, "unlock: callback reverted");
        return ret;
    }

    function swap(V4PoolKey calldata, SwapParams calldata p, bytes calldata)
        external returns (int256)
    {
        swapCalls++;
        uint256 amt = uint256(-p.amountSpecified);
        int128 owe  = -int128(int256(amt));
        int128 recv =  int128(int256(amt));
        return p.zeroForOne ? _pack(owe, recv) : _pack(recv, owe);
    }

    function sync(address) external {}
    function settle() payable external returns (uint256) { return 0; }
    function take(address currency, address to, uint256 amount) external {
        IAuxIdTransfer(currency).transfer(to, amount);
    }
}

contract V4LegCounterCurrencyIsTheHopOutTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    AuxIdV4Manager mgr;
    AuxIdMockERC20 A;
    AuxIdMockERC20 B;
    AuxIdMockERC20 C;

    address user = makeAddr("user");
    uint160 constant Q96 = uint160(uint256(1) << 96);
    uint24 constant FEE = 500;
    int24  constant TS  = 10;

    function setUp() public {
        mgr = new AuxIdV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), makeAddr("t1"), makeAddr("t2"));
        hub.setRoles(address(router), address(solver), address(this));

        A = new AuxIdMockERC20();
        B = new AuxIdMockERC20();
        C = new AuxIdMockERC20();
        A.mint(user, 1_000e18);
        B.mint(address(mgr), 1_000e18);
        C.mint(address(mgr), 1_000e18);
    }

    function _pid(address x, address y) internal pure returns (bytes32) {
        (address t0, address t1) = BPC.sortTokens(x, y);
        return BPC.computeV4PoolId(t0, t1, FEE, TS, address(0));
    }

    function _bucket(address pool, address x, address y) internal view returns (uint8) {
        (address t0, address t1) = BPC.sortTokens(x, y);
        return uint8((hub.getSlot(hub.keyOf(pool, t0, t1)) >> 60) & 0xF);
    }

    function _route(bytes32 pid, address counter, address hopOut) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(uint160(uint256(pid))),
            hooks: address(0), kind: BPC.KIND_V4, fee: FEE, tickSpacing: TS,
            zeroForOne: address(A) < counter, stable: false,
            amountIn: 1e18, expectedOut: 0,
            auxId: bytes32(uint256(uint160(counter)))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: hopOut,
                       amountIn: 1e18, expectedOut: 0, legs: legs});
        r.hops = hops;
    }

    /// @notice auxId = C (the real key, so the pool id derives) under a hop
    ///         labelled A -> B: refused with RouterE(3) before any swap, and no
    ///         row is credited - neither the labelled one nor the real one.
    function test_AuxIdOtherThanTheHopOut_IsRefusedBeforeAnySwap() public {
        bytes32 pidAC = _pid(address(A), address(C));
        bytes32 pidAB = _pid(address(A), address(B));
        mgr.setPool(pidAC, Q96, 1e24);
        mgr.setPool(pidAB, Q96, 1e9);
        Route memory r = _route(pidAC, address(C), address(B));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(3)));
        router.swapExactIn(r, 1e18, 1, user, block.timestamp + 1);

        assertEq(mgr.swapCalls(), 0, "nothing may execute on the manager");
        assertEq(_bucket(address(uint160(uint256(pidAB))), address(A), address(B)), 0,
            "the labelled row (A,B) is not credited");
        assertEq(_bucket(address(uint160(uint256(pidAC))), address(A), address(C)), 0,
            "the executed row (A,C) is not credited");
    }

    /// @notice Control: auxId == hop.tokenOut executes and credits the pool
    ///         that executed.
    function test_Control_HonestAuxIdCreditsTheExecutedPool() public {
        bytes32 pidAB = _pid(address(A), address(B));
        mgr.setPool(pidAB, Q96, 1e24);
        Route memory r = _route(pidAB, address(B), address(B));

        vm.prank(user);
        router.swapExactIn(r, 1e18, 1, user, block.timestamp + 1);

        assertEq(mgr.swapCalls(), 1, "control: the honest leg executes once");
        assertGt(_bucket(address(uint160(uint256(pidAB))), address(A), address(B)), 0,
            "control: the honest route credits the pool that executed");
    }
}
