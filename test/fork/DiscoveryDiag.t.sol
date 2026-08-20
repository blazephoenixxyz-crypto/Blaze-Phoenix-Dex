// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTestDeploy} from "./BaseTestDeploy.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {PoolInfo} from "../../src/BlazePhoenixCore.sol";

/// @notice One-off diagnostic: for each of the 21 top-100 Base tokens that
///         found no route in BaseTop100.t.sol, check whether that is because
///         NO factory-derivable pool exists at all (hub.discoverFor returns
///         zero hits) versus something else (a reverting/restricted token).
contract DiscoveryDiagTest is Test {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    BlazePhoenixHub hub;

    function setUp() public {
        // Sem DRPC_KEY nao ha fork. SALTAR, nao falhar: um teste que rebenta por falta de uma
        // variavel de ambiente e ruido que esconde falhas reais na suite local — foram 15 destas
        // a mascarar o resultado. O job `fork-tests` do CI tem o segredo e continua a corre-los
        // a serio, portanto a cobertura nao se perde; so deixa de haver vermelho falso.
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base");
        (hub, , , ) = BaseTestDeploy.deploy(address(this));
    }

    function test_DiscoveryDiag_NoRouteTokens() public {
        string[21] memory syms = [
            "EURSAFO", "EUTBL", "JTRSY", "JAAA", "USD0", "USDAI", "APYUSD", "USTBL", "SAFO", "THBILL", "ALFW", "O", "BRLV", "RIF", "HOT", "FT", "CYS", "XVS", "ZCHF", "BR", "MGLO"
        ];
        address[21] memory addrs = [
            0xD879846CbE20751bDE8a9342a3CCa00A3E56CA47,
            0xa0769f7A8fC65e47dE93797b4e21C073c117Fc80,
            0x8c213ee79581Ff4984583C6a801e5263418C4b86,
            0x5a0F93D040De44e78F251b03c43be9CF317Dcf64,
            0x758a3e0b1F842C9306B783f8A4078C6C8C03a270,
            0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF,
            0x2c271ddF484aC0386d216eB7eB9Ff02D4Dc0F6AA,
            0xe4880249745eAc5F1eD9d8F7DF844792D560e750,
            0x0BB754d8940e283D9Ff6855ab5dAfBC14165c059,
            0xfDD22Ce6D1F66bc0Ec89b20BF16CcB6670F55A5a,
            0x19CF86D38ae55d1dC08F50588f11b6acc297f977,
            0x182FA643E5f29d5EcA75e7b9CF9336A3fe4620b2,
            0xd2047ebdb205Ee6862b69ae9fB3501652cC97d36,
            0xe5e851b01DD3Eda24FDe709a407dB44555B6d1E0,
            0xf3dD141109Dfe8e4c006F88a2A8747a086e7C1f8,
            0x5DD1A7A369e8273371d2DBf9d83356057088082c,
            0x19e8d59ff3D7A31289e0Dc04Db48d43b02c7ffa6,
            0xebB7873213c8d1d9913D8eA39Aa12d74cB107995,
            0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553,
            0xd6122ddADa244913521F3d62006eaF756c157660,
            0xFCc9Cc1209651Ed8867332d6F664CF82743A2584
        ];
        for (uint256 i; i < 21; ++i) {
            address a = addrs[i];
            uint256 sz;
            assembly { sz := extcodesize(a) }
            PoolInfo[] memory hits;
            bool discoverOk = true;
            try hub.discoverFor(BASE_USDC, a) returns (PoolInfo[] memory h) {
                hits = h;
            } catch {
                discoverOk = false;
            }
            console2.log(syms[i], hits.length, sz > 0 ? uint256(1) : uint256(0));
            if (!discoverOk) console2.log("  ^ discoverFor ITSELF reverted");
        }
    }
}
