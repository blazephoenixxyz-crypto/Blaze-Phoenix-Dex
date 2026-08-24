// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Leg} from "../../src/BlazePhoenixCore.sol";
import {Top100ArbitrumTokens} from "./Top100ArbitrumTokens.sol";
import {Top100OptimismTokens} from "./Top100OptimismTokens.sol";
import {Top100BaseTokens} from "./Top100BaseTokens.sol";

/// @notice VARRIMENTO DE TOKENS EM TRES CHAINS — o que a stack encontra a serio.
///
/// Corre a lista de tokens mais liquidos de cada chain contra a stack REAL
/// (factories e bridges do deploy) e mede, por token:
///   · encontrou rota? quantas legs, quantos hops?
///   · que TOPOLOGIA (directo / uma ponte / duas pontes)
///   · que familia de venue ganhou a perna
///   · o V4 roteia alguma coisa?
///
/// NAO E UM TESTE DE CORRECCAO por token: a maior parte da cauda longa nao tem
/// pool nas venues cabladas, e isso NAO e falha. O que aqui e falha e a stack
/// nao encontrar rota para uma fraccao razoavel dos tokens MAIS LIQUIDOS da
/// chain — isso seria cablagem errada, nao iliquidez.
///
/// forge test --match-contract TokenSweep --threads 1 -vv
abstract contract TokenSweepBase is Test {
    uint8 internal constant KIND_V2 = 0;
    uint8 internal constant KIND_V3 = 1;
    uint8 internal constant KIND_SOLIDLY = 5;
    uint8 internal constant KIND_ALGEBRA = 6;
    uint8 internal constant KIND_V4 = 4;
    uint8 internal constant MODE_V4_DERIVE = 9;
    uint8 internal constant MODE_CALL_GENERIC = 0;
    uint8 internal constant MODE_CALL_V3 = 1;
    uint8 internal constant MODE_CALL_SOLIDLY = 2;
    uint8 internal constant MODE_CALL_V3CL = 3;
    uint8 internal constant MODE_CREATE2_V3 = 5;
    bytes32 internal constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant T1 = address(0x7E51111111111111111111111111111111111111);
    address internal constant T2 = address(0x7e52222222222222222222222222222222222222);

    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    function _core(address v4mgr) internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), v4mgr);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
    }

    /// @dev CABLAGEM V4 COMPLETA — as tres pecas, e nenhuma e opcional.
    ///
    ///   1. `setWeth` — o Router e o produtor unico do "qual e o WETH desta
    ///      chain". Sem ele a descoberta nao sabe que par e o nativo e salta a
    ///      passada inteira (fail-open: comporta-se como antes, nunca pior).
    ///   2. ancora EXPLICITA na variante NATIVA. Era `addV4(USDC, WETH, ...)`,
    ///      a wrapped — MEDIDO 3,76x mais rasa na Base e 292x na Robinhood.
    ///   3. linha `MODE_V4_DERIVE` — a varredura derivada. Existia no Hub desde
    ///      sempre e NUNCA foi registada por ninguem, portanto nunca correu.
    ///      Sem ela, so a ancora e visivel e a V4 fica limitada a um par.
    function _v4Wire(address mgr, address weth_, address dollar_) internal {
        router.setWeth(weth_);
        hub.addV4(address(0), dollar_, 500, 10, address(0));
        uint24[] memory f = new uint24[](0);
        int24[]  memory sp = new int24[](0);
        hub.addFactory(mgr, KIND_V4, MODE_V4_DERIVE, bytes32(0), f, sp);
    }

    function _v3Fees() internal pure returns (uint24[] memory f) {
        f = new uint24[](4); f[0]=100; f[1]=500; f[2]=3000; f[3]=10000;
    }
    function _pckFees() internal pure returns (uint24[] memory f) {
        f = new uint24[](4); f[0]=100; f[1]=500; f[2]=2500; f[3]=10000;
    }
    function _v3Sp() internal pure returns (int24[] memory s) {
        s = new int24[](4); s[0]=1; s[1]=10; s[2]=60; s[3]=200;
    }
    function _pckSp() internal pure returns (int24[] memory s) {
        s = new int24[](4); s[0]=1; s[1]=10; s[2]=50; s[3]=200;
    }
    function _clSp() internal pure returns (int24[] memory s) {
        s = new int24[](5); s[0]=1; s[1]=50; s[2]=100; s[3]=200; s[4]=2000;
    }
    function _n24() internal pure returns (uint24[] memory f) { f = new uint24[](0); }
    function _nSp() internal pure returns (int24[] memory s) { s = new int24[](0); }

    // ─── o que cada chain fornece ───
    function _dollar() internal view virtual returns (address);
    function _n() internal view virtual returns (uint256);
    function _at(uint256 i) internal view virtual returns (string memory, address);
    function _label() internal pure virtual returns (string memory);

    /// @dev Extraida do `_sweep` porque as suas locais punham o frame do
    ///      `_sweep` "stack too deep" — e uma funcao propria e mais barata que
    ///      um bloco `unchecked` a fingir de escopo. Devolve as pernas V4 desta
    ///      rota (ambas as variantes) e acumula o resto em `porKind`.
    function _contaLegs(Route memory rt, uint256[9] memory porKind)
        internal pure returns (uint256 v4Aqui)
    {
        for (uint256 h; h < rt.hops.length; ++h) {
            Leg[] memory ls = rt.hops[h].legs;
            for (uint256 l; l < ls.length; ++l) {
                uint8 kd = ls[l].kind;
                if (kd < 9) porKind[kd]++;
                if (kd == BPC.KIND_V4 || kd == BPC.KIND_V4_NATIVE) v4Aqui++;
            }
        }
    }

    function _sweep(uint256 amountIn) internal { _sweep(amountIn, 0, _n()); }

    /// @dev EM LOTES, e a razao e o RPC e nao o codigo. A Base varre com BLOCO
    ///      FIXADO (reprodutivel), o que obriga o endpoint a servir dados de
    ///      ARQUIVO — mais lentos e com limites mais apertados que o `latest`
    ///      que as outras chains usam. Uma corrida de 100 tokens de uma vez
    ///      estourava a meio e devolvia 12 testes vermelhos que NAO eram codigo.
    ///      Partido em dois, cada lote cabe na quota, e se um cair o outro
    ///      sobrevive com metade da medicao em vez de nenhuma.
    function _sweep(uint256 amountIn, uint256 de, uint256 ate) internal {
        if (address(hub) == address(0)) { vm.skip(true); return; }
        address tIn = _dollar();
        uint256 n = ate;

        uint256 achou; uint256 semRota; uint256 proprio;
        uint256 somaLegs; uint256 somaHops; uint256 maxLegs; uint256 maxHops;
        uint256[3] memory topo;          // 0=directo 1=uma ponte 2=duas pontes
        // NOVE, nao oito. O `KIND_V4_NATIVE` e 8 — com um array de 8 e um
        // guarda `kd < 8` as pernas nativas nao eram contadas em lado
        // nenhum, e o resumo dizia `legs V4: 0` com a V4 nativa a rotear.
        uint256[9] memory porKind;
        uint256 naoExecutavel;

        console2.log("=========================================");
        console2.log(_label());
        console2.log(" factories:", hub.factoryCount(), "| bridges:", hub.bridgeCount());
        console2.log("=========================================");

        for (uint256 i = de; i < n; ++i) {
            (string memory sym, address tok) = _at(i);
            if (tok == tIn || tok == address(0)) { proprio++; continue; }
            try quoter.previewPlan(tIn, tok, amountIn)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
            {
                // Distinguir as DUAS causas de "sem rota". Ate agora caiam no
                // mesmo balde e o log nao dizia QUAL token falhou, o que torna
                // a cobertura um numero sem diagnostico possivel.
                //   [ZERO] o Quoter respondeu, mas nao achou liquidez -> par
                //          genuinamente sem caminho nas factories registadas.
                //   [REVT] o Quoter REVERTEU -> isso e um defeito nosso ou um
                //          token que quebra alguma suposicao (fee-on-transfer,
                //          decimals() ausente, rebasing), e merece ser visto.
                if (pv.grossOut == 0) {
                    semRota++;
                    console2.log(string.concat("[ZERO] ", sym));
                    continue;
                }
                achou++;
                if (!pv.canExecute) naoExecutavel++;
                somaLegs += pv.legs; somaHops += pv.hops;
                if (pv.legs > maxLegs) maxLegs = pv.legs;
                if (pv.hops > maxHops) maxHops = pv.hops;
                if (pv.topology < 3) topo[pv.topology]++;
                // Conta AQUI as pernas V4 desta rota, nao so no agregado. Sem
                // isto o resumo diz "legs V4: 1" e nao ha maneira de saber em
                // que par — um numero que nao se pode ir verificar nao serve
                // para decidir nada.
                uint256 v4Aqui = _contaLegs(pv.route, porKind);
                console2.log(string.concat("[OK] ", sym), pv.legs, pv.hops, pv.estGas);
                if (v4Aqui != 0) console2.log(string.concat("  ^^ V4 -> ", sym), v4Aqui);
            } catch {
                semRota++;
                console2.log(string.concat("[REVT] ", sym));
            }
        }

        console2.log("--------- RESUMO -----------------------");
        console2.log("com rota / sem rota / proprio:", achou, semRota, proprio);
        console2.log("nao executaveis (canExecute=false):", naoExecutavel);
        if (achou > 0) {
            console2.log("legs media x100:", (somaLegs * 100) / achou, "| max:", maxLegs);
            console2.log("hops media x100:", (somaHops * 100) / achou, "| max:", maxHops);
        }
        console2.log("TOPOLOGIA  directo:", topo[0]);
        console2.log("TOPOLOGIA  uma ponte:", topo[1]);
        console2.log("TOPOLOGIA  DUAS pontes (3 hops):", topo[2]);
        console2.log("legs V2:", porKind[0]);
        console2.log("legs V3:", porKind[1]);
        console2.log("legs V4 wrapped:", porKind[4]);
        console2.log("legs V4 NATIVA:", porKind[8]);
        console2.log("legs SOLIDLY:", porKind[5]);
        console2.log("legs ALGEBRA:", porKind[6]);

        // O PISO DE COBERTURA. Nao e correccao por token — e "a cablagem esta
        // viva?". Se menos de um quinto dos tokens MAIS LIQUIDOS da chain
        // encontra rota, o problema e a cablagem e nao a iliquidez.
        assertGt(achou * 5, (n - de), "cobertura abaixo de 1/5 dos tokens mais liquidos: cablagem suspeita");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
contract TokenSweepBaseChainTest is TokenSweepBase {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) return;
        vm.createSelectFork("base", 49_800_000);
        _core(0x498581fF718922c3f8e6A244956aF099B2652b2b);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(WSTETH);
        hub.addFactory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A, KIND_V3, MODE_CALL_V3CL, bytes32(0), _n24(), _clSp());
        hub.addFactory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, KIND_V3, MODE_CALL_V3, bytes32(0), _pckFees(), _pckSp());
        hub.addFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0x71524B4f93c58fcbF659783284E38825f0622859, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        _v4Wire(0x498581fF718922c3f8e6A244956aF099B2652b2b, WETH, USDC);
    }

    function _dollar() internal pure override returns (address) { return USDC; }
    function _label() internal pure override returns (string memory) { return " BASE 8453 - varrimento"; }
    function _n() internal pure override returns (uint256) { return 100; }
    function _at(uint256 i) internal pure override returns (string memory, address) {
        Top100BaseTokens.Entry[100] memory e = Top100BaseTokens.all();
        return (e[i].symbol, e[i].token);
    }
    /// @notice CENSO DE FALHAS — porque e que o `previewPlan` nao devolve rota.
    ///
    /// O `_sweep` conta os falhados mas o `catch` dele nao distingue causas: um
    /// `revert` nomeado do nosso codigo, um `revert` do token, e um erro de EVM
    /// (MemoryOOG, que consome todo o gas do sub-call) caem todos no mesmo
    /// balde. Sao tres defeitos diferentes com tres curas diferentes.
    ///
    /// O `returndata` separa-os sem ambiguidade:
    ///   len == 0        -> erro de EVM (OOG / invalid opcode) ou revert vazio
    ///   len == 4        -> erro custom sem argumentos
    ///   len >= 4, sel   -> erro custom (o selector diz QUAL) ou Error(string)
    ///
    /// E o mesmo criterio que separou "endpoint doente" de "rate limit" hoje de
    /// manha: uma falha nomeada diz qual e o remedio, uma generica nao.
    function _censo(uint256 amountIn, uint256 de, uint256 ate) internal {
        if (address(hub) == address(0)) return;
        address tIn = _dollar();
        uint256 vazio; uint256 custom; uint256 zeroOut;
        for (uint256 i = de; i < ate; ++i) {
            (string memory sym, address tok) = _at(i);
            if (tok == tIn || tok == address(0)) continue;
            try quoter.previewPlan(tIn, tok, amountIn)
                returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool)
            {
                if (pv.grossOut == 0) {
                    zeroOut++;
                    console2.log(string.concat("[ZERO] ", sym));
                }
            } catch (bytes memory r) {
                if (r.length == 0) {
                    vazio++;
                    console2.log(string.concat("[EVM ] ", sym), r.length);
                } else {
                    custom++;
                    bytes4 sel = bytes4(r[0]) | (bytes4(r[1]) >> 8)
                               | (bytes4(r[2]) >> 16) | (bytes4(r[3]) >> 24);
                    // O argumento (32 bytes a seguir ao selector) e o CODIGO.
                    // Sem ele o selector so diz de que contrato veio o erro,
                    // nao QUAL guarda disparou — e e a guarda que se corrige.
                    uint256 code;
                    if (r.length >= 36) {
                        assembly { code := mload(add(r, 36)) }
                    }
                    console2.log(string.concat("[SEL ] ", sym), uint32(sel), code);
                }
            }
        }
        console2.log("--- CENSO ---");
        console2.log("EVM (len 0) / custom (len>0) / grossOut==0:", vazio, custom, zeroOut);
    }

    /// DEZ LOTES DE DEZ, e a razao e o CACHE e nao o tamanho.
    ///
    /// A Base varre com bloco FIXADO (49.800.000), logo o endpoint tem de
    /// servir dados de ARQUIVO — mais lentos e com limites mais apertados que o
    /// `latest`. Lotes de 50 estouravam a meio e perdiam a corrida inteira.
    ///
    /// Mas o foundry CACHEIA as respostas de fork por (chain, bloco), em
    /// ~/.foundry/cache/rpc/base/. Cada lote que passa AQUECE o cache para os
    /// seguintes: dez lotes pequenos convergem onde dois grandes nao chegam, e
    /// um lote que falhe pode ser repetido sozinho aproveitando o que os outros
    /// ja trouxeram. E progresso acumulado em vez de tudo-ou-nada.
    function test_Censo_C0() public { _censo(1_000e6,  0, 25); }
    function test_Censo_C1() public { _censo(1_000e6, 25, 50); }
    function test_Censo_C2() public { _censo(1_000e6, 50, 75); }
    function test_Censo_C3() public { _censo(1_000e6, 75,100); }

    function test_Sweep_L00() public { _sweep(1_000e6,   0,  10); }
    function test_Sweep_L01() public { _sweep(1_000e6,  10,  20); }
    function test_Sweep_L02() public { _sweep(1_000e6,  20,  30); }
    function test_Sweep_L03() public { _sweep(1_000e6,  30,  40); }
    function test_Sweep_L04() public { _sweep(1_000e6,  40,  50); }
    function test_Sweep_L05() public { _sweep(1_000e6,  50,  60); }
    function test_Sweep_L06() public { _sweep(1_000e6,  60,  70); }
    function test_Sweep_L07() public { _sweep(1_000e6,  70,  80); }
    function test_Sweep_L08() public { _sweep(1_000e6,  80,  90); }
    function test_Sweep_L09() public { _sweep(1_000e6,  90, 100); }
}

