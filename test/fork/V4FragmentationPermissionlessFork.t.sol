// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  A STRANGER CAN FRAGMENT SOMEONE ELSE'S V4 BOOK - measured on the canonical
//  PoolManager on Base, not on the mock.
//
//  An honest LP initializes a pool and adds one wide position. A second contract,
//  with no role and no relation to the pool, mints twenty one-wei positions on
//  consecutive ticks beneath spot through `unlock` -> `modifyLiquidity`. The
//  PoolManager accepts them (no hook, so nothing gates the call), and the walk the
//  Solver ranks with (`Core.v4WalkOut`, 16 stretches) now stops 15 ticks below
//  spot. This is the precondition the mock tests in V4FragmentationReach.t.sol
//  and V4FragmentationRanking.t.sol take as given. The sixteen-stretch walk is the
//  PROMISE and stays truncated (a floor is safe); the ranking figure the Solver
//  orders by (`Core.v4WalkRank`, deep walk) must still read the honest book.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

struct PoolKeyP { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct ModifyLiquidityParamsP { int24 tickLower; int24 tickUpper; int256 liquidityDelta; bytes32 salt; }

interface IPoolManagerP {
    function initialize(PoolKeyP memory key, uint160 sqrtPriceX96) external returns (int24);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKeyP memory key, ModifyLiquidityParamsP memory p, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
}

/// @dev Adds a list of positions through one canonical unlock and pays what it owes.
contract PositionMinter {
    IPoolManagerP immutable pm;
    constructor(IPoolManagerP p) { pm = p; }

    function mint(PoolKeyP memory key, int24[] memory lo, int24[] memory hi, int256 liq) external {
        pm.unlock(abi.encode(key, lo, hi, liq));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKeyP memory key, int24[] memory lo, int24[] memory hi, int256 liq) =
            abi.decode(data, (PoolKeyP, int24[], int24[], int256));
        int256 owe0;
        int256 owe1;
        for (uint256 i; i < lo.length; ++i) {
            (int256 d, ) = pm.modifyLiquidity(key, ModifyLiquidityParamsP(lo[i], hi[i], liq, bytes32(0)), "");
            owe0 += int256(int128(d >> 128));
            owe1 += int256(int128(d));
        }
        if (owe0 < 0) _pay(key.currency0, uint256(-owe0));
        if (owe1 < 0) _pay(key.currency1, uint256(-owe1));
        return "";
    }

    function _pay(address c, uint256 amt) internal {
        pm.sync(c);
        MockERC20(c).transfer(address(pm), amt);
        pm.settle();
    }
}

contract V4FragmentationPermissionlessFork is Test {
    IPoolManagerP constant PM = IPoolManagerP(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    uint256 constant BASE_BLOCK = 49_800_000;
    uint24  constant FEE = 100;
    int24   constant TS  = 1;
    uint256 constant ORDER = 1e22;

    function test_Fork_StrangerFragmentsAnHonestPool() public {
        // No DRPC_KEY, no fork: skip rather than fail, as every fork suite here does.
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base", BASE_BLOCK);

        MockERC20 a = new MockERC20("A", "A");
        MockERC20 b = new MockERC20("B", "B");
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKeyP memory key = PoolKeyP(c0, c1, FEE, TS, address(0));
        bytes32 pid = BPC.computeV4PoolId(c0, c1, FEE, TS, address(0));

        PositionMinter honest   = new PositionMinter(PM);
        PositionMinter stranger = new PositionMinter(PM);
        MockERC20(c0).mint(address(honest), 1e30);
        MockERC20(c1).mint(address(honest), 1e30);
        MockERC20(c0).mint(address(stranger), 1e6);
        MockERC20(c1).mint(address(stranger), 1e6);

        PM.initialize(key, BPC.sqrtPriceAtTick(0));
        int24[] memory lo = new int24[](1);
        int24[] memory hi = new int24[](1);
        lo[0] = -20_000; hi[0] = 20_000;
        honest.mint(key, lo, hi, 1e24);
        uint256 clean = BPC.v4WalkOut(address(PM), pid, ORDER, FEE, TS, true);

        int24[] memory flo = new int24[](20);
        int24[] memory fhi = new int24[](20);
        for (uint256 i; i < 20; ++i) { flo[i] = -20 + int24(int256(i)); fhi[i] = flo[i] + 1; }
        uint256 s0 = MockERC20(c0).balanceOf(address(stranger));
        uint256 s1 = MockERC20(c1).balanceOf(address(stranger));
        stranger.mint(key, flo, fhi, 1);        // no prank, no role: a plain contract
        uint256 dirty = BPC.v4WalkOut(address(PM), pid, ORDER, FEE, TS, true);
        (uint256 lo_, uint256 rank, ) = BPC.v4WalkRank(address(PM), pid, ORDER, FEE, TS, true, 0);

        emit log_named_uint("walk, clean (real PoolManager)     ", clean);
        emit log_named_uint("walk, after 20 one-wei mints       ", dirty);
        emit log_named_uint("stranger paid, token0 (wei)        ", s0 - MockERC20(c0).balanceOf(address(stranger)));
        emit log_named_uint("stranger paid, token1 (wei)        ", s1 - MockERC20(c1).balanceOf(address(stranger)));
        assertGt(clean, 9e21, "control: the walk reads the honest book");
        assertLt(dirty * 10, clean, "the stranger's mints did not truncate the walk");
        emit log_named_uint("rank, after 20 one-wei mints       ", rank);
        assertEq(lo_, dirty, "the rank walk's promise is the sixteen-stretch walk");
        assertApproxEqRel(rank, clean, 1e12, "the deep walk does not read the honest book");
    }
}
