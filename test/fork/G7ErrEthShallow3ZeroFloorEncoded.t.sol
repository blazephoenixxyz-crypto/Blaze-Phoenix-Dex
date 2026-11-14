// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  G7 draw ethereum shallow-3 idx 2 (block 26,316,739): USDC -> MKR, amount_in 1 (one unit).
//  G7 lines: 16 (idx 2 and idx 5, 8 modes each), all `revert exec:0x62b0a386` = RouterE(10),
//  quoted with eff_min_out 0 and netOut 650,889,588 (idx 2) / 647,300,683 (idx 5).
//
//  The floor of a one-unit input is zero: `Solver._assembleRouteMulti` sizes it as
//  mulDivUp(base, floorBps, BPS) with base = `BPC.netOfInputFees`, and on b = 1 the fee
//  mulDivUp(1, PROTOCOL_FEE_BPS, BPS) = 1 takes the whole input (b > f false -> base 0).
//  `Quoter._pack` publishes effectiveMinOut = max(0, 0) = 0 and canExecute = netOut > 0 &&
//  netOut >= 0; `previewAndEncode` encodes swapExactIn(..., minOut 0, ...), and the Router
//  refuses minOut 0 with a non-zero amountIn (Router:482, BP-04). The door's own doc: it never
//  returns bytes it already knows will not settle.
//
//  Pinned here (stack: G7 ethereum deploy, `_core` + `_ethereum` + wiring.tsv, bridges on):
//    oracle : one whole USDC (1e6 units) quotes a non-zero floor and the bytes settle. Green.
//    cause  : at 1 unit, whenever the door says canExecute, the bytes carry a non-zero floor
//             and the Router accepts them. Red at juncao-125 588364f (canExecute with a
//             zero floor); green since `Quoter._encode` withholds canExecute and the bytes
//             on a zero effectiveMinOut (2026-11-14). Mutant [QF-6].
//  Run: forge test --match-path test/fork/G7ErrEthShallow3ZeroFloorEncoded.t.sol -vv (DRPC_KEY set).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixGate} from "../../src/BlazePhoenixGate.sol";

