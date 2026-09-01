// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// @notice AS TRES INVARIANTES QUE FALTAVAM: o contrato do Monoslot, a segunda
///         porta de registo como caminho de REFRESH, e a vitalidade a decidir.
///
/// O que os vizinhos ja cobrem (e este ficheiro NAO repete):
///   - VitalityRefactorEquivalence: a MATEMATICA do decay, fuzzada ate ao osso
///     (equivalencia com a implementacao historica + fronteiras + consumidor psi).
///   - LifecycleMetrics: custos (registo por swap, cold vs warm).
///   - DepthBucketDecimals: o balde de profundidade e os decimais.
///
/// O que NINGUEM pinava:
///   (A) O CONTRATO DO MONOSLOT — "tickSlot toca APENAS {swapCount, lastBlk,
///       bucket}". Onze campos num uint256; uma escrita que sangre para fora
///       da sua mascara corrompe kind/fee/bridge-flag em silencio. E a classe
///       do "Monoslot bit 6" e do conc-vs-bucket que os comentarios do src ja
///       documentam como quase-defeitos. Aqui fica ALGEBRA, nao enumeracao:
///       (antes XOR depois) & ~mascara == 0 cobre os 8 campos preservados de
///       uma vez, incluindo os bits reservados.
///   (B) A SEGUNDA PORTA (recordSwap) — insercao fria com vitalidade 1 e prova
///       de par; refresh quente a re-bucketar; fecho de kinds sem revert; e o
///       po que NAO PODE segurar as 16 cadeiras contra um pool fundo.
///   (C) A CONSEQUENCIA DA VITALIDADE — depois do decay, um tick de refresh
///       reordena o psi. E o fecho end-to-end pela porta do Hub do que o
///       equivalence test prova ao nivel puro.
///
/// NOTA DE AMBIENTE: zero vm.warp/vm.roll em LOOP — o forge desta maquina tem
/// o bug do stale-call-cache (memoria da sessao 2026-08-1x); cada teste faz no
/// maximo UM warp e UM roll, em callsites distintos.
///
/// forge test --match-contract DiscoveryRefreshMonoslot -vv

// ─── (A) O CONTRATO DO MONOSLOT ─────────────────────────────────────────────
contract MonoslotContractTest is Test {
    /// bits que o tickSlot TEM licenca para tocar:
    ///   swapCount [191:160] · lastBlk [255:224] · bucket [63:60]
    uint256 constant TICK_LICENSE =
        (uint256(0xFFFFFFFF) << 160) | (uint256(0xFFFFFFFF) << 224) | (uint256(0xF) << 60);

    /// A invariante central, como algebra e nao como lista: TUDO fora da
    /// licenca sobrevive bit a bit — kind, fee, tier, conc, emaIn/Out, regBlk,
    /// lastUpdateTs, a flag de bridge (bit 7) e os reservados [6:1].
    function testFuzz_TickSlot_SoTocaNosSeusCampos(
        uint256 slot, uint32 blk, uint256 depthWad, uint32 ts
    ) public pure {
        uint256 depois = BPC.tickSlot(slot, blk, depthWad, ts);
        assertEq((slot ^ depois) & ~TICK_LICENSE, 0,
            "tickSlot sangrou para fora de {swapCount, lastBlk, bucket}");
        assertEq(BPC.decodeLastBlk(depois), blk, "lastBlk nao foi escrito");
        assertEq(BPC.decodeBucket(depois), BPC.depthBucket(depthWad),
            "bucket nao re-derivado da profundidade nova");
    }

    /// Identidade encode -> decode em todos os campos com decoder, e por
    /// extraccao crua nos restantes. O bucket NAO e input do encode (nasce no
    /// tickSlot) — tem de sair 0.
    function testFuzz_EncodeDecode_Identidade(
        bool active, uint24 fee, uint8 kind, uint8 tier, uint16 conc,
        uint32 ts, uint32 emaIn, uint32 emaOut, uint32 sc, uint32 regBlk, uint32 lastBlk
    ) public pure {
        uint256 s = BPC.encodeSlot(active, fee, kind, tier, conc, ts, emaIn, emaOut, sc, regBlk, lastBlk);
        assertEq(BPC.isActive(s), active);
        assertEq(BPC.decodeFee(s), fee);
        assertEq(BPC.decodeKind(s), kind);
        assertEq(BPC.decodeSwapCount(s), sc);
        assertEq(uint32(s >> 192), regBlk,               "regBlk [223:192] (sem decoder proprio)");
        assertEq(BPC.decodeLastBlk(s), lastBlk);
        assertEq(BPC.decodeLastUpdateTs(s), ts);
        assertEq(uint8(s >> 40), tier,                    "tier [47:40]");
        assertEq((s >> 48) & 0xFFF, uint256(conc) & 0xFFF, "conc [59:48] mascarado a 12 bits");
        assertEq(uint32(s >> 96), emaIn,                  "emaIn [127:96]");
        assertEq(uint32(s >> 128), emaOut,                "emaOut [159:128]");
        assertEq(BPC.decodeBucket(s), 0, "bucket nasce no tickSlot, nunca no encode");
    }

    /// A quase-colisao documentada no proprio encode: conc e uint16 na
    /// assinatura mas [59:48] no layout — sem a mascara, os 4 bits altos de um
    /// conc >= 4096 aterravam DENTRO do bucket [63:60].
    function testFuzz_ConcNuncaSangraParaOBucket(uint16 conc) public pure {
        uint256 s = BPC.encodeSlot(true, 500, 1, 0, conc, 0, 0, 0, 0, 0, 0);
        assertEq(BPC.decodeBucket(s), 0, "conc alto poluiu o bucket");
    }
}

