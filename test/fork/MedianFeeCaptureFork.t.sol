// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// MED (2026-10-27), on Base: the real BRETT/WETH venues (Uniswap V3 0.05/0.3/1%, Aerodrome, ...)
// beside a HOOKLESS V4 pool at a static 10% fee, initialized at the market price on the canonical
// PoolManager by a stranger and claimed through the permissionless `Hub.claimV4`. The stranger's
// full-range liquidity is sized as k times the honest voting mass H (short side, 18 decimals,
// capped by the tokenOut held - the figure `_buildHop` hands the median). Red on the tree before
// MED (2026-10-28), measured at e211ef3; the fix is the band of BlazePhoenixMath ("THE BAND").
// Runs only with MED_RPC set to a Base archive RPC (block 53_174_000) and skips without it; it is
// not in the CI fork lane's list.
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../../src/BlazePhoenixCore.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {PositionMinter, PoolKeyP, IPoolManagerP} from "./V4FragmentationPermissionlessFork.t.sol";

interface IV3Like { function liquidity() external view returns (uint128); function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool); }
interface IPairLike { function getReserves() external view returns (uint256, uint256, uint256); }
interface IERC20L { function balanceOf(address) external view returns (uint256); function approve(address, uint256) external returns (bool); }

contract MedianFeeCaptureFork is Test {
    address constant WETH  = 0x4200000000000000000000000000000000000006;
    address constant BRETT = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
    address constant UNI3_1PC = 0xBA3F945812a83471d709BCe9C3CA699A19FB46f7;   // BRETT/WETH 1%, the price reference
    IPoolManagerP constant PM = IPoolManagerP(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    uint256 constant BLOCK = 53_174_000;
    uint24 constant BAD_FEE = 100_000;   // 10%, static, hookless: any LP may create it
    int24 constant TS = 200;
    uint256 constant AMOUNT_IN = 1e18;   // 1 WETH -> BRETT

    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    function setUp() public {
        string memory rpc = vm.envOr("MED_RPC", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc, BLOCK);
        (hub, solver, router, quoter) = BaseTestDeploy.deploy(address(this));
    }

    /// The honest voting mass for WETH -> BRETT, as `_buildHop` builds it for these kinds.
    function _honestMass() internal returns (uint256 h) {
        PoolInfo[] memory c = hub.discoverFor(WETH, BRETT);
        for (uint256 i; i < c.length; ++i) {
            uint256 d;
            (bool ok, bytes memory r) = c[i].pool.staticcall(abi.encodeWithSignature("liquidity()"));
            if (ok && r.length == 32) {
                // first word only: Slipstream's slot0 has six fields, Uniswap's seven
                (, bytes memory s0) = c[i].pool.staticcall(abi.encodeWithSignature("slot0()"));
                uint160 sp = uint160(uint256(bytes32(s0)));
                d = BPC.depthFromL18(abi.decode(r, (uint128)), sp, 18, 18);
            } else {
                (uint256 r0, uint256 r1, ) = IPairLike(c[i].pool).getReserves();
                d = r0 < r1 ? r0 : r1;
            }
            uint256 phys = IERC20L(BRETT).balanceOf(c[i].pool);
            if (phys < d) d = phys;
            emit log_named_address("honest venue", c[i].pool);
            emit log_named_uint("  its vote (short side, 1e18)", d);
            h += d;
        }
    }

    function _preview() internal returns (BlazePhoenixQuoter.Preview memory pv) {
        vm.roll(block.number + 1);
        (pv, ) = quoter.previewAndEncode(WETH, BRETT, AMOUNT_IN, user, block.timestamp + 600);
    }

    function _inOf(BlazePhoenixQuoter.Preview memory pv, address p) internal pure returns (uint256 s) {
        for (uint256 h; h < pv.route.hops.length; ++h) {
            for (uint256 l; l < pv.route.hops[h].legs.length; ++l) {
                if (pv.route.hops[h].legs[l].pool == p) s += pv.route.hops[h].legs[l].amountIn;
            }
        }
    }

    /// The stranger's pool: init at the 1% pool's price, one full-range position of liquidity
    /// `liq`, claimed with no role. Returns the V4 pool's pseudo-address (the route's leg).
    function _strangerPool(uint256 liq) internal returns (address v4) {
        (uint160 sp, , , , , , ) = IV3Like(UNI3_1PC).slot0();
        PoolKeyP memory key = PoolKeyP(WETH, BRETT, BAD_FEE, TS, address(0));
        PM.initialize(key, sp);
        PositionMinter m = new PositionMinter(PM);
        uint256 x0 = BPC.mulDiv(liq, BPC.Q96, sp) + 1e18;
        uint256 x1 = BPC.mulDiv(liq, sp, BPC.Q96) + 1e18;
        deal(WETH, address(m), x0);
        deal(BRETT, address(m), x1);
        int24[] memory lo = new int24[](1);
        int24[] memory hi = new int24[](1);
        lo[0] = -887_200; hi[0] = 887_200;
        m.mint(key, lo, hi, int256(liq));
        emit log_named_uint("stranger deposit, WETH (wei)", x0 - IERC20L(WETH).balanceOf(address(m)));
        emit log_named_uint("stranger deposit, BRETT (wei)", x1 - IERC20L(BRETT).balanceOf(address(m)));
        vm.prank(stranger);
        hub.claimV4(WETH, BRETT, BAD_FEE, TS);
        v4 = address(uint160(uint256(BPC.computeV4PoolId(WETH, BRETT, BAD_FEE, TS, address(0)))));
    }

    /// Liquidity whose short-side depth at the market price is `k1000/1000` x the honest mass.
    function _liqFor(uint256 h, uint256 k1000) internal view returns (uint256) {
        (uint160 sp, , , , , , ) = IV3Like(UNI3_1PC).slot0();
        uint256 unit = BPC.depthFromL18(1e18, sp, 18, 18);
        return BPC.mulDiv(h, k1000 * 1e18, unit * 1000);
    }

    function _legs(BlazePhoenixQuoter.Preview memory pv) internal pure returns (uint256 n) {
        for (uint256 h; h < pv.route.hops.length; ++h) n += pv.route.hops[h].legs.length;
    }

    function _run(uint256 k1000) internal returns (uint256 baseline, uint256 attacked, uint256 viaBad) {
        BlazePhoenixQuoter.Preview memory p0 = _preview();
        baseline = p0.netOut;
        uint256 h = _honestMass();
        emit log_named_uint("honest mass H (1e18)", h);
        address bad = _strangerPool(_liqFor(h, k1000));
        BlazePhoenixQuoter.Preview memory pv = _preview();
        attacked = pv.netOut;
        viaBad = _inOf(pv, bad);
        emit log_named_uint("k x1000", k1000);
        emit log_named_uint("netOut before the stranger's pool", baseline);
        emit log_named_uint("  legs before", _legs(p0));
        emit log_named_uint("netOut after", attacked);
        emit log_named_uint("  legs after", _legs(pv));
        emit log_named_uint("WETH routed into the 10% pool", viaBad);
    }

    /// RED on the tree before MED: at 1.02 H the 10% pool takes the order and the output drops ~10%.
    /// After MED the pool sits inside the band and the split's gate decides: the gate keeps the
    /// best single venue, not the honest split. If the route before the pool was a split that
    /// beat its best single leg, this stays red by that margin (on mocks of this shape, two 0.3%
    /// venues and an order of 1% of each one's depth, the collapse cost 0.49%). The legs logged
    /// above tell which case the block is in.
    function test_Fork_A10pcPoolAtTheHonestMassTakesTheOrder() public {
        (uint256 baseline, uint256 attacked, ) = _run(1020);
        assertGe(attacked, baseline, "a stranger's 10% pool lowered the route's output");
    }

    /// The user's floor from the preview does not stop it: the Router delivers the loss.
    function test_Fork_TheFloorFromThePreviewDeliversTheLoss() public {
        (uint256 baseline, , ) = _run(1020);
        BlazePhoenixQuoter.Preview memory pv = _preview();
        deal(WETH, user, AMOUNT_IN);
        vm.startPrank(user);
        IERC20L(WETH).approve(address(router), AMOUNT_IN);
        uint256 delivered = router.swapExactIn(pv.route, AMOUNT_IN, pv.netOut * 9950 / 10_000, user, block.timestamp + 600);
        vm.stopPrank();
        emit log_named_uint("delivered BRETT (wei)", delivered);
        assertGe(delivered, baseline * 9950 / 10_000, "the floor from the preview let the loss through");
    }

    /// CONTROL (green on the tree before MED): at 0.5 H the 10% pool is no leg.
    function test_Fork_Control_HalfTheHonestMassIsNoLeg() public {
        (uint256 baseline, uint256 attacked, uint256 viaBad) = _run(500);
        assertEq(viaBad, 0, "control: the 10% pool is a leg at half the honest mass");
        assertGe(attacked, baseline * 9990 / 10_000, "control: output kept");
    }
}
