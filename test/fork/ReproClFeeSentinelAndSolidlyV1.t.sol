// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, QuoteCtx, PoolInfo} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";

/// @notice REPRO dos dois defeitos que o censo por factory expos — as familias
///         inteiras que NUNCA ganham um par, com a causa em cada uma MEDIDA.
///
/// (1) FAMILIA CL QUOTA ZERO POR CONSTRUCAO. As linhas CL registam-se com a
///     lista de fees VAZIA (a fee vive no tickSpacing), e o `_scanFactory`
///     estampa `fee = 0` no PoolInfo. Mas `fee == 0` e TAMBEM o sentinel de
///     fee dinamica da Algebra (regra R2 do Hub) — e o `effV3Fee`, para um
///     pool que responde a slot0() (logo `dyn = false`), faz fail-closed em
///     0xFFFFFF e o guard do outV3 quota 0. O fix da fee Algebra (INV-20)
///     matou colateralmente a familia CL no caminho do QUOTE; o caminho da
///     EXECUCAO (Router:774) sempre soube o remedio: ler `fee()` do pool.
///     MEDIDO 2026-08-24 no pool AeroCL USDC/WETH sp=100 da Base
///     (0xb2cc224c...): fee() = 334 (DINAMICA, nem sequer a nominal 500),
///     slot0() responde 192 B, 1.479 WETH no pool — e a stack quotava 0.
///
/// (2) VELODROME V1 E INVISIVEL A DESCOBERTA. O modo CALL_SOLIDLY fala so o
///     dialecto V2/Aerodrome — getPool(address,address,bool). O Solidly
///     classico (Velodrome V1) expoe getPair(address,address,bool). MEDIDO
///     no OP: getPair(WETH,USDC,false) = 0x055f...a790 (par real);
///     getPool(...) reverte. O portao de identidade aceita a factory
///     (allPairsLength responde) mas a descoberta nunca lhe arranca um
///     candidato: tem-pool = 0 em 62 pares no censo. O modo 1 ja tem um
///     fallback de dialecto (poolByPair da Algebra) — este e o gemeo Solidly.
///
/// forge test --match-contract ReproClFeeSentinelAndSolidlyV1 -vv
contract ReproClFeeSentinelBase is Test {
    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH   = 0x4200000000000000000000000000000000000006;
    // AeroCL USDC/WETH tickSpacing 100 — resolvido ao vivo pela factory a
    // 2026-08-24; ~1.479 WETH detidos no momento da medicao.
    address constant AEROCL_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base", 49_800_000);
    }

    /// A forma EXACTA que a descoberta produz para uma linha CL: kind V3,
    /// fee 0 (lista vazia), tickSpacing real. Se este teste esta vermelho,
    /// TODA a familia CL e invisivel ao Solver — e por isso que o censo lhe
    /// mediu ganhou=0 com tem-pool=80/122.
    function test_ClPool_QuotesNonZero_WithDiscoveryShapedCtx() public view {
        QuoteCtx memory c = QuoteCtx({
            kind: 1,                 // KIND_V3 (forma da linha CL na descoberta)
            pool: AEROCL_POOL,
            zeroForOne: false,       // USDC -> WETH: token0 = WETH (0x42..<0x83..)
            //                          A 1a versao pos true e cotou 1000e6 DE
            //                          WETH (1e-9 WETH) -> out=1 wei. Foi a
            //                          BANDA de unidades que apanhou, nao o
            //                          assertGt(out,0) — a licao de manter
            //                          bandas nos testes de fork.
            fee: 0,                  // o sentinel que a lista vazia estampa
            tickSpacing: 100,
            stable: false,
            tokenIn: USDC,
            tokenOther: WETH,
            hooks: address(0),
            v4Manager: address(0),
            decIn1: 0,
            decOther1: 0
        });
        (uint256 out, uint256 depth) = BPC.universalQuote(c, 1_000e6);
        console2.log("AeroCL quote out/depth:", out, depth);
        // Sanidade de unidades, mesma disciplina do BaseFork: 1.000 USDC em
        // WETH tem de cair numa banda larga — nao e oraculo de preco.
        assertGt(out, 0, "familia CL quota 0: sentinel de fee dinamica aplicado a um pool estatico-com-fee-no-pool");
        assertGt(out, 0.0001 ether);
        assertLt(out, 10 ether);
    }

    /// O contraste que prova que o defeito e o SENTINEL e nao o pool: com a
    /// fee real medida do proprio pool, o mesmo pool quota.
    function test_ClPool_QuotesWithMeasuredFee_Control() public view {
        uint24 measured = BPC.getV3Fee(AEROCL_POOL);
        console2.log("AeroCL fee() medida:", measured);
        assertGt(measured, 0, "fee() do pool CL tem de responder");
        QuoteCtx memory c = QuoteCtx({
            kind: 1, pool: AEROCL_POOL, zeroForOne: false, fee: measured,
            tickSpacing: 100, stable: false, tokenIn: USDC, tokenOther: WETH,
            hooks: address(0), v4Manager: address(0), decIn1: 0, decOther1: 0
        });
        (uint256 out, ) = BPC.universalQuote(c, 1_000e6);
        assertGt(out, 0.0001 ether, "controlo: com fee explicita o pool quota na banda");
        assertLt(out, 10 ether);
    }
}

contract ReproSolidlyV1DialectOP is Test {
    address constant WETH  = 0x4200000000000000000000000000000000000006;
    address constant USDC  = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant VELO1 = 0x25CbdDb98b35ab1FF77413456B31EC81A6B6B746;
    // Par volatil WETH/USDC da V1 — resolvido ao vivo por getPair 2026-08-24.
    address constant VELO1_PAIR = 0x055f06391C4bb260e43Fb5D5315Ab67271E6A790;

    uint8 constant KIND_SOLIDLY = 5;
    uint8 constant MODE_CALL_SOLIDLY = 2;

    BlazePhoenixHub hub;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("optimism");
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        // So a V1: se a descoberta nao fala o dialecto dela, hits = 0 e o
        // teste esta vermelho — o estado exacto do censo (tem-pool 0 em 62).
        uint24[] memory f = new uint24[](0);
        int24[] memory sp = new int24[](0);
        hub.addFactory(VELO1, KIND_SOLIDLY, MODE_CALL_SOLIDLY, bytes32(0), f, sp);
    }

    function test_VeloV1_DiscoveryFindsThePair() public view {
        // O par existe on-chain (getPair respondeu-o ao vivo) — o que esta em
        // teste e se a NOSSA descoberta o alcanca.
        assertGt(VELO1_PAIR.code.length, 0, "precondicao: o par V1 existe");
        PoolInfo[] memory hits = hub.discoverFor(WETH, USDC);
        uint256 v1Hits;
        for (uint256 i; i < hits.length; ++i) {
            if (hits[i].pool == VELO1_PAIR) v1Hits++;
            if (hits[i].pool != address(0))
                console2.log("hit:", hits[i].pool, hits[i].stable);
        }
        assertGt(v1Hits, 0, "descoberta nao fala o dialecto getPair(a,a,bool) do Solidly classico");
    }
}