// ─── mocks minimos: um par que responde token0/token1 ───────────────────────
contract MockPair {
    address public token0;
    address public token1;
    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    /// a fee VIVE no pool — e o que a porta fria mede (getV3Fee), por desenho
    function fee() external pure returns (uint24) { return 500; }
    /// E A FORMA TAMBEM VIVE NO POOL. Estes testes registam com KIND_V3, e o
    /// registo passou a REFUTAR o kind declarado contra a forma medida: um pool
    /// V3 real responde sempre slot0(), e um que nao responde nao e V3. Sem
    /// isto o mock afirmava uma familia que nao sabia demonstrar, e a porta
    /// recusava-o — correctamente. O preco (1.0) e irrelevante para o que estes
    /// testes medem (vitalidade, baldes, despejo); so precisa de nao ser zero.
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (79228162514264337593543950336, int24(0), 0, 0, 0, 0, true);
    }
}

contract MockPairImpostor {
    // afirma trocar um par que NAO e o que o Router diz
    address public token0 = address(0xDEAD01);
    address public token1 = address(0xDEAD02);
}

// ─── (B) + (C) A SEGUNDA PORTA E A VITALIDADE ───────────────────────────────
contract DiscoveryRefreshTest is Test {
    BlazePhoenixHub hub;

    address constant TA = address(0xAAA1);
    address constant TB = address(0xBBB2);
    uint8   constant KIND_V3 = 1;
    uint256 constant DEPTH_RASA  = 1e18;        // bucket baixo
    uint256 constant DEPTH_FUNDA = 1_000_000e18; // bucket alto
    uint256 constant DECAY_STEP  = 24_576;      // VITALITY_DECAY_STEP_SECONDS

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        // o teste faz de Router: recordSwap e a porta DELE
        hub.setRoles(address(this), address(this), address(this));
    }

    function _rec(address pool, uint8 kind, uint256 depth) internal {
        hub.recordSwap(pool, kind, 500, address(0), TA, TB, 1e18, 1e18, depth);
    }

    /// PORTA FRIA: primeiro swap regista com vitalidade 1, bucket derivado da
    /// profundidade — e a fee MEDIDA DO POOL, nunca a da calldata. A primeira
    /// versao deste teste exigia a fee da calldata e ficou vermelha: o
    /// protocolo estava certo e o teste errado — `feeReg = getV3Fee(pool)` e
    /// o irmao, na porta do registo, do quoteV3Fee do caminho de quote
    /// (calldata nunca e base de fee). Por isso a calldata leva 9999 aqui:
    /// se alguem um dia "simplificar" para confiar nela, isto fica vermelho.
    function test_PortaFria_InsereComVitalidadeUm_EFeeMedida() public {
        MockPair p = new MockPair(TA, TB);
        hub.recordSwap(address(p), KIND_V3, 9999, address(0), TA, TB, 1e18, 1e18, DEPTH_RASA);
        bytes32 key = hub.keyOf(address(p), TA, TB);
        uint256 s = hub.getSlot(key);
        assertTrue(BPC.isActive(s), "insercao fria tem de activar o slot");
        assertEq(BPC.decodeKind(s), KIND_V3);
        assertEq(BPC.decodeFee(s), 500,
            "o registo tem de guardar a fee MEDIDA do pool (500), nunca a calldata (9999)");
        assertEq(BPC.decodeSwapCount(s), 1, "vitalidade nasce a 1");
        assertEq(BPC.decodeBucket(s), BPC.depthBucket(DEPTH_RASA));
        assertEq(hub.getPool(key), address(p));
    }

    /// PORTA QUENTE (o REFRESH): segundo swap incrementa a contagem, actualiza
    /// o lastBlk e RE-BUCKETA com a profundidade nova — a liquidez mudou, o
    /// registo acompanha. Um unico vm.roll, callsite unico (stale-cache).
    function test_PortaQuente_RefrescaContagemEBalde() public {
        MockPair p = new MockPair(TA, TB);
        _rec(address(p), KIND_V3, DEPTH_RASA);
        vm.roll(block.number + 7);
        _rec(address(p), KIND_V3, DEPTH_FUNDA);
        uint256 s = hub.getSlot(hub.keyOf(address(p), TA, TB));
        assertEq(BPC.decodeSwapCount(s), 2, "refresh tem de contar do valor decaido + 1");
        assertEq(BPC.decodeLastBlk(s), uint32(block.number), "lastBlk do refresh");
        assertEq(BPC.decodeBucket(s), BPC.depthBucket(DEPTH_FUNDA),
            "o balde tem de seguir a profundidade NOVA, nao a da insercao");
    }

    /// PROVA DE PAR: pool/kind/depth sao calldata do Router — sem a prova, um
    /// atacante regista um contrato dele num par que escolheu, a uma
    /// profundidade que escolheu. Recusa SEM reverter (o swap ja executou).
    function test_ProvaDePar_RecusaImpostorSemReverter() public {
        MockPairImpostor imp = new MockPairImpostor();
        _rec(address(imp), KIND_V3, DEPTH_FUNDA);   // nao pode reverter
        assertEq(hub.getSlot(hub.keyOf(address(imp), TA, TB)), 0,
            "impostor nao pode entrar no registo");
    }

    /// FECHO DE KINDS: um kind que o Router nao pode ter executado (3 nao
    /// existe na taxonomia executavel) salta o registo — sem revert, mesma
    /// disciplina.
    function test_FechoDeKinds_NaoExecutavelNaoRegista() public {
        MockPair p = new MockPair(TA, TB);
        _rec(address(p), 3, DEPTH_FUNDA);
        assertEq(hub.getSlot(hub.keyOf(address(p), TA, TB)), 0,
            "kind fora de KINDS_EXECUTABLE nao pode registar");
    }

    /// O PO NAO SEGURA AS 16 CADEIRAS. Dezasseis pools rasas enchem o par; a
    /// 17a, funda, tem de entrar na mesma — a admissao e por FITNESS projectada
    /// (bucketWeight), nao por antiguidade nem por vitalidade mantida a dust.
    /// E a propriedade anti-griefing documentada no _canInsert.
    function test_PoNaoSeguraAs16Cadeiras() public {
        for (uint256 i; i < 16; ++i) {
            MockPair raso = new MockPair(TA, TB);
            _rec(address(raso), KIND_V3, DEPTH_RASA);
        }
        MockPair fundo = new MockPair(TA, TB);
        _rec(address(fundo), KIND_V3, DEPTH_FUNDA);
        assertGt(hub.getSlot(hub.keyOf(address(fundo), TA, TB)), 0,
            "pool funda barrada por 16 cadeiras de po: o anti-griefing do _canInsert quebrou");
    }

    /// (C) A CONSEQUENCIA: dois pools iguais; o tempo passa 3 passos de decay;
    /// UM recebe DOIS swaps de refresh. O psi reordena — o refrescado supera o
    /// estagnado. DOIS ticks e nao um, e a razao e uma propriedade que a 1a
    /// versao deste teste descobriu a vermelho: a vitalidade de um slot VIVO
    /// dentro do horizonte tem CHAO em 1 ("a real pool never vanishes" —
    /// Core.vitality), logo um tick unico empata com o estagnado em vez de o
    /// superar. O chao e deliberado; o teste pina-o tambem. Um unico vm.warp
    /// (bug do stale-cache deste forge).
    function test_Vitalidade_RefrescadoSuperaEstagnado() public {
        MockPair a = new MockPair(TA, TB);
        MockPair b = new MockPair(TA, TB);
        _rec(address(a), KIND_V3, DEPTH_RASA);
        _rec(address(b), KIND_V3, DEPTH_RASA);
        vm.warp(block.timestamp + 3 * DECAY_STEP);
        _rec(address(a), KIND_V3, DEPTH_RASA);   // refresh 1: repoe do chao
        _rec(address(a), KIND_V3, DEPTH_RASA);   // refresh 2: sobe acima do chao
        uint256 psiA = hub.getPsi(hub.keyOf(address(a), TA, TB));
        uint256 psiB = hub.getPsi(hub.keyOf(address(b), TA, TB));
        assertGt(psiA, psiB, "dois refreshes tem de reordenar o psi apos o decay");
        assertGt(psiB, 0, "o CHAO: um pool vivo dentro do horizonte nunca cai a zero");
    }
}
