// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  WHAT A HOOK REACHED THROUGH A NESTED POOLMANAGER CALL CAN DO TO OUR SWAP,
//  measured against the canonical PoolManager on Base (ninth wave, Karan Rathod).
//
//  An admitted BEFORE_SWAP hook calls `donate` on a second pool from inside its
//  callback; the second pool's BEFORE_DONATE hook was never admitted by the Hub.
//  The claim under test has two halves, and they are measured separately:
//    1. the unadmitted hook's code runs inside the Router's unlock        (true?)
//    2. it can `take` tokens it never settles, and keep them              (drain?)
//  plus the report's later form: a donate the admitted hook never settles.
//  The PoolManager's own flash accounting is the boundary being measured: every
//  delta must be zero when the unlock returns, whoever created it.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

struct PoolKeyF { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct ModifyLiquidityParamsF { int24 tickLower; int24 tickUpper; int256 liquidityDelta; bytes32 salt; }
struct SwapParamsF { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

interface IPoolManagerF {
    function initialize(PoolKeyF memory key, uint160 sqrtPriceX96) external returns (int24);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKeyF memory key, ModifyLiquidityParamsF memory p, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function donate(PoolKeyF memory key, uint256 a0, uint256 a1, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

interface IERC20F {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Adds liquidity through the canonical unlock and settles what it owes.
contract LiquidityAdder {
    IPoolManagerF immutable pm;
    constructor(IPoolManagerF p) { pm = p; }

    function add(PoolKeyF memory key, int256 liq) external {
        pm.unlock(abi.encode(key, liq));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKeyF memory key, int256 liq) = abi.decode(data, (PoolKeyF, int256));
        (int256 d, ) = pm.modifyLiquidity(key, ModifyLiquidityParamsF(-600, 600, liq, bytes32(0)), "");
        int128 a0 = int128(d >> 128);
        int128 a1 = int128(d);
        if (a0 < 0) _pay(key.currency0, uint256(uint128(-a0)));
        if (a1 < 0) _pay(key.currency1, uint256(uint128(-a1)));
        return "";
    }

    function _pay(address c, uint256 amt) internal {
        pm.sync(c);
        IERC20F(c).transfer(address(pm), amt);
        pm.settle();
    }
}

/// @dev BEFORE_SWAP only (address bit 7). Donates to a second pool from inside
///      its callback - the "documented fee-redistribution" pattern of the report.
contract DonatingHook {
    IPoolManagerF public pm;
    PoolKeyF public target;
    uint256 public donate0;

    function configure(IPoolManagerF p, PoolKeyF memory t, uint256 d0) external {
        pm = p; target = t; donate0 = d0;
    }

    function beforeSwap(address, PoolKeyF calldata, SwapParamsF calldata, bytes calldata)
        external returns (bytes4, int256, uint24)
    {
        pm.donate(target, donate0, 0, "");
        return (this.beforeSwap.selector, 0, 0);
    }
}

/// @dev BEFORE_DONATE only (address bit 5). Never admitted by the Hub. Records
///      that it ran, and optionally takes tokens it never settles.
contract TakingHook {
    IPoolManagerF public pm;
    address public currency;
    address public attacker;
    uint256 public takeAmt;
    bool public ran;

    function configure(IPoolManagerF p, address c, address a, uint256 t) external {
        pm = p; currency = c; attacker = a; takeAmt = t;
    }

    function beforeDonate(address, PoolKeyF calldata, uint256, uint256, bytes calldata)
        external returns (bytes4)
    {
        ran = true;
        if (takeAmt != 0) pm.take(currency, attacker, takeAmt);
        return this.beforeDonate.selector;
    }
}

contract NestedHookSettlementFork is Test {
    IPoolManagerF constant PM = IPoolManagerF(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    bytes4 constant CURRENCY_NOT_SETTLED = bytes4(keccak256("CurrencyNotSettled()"));

    // Flag bits live in the low 14 bits of the address; the high bits are free.
    address constant H_A = address(uint160(0x4000000000000000000000000000000000000080)); // BEFORE_SWAP
    address constant H_B = address(uint160(0x4000000000000000000000000000000000000020)); // BEFORE_DONATE
    address constant USER = address(0xBEEF);
    address constant ATTACKER = address(0xBAD);

    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 A;
    MockERC20 B;
    address c0;
    address c1;
    PoolKeyF keyA;
    PoolKeyF keyB;

    function setUp() public {
        vm.createSelectFork("base");

        A = new MockERC20("AAA", "AAA");
        B = new MockERC20("BBB", "BBB");
        (c0, c1) = address(A) < address(B) ? (address(A), address(B)) : (address(B), address(A));

        vm.etch(H_A, address(new DonatingHook()).code);
        vm.etch(H_B, address(new TakingHook()).code);

        keyA = PoolKeyF(c0, c1, 3000, 60, H_A);
        keyB = PoolKeyF(c0, c1, 3000, 60, H_B);
        PM.initialize(keyA, uint160(1 << 96));
        PM.initialize(keyB, uint160(1 << 96));

        LiquidityAdder adder = new LiquidityAdder(PM);
        A.mint(address(adder), 1e24);
        B.mint(address(adder), 1e24);
        adder.add(keyA, 1e23);
        adder.add(keyB, 1e23);

        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(PM));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));
        // The operator door admits and pins the swap hook - the path the report names.
        hub.addV4(c0, c1, 3000, 60, H_A);

        A.mint(USER, 1e21);
        vm.prank(USER);
        A.approve(address(router), type(uint256).max);
    }

