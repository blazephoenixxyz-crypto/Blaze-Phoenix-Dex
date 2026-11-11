// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockOriginFactory, Origin} from "./mocks/MockOriginFactory.sol";

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
///   (A) O CONTRATO DO MONOSLOT — "tickSlot toca APENAS {swapCount, tau,
///       lastUpdateTs, bucket}". Onze campos num uint256; uma escrita que sangre para fora
///       da sua mascara corrompe kind/fee/bridge-flag em silencio. E a classe
///       do "Monoslot bit 6" e do conc-vs-bucket que os comentarios do src ja
///       documentam como quase-defeitos. Aqui fica ALGEBRA, nao enumeracao:
///       (antes XOR depois) & ~mascara == 0 cobre os 7 campos preservados de
///       uma vez, incluindo os bits reservados.
///       fix-1102 A: was {swapCount, tau, bucket} and 8 preserved fields, because the callers
///       stamped lastUpdateTs; now lastUpdateTs is licensed and asserted by value, because
///       tickSlot is the clock's one writer and stamps it (BlazePhoenixCore.sol:2913).
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
/// fix-1102 A: was at most one warp per test; test_Vitalidade_RefrescadoSuperaEstagnado now warps
/// in a loop, because only an anchored tick that closes a real interval moves the clock
/// (BlazePhoenixCore.sol:2898): every target is absolute, t1 + i with t1 read once through the
/// cheatcode, as in test/DimensionsTime.t.sol:11-14.
///
/// forge test --match-contract DiscoveryRefreshMonoslot -vv

