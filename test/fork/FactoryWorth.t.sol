// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";

interface IV3F  { function getPool(address,address,uint24) external view returns (address); }
interface IV2F  { function getPair(address,address) external view returns (address); }
interface ISolF { function getPool(address,address,bool) external view returns (address); }
interface ICLF  { function getPool(address,address,int24) external view returns (address); }
interface IERC20W { function balanceOf(address) external view returns (uint256); }

/// @notice QUAIS FACTORIES VALEM OS ~200.000 GAS QUE CUSTAM POR SOLVE.
///
/// Cada factory registada acrescenta ~160-230k gas a um solve on-chain
/// (medido em test/fork/DiscoveryCostBreakdown.t.sol). Uma factory que nao
/// tem pool no par, ou que so tem po, NUNCA ganha uma perna — paga-se o custo
/// da sondagem em todos os solves para nada.
///
/// Este ficheiro nao opina: para cada factory registada no deploy, procura a
/// pool do par pedido em todos os tiers e mede o SALDO REAL de tokenOut que
/// ela detem. O saldo e o tecto absoluto do que a pool pode entregar.
///
/// forge test --match-contract FactoryWorth -vv
contract FactoryWorthBaseTest is Test {
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    uint256 constant BLK    = 49_800_000;

    // as 9 do deploy, pela ordem em que la estao
    address constant UNIV3  = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant AERO   = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant AEROCL = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address constant UNIV2  = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address constant PCK3   = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PCK2   = 0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E;
    address constant SUSHI3 = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
    address constant SUSHI2 = 0x71524B4f93c58fcbF659783284E38825f0622859;
    address constant BSWAP  = 0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) return;
        vm.createSelectFork("base", BLK);
    }

    function _bal(address pool, address tok) internal view returns (uint256) {
        if (pool == address(0)) return 0;
        try IERC20W(tok).balanceOf(pool) returns (uint256 b) { return b; } catch { return 0; }
    }

    /// Melhor pool de uma factory V3 sobre os quatro tiers.
    function _v3Best(address f, address a, address b, address medir)
        internal view returns (uint256 best, uint24 tier)
    {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        for (uint256 i; i < 4; ++i) {
            try IV3F(f).getPool(a, b, fees[i]) returns (address p) {
                uint256 v = _bal(p, medir);
                if (v > best) { best = v; tier = fees[i]; }
            } catch { }
        }
    }

    function _clBest(address f, address a, address b, address medir)
        internal view returns (uint256 best)
    {
        int24[5] memory sp = [int24(1), 50, 100, 200, 2000];
        for (uint256 i; i < 5; ++i) {
            try ICLF(f).getPool(a, b, sp[i]) returns (address p) {
                uint256 v = _bal(p, medir);
                if (v > best) best = v;
            } catch { }
        }
    }

    function _v2(address f, address a, address b, address medir) internal view returns (uint256) {
        try IV2F(f).getPair(a, b) returns (address p) { return _bal(p, medir); } catch { return 0; }
    }

    function _sol(address f, address a, address b, address medir) internal view returns (uint256) {
        uint256 best;
        try ISolF(f).getPool(a, b, false) returns (address p) { best = _bal(p, medir); } catch { }
        try ISolF(f).getPool(a, b, true) returns (address p) {
            uint256 v = _bal(p, medir); if (v > best) best = v;
        } catch { }
        return best;
    }

    function _linha(string memory nome, uint256 wei_, uint256 total) internal pure {
        // permilagem do total, para nao depender de floats
        uint256 permil = total == 0 ? 0 : (wei_ * 1000) / total;
        console2.log(nome);
        console2.log("     WETH detido:", wei_ / 1e18, "| quota (por mil):", permil);
    }

    function test_QuantoValeCadaFactory_USDC_WETH() public view {
        if (block.chainid != 8453) return;
        console2.log("=========================================");
        console2.log(" BASE @ 49.800.000 -- par USDC/WETH");
        console2.log(" saldo de WETH que cada factory oferece");
        console2.log("=========================================");

        (uint256 v3,)   = _v3Best(UNIV3,  USDC, WETH, WETH);
        uint256 aero    = _sol(AERO,      USDC, WETH, WETH);
        uint256 aerocl  = _clBest(AEROCL, USDC, WETH, WETH);
        uint256 uni2    = _v2(UNIV2,      USDC, WETH, WETH);
        (uint256 pck3,) = _v3Best(PCK3,   USDC, WETH, WETH);
        uint256 pck2    = _v2(PCK2,       USDC, WETH, WETH);
        (uint256 su3,)  = _v3Best(SUSHI3, USDC, WETH, WETH);
        uint256 su2     = _v2(SUSHI2,     USDC, WETH, WETH);
        uint256 bsw     = _v2(BSWAP,      USDC, WETH, WETH);

        uint256 tot = v3 + aero + aerocl + uni2 + pck3 + pck2 + su3 + su2 + bsw;
        _linha("1 Uniswap V3   ", v3,     tot);
        _linha("2 Aerodrome    ", aero,   tot);
        _linha("3 Aerodrome CL ", aerocl, tot);
        _linha("4 Uniswap V2   ", uni2,   tot);
        _linha("5 Pancake V3   ", pck3,   tot);
        _linha("6 Pancake V2   ", pck2,   tot);
        _linha("7 Sushi V3     ", su3,    tot);
        _linha("8 Sushi V2     ", su2,    tot);
        _linha("9 BaseSwap     ", bsw,    tot);
        console2.log("-----------------------------------------");
        console2.log("TOTAL WETH no par:", tot / 1e18);
    }

    function test_QuantoValeCadaFactory_WETH_WSTETH() public view {
        if (block.chainid != 8453) return;
        console2.log("=========================================");
        console2.log(" BASE -- par WETH/wstETH (a 3a bridge)");
        console2.log("=========================================");

        (uint256 v3,)   = _v3Best(UNIV3,  WETH, WSTETH, WETH);
        uint256 aero    = _sol(AERO,      WETH, WSTETH, WETH);
        uint256 aerocl  = _clBest(AEROCL, WETH, WSTETH, WETH);
        uint256 uni2    = _v2(UNIV2,      WETH, WSTETH, WETH);
        (uint256 pck3,) = _v3Best(PCK3,   WETH, WSTETH, WETH);
        uint256 pck2    = _v2(PCK2,       WETH, WSTETH, WETH);
        (uint256 su3,)  = _v3Best(SUSHI3, WETH, WSTETH, WETH);
        uint256 su2     = _v2(SUSHI2,     WETH, WSTETH, WETH);
        uint256 bsw     = _v2(BSWAP,      WETH, WSTETH, WETH);

        uint256 tot = v3 + aero + aerocl + uni2 + pck3 + pck2 + su3 + su2 + bsw;
        _linha("1 Uniswap V3   ", v3,     tot);
        _linha("2 Aerodrome    ", aero,   tot);
        _linha("3 Aerodrome CL ", aerocl, tot);
        _linha("4 Uniswap V2   ", uni2,   tot);
        _linha("5 Pancake V3   ", pck3,   tot);
        _linha("6 Pancake V2   ", pck2,   tot);
        _linha("7 Sushi V3     ", su3,    tot);
        _linha("8 Sushi V2     ", su2,    tot);
        _linha("9 BaseSwap     ", bsw,    tot);
        console2.log("-----------------------------------------");
        console2.log("TOTAL WETH no par:", tot / 1e18);
    }
}