// ═══════════════════════════════════════════════════════════════════════════
contract TokenSweepArbitrumTest is TokenSweepBase {
    address constant USDC   = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH   = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) return;
        vm.createSelectFork("arbitrum");
        _core(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(WSTETH);
        uint24[] memory af = new uint24[](1); af[0] = 0;
        int24[] memory asp = new int24[](1); asp[0] = 1;
        hub.addFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0x1a3c9B1d2F0529D97f2afC5136Cc23e58f1FD35B, KIND_ALGEBRA, MODE_CALL_V3, bytes32(0), af, asp);
        hub.addFactory(0x6EcCab422D763aC031210895C81787E87B43A652, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x1af415a1EbA07a4986a52B6f2e7dE7003D82231e, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, KIND_V3, MODE_CALL_V3, bytes32(0), _pckFees(), _pckSp());
        // A CHAVE V4 FALTAVA. Na primeira corrida deste varrimento o V4 roteou
        // ZERO pernas em Arbitrum e Optimism, e eu quase reportei isso como
        // achado do protocolo. Nao era: o manager estava cablado mas nenhuma
        // pool V4 registada, portanto o Solver nunca teve uma candidata V4 para
        // propor. Um varrimento que nao cabla uma familia mede a ausencia dela,
        // nao a qualidade dela.
        _v4Wire(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32, WETH, USDC);
    }

    function _dollar() internal pure override returns (address) { return USDC; }
    function _label() internal pure override returns (string memory) { return " ARBITRUM 42161 - varrimento"; }
    function _n() internal pure override returns (uint256) { return 59; }
    function _at(uint256 i) internal pure override returns (string memory, address) {
        Top100ArbitrumTokens.Entry[59] memory e = Top100ArbitrumTokens.all();
        return (e[i].symbol, e[i].token);
    }
    /// Dois lotes: ver a nota em `_sweep(amountIn, de, ate)`.
    function test_Sweep_Lote1() public { _sweep(1_000e6,  0, 30); }
    function test_Sweep_Lote2() public { _sweep(1_000e6, 30, 59); }
}

