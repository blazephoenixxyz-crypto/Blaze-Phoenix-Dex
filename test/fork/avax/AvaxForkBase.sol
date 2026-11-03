// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixGate} from "../../../src/BlazePhoenixGate.sol";
import {BlazePhoenixRouter} from "../../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../../src/BlazePhoenixQuoter.sol";

/// @notice Test-only Avalanche C-Chain wiring for the fork tests under test/fork/avax.
///         Same stack and the same order as test/fork/BaseTestDeploy.sol (Hub, Gate, Solver,
///         Router, Quoter, setRoles), with WAVAX as the wrapped native (Router.setWeth) and
///         the battery's three bridges (WAVAX, USDC, BTC.b). Placeholder treasuries only,
///         never the protocol's real ones. No factory row is added here: each test admits
///         exactly the rows it measures, through the helpers below.
/// @dev    One fixed block (FORK_BLOCK) for every Avalanche fork test, so the foundry RPC
///         cache is reused across files. The URL comes from AVAX_FORK_URL only; with it unset
///         the whole contract is skipped (no new foundry.toml entry).
///         EXTENSION POINT: a later file that needs the Gate or an adapter overrides
///         `_afterDeploy()`; it runs once, right after the stack is wired, with this contract
///         as the admin of every component (Hub, Gate, Router).
abstract contract AvaxForkBase is Test {
    uint256 internal constant FORK_BLOCK = 99_270_000;

    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant USDC  = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant BTCB  = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;

    // Uniswap V3 on Avalanche: the canonical V3 factory and init code hash.
    address internal constant UNIV3_FACTORY = 0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD;
    bytes32 internal constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    // Pharaoh V3 (RamsesV3): getPool(address,address,int24) on the factory; the pools are
    // deployed by a separate deployer under keccak(abi.encode(t0, t1, tickSpacing)).
    address internal constant PHARAOH_V3_FACTORY  = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d;
    address internal constant PHARAOH_V3_DEPLOYER = 0x6a4113ed0915bCf5E48e758e8f4cEBFFC07C66f9;
    bytes32 internal constant PHARAOH_V3_INIT =
        0x892f127ed4b26ca352056c8fb54585a3268f76f97fdd84d5836ef4bda8d8c685;

    uint8 internal constant KIND_V3 = 1;
    uint8 internal constant MODE_CALL_V3CL    = 3; // factory.getPool(t0, t1, tickSpacing)
    uint8 internal constant MODE_CREATE2_V3   = 5; // create2(factory, keccak(t0, t1, fee))
    uint8 internal constant MODE_CREATE2_V3CL = 7; // create2(origin, keccak(t0, t1, spacing))

    address internal constant TEST_TREASURY_1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant TEST_TREASURY_2 = address(0x7e52222222222222222222222222222222222222);

    BlazePhoenixHub    internal hub;
    BlazePhoenixGate   internal gate;
    BlazePhoenixSolver internal solver;
    BlazePhoenixRouter internal router;
    BlazePhoenixQuoter internal quoter;

    function setUp() public virtual {
        string memory u = vm.envOr("AVAX_FORK_URL", string(""));
        if (bytes(u).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(u, FORK_BLOCK);
        _deployStack();
        _afterDeploy();
    }

    /// @dev The BaseTestDeploy wiring with this contract as admin. The V4 PoolManager is left
    ///      at zero: no Avalanche V4 row is admitted by this base (a later file may set it).
    function _deployStack() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        gate = new BlazePhoenixGate(address(this));
        solver = new BlazePhoenixSolver(address(hub), address(gate));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), TEST_TREASURY_1, TEST_TREASURY_2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        router.setWeth(WAVAX);
        hub.addBridge(WAVAX);
        hub.addBridge(USDC);
        hub.addBridge(BTCB);
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

    /// @dev Uniswap V3 as BaseTestDeploy wires it: V3 salt by CREATE2, the four tiers.
    function _addUniV3Row() internal returns (uint8) {
        uint24[] memory f = new uint24[](4);
        (f[0], f[1], f[2], f[3]) = (100, 500, 3000, 10000);
        int24[] memory s = new int24[](4);
        (s[0], s[1], s[2], s[3]) = (1, 10, 60, 200);
        return _addRow(UNIV3_FACTORY, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, f, s);
    }

    /// @dev Pharaoh V3 by spacing: mode 3 asks the factory, mode 7 derives from the deployer.
    ///      No fee tier: the fee is dynamic and the Core reads it live (fee 0 in the row).
    function _addPharaohV3Row(uint8 mode) internal returns (uint8) {
        int24[] memory s = new int24[](6);
        (s[0], s[1], s[2], s[3], s[4], s[5]) = (1, 5, 10, 50, 100, 200);
        bool derive = mode == MODE_CREATE2_V3CL;
        return _addRow(
            derive ? PHARAOH_V3_DEPLOYER : PHARAOH_V3_FACTORY, KIND_V3, mode,
            derive ? PHARAOH_V3_INIT : bytes32(0), new uint24[](0), s
        );
    }
}