interface IERC20G7Z {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

contract G7ErrEthShallow3ZeroFloorEncodedTest is Test {
    uint256 internal constant BLK = 26_316_739;
    address internal constant MKR = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant V4_MGR = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant UNIV3_INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    struct Stack { BlazePhoenixHub hub; BlazePhoenixSolver solver; BlazePhoenixRouter router; BlazePhoenixQuoter quoter; }

    address internal user = address(0xD1A6);

    function setUp() public {
        vm.createSelectFork("mainnet", BLK);
    }

    /// @dev Same deploy as G7ErrEthC6UnwalkedLastHop `_deploy(true)`.
    function _deploy() internal returns (Stack memory s) {
        address me = address(this);
        s.hub = new BlazePhoenixHub(me);
        s.hub.initialize(me, V4_MGR);
        address gate = address(new BlazePhoenixGate(me));
        s.solver = new BlazePhoenixSolver(address(s.hub), gate);
        s.router = new BlazePhoenixRouter(
            address(s.hub), address(s.solver), me,
            address(0x7E51111111111111111111111111111111111111), address(0x7e52222222222222222222222222222222222222));
        s.quoter = new BlazePhoenixQuoter(address(s.hub), address(s.solver));
        s.hub.setRoles(address(s.router), address(s.solver), address(s.quoter));
        uint24[] memory f0 = new uint24[](0);
        int24[] memory s0 = new int24[](0);
        s.hub.addFactory(0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f, 0, 0, bytes32(0), f0, s0); // _core row
        s.router.setWeth(WETH);
        s.hub.addBridge(WETH); s.hub.addBridge(USDC); s.hub.addBridge(USDT);
        uint24[] memory f = new uint24[](4); f[0] = 100; f[1] = 500; f[2] = 3000; f[3] = 10000;
        int24[] memory sp = new int24[](4); sp[0] = 1; sp[1] = 10; sp[2] = 60; sp[3] = 200;
        s.hub.addFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984, 1, 5, UNIV3_INIT, f, sp);   // wiring.tsv 1
        s.hub.addFactory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f, 0, 0, bytes32(0), f0, s0);   // 2
        s.hub.addFactory(0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac, 0, 0, bytes32(0), f0, s0);   // 3
        s.hub.addFactory(0x1097053Fd2ea711dad45caCcc45EfF7548fCB362, 0, 0, bytes32(0), f0, s0);   // 4
        s.hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, 1, 1, bytes32(0), f, sp);    // 5
        s.hub.addFactory(0xbACEB8eC6b9355Dfc0269C18bac9d6E2Bdc29C4F, 1, 1, bytes32(0), f, sp);    // 6
        s.hub.addFactory(0x115934131916C8b277DD010Ee02de363c09d037c, 0, 0, bytes32(0), f0, s0);   // 7
        s.hub.addFactory(0x43eC799eAdd63848443E2347C49f5f52e8Fe0F6f, 0, 0, bytes32(0), f0, s0);   // 8
    }

    /// @dev Encode at `amt`, then submit the bytes as the user. Returns the preview and whether
    ///      the Router accepted them (false also when the door returned no bytes).
    function _encodeAndSubmit(Stack memory s, uint256 amt)
        internal returns (BlazePhoenixQuoter.Preview memory pv, bool settled)
    {
        bytes memory call;
        (pv, call) = s.quoter.previewAndEncode(USDC, MKR, amt, user, block.timestamp + 600);
        emit log_named_uint("amountIn", amt);
        emit log_named_uint("netOut", pv.netOut);
        emit log_named_uint("effectiveMinOut", pv.effectiveMinOut);
        emit log_named_uint("canExecute", pv.canExecute ? 1 : 0);
        if (call.length == 0) return (pv, false);
        deal(USDC, user, amt);
        vm.startPrank(user);
        IERC20G7Z(USDC).approve(address(s.router), amt);
        (settled,) = address(s.router).call(call);
        vm.stopPrank();
    }

    /// @dev Oracle: a whole USDC carries a non-zero floor and settles.
    function test_oracle_oneWholeUsdc_floorIsNonZeroAndTheBytesSettle() public {
        Stack memory s = _deploy();
        (BlazePhoenixQuoter.Preview memory pv, bool settled) = _encodeAndSubmit(s, 1e6);
        assertTrue(pv.canExecute, "precondition: one USDC quotes at this block");
        assertGt(pv.effectiveMinOut, 0, "a whole unit carries a floor");
        assertTrue(settled, "the Router settles the bytes the Quoter encoded");
    }

    /// @dev One unit: the door never says executable with a zero floor the Router refuses.
    function test_oneUnit_executableBytesCarryANonZeroFloorAndSettle() public {
        Stack memory s = _deploy();
        (BlazePhoenixQuoter.Preview memory pv, bool settled) = _encodeAndSubmit(s, 1);
        if (!pv.canExecute) return; // a door that refuses is the fixed behaviour
        assertGt(pv.effectiveMinOut, 0, "executable bytes carry a non-zero floor (Router:482 refuses 0)");
        assertTrue(settled, "executable bytes settle");
    }

    /// @dev The fee boundary: at 2 units the input fee no longer takes the whole input, so the
    ///      floor base is non-zero. Pins the edge of the cause, either side of +1 unit.
    function test_twoUnits_feeLeavesABase_executableBytesSettleOrTheDoorRefuses() public {
        Stack memory s = _deploy();
        (BlazePhoenixQuoter.Preview memory pv, bool settled) = _encodeAndSubmit(s, 2);
        if (!pv.canExecute) return;
        assertGt(pv.effectiveMinOut, 0, "two units carry a non-zero floor");
        assertTrue(settled, "executable bytes settle");
    }
}
