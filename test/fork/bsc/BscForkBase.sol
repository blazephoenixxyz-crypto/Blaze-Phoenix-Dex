// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixGate} from "../../../src/BlazePhoenixGate.sol";
import {BlazePhoenixRouter} from "../../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../../src/BlazePhoenixQuoter.sol";

/// @notice Test-only BNB Smart Chain wiring for the fork tests under test/fork/bsc.
///         Same stack and the same order as test/fork/BaseTestDeploy.sol (Hub, Gate, Solver,
///         Router, Quoter, setRoles), with WBNB as the wrapped native (Router.setWeth), the
///         Uniswap V4 PoolManager on BSC as the Hub's V4 manager, and three bridges (WBNB,
///         USDT, USDC). Placeholder treasuries only, never the protocol's real ones. No
///         factory row is added here: each test admits exactly the rows it measures.
/// @dev    One fixed block (FORK_BLOCK) for every BSC fork test, so the foundry RPC cache is
///         reused across files. The URL comes from BSC_FORK_URL only; with it unset the whole
///         contract is skipped (no new foundry.toml entry). Mirrors test/fork/avax/AvaxForkBase.
///         EXTENSION POINT: a later file that needs the Gate or an adapter overrides
///         `_afterDeploy()`; it runs once, right after the stack is wired, with this contract
///         as the admin of every component (Hub, Gate, Router).
abstract contract BscForkBase is Test {
    uint256 internal constant FORK_BLOCK = 131_960_000;

    // BSC tokens. BSC-USD (USDT) and USDC are 18-decimal BEP-20s on this chain.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    // Venue factories, each answering the Hub's lookup modes (0 getPair, 1 getPool(fee)).
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant UNI_V3_FACTORY     = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    // Uniswap V4 singleton on BSC.
    address internal constant UNI_V4_PM          = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;

    uint8 internal constant KIND_V2 = 0;
    uint8 internal constant KIND_V3 = 1;
    uint8 internal constant MODE_CALL_V2 = 0; // factory.getPair(t0, t1)
    uint8 internal constant MODE_CALL_V3 = 1; // factory.getPool(t0, t1, fee)

    address internal constant TEST_TREASURY_1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant TEST_TREASURY_2 = address(0x7e52222222222222222222222222222222222222);

    BlazePhoenixHub    internal hub;
    BlazePhoenixGate   internal gate;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    BlazePhoenixQuoter internal quoter;

    function setUp() public virtual {
        string memory u = vm.envOr("BSC_FORK_URL", string(""));
        if (bytes(u).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(u, FORK_BLOCK);
        _deployStack();
        _afterDeploy();
    }

    /// @dev The BaseTestDeploy wiring with this contract as admin, the BSC V4 PoolManager as
    ///      the Hub's V4 manager.
    function _deployStack() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), UNI_V4_PM);
        gate = new BlazePhoenixGate(address(this));
        solver = new BlazePhoenixSolver(address(hub), address(gate));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), TEST_TREASURY_1, TEST_TREASURY_2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        router.setWeth(WBNB);
        hub.addBridge(WBNB);
        hub.addBridge(USDT);
        hub.addBridge(USDC);
    }

    /// @dev Extension point for the Gate and the adapters (later waves). Empty here.
    function _afterDeploy() internal virtual {}

    /// @dev One Hub row, admitted with this contract as admin. Returns the row index.
    function _addRow(
        address factory, uint8 kind, uint8 mode, bytes32 initHash,
        uint24[] memory fees, int24[] memory spacings
    ) internal returns (uint8) {
        return hub.addFactory(factory, kind, mode, initHash, fees, spacings);
    }

    /// @dev A V3 row that asks `factory.getPool(t0, t1, fee)` at four fee tiers; the spacing
    ///      axis is never read by mode 1 (its first cell is what discovery lists).
    function _addV3CallRow(address factory, uint24[4] memory f, int24[4] memory s) internal returns (uint8) {
        uint24[] memory fees = new uint24[](4);
        int24[] memory sp = new int24[](4);
        for (uint256 i; i < 4; ++i) (fees[i], sp[i]) = (f[i], s[i]);
        return _addRow(factory, KIND_V3, MODE_CALL_V3, bytes32(0), fees, sp);
    }

    /// @dev A V2 row that asks `factory.getPair(t0, t1)`; no fee tier declared.
    function _addV2CallRow(address factory) internal returns (uint8) {
        return _addRow(factory, KIND_V2, MODE_CALL_V2, bytes32(0), new uint24[](0), new int24[](0));
    }
}