// ─── (A) O CONTRATO DO MONOSLOT ─────────────────────────────────────────────
contract MonoslotContractTest is Test {
    /// bits que o tickSlot TEM licenca para tocar:
    ///   swapCount [191:160] · tau [255:224] · lastUpdateTs [95:64] · bucket [63:60]
    // fix-1102 A: was without lastUpdateTs [95:64], because the callers stamped it; now with it, because tickSlot writes currentTs there on the tick that moves the clock (BlazePhoenixCore.sol:2913)
    uint256 constant TICK_LICENSE = (uint256(0xFFFFFFFF) << 160) | (uint256(0xFFFFFFFF) << 224)
        | (uint256(0xFFFFFFFF) << 64) | (uint256(0xF) << 60);

    /// A invariante central, como algebra e nao como lista: TUDO fora da
    /// licenca sobrevive bit a bit — kind, fee, tier, conc, emaIn/Out, regBlk,
    /// a flag de bridge (bit 7) e os reservados [6:1].
    function testFuzz_TickSlot_SoTocaNosSeusCampos(
        uint256 slot, bool anchored, uint256 depthWad, uint32 ts, uint8 shape
    ) public pure {
        // One run in four is a slot never stamped (lastTs == 0), by construction: the arm where
        // no interval closes, which a free uint256 reached once in 2^32 runs.
        if (bound(shape, 0, 3) == 0) slot &= ~(uint256(0xFFFFFFFF) << 64);
        uint256 depois = BPC.tickSlot(slot, anchored, depthWad, ts);
        assertEq((slot ^ depois) & ~TICK_LICENSE, 0,
            "tickSlot sangrou para fora de {swapCount, tau, lastUpdateTs, bucket}");
        // tau and lastUpdateTs are WRITTEN on every arm, and asserted on every arm: an anchored tick
        // that closes a real interval (lastTs != 0, ts > lastTs) moves tau 2^-3 of the gap, rounded
        // up, from 24 576 / 4 when tau is 0 (TAU_EMA_SHIFT and the first step, by value); an anchored
        // tick on a slot never stamped moves no tau; any other tick leaves the clock.
        uint256 lastTs = BPC.decodeLastUpdateTs(slot);
        uint256 tau = BPC.decodeTau(slot);
        // fix-1102 A: was every anchored tick with lastTs != 0, ts <= lastTs closing a 0 s interval; now such a tick moves nothing, because a tick inside the stamped second leaves the clock (BlazePhoenixCore.sol:2898)
        bool moves = anchored && (lastTs == 0 || ts > lastTs);
        uint256 want = tau;
        if (moves && lastTs != 0) {
            // fix-1102 A: was dt itself when tau is 0, and a step rounded down; now from 6144 = 24 576 / 4, and rounded up, because no single interval is read whole and the EMA cannot stall (BlazePhoenixCore.sol:2904, :2907-2908)
            uint256 from = tau == 0 ? 6144 : tau;
            uint256 dt = ts - lastTs;
            if (dt >= from) want = from + (dt - from + 7) / 8;
            else want = from - (from - dt + 7) / 8;
        }
        assertEq(BPC.decodeTau(depois), want, "tau is not the clock's own next value");
        // fix-1102 A: was preserved bit for bit, because the callers stamped it; now ts on the tick that moves the clock and the old stamp on any other, because tickSlot stamps currentTs (BlazePhoenixCore.sol:2898, :2913)
        assertEq(BPC.decodeLastUpdateTs(depois), moves ? uint256(ts) : lastTs,
            "lastUpdateTs is not the clock's own stamp");
        assertEq(BPC.decodeBucket(depois), BPC.depthBucket(depthWad),
            "bucket nao re-derivado da profundidade nova");
    }

    /// Identidade encode -> decode em todos os campos com decoder, e por
    /// extraccao crua nos restantes. O bucket NAO e input do encode (nasce no
    /// tickSlot) — tem de sair 0.
    function testFuzz_EncodeDecode_Identidade(
        bool active, uint24 fee, uint8 kind, uint8 tier, uint16 conc,
        uint32 ts, uint32 emaIn, uint32 emaOut, uint32 sc, uint32 regBlk, uint32 tau
    ) public pure {
        uint256 s = BPC.encodeSlot(active, fee, kind, tier, conc, ts, emaIn, emaOut, sc, regBlk, tau);
        assertEq(BPC.isActive(s), active);
        assertEq(BPC.decodeFee(s), fee);
        assertEq(BPC.decodeKind(s), kind);
        assertEq(BPC.decodeSwapCount(s), sc);
        assertEq(uint32(s >> 192), regBlk,               "regBlk [223:192] (sem decoder proprio)");
        assertEq(BPC.decodeTau(s), tau);
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

    /// rizki-3107: a porta fria so senta uma pool que uma fabrica ligada deriva. Os pares que
    /// estes testes sentam nascem TODOS numa fabrica V3 com um tier de fee por par: cabem 17
    /// pools do mesmo par, e o MAX_FACTORIES (16) nao chegaria a uma fabrica por pool. O tier e
    /// so a chave do lookup da fabrica; a fee do slot continua a ser a medida no pool (500).
    MockOriginFactory origem;
    uint24 tier;

    function _pair() internal returns (MockPair p) {
        if (address(origem) == address(0)) origem = Origin.tiers(hub, KIND_V3, 17);
        p = new MockPair(TA, TB);
        origem.list(address(p), TA, TB, ++tier, false);
    }

    function _rec(address pool, uint8 kind, uint256 depth) internal {
        hub.recordSwap(pool, kind, 500, address(0), TA, TB, 1e18, 1e18, depth);
    }

    /// PORTA FRIA: primeiro swap regista com vitalidade 1, bucket derivado da
    /// profundidade — e a fee que cota e a MEDIDA DO POOL, nunca a da calldata. A
    /// primeira versao deste teste exigia a fee da calldata e ficou vermelha: o
    /// protocolo estava certo e o teste errado (calldata nunca e base de fee). Desde
    /// aero-nova (2026-10-26) a linha guarda o tier da derivacao quando o pool
    /// concorda, senao 0 = leitura ao vivo pelo quoteV3Fee; nunca um instantaneo.
    /// A calldata leva 9999 aqui: se alguem um dia "simplificar" para confiar
    /// nela, isto fica vermelho.
    function test_PortaFria_InsereComVitalidadeUm_EFeeMedida() public {
        MockPair p = _pair();
        hub.recordSwap(address(p), KIND_V3, 9999, address(0), TA, TB, 1e18, 1e18, DEPTH_RASA);
        bytes32 key = hub.keyOf(address(p), TA, TB);
        uint256 s = hub.getSlot(key);
        assertTrue(BPC.isActive(s), "insercao fria tem de activar o slot");
        assertEq(BPC.decodeKind(s), KIND_V3);
        // aero-nova 2026-10-26: o tier da origem (1..17) nao e a fee do pool (500), logo a
        // linha le o pool ao vivo (0) em vez de guardar um instantaneo; a cotacao paga 500.
        assertEq(BPC.decodeFee(s), 0, "sem identidade de fee a linha le ao vivo, nunca a calldata (9999)");
        assertEq(BPC.quoteV3Fee(address(p), 0, 0, false), 500,
            "o registo tem de cotar a fee MEDIDA do pool (500), nunca a calldata (9999)");
        // fix-1102 A: was swapCount 1 because the registration ticked the new row; now 0 because the row is born unticked (BlazePhoenixHub.sol:2168), and its vitality is the live floor: c 0 on the unmeasured step scores 0, floored to 1 (BlazePhoenixCore.sol:2598-2599)
        assertEq(BPC.decodeSwapCount(s), 0, "the cold door records no trade: the row is born with swapCount 0");
        assertEq(BPC.vitality(s, uint32(block.timestamp)), 1, "vitalidade nasce a 1");
        assertEq(BPC.decodeBucket(s), BPC.depthBucket(DEPTH_RASA));
        assertEq(hub.getPool(key), address(p));
    }

    /// PORTA QUENTE (o REFRESH): segundo swap incrementa a contagem, actualiza
    /// o lastUpdateTs e RE-BUCKETA com a profundidade nova — a liquidez mudou, o
    /// registo acompanha. One vm.warp, one callsite (stale-cache): the refresh is anchored and
    /// closes a 100 s interval, so both time fields it WRITES differ from the insertion's and
    /// are asserted by value: tau (the first interval) and lastUpdateTs (the refresh's stamp).
    function test_PortaQuente_RefrescaContagemEBalde() public {
        MockPair p = _pair();
        _rec(address(p), KIND_V3, DEPTH_RASA);
        uint256 tIns = block.timestamp;
        vm.warp(tIns + 100);
        _rec(address(p), KIND_V3, DEPTH_FUNDA | BPC.TICK_ANCHORED);
        uint256 s = hub.getSlot(hub.keyOf(address(p), TA, TB));
        // fix-1102 A: was 2 because the registration ticked the new row; now 1 because the row is born with swapCount 0 (BlazePhoenixHub.sol:2168) and the anchored refresh counts the decayed 0 + 1 (BlazePhoenixCore.sol:2900-2901)
        assertEq(BPC.decodeSwapCount(s), 1, "refresh tem de contar do valor decaido + 1");
        // fix-1102 A: was 100 because the first interval was read whole; now 5388 = 6144 - ((6144 - 100 + 7) >> 3) because the first interval moves tau from 24 576 / 4, rounded up (BlazePhoenixCore.sol:2904, :2908)
        assertEq(BPC.decodeTau(s), 5388, "the first anchored interval since insertion moves tau from 24 576 / 4");
        assertEq(BPC.decodeLastUpdateTs(s), tIns + 100, "the refresh stamps lastUpdateTs");
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
            MockPair raso = _pair();
            _rec(address(raso), KIND_V3, DEPTH_RASA);
        }
        MockPair fundo = _pair();
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
    /// superar. O chao e deliberado; o teste pina-o tambem. Every warp goes to an absolute
    /// target (this forge's stale-cache bug).
    /// fix-1102 A: was two dust refreshes in one second, which counted; now dust counts nothing and a
    /// tick inside the stamped second neither (BlazePhoenixCore.sol:2898), so the refreshes are four
    /// material trades a second apart: the first closes the 3-step interval and pulls tau from
    /// 24 576 / 4 up to 14 593, the next three pull it to 12 769, 11 173 and 9 776 (rounded up,
    /// :2904, :2907-2908) while the count goes 1, 2, 3, 4 (the chord takes 0 from a 1 s age,
    /// :2642). v = c * 24 576 / (4 * tau) is 0, 0, 1, 2 (:2598): through the third tick a scores 1
    /// (floored from 0, :2599), level with b, and the fourth scores 2, so psiA = 2 * 8 > psiB = 1 * 8.
    function test_Vitalidade_RefrescadoSuperaEstagnado() public {
        MockPair a = _pair();
        MockPair b = _pair();
        _rec(address(a), KIND_V3, DEPTH_RASA);
        _rec(address(b), KIND_V3, DEPTH_RASA);
        // fix-1102 A: was one warp to block.timestamp + 3 steps; now t1 from the cheatcode and absolute targets t1 + i, because the trades must land in distinct seconds (BlazePhoenixCore.sol:2898) and a via_ir build may re-read block.timestamp after a warp (test/DimensionsTime.t.sol:11-14)
        uint256 t1 = vm.getBlockTimestamp() + 3 * DECAY_STEP;
        // The two dust refreshes this test used to send, and two more, a second apart: dust counts
        // nothing and stamps nothing, so it pumps no psi and a stays level with its untouched twin.
        for (uint256 i; i < 4; ++i) {
            vm.warp(t1 + i);
            _rec(address(a), KIND_V3, DEPTH_RASA);
        }
        assertEq(hub.getPsi(address(a), TA, TB), hub.getPsi(address(b), TA, TB),
            "dust pumped the psi: four unanchored refreshes moved a above its twin");
        // fix-1102 A: was the two dust refreshes above; now four anchored ones a second apart, because only an anchored tick that closes a real interval counts (BlazePhoenixCore.sol:2898, :2900-2901)
        for (uint256 i = 4; i < 8; ++i) {
            vm.warp(t1 + i);
            _rec(address(a), KIND_V3, DEPTH_RASA | BPC.TICK_ANCHORED);
        }
        uint256 psiA = hub.getPsi(address(a), TA, TB);
        uint256 psiB = hub.getPsi(address(b), TA, TB);
        assertGt(psiA, psiB, "four material refreshes must reorder the psi after the decay");
        assertGt(psiB, 0, "o CHAO: um pool vivo dentro do horizonte nunca cai a zero");
    }
}