    function _route(uint256 amt) internal view returns (Route memory r) {
        bytes32 pid = keccak256(abi.encode(keyA));
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(uint160(uint256(pid))), hooks: H_A, kind: BPC.KIND_V4,
            fee: 3000, tickSpacing: 60, zeroForOne: address(A) == c0, stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(uint256(uint160(address(B))))
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: amt, expectedOut: 0, legs: legs});
        r = Route({hops: hops, totalOut: 0, singleOut: 0, singleOutFloor: 0,
                   expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    /// Half 1: the unadmitted hook's code does run inside the Router's unlock.
    function test_AnUnadmittedHookReachedByANestedDonateRunsInsideOurSwap() public {
        DonatingHook(H_A).configure(PM, keyB, 0);
        TakingHook(H_B).configure(PM, address(A), ATTACKER, 0);
        assertFalse(hub.isHookLive(H_B), "setup: H_B must not be admitted");

        vm.prank(USER);
        uint256 got = router.swapExactIn(_route(1e18), 1e18, 1, USER, block.timestamp + 1);
        console2.log("delivered:", got);
        assertTrue(TakingHook(H_B).ran(), "the nested hook did not run");
    }

    /// Half 2: what it takes without settling cannot leave - the whole swap reverts.
    function test_ATakeTheNestedHookNeverSettlesRevertsTheWholeSwap() public {
        DonatingHook(H_A).configure(PM, keyB, 0);
        TakingHook(H_B).configure(PM, address(A), ATTACKER, 500e18);

        vm.prank(USER);
        try router.swapExactIn(_route(1e18), 1e18, 1, USER, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            emit log_named_bytes("revert data", err);
            assertEq(bytes4(err), CURRENCY_NOT_SETTLED, "the swap failed for another reason");
        }
        assertEq(A.balanceOf(ATTACKER), 0, "the nested hook kept tokens it never settled");
    }

    /// The report's later form: the admitted hook donates without settling.
    function test_AnAdmittedHookThatNeverSettlesItsDonateRevertsTheSwap() public {
        DonatingHook(H_A).configure(PM, keyB, 1e15);
        TakingHook(H_B).configure(PM, address(A), ATTACKER, 0);

        vm.prank(USER);
        try router.swapExactIn(_route(1e18), 1e18, 1, USER, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            emit log_named_bytes("revert data", err);
            assertEq(bytes4(err), CURRENCY_NOT_SETTLED, "the swap failed for another reason");
        }
    }
}
