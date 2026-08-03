// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  ROUTER EXEC-PATH GUARDS — offline, mock execution venue.
//
//  Two execution-path defences that can only be reached mid-swap, so they need
//  a venue that actually settles. We stand up a minimal executable V2 pool +
//  mock tokens (no fork, no RPC) and drive a real single-leg swap through it:
//
//    * REENTRANCY (RouterE 7): a malicious tokenIn re-enters swapExactIn during
//      the user-pull (transferFrom). The nrEntrant guard must reject the inner
//      call. The outer swap then completes normally, so the malicious token's
//      record of the rejection survives the transaction.
//    * HOOK ALTERS DELTAS (RouterE 9): a V4 leg whose hook address has the
//      delta-returning permission bits set must be refused before any unlock.
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { BlazePhoenixHub }    from "../src/BlazePhoenixHub.sol";
import { BlazePhoenixSolver } from "../src/BlazePhoenixSolver.sol";
import { BlazePhoenixRouter } from "../src/BlazePhoenixRouter.sol";
import { Route, Hop, Leg } from "../src/BlazePhoenixCore.sol";

interface IERC20Like { function transfer(address, uint256) external returns (bool); }

/// @dev Minimal ERC20: no allowance enforcement (irrelevant to these guards).
contract MockERC20Exec {
    string public symbol = "MOCK";
    uint8  public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) public returns (bool) {
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address from, address to, uint256 amt) public virtual returns (bool) {
        balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
}

/// @dev tokenIn that re-enters the Router during transferFrom, captures the
///      revert, then completes the transfer so the outer swap can finish.
contract ReentrantToken is MockERC20Exec {
    BlazePhoenixRouter public router;
    bool    public armed;
    bool    public fired;
    bool    public reenteredOk;   // true only if the inner swap did NOT revert
    bytes   public reentryErr;

    function arm(BlazePhoenixRouter r) external { router = r; armed = true; }

    function transferFrom(address from, address to, uint256 amt)
        public override returns (bool)
    {
        if (armed && !fired) {
            fired = true;
            Route memory empty;                       // hops.length == 0
            try router.swapExactIn(empty, 1, 0, address(this), type(uint256).max)
                returns (uint256) { reenteredOk = true; }
            catch (bytes memory e) { reentryErr = e; }
        }
        return super.transferFrom(from, to, amt);
    }
}

/// @dev Uniswap-V2-shaped pool that settles: pays the requested side to `to`.
contract MockV2ExecPool {
    address public token0;
    address public token1;
    uint112 private r0;
    uint112 private r1;

    constructor(address t0, address t1, uint112 _r0, uint112 _r1) {
        token0 = t0; token1 = t1; r0 = _r0; r1 = _r1;
    }
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, uint32(block.timestamp));
    }
    function swap(uint256 a0, uint256 a1, address to, bytes calldata) external {
        if (a0 > 0) IERC20Like(token0).transfer(to, a0);
        if (a1 > 0) IERC20Like(token1).transfer(to, a1);
    }
}

contract RouterExecGuardsTest is Test {
    error RouterE(uint16 code);

    uint8 constant KIND_V2 = 0;
    uint8 constant KIND_V4 = 4;

    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    address v4mgr     = makeAddr("v4PoolManager");
    address recipient = makeAddr("recipient");

    function setUp() public {
        hub = new BlazePhoenixHub();
        hub.initialize(address(this), v4mgr);      // nonzero V4 manager
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(this), address(this));
    }

    // ── single V2 leg, h=0, in=token0, out=token1 ──
    function _singleV2Route(address pool, uint256 amt) internal pure returns (Route memory r) {
        Leg memory leg = Leg({
            pool: pool, hooks: address(0), kind: KIND_V2, fee: 0, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({ tokenIn: address(0), tokenOut: address(0), amountIn: amt, expectedOut: 0, legs: legs });
        r.hops = hops;   // tokenIn/Out filled by caller (pool tokens)
    }

    // =========================================================================
    //  REENTRANCY — RouterE(7)
    // =========================================================================
    function test_reentrancy_blocked_RouterE7() public {
        ReentrantToken tin = new ReentrantToken();
        MockERC20Exec  tout = new MockERC20Exec();
        // deep reserves so outV2 yields a clean positive output
        MockV2ExecPool pool = new MockV2ExecPool(
            address(tin), address(tout), uint112(1e24), uint112(1e24));

        uint256 amt = 1e18;
        tin.mint(address(this), amt);        // user funds
        tout.mint(address(pool), 1e24);      // pool can pay out

        Route memory r = _singleV2Route(address(pool), amt);
        r.hops[0].tokenIn  = address(tin);
        r.hops[0].tokenOut = address(tout);

        tin.arm(router);                     // re-enter on the pull

        uint256 out = router.swapExactIn(r, amt, 0, recipient, block.timestamp + 1);

        // The outer swap settled (proves the venue works and state survived)…
        assertGt(out, 0, "outer swap should settle");
        // …and the inner re-entrant call was rejected with RouterE(7).
        assertTrue(tin.fired(), "reentry path not exercised");
        assertFalse(tin.reenteredOk(), "reentry was NOT blocked");
        assertEq(tin.reentryErr(), abi.encodeWithSelector(RouterE.selector, uint16(7)),
            "reentry did not revert RouterE(7)");
    }

    // =========================================================================
    //  HOOK ALTERS DELTAS — RouterE(9)
    // =========================================================================
    function test_v4_hookAltersDeltas_RouterE9() public {
        MockERC20Exec tin = new MockERC20Exec();
        uint256 amt = 1e18;
        tin.mint(address(this), amt);

        // hook with delta-returning bits set (bit 2 → 0x04) ⇒ hookAltersDeltas.
        address badHook = address(0x04);

        Leg memory leg = Leg({
            pool: address(0xDEAD), hooks: badHook, kind: KIND_V4, fee: 0, tickSpacing: 0,
            zeroForOne: true, stable: false, amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tin), tokenOut: makeAddr("tout"),
            amountIn: amt, expectedOut: 0, legs: legs
        });
        Route memory r; r.hops = hops;

        vm.expectRevert(abi.encodeWithSelector(RouterE.selector, uint16(9)));
        router.swapExactIn(r, amt, 0, recipient, block.timestamp + 1);
    }
}