// ═══════════════════════════════════════════════════════════════════════════
contract TokenSweepOptimismTest is TokenSweepBase {
    address constant USDC   = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    address constant WSTETH = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) return;
        vm.createSelectFork("optimism");
        // O PoolManager da Optimism EXISTE (0x9a13F98C..., verificado no
        // test/fork/MultichainProbe.t.sol). Passar address(0) aqui desligava o
        // V4 inteiro e fazia o varrimento reportar "V4 = 0 pernas" como se
        // fosse uma medicao. Era uma ausencia disfarcada de resultado.
        _core(0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3);
        hub.addBridge(WETH); hub.addBridge(USDC); hub.addBridge(WSTETH);
        hub.addFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984, KIND_V3, MODE_CREATE2_V3, UNIV3_INIT, _v3Fees(), _v3Sp());
        hub.addFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
        hub.addFactory(0xCc0bDDB707055e04e497aB22a59c2aF4391cd12F, KIND_V3, MODE_CALL_V3CL, bytes32(0), _n24(), _clSp());
        hub.addFactory(0x25CbdDb98b35ab1FF77413456B31EC81A6B6B746, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x0c3c1c532F1e39EdF36BE9Fe0bE1410313E074Bf, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        hub.addFactory(0x9c6522117e2ed1fE5bdb72bb0eD5E3f2bdE7DBe0, KIND_V3, MODE_CALL_V3, bytes32(0), _v3Fees(), _v3Sp());
        hub.addFactory(0xFbc12984689e5f15626Bad03Ad60160Fe98B303C, KIND_V2, MODE_CALL_GENERIC, bytes32(0), _n24(), _nSp());
        _v4Wire(0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3, WETH, USDC);
    }

    function _dollar() internal pure override returns (address) { return USDC; }
    function _label() internal pure override returns (string memory) { return " OPTIMISM 10 - varrimento"; }
    function _n() internal pure override returns (uint256) { return 41; }
    function _at(uint256 i) internal pure override returns (string memory, address) {
        Top100OptimismTokens.Entry[41] memory e = Top100OptimismTokens.all();
        return (e[i].symbol, e[i].token);
    }
    /// Dois lotes: ver a nota em `_sweep(amountIn, de, ate)`.
    function test_Sweep_Lote1() public { _sweep(1_000e6,  0, 21); }
    function test_Sweep_Lote2() public { _sweep(1_000e6, 21, 41); }
}
