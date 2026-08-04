// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

/// @notice Test-only Base mainnet wiring: registers the same public,
///         well-known DEX factories/bridges a real deploy would, using
///         placeholder test treasuries (never the protocol's real ones).
///         This repository's operational deploy script is intentionally
///         not published here — this helper exists purely so the fork
///         tests can exercise real discovery/execution against live venues
///         without depending on it.
///
///         Internal library function (not an external script call): `new`
///         and every subsequent call run in the CALLER's own context, so
///         the caller can pass itself as `admin` and every onlyControl call
///         that follows matches — avoids the caller-consistency pitfall an
///         external `forge script` broadcast doesn't have to worry about
///         (every call in a real broadcast runs as the same EOA) but a
///         plain external call to a separately-deployed script contract
///         does.
library BaseTestDeploy {
    uint8 internal constant KIND_V2 = 0;
    uint8 internal constant KIND_V3 = 1;
    uint8 internal constant KIND_SOLIDLY = 5;
    uint8 internal constant MODE_CALL_GENERIC = 0;
    uint8 internal constant MODE_CALL_V3 = 1;
    uint8 internal constant MODE_CALL_SOLIDLY = 2;
    uint8 internal constant MODE_CALL_V3CL = 3;
    uint8 internal constant MODE_CREATE2_V3 = 5;
    bytes32 internal constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    address internal constant BASE_UNIV2  = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address internal constant BASE_UNIV3  = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant BASE_AERO   = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address internal constant BASE_V4_MGR = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant BASE_PCK3   = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant BASE_SUSHI3 = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
    address internal constant BASE_BSWAP  = 0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB;
    address internal constant BASE_SUSHI2 = 0x71524B4f93c58fcbF659783284E38825f0622859;
    address internal constant BASE_AEROCL = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant BASE_PCK2   = 0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Placeholder test-only fee recipients — never the real treasuries.
    address internal constant TEST_TREASURY_1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant TEST_TREASURY_2 = address(0x7e52222222222222222222222222222222222222);

    function deploy(address admin)
        internal
        returns (BlazePhoenixHub hub, BlazePhoenixSolver solver, BlazePhoenixRouter router, BlazePhoenixQuoter quoter)
    {
        hub = new BlazePhoenixHub();
        hub.initialize(admin, BASE_V4_MGR);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), admin, TEST_TREASURY_1, TEST_TREASURY_2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));

        hub.addBridge(BASE_WETH);
        hub.addBridge(BASE_USDC);
        hub.addFactory(BASE_UNIV3,  KIND_V3,      MODE_CREATE2_V3,   UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(BASE_AERO,   KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _none24(), _noneSp());
        hub.addFactory(BASE_UNIV2,  KIND_V2,      MODE_CALL_GENERIC, bytes32(0), _none24(), _noneSp());
        hub.addFactory(BASE_PCK3,   KIND_V3,      MODE_CALL_V3,      bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(BASE_SUSHI3, KIND_V3,      MODE_CALL_V3,      bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(BASE_BSWAP,  KIND_V2,      MODE_CALL_GENERIC, bytes32(0), _none24(), _noneSp());
        hub.addFactory(BASE_SUSHI2, KIND_V2,      MODE_CALL_GENERIC, bytes32(0), _none24(), _noneSp());
        hub.addFactory(BASE_AEROCL, KIND_V3,      MODE_CALL_V3CL,    bytes32(0), _none24(), _clSp());
        hub.addFactory(BASE_PCK2,   KIND_V2,      MODE_CALL_GENERIC, bytes32(0), _none24(), _noneSp());
        hub.addV4(BASE_USDC, BASE_WETH, 500, 10, address(0));
    }

    function _v3Fees() private pure returns (uint24[] memory f) {
        f = new uint24[](4); f[0]=100; f[1]=500; f[2]=3000; f[3]=10000;
    }
    function _v3Sp() private pure returns (int24[] memory s) {
        s = new int24[](4); s[0]=1; s[1]=10; s[2]=60; s[3]=200;
    }
    function _clSp() private pure returns (int24[] memory s) {
        s = new int24[](5); s[0]=1; s[1]=50; s[2]=100; s[3]=200; s[4]=2000;
    }
    function _none24() private pure returns (uint24[] memory f) { f = new uint24[](0); }
    function _noneSp() private pure returns (int24[] memory s) { s = new int24[](0); }
}
