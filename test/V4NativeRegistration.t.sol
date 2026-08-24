// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// Router minimo: o Hub so lhe pergunta o WETH canonico.
contract RouterWethStub {
    address public weth;
    constructor(address w) { weth = w; }
}

/// @notice O V4 DE ETH NATIVO TEM DE CONSEGUIR ENTRAR NO REGISTO.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O DEFEITO (antes de 2026-08-21)
/// ─────────────────────────────────────────────────────────────────────────
///  No Uniswap V4 o ETH nativo E `address(0)` como currency, e ordena SEMPRE
///  primeiro (nenhum endereco e menor que zero). As pools V4 mais fundas sao
///  NATIVAS — medido na Unichain a 2026-08-21: o PoolManager detinha 2.964 ETH
///  nativo contra 5,1 WETH.
///
///  O Router SABE executa-las: `KIND_V4_NATIVE` aparece 10x no src,
///  `nativeMapVerified` traduz o lado WETH para `address(0)` ao construir a
///  chave, e o `unlockCallback` tem a costura JIT que faz unwrap para liquidar
///  e wrap de volta no MESMO frame, com o `TSLOT_ETHOK` a autorizar um unico
///  remetente de ETH cru de cada vez.
///
///  MAS AS DUAS PORTAS DE DESCOBERTA RECUSAVAM-NAS:
///      addV4(...)   { _ne0(c0); _ne0(c1); }   // Hub — revertia
///      claimV4(...) { _ne0(c0); _ne0(c1); }   // Hub — "native currency rejected"
///
///  Sobrava o `recordSwap`, que so regista o que JA foi usado. E para ser usada
///  a pool tem de estar no registo, para o Solver a propor. **Galo e ovo**: a
///  familia inteira era inalcancavel.
///
/// ─────────────────────────────────────────────────────────────────────────
///  A CURA, e porque a recusa de address(0) estava CERTA
/// ─────────────────────────────────────────────────────────────────────────
///  A divisao que o Router ja fazia passa a valer tambem no registo:
///    **a chave da POOL fala nas currencies reais (nativo = address(0));
///      o REGISTO fala WETH.**
///  Assim o Solver encontra a pool ao rotear WETH->X como qualquer outra, e so
///  na execucao o Router traduz. O `address(0)` continua a nao ser aceite como
///  "um token" — e aceite como a MARCA de que a pool e nativa.
contract V4NativeRegistrationTest is Test {
    BlazePhoenixHub hub;
    RouterWethStub  routerStub;

    address constant WETH  = address(0xEEEE);
    address constant USDC  = address(0x05DC);
    address constant V4MGR = address(0x4444);

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4MGR);
        routerStub = new RouterWethStub(WETH);
        // o Hub pergunta o weth ao router; solver/quoter irrelevantes aqui
        hub.setRoles(address(routerStub), address(this), address(this));
    }

    /// @notice O NUCLEO. Uma pool V4 nativa entra no registo.
    ///         Revertia com HubE(3) antes do fix.
    function test_PoolV4NativaEntraNoRegisto() public {
        bytes32 key = hub.addV4(address(0), USDC, 500, 10, address(0));
        assertTrue(key != bytes32(0), "a chave nao pode ser vazia");
        uint256 s = hub.getSlot(key);
        assertEq(BPC.decodeKind(s), BPC.KIND_V4_NATIVE, "tem de ficar marcada como NATIVA");
    }

    /// @notice O REGISTO FALA WETH. E isto que faz o Solver encontra-la ao
    ///         rotear WETH->USDC — se ficasse indexada sob address(0)/USDC,
    ///         nenhuma rota normal lhe chegava.
    function test_RegistoIndexadoPorWethNaoPorZero() public {
        hub.addV4(address(0), USDC, 500, 10, address(0));

        PoolInfo[] memory sobWeth = hub.getActivePools(WETH, USDC);
        assertEq(sobWeth.length, 1, "tem de estar sob o par WETH/USDC");
        assertEq(sobWeth[0].kind, BPC.KIND_V4_NATIVE, "e nativa");

        PoolInfo[] memory sobZero = hub.getActivePools(address(0), USDC);
        assertEq(sobZero.length, 0, "NAO pode estar indexada sob address(0)");
    }

    /// @notice A pool tem de ser a REAL: o poolId deriva das currencies
    ///         NATIVAS, nao das do registo. Se derivasse de WETH, o endereco
    ///         apontaria para uma pool que nao existe no PoolManager.
    function test_PoolIdDerivaDasCurrenciesReais() public {
        bytes32 key = hub.addV4(address(0), USDC, 500, 10, address(0));
        (address n0, address n1) = BPC.sortTokens(address(0), USDC);
        bytes32 pidNativo = BPC.computeV4PoolId(n0, n1, 500, 10, address(0));
        assertEq(hub.getPool(key), address(uint160(uint256(pidNativo))),
                 "o endereco tem de vir do poolId NATIVO");

        (address w0, address w1) = BPC.sortTokens(WETH, USDC);
        bytes32 pidWeth = BPC.computeV4PoolId(w0, w1, 500, 10, address(0));
        assertTrue(pidNativo != pidWeth, "os dois poolIds tem de diferir");
    }

    /// @notice FAIL-CLOSED: sem WETH cablado no Router nao ha traducao possivel.
    ///         Registar seria criar uma entrada que a execucao nao consegue
    ///         honrar — pior que recusar.
    function test_SemWethCabladoRecusa() public {
        BlazePhoenixHub h2 = new BlazePhoenixHub(address(this));
        h2.initialize(address(this), V4MGR);
        h2.setRoles(address(new RouterWethStub(address(0))), address(this), address(this));
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, 3));
        h2.addV4(address(0), USDC, 500, 10, address(0));
    }

    /// @notice O caminho NAO-nativo continua igual: kind V4, indexado pelos
    ///         dois ERC20. Sem isto, o fix podia ter mudado o comportamento
    ///         de todas as pools V4 existentes sem ninguem reparar.
    function test_V4NormalNaoMudou() public {
        bytes32 key = hub.addV4(WETH, USDC, 3000, 60, address(0));
        assertEq(BPC.decodeKind(hub.getSlot(key)), BPC.KIND_V4, "continua V4 simples");
        assertEq(hub.getActivePools(WETH, USDC).length, 1, "indexada sob WETH/USDC");
    }

    /// @notice address(0) dos DOIS lados continua a ser recusado — e a marca de
    ///         "nativa", nao um token, e uma pool nativa/nativa nao existe.
    function test_ZeroNosDoisLadosRecusado() public {
        vm.expectRevert();
        hub.addV4(address(0), address(0), 500, 10, address(0));
    }
}
