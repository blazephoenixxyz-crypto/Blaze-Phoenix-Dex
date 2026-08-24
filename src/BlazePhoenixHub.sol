// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixHub
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  RESPONSABILIDADE UNICA
//      Saber que pools existem e quanto valem. O Hub e a memoria do protocolo —
//      e memoria e a superficie mais perigosa que ha, porque tudo o que la entrar
//      errado sai errado a toda a gente, para sempre.
//
//  O QUE ESTE CONTRATO GARANTE
//      H1  NADA ENTRA SEM PROVA. Todo o argumento de registo e calldata do
//          chamador — pool, kind e profundidade. Um kind cujo `pool` e um par tem
//          de PROVAR que negoceia mesmo aquele par (token0/token1) antes de ser
//          gravado; um V4 tem de recomputar o seu proprio poolId. Sem isto,
//          registava-se um contrato escrito pelo atacante, sob um par escolhido
//          por ele, a uma profundidade escolhida por ele, sem segurar nada.
//      H2  AS DUAS PORTAS FECHAM — CADA UMA COM A SUA MASCARA. Ha dois caminhos de
//          escrita, `addFactory` e `recordSwap`, e ambos filtram kinds. Um fix
//          aplicado a uma so das duas e a assinatura de defeito da casa; ja
//          aconteceu aqui e esta corrigido. Mas a correcao NAO e as duas usarem a
//          mesma constante: fecharam-se com `KINDS_ROUTABLE` e `KINDS_EXECUTABLE`,
//          que hoje diferem num bit (o V4_NATIVE, que nenhuma factory regista e o
//          Router executa). Usar a mesma constante nao e fazer a mesma pergunta —
//          a primeira tentativa deste fecho partilhou a mascara e matou em silencio
//          todo o registo de pools nativas. E ha uma TERCEIRA porta, a `seedPool`
//          do operador, que deliberadamente nao filtra kind: e a unica cujo
//          chamador ja e de confianca, e fecha a jusante (theta 0x0 cota zero).
//      H3  A DEFESA E LOCAL. `$.router` e trocavel, logo o unico produtor de
//          kinds nao e imutavel: o Hub nao delega a sua propria admissao a um
//          endereco que pode deixar de ser o que era no dia do deploy.
//      H4  RECUSAR NUNCA REVERTE UM SWAP. O swap do utilizador ja executou; uma
//          decisao de registo nao pode fazer falhar o que ja liquidou. Falha-se
//          a fechar sobre o REGISTO, a abrir sobre o UTILIZADOR.
//
//  O QUE ESTE CONTRATO NAO FAZ, DELIBERADAMENTE
//      Nao e fonte de preco — a vitalidade e a profundidade sao pistas de
//      DESCOBERTA, nunca entradas de matematica de cotacao. Nao decide rotas. E
//      nao tem lista branca de venues: a admissao e por prova, nao por confianca.
//
//  The Hub is the on-chain pool registry. Each pool's state is encoded in a
//  single packed 256-bit slot (vitality, depth bucket, kind, timestamps,
//  bridge bit), so reading its fitness score costs one SLOAD. Storage is
//  three mappings:
//
//    1.  slot[key]        → packed pool state
//    2.  poolOf[key]      → address of the pool
//    3.  pairKeys[t0][t1] → slot keys for the (t0, t1) pair
//
//  Registration is automatic: a swap routed through a previously unknown
//  pool inserts it on the success path with vitality = 1 and a depth bucket
//  derived from the current pool depth. When a pair already holds MAX_SLOTS
//  pools, the lowest-scoring occupant is overwritten only if the newcomer's
//  projected score improves on it by at least EVICTION_IMPROVE_BPS.
//
//  Discovery is permissionless and factory/CREATE2-driven. Factory entries
//  describe the supported DEXs; for any (t0, t1) the Hub iterates the factory
//  list, derives candidate addresses and includes those with code. V4 is
//  handled separately: the PoolManager singleton has no per-pair factory, so
//  admins register V4 keys directly.
//
//  Storage layout follows ERC-7201 namespacing for proxy compatibility.
// =============================================================================
pragma solidity 0.8.36;

import {
    BlazePhoenixCore as BPC,
    PoolInfo
} from "./BlazePhoenixCore.sol";

/// @dev O Router e o PRODUTOR UNICO do "qual e o WETH canonico desta chain".
///      O Hub pergunta-lhe em vez de guardar uma segunda copia — uma constante
///      duplicada aqui podia divergir da que o Router usa para validar o
///      unwrap, e a divergencia seria explorada pelo lado do wrap.
interface IRouterWeth { function weth() external view returns (address); }

contract BlazePhoenixHub {

    string  internal constant VERSION = "2.0.0";

    // ─── Pool-fitness constants ────────────────────────────────────────

    uint8   internal constant MAX_SLOTS              = 16;
    /// 3 BRIDGES. Desceu para 2 a 2026-08-21 e VOLTOU a 3 no mesmo dia, porque
    /// a medicao que justificou o corte estava a olhar para a porta errada.
    ///
    /// O QUE SE MEDIU: a 3a bridge custa +760.125 gas por solve a frio (+32,5%).
    /// O QUE ESCAPOU: esse custo esta INTEIRAMENTE no SOLVE, e o solve so corre
    /// on-chain na porta B (`swapBestExactIn`). Nas outras tres portas a rota
    /// vem resolvida de fora, por `eth_call` — de graca.
    ///
    /// E o `_rank` escolhe UMA rota entre os candidatos: mais bridges avaliadas
    /// nao tornam a rota executada maior. Medido: a calldata de `swapExactIn`
    /// depende da TOPOLOGIA (1.028 bytes a 1 hop/1 leg, +544 por hop, +320 por
    /// leg), nunca de quantas bridges o Solver considerou.
    ///
    /// Logo, na porta A — a que as quatro chains do deploy devem usar — a 3a
    /// bridge custa ZERO on-chain e so acrescenta uma topologia candidata.
    /// Cortar era optimizar a porta que ninguem paga: o mesmo erro que o
    /// SSTORE2 (-48.772 gas medidos, valor esperado ~0).
    uint8   internal constant MAX_BRIDGES            = 3;
    /// @dev Por quantas bridges o Solver REALMENTE roteia. NAO e o MAX_BRIDGES, e a diferenca
    ///      entre os dois era uma assimetria silenciosa: o Solver expande as bridges DESENROLADO
    ///      a mao (`b0`, `b1` em Solver:203-215) e `_rank` tem tres lugares — directo + duas.
    ///      A terceira bridge nunca podia ser um hop.
    ///
    ///      E MESMO ASSIM TINHA PODERES. O `isBridge[t]` abre a porta permissionless do
    ///      `claimV4` ("um dos lados tem de ser uma bridge de confianca") e poe a flag `bridged`
    ///      no Monoslot, que vale +25% de fitness no `psi` (Core). Num registo CAPADO com despejo
    ///      por fitness, isso significa que uma terceira bridge enchia o registo de pools bem
    ///      classificadas e INALCANCAVEIS, a despejar as que o router consegue usar. O bonus era
    ///      pago sobre liquidez que o router nao toca.
    ///
    ///      SAO DUAS PERGUNTAS — "este token e uma ancora de confianca?" (`isBridge`) e "pode um
    ///      hop passar por aqui?" (`_isRoutableBridge`) — e HOJE TEM A MESMA RESPOSTA, porque o
    ///      Solver expande TODAS as bridges configuradas e deixa o `_rank` decidir pelo
    ///      `totalOut` medido. Ficam duas perguntas com dois nomes na mesma: a igualdade e um
    ///      FACTO, nao uma definicao, e e o `test_NenhumaBridgeConfiguradaEFantasma` que a pina.
    ///      No dia em que alguem subir o MAX_BRIDGES sem acrescentar um bracco ao Solver, e o
    ///      teste que explica a divergencia em vez de ela voltar a acontecer em silencio.
    ///
    ///      PORQUE NAO SE ESCOLHEM "AS MELHORES 2": porque isso seria um SEGUNDO produtor do
    ///      juizo "qual rota e melhor", ao lado do `_rank` — que ja o produz, e produz melhor.
    ///      Profundidade registada e um proxy; `totalOut` e a saida construida e medida. Um
    ///      pre-filtro por proxy so podia descartar a rota que o produtor verdadeiro escolheria.
    ///
    ///      PINADO por `test_RoutableBridgesMatchSolverExpansion`: se alguem acrescentar um `b2`
    ///      ao Solver sem mexer aqui, ou mexer aqui sem mexer la, o teste explica a divergencia
    ///      em vez de a deixar em silencio.
    uint8   internal constant MAX_BRIDGE_ROUTES      = MAX_BRIDGES;
    uint8   internal constant MAX_FACTORIES          = 16;
    uint16  internal constant EVICTION_IMPROVE_BPS   = 1_000;

    // ─── addFactory coherence-guard constants ────────────────────────────
    // Enumeracao de kinds: PRODUTOR UNICO no Core (`BPC.KIND_*`). Este ficheiro tinha aqui uma
    // copia local que se anunciava como "espelha o Core" — e o espelho estava INCOMPLETO: parava
    // no ALGEBRA e nao tinha nome nenhum para o KIND_V4_NATIVE (8). Uma mascara escrita com os
    // nomes disponiveis nao conseguia sequer EXPRIMIR o bit 8, e foi por essa porta que a
    // regressao entrou (ver KINDS_EXECUTABLE abaixo). Os numeros 2, 3 e 7 sao LAPIDES e nao sao
    // nomeados nem aqui nem la — ver a nota das lapides no Core quanto a por que nao voltam.
    //
    // PORQUE ESTE COLAPSO E LEGITIMO E O DO PREDICADO NAO E: um numero de kind e uma PRIMITIVA
    // (um produtor de um valor). Primitivas querem produtor unico — duplica-las cria irmaos que
    // divergem, como este divergiu. Um PREDICADO DE ACEITACAO quer o oposto: manter dois juizes
    // que hoje concordam e o que permite detetar o dia em que deixarem de concordar. Ver a nota
    // do KINDS_PAIR_PROOF logo abaixo, onde duas mascaras coincidentes ficam DELIBERADAMENTE
    // separadas — e onde um mutante do harness ja se escondeu uma vez.

    /// @notice Os kinds que uma factory pode registar — o conjunto, como uma palavra de bits.
    /// @dev    Bit `k` ligado = kind `k` admissivel. Bits desligados sao LAPIDES, nao lacunas:
    ///
    ///           bits 2, 3 e 7 (as LAPIDES)      — venues retiradas por decisao do dono em
    ///                                             2026-08-20: quase nenhuma L2 as tinha e
    ///                                             custavam bytecode em cinco contratos. Com elas
    ///                                             saiu o unico `approve` do Router (onde vivia o
    ///                                             HUNT-001), o unico produtor de profundidade
    ///                                             atestado pelo caller, e o unico buraco
    ///                                             deliberado na prova de autenticidade daqui.
    ///                                             O numero fica queimado; ver o Core.
    ///           bit 8 (V4_NATIVE)               — nao se registaram por factory: derivam-se do
    ///                                             singleton. Nunca tiveram bit e nao passam a ter.
    ///
    ///         OS NUMEROS NUNCA SE REUTILIZAM. `decodeKind` le o kind dos bits do Monoslot: dar o
    ///         2 a uma venue nova reinterpretaria pools ja gravadas como sendo dessa venue. Uma
    ///         venue nova leva um numero novo e liga o bit dele — uma linha de dados, zero ramos.
    uint256 internal constant KINDS_ROUTABLE =
          (uint256(1) << BPC.KIND_V2)      // 0 — constant-product
        | (uint256(1) << BPC.KIND_V3)      // 1 — concentrada
        | (uint256(1) << BPC.KIND_V4)      // 4 — singleton, via MODE_V4_DERIVE
        | (uint256(1) << BPC.KIND_SOLIDLY) // 5 — pares stable/volatile
        | (uint256(1) << BPC.KIND_ALGEBRA);// 6 — concentrada com fee dinamica

    /// @notice Os kinds que o Router SABE EXECUTAR — o conjunto legitimo na porta do `recordSwap`,
    ///         que corre depois de a perna ja ter executado.
    /// @dev    NAO E O `KINDS_ROUTABLE`, E ESSA DISTINCAO E O PONTO DESTA CONSTANTE.
    ///
    ///         `KINDS_ROUTABLE` responde a "que kinds pode uma FACTORY registar?". O bit 8 esta
    ///         desligado la por uma razao que so vale para AQUELA pergunta: as pools V4 nativas
    ///         nao vem de factory nenhuma, derivam-se do singleton. Esta constante responde a
    ///         "que kinds pode o Router ter acabado de executar?" — e o V4_NATIVE e um deles: o
    ///         Router deriva o poolId nativo antes de chamar este `recordSwap` com esse kind.
    ///
    ///         USAR A MESMA CONSTANTE NAO E FAZER A MESMA PERGUNTA. As duas mascaras partilham
    ///         cinco dos seis bits; partilhar bits nao e partilhar semantica. Reutilizar aqui a
    ///         mascara da factory deixava cair TODOS os swaps V4 nativos em silencio — o ramo
    ///         nativo do insert ficava inalcancavel, e as pools nativas ja registadas deixavam de
    ///         ser refrescadas ate envelhecerem para fora do registo. Medido, e pinado por
    ///         `test_RecordSwapRefreshesNativeV4Pool`.
    ///
    ///         Escrita por extenso, e NAO derivada de `KINDS_ROUTABLE | (1 << KIND_V4_NATIVE)`:
    ///         deriva-la reamarrava as duas perguntas uma a outra e devolvia o defeito pela porta
    ///         do lado, disfarcado de elegancia.
    uint256 internal constant KINDS_EXECUTABLE =
          (uint256(1) << BPC.KIND_V2)        // 0 — constant-product
        | (uint256(1) << BPC.KIND_V3)        // 1 — concentrada
        | (uint256(1) << BPC.KIND_V4)        // 4 — singleton
        | (uint256(1) << BPC.KIND_SOLIDLY)   // 5 — pares stable/volatile
        | (uint256(1) << BPC.KIND_ALGEBRA)   // 6 — concentrada com fee dinamica
        | (uint256(1) << BPC.KIND_V4_NATIVE);// 8 — singleton, perna em ETH nativo

    /// @notice Os modes de descoberta validos, pelo mesmo criterio.
    /// @dev    0-3 chamam a factory (getPair/getPool); 4-7 derivam por CREATE2; 9 e o derive do V4.
    ///         O bit 8 esta desligado: era o meta-registry de uma venue retirada e saiu com ela.
    ///         Sem esta mascara ficaria aceite para QUALQUER kind, porque o unico
    ///         limite anterior era `mode > MODE_V4_DERIVE` e o 8 cabia la dentro — um mode que so
    ///         fazia sentido para uma venue removida continuaria aberto a todas as outras.
    /// @dev Kinds cujo campo `pool` e um par que expoe token0()/token1() — logo a prova de
    ///      autenticidade do `recordSwap` aplica-se-lhes. Era o literal 0x6b, que tinha o bit 3
    ///      ligado por uma venue ja retirada.
    ///
    ///      NAO E A MESMA PERGUNTA QUE O A_PAIR_VER DA THETA, e por isso vive aqui e nao la: o
    ///      A_PAIR_VER descreve a FORMA do estado ("existe token0()?"); isto e um predicado de
    ///      ACEITACAO ("que kinds tem de PROVAR o par antes de entrar no registo?"). Que hoje
    ///      coincidam e um facto medido, nao uma definicao — e o teste pina a igualdade por
    ///      construcao para que, no dia em que divergirem, seja a divergencia a ser explicada
    ///      e nao o silencio. Colapsar os dois porque os bits batem certo trocava uma
    ///      verificacao por uma coincidencia.
    uint256 internal constant KINDS_PAIR_PROOF =
          (uint256(1) << BPC.KIND_V2) | (uint256(1) << BPC.KIND_V3)
        | (uint256(1) << BPC.KIND_SOLIDLY) | (uint256(1) << BPC.KIND_ALGEBRA);

    uint256 internal constant MODES_VALID = 0x2FF; // bits 0-7 e 9; bit 8 e lapide
    // MODE enumeration: 0-3 are factory-call (getPair/getPool variants);
    // 4-7 are CREATE2 salt families (V2 salt, V3 salt, EIP-1167 clone, V3-CL).
    uint8   internal constant MODE_CREATE2_V2        = 4;
    uint8   internal constant MODE_CREATE2_V3        = 5;
    uint8   internal constant MODE_CREATE2_CLONE     = 6;
    // Live, but dispatched by arithmetic (`sub = mode - 4`) inside BPC.deriveAddress rather than
    // by name, so a naive "unreferenced identifier" scan will flag it as dead. It is not: mode 7
    // is the V3-CL salt family (keccak(t0, t1, tickSpacing) — Velodrome/Aerodrome CL).
    uint8   internal constant MODE_CREATE2_V3CL      = 7;
    // MODE_V4_DERIVE: Uniswap-V4 derive-scan. V4's singleton PoolManager has
    // no factory/pair enumeration, so this mode DERIVES hookless candidate
    // poolIds (learned per-token pattern code -> canonical tiers -> the row's
    // paired extras -> a bounded generator grid) and emits only the ones
    // proven live on the PoolManager via extsload. The row's `factory` field
    // records the PoolManager for operator legibility (and `_ne0`); the scan
    // itself always reads `$.v4PoolManager` — the single source of truth,
    // which `setV4Manager` can still rotate while control lasts.
    uint8   internal constant MODE_V4_DERIVE         = 9;

    // ─── V4 derive-scan bounds ─────────────────────────────────────────
    // Per-scan cap on emitted V4 pools (early-stop), sized to the Solver's
    // appetite for parallel candidates on one pair.
    uint256 internal constant V4_CAP                 = 8;
    // Generator Pi_K: fee = 10_000*j, tickSpacing = 100*j, hookless — the
    // observed launchpad family ("ratio-100" pools). j descends from
    // V4_GRID_MAX so the high-fee launch tiers (the ones that exist before a
    // token matures into canonical tiers) are probed first; V4_GRID_PROBES
    // caps what a cold miss can cost. Must satisfy V4_GRID_PROBES <= V4_GRID_MAX.
    uint256 internal constant V4_GRID_MAX            = 99;
    uint256 internal constant V4_GRID_PROBES         = 40;

    // ─── ERC-7201 namespace ────────────────────────────────────────────

    bytes32 private constant HUB_SLOT
        = keccak256(abi.encode(uint256(keccak256("blazephoenix.hub.v1")) - 1))
        & ~bytes32(uint256(0xff));

    struct Factory {
        address factory;
        uint8   kind;
        uint8   mode;        // CREATE2 salt mode (see BPC.deriveAddress)
        bytes32 initHash;
        uint24[] fees;
        int24[]  spacings;
    }

    struct V4Entry {
        address currency0;
        address currency1;
        uint24  fee;
        int24   tickSpacing;
        address hooks;
    }

    struct HubStore {
        // access
        address admin;
        address router;
        address solver;
        address quoter;
        mapping(address => bool) operator;
        // pool registry
        mapping(bytes32 => uint256) slot;       // packed pool state per key (kind lives HERE, encodeSlot)
        mapping(bytes32 => address) poolOf;     // pool address per key
        // kindOf mapping DELETED (2026-08-11 gas audit): it was write-only dead
        // storage — kind is decoded from the packed slot by every consumer —
        // and cost 22.1k per fresh pool registration for nothing.
        mapping(bytes32 => address) hooksOf;    // hooks per key (V4 only; zero-guarded write)
        // pair index
        mapping(address => mapping(address => bytes32[])) pairKeys;
        // bridges
        address[MAX_BRIDGES] bridges;
        uint8 bridgeCount_;
        mapping(address => bool) isBridge;
        // factories
        Factory[] factories;
        // V4 registry (singleton-managed, manual entries)
        V4Entry[] v4Entries;
        address v4PoolManager;
        // hooks allow-list + codehash pin (Layer 3: auto-pause on code change)
        mapping(address => bool) hookAllowed;
        mapping(address => bytes32) hookCodehash;
        // status
        bool paused;
        bool initialized;
        bool controlRenounced;
        // V4 derive-discovery: learned per-token "pattern code" — the packed
        // (fee << 24 | uint24(tickSpacing)) hookless tier this token's V4
        // pool was last PROVEN at (claimV4 or a routed V4 swap). 0 = unknown
        // (a real tier always has tickSpacing >= 1, so a valid code is never
        // zero). DISCOVERY-HINT METADATA ONLY (INV-16 boundary): read
        // exclusively by the derive-scan and the recordSwap healer — never by
        // psi/fitness/eviction/route-ranking — so a stale or manipulated code
        // can only ever waste one probe: every candidate is re-proven live
        // before emission and proven again at quote time.
        mapping(address => uint256) v4CodeOf;
        // V1 / invariant I11 (no unbounded scan on the hot path): O(1) recovery of
        // a V4 pool's V4Entry by its registry key (stored value is index+1 into
        // v4Entries; 0 = absent). The global v4Entries array is append-only and
        // permissionlessly grown by claimV4, so scanning it in _readPoolInfo made
        // every V4 quote pay O(#entries) on the per-solve getActivePools path.
        mapping(bytes32 => uint256) v4EntryOf;
    }

    function _store() private pure returns (HubStore storage $) {
        bytes32 s = HUB_SLOT;
        assembly { $.slot := s }
    }

    // ─── Events ────────────────────────────────────────────────────────

    event Registered(bytes32 indexed key, address indexed pool, uint8 kind);
    event Evicted(bytes32 indexed key, address indexed pool);
    event Volume(bytes32 indexed key, uint256 amtIn, uint256 amtOut);
    event Factory_(address indexed factory, uint8 kind, uint8 mode);
    event Bridge_(address indexed token, bool added);
    event V4Add(uint256 indexed idx, address c0, address c1, uint24 fee);
    /// @dev ids: 0 admin · 1 router · 2 solver · 3 quoter · 4 operator · 5 v4PoolManager.
    ///      O 5 nao e um "papel" no sentido de permissao — e o SINGLETON contra o qual correm os
    ///      extsload que constituem a prova de autenticidade do claimV4. Entra aqui em vez de num
    ///      evento proprio porque E um endereco de protocolo e cabe na forma sem custo. O que nao
    ///      podia continuar era mudar em silencio: o Axioma Meta-Supremo pressupoe o APARELHO de
    ///      medicao fixo, e um instrumento mutavel e inobservavel devolve um numero perfeitamente
    ///      valido do sitio errado, sem sintoma nenhum.
    event RoleSet(uint8 role, address who);
    /// @notice O interruptor de emergencia mudou.
    event PausedSet(bool paused);
    event ControlRenounced();

    // ─── Single error path ─────────────────────────────────────────────

    error HubE(uint16 code);

    // 1 = unauthorized, 2 = paused, 3 = zero address, 4 = bad input
    // 5 = unknown pool, 6 = max slots, 7 = bridge cap, 8 = hook denied
    // 9 = V4 claim ineligible (no bridge anchor / not a live hookless pool /
    //     unresolved dynamic fee)

    function _auth(bool ok) internal pure { if (!ok) revert HubE(1); }
    function _ne0 (address a) internal pure { if (a == address(0)) revert HubE(3); }

    // ─── Constructor / initializer ─────────────────────────────────────

    constructor(address admin_) {
        // The admin is fixed at construction (an explicit argument, NOT
        // msg.sender) so the Hub can be deployed through a CREATE3 factory —
        // where msg.sender is the one-shot proxy that could never call
        // initialize, which would otherwise brick the registry permanently.
        // Only this admin may initialize, so the front-running window stays shut.
        _ne0(admin_);
        _store().admin = admin_;
    }

    function initialize(address admin_, address v4Manager_) external {
        HubStore storage $ = _store();
        // Only the deployer can initialize, and only once.
        if ($.initialized || msg.sender != $.admin) revert HubE(1);
        _ne0(admin_);
        $.initialized = true;
        $.admin = admin_;
        $.operator[admin_] = true;
        $.v4PoolManager = v4Manager_;
        emit RoleSet(0, admin_);
    }

    /// @notice Permanently surrender the CONTROL powers — the ones that can
    ///         redirect or freeze the protocol: setRoles, setOperator,
    ///         setPaused, setV4Manager and removeBridge can never be used
    ///         again. The CURATOR powers that only grow the registry —
    ///         addFactory, addBridge, allowHook — remain available so new
    ///         venues can still be listed (a malicious listing cannot drain:
    ///         pools are validated at quote and execution and bounded by the
    ///         output floor and the caller's userMinOut). Irreversible.
    function renounceControl() external onlyAdmin {
        _store().controlRenounced = true;
        emit ControlRenounced();
    }

    // ─── Modifiers ─────────────────────────────────────────────────────

    // Curator: addFactory / addBridge / allowHook — grows the registry only.
    modifier onlyAdmin()    { _auth(msg.sender == _store().admin); _; }
    // Control: redirect/freeze powers. Disabled forever by renounceControl().
    modifier onlyControl()  {
        HubStore storage $ = _store();
        _auth(msg.sender == $.admin && !$.controlRenounced);
        _;
    }
    modifier onlyOperator() { _auth(_store().operator[msg.sender] || msg.sender == _store().admin); _; }
    modifier onlyRouter()   { _auth(msg.sender == _store().router); _; }
    modifier whenLive()     { if (_store().paused) revert HubE(2); _; }

    // ─── Control (frozen by renounceControl) ───────────────────────────

    function setRoles(address r, address s, address q) external onlyControl {
        HubStore storage $ = _store();
        $.router = r; $.solver = s; $.quoter = q;
        emit RoleSet(1, r); emit RoleSet(2, s); emit RoleSet(3, q);
    }
    function setOperator(address who, bool ok) external onlyControl {
        _store().operator[who] = ok; emit RoleSet(4, who);
    }
    function setPaused(bool b) external onlyControl { _store().paused = b; emit PausedSet(b); }
    function setV4Manager(address m) external onlyControl { _store().v4PoolManager = m; emit RoleSet(5, m); }

    // ─── Curator (permanent: grows the registry only) ──────────────────

    function allowHook(address h, bool ok) external onlyAdmin {
        HubStore storage $ = _store();
        $.hookAllowed[h] = ok;
        // Pin the code at admission (Layer 3). A later code change (proxy
        // upgrade, selfdestruct+redeploy) makes isHookLive() false → the hook is
        // auto-paused (not routable) WITHOUT eviction; re-admitting re-pins it.
        if (ok) $.hookCodehash[h] = h.codehash; else delete $.hookCodehash[h];
    }

    /// @notice A hook is routable only while allow-listed AND its runtime code
    ///         still matches the codehash pinned at admission. A hook whose code
    ///         changes is auto-paused (not routable) with its pools' registry
    ///         state preserved (read-only) — it resumes only if re-admitted. A
    ///         hookless pool (h == 0) is always live.
    function isHookLive(address h) public view returns (bool) {
        if (h == address(0)) return true;
        HubStore storage $ = _store();
        return $.hookAllowed[h] && h.codehash == $.hookCodehash[h];
    }

    // ─── Bridges (MAX_BRIDGES configuraveis, MAX_BRIDGE_ROUTES roteaveis) ───────────────────────────────────────────────

    function addBridge(address t) external onlyAdmin {
        _ne0(t);
        HubStore storage $ = _store();
        if ($.bridgeCount_ >= MAX_BRIDGES) revert HubE(7);
        $.bridges[$.bridgeCount_] = t;
        $.isBridge[t] = true;
        unchecked { $.bridgeCount_++; }
        emit Bridge_(t, true);
    }

    function removeBridge(uint8 idx) external onlyControl {
        HubStore storage $ = _store();
        if (idx >= $.bridgeCount_) revert HubE(4);
        address t = $.bridges[idx];
        $.isBridge[t] = false;
        for (uint8 i = idx; i + 1 < $.bridgeCount_; ) {
            $.bridges[i] = $.bridges[i + 1];
            unchecked { ++i; }
        }
        $.bridges[$.bridgeCount_ - 1] = address(0);
        unchecked { $.bridgeCount_--; }
        emit Bridge_(t, false);
    }

    /// @dev "Pode um hop passar por este token?" — distinto de `isBridge`, que responde "e uma
    ///      ancora de confianca?". So as primeiras MAX_BRIDGE_ROUTES posicoes sao roteaveis,
    ///      porque so essas o Solver expande. O early-out no `isBridge` mantem o caso comum (nem
    ///      um nem outro token e bridge) exatamente ao custo de hoje: um SLOAD.
    function _isRoutableBridge(HubStore storage $, address t) private view returns (bool) {
        if (!$.isBridge[t]) return false;
        for (uint8 i; i < MAX_BRIDGE_ROUTES; ) {
            if ($.bridges[i] == t) return true;
            unchecked { ++i; }
        }
        return false;
    }

    function bridge(uint8 i) external view returns (address) { return _store().bridges[i]; }
    function bridgeCount() external view returns (uint8) { return _store().bridgeCount_; }
    function isBridgeToken(address t) external view returns (bool) { return _store().isBridge[t]; }

    // ─── Factory registry ──────────────────────────────────────────────

    /// @notice Register a DEX factory adapter.
    /// @dev    Enforces configuration coherence between (kind, mode, initHash,
    ///         fees) before storing. A mis-configured adapter would otherwise
    ///         derive wrong pool addresses silently, so every structurally
    ///         impossible combination reverts with HubE(5). Rules:
    ///           * kind pertence a KINDS_ROUTABLE                 [invalidKind]
    ///           * mode pertence a MODES_VALID: 0-3 factory-call,
    ///             4-7 CREATE2, 9 V4 derive-scan (o 8 e lapide)     [invalidMode]
    ///           * CREATE2 modes (mode >= 4) require initHash != 0, except
    ///             modes 8 and 9 which derive nothing via CREATE2         [R1]
    ///           * mode 4 (V2 salt)  is only valid for kind V2
    ///           * mode 6 (clone)    is only valid for kind SOLIDLY
    ///           * mode 5 (V3 salt)  is valid for V3 or ALGEBRA; ALGEBRA
    ///             additionally requires every fee == 0 (dynamic-fee sentinel) [R2]
    ///           * mode 9 (V4 derive) is only valid for kind V4, and its
    ///             fees/spacings are PAIRED explicit extras (fees[i] with
    ///             spacings[i], never a cross-product) — equal length required
    ///         Factory-call modes (mode < 4) carry no initHash requirement.
    function addFactory(
        address factory, uint8 kind, uint8 mode, bytes32 initHash,
        uint24[] calldata fees, int24[] calldata spacings
    ) external onlyAdmin returns (uint8) {
        _ne0(factory);

        // 1) kind / mode domain — DOIS conjuntos, expressos como DADOS.
        //
        // COMO LER ISTO, se e a primeira vez. Cada bit da constante e um kind: o bit numero `k`
        // ligado significa "o kind k e admissivel". A verificacao `(MASK >> kind) & 1` pergunta
        // "o bit deste kind esta ligado?" — uma so operacao, em vez de uma cadeia de `if`s que
        // nomeiam cada kind a mao.
        //
        // PORQUE ASSIM. Este contrato tem um meta-padrao de defeito bem documentado: um fix
        // aplicado a UM de dois canais simetricos, e o irmao esquecido. Aconteceu 10+ vezes. Uma
        // cadeia de `if`s e exatamente isso a acontecer: cada sitio que enumera kinds a mao e um
        // sitio que pode ficar dessincronizado dos outros. Um conjunto expresso como uma palavra
        // de bits nao tem irmao para divergir — a diversidade passa a ser uma COORDENADA (um bit)
        // e nao um RAMO.
        //
        // NAO E PADRAO NOVO: o Hub ja o usa em `_register` (a mascara das kinds "pair-shaped", as
        // que expoem token0()/token1()). Isto so lhe da um nome e um irmao, em vez de o deixar
        // como literal magico solto no meio do codigo.
        //
        // FAIL-CLOSED DE GRACA. Um kind fora do conjunto tem bit 0 e reverte. Um kind acima de
        // 255 nao existe (o tipo e uint8) e um shift alto devolve 0 — reverte na mesma. Nao ha
        // ramo de "default" para alguem esquecer.
        if (((KINDS_ROUTABLE >> kind) & 1) == 0) revert HubE(5); // invalidKind
        if (((MODES_VALID    >> mode) & 1) == 0) revert HubE(5); // invalidMode

        // 2) CREATE2 modes require a non-zero init-code hash (R1). Os modes altos que
        //    NAO derivam por CREATE2 estao isentos; desses so o 9 sobrevive — o 8 e
        //    lapide e o MODES_VALID recusa-o antes de chegar aqui.
        if (
            mode >= MODE_CREATE2_V2
                && mode != MODE_V4_DERIVE && initHash == bytes32(0)
        ) revert HubE(5);

        // 3) salt-slot ↔ kind coherence
        if (mode == MODE_CREATE2_V2 && kind != BPC.KIND_V2)      revert HubE(5);
        if (mode == MODE_CREATE2_CLONE && kind != BPC.KIND_SOLIDLY) revert HubE(5);
        if (mode == MODE_CREATE2_V3) {
            // V3 salt slot accepts V3 or Algebra only
            if (kind != BPC.KIND_V3 && kind != BPC.KIND_ALGEBRA) revert HubE(5);
            // Algebra is dynamic-fee: every declared fee must be the 0 sentinel (R2)
            if (kind == BPC.KIND_ALGEBRA) {
                for (uint256 i; i < fees.length; ) {
                    if (fees[i] != 0) revert HubE(5);
                    unchecked { ++i; }
                }
            }
        }
        // V4 derive-scan coherence: mode 9 is only meaningful for the V4
        // kind, and its fees/spacings are PAIRED explicit extras — enforce
        // equal length so a misregistered row cannot silently mispair them.
        if (mode == MODE_V4_DERIVE) {
            if (kind != BPC.KIND_V4) revert HubE(5);
            if (fees.length != spacings.length) revert HubE(5);
        }

        HubStore storage $ = _store();
        if ($.factories.length >= MAX_FACTORIES) revert HubE(4);
        $.factories.push(Factory({
            factory: factory, kind: kind, mode: mode,
            initHash: initHash, fees: fees, spacings: spacings
        }));
        emit Factory_(factory, kind, mode);
        return uint8($.factories.length - 1);
    }

    function factoryCount() external view returns (uint256) { return _store().factories.length; }

    // ─── V4 explicit registration ──────────────────────────────────────

    function addV4(
        address c0, address c1, uint24 fee, int24 tickSpacing, address hooks
    ) external onlyOperator returns (bytes32 key) {
        _ne0(c1);
        if (c0 == c1) revert HubE(4);
        HubStore storage $ = _store();
        if (hooks != address(0) && !$.hookAllowed[hooks]) revert HubE(8);

        // ─── POOL DE ETH NATIVO ───────────────────────────────────────────
        // No V4 o ETH nativo E `address(0)` como currency, e ordena SEMPRE
        // primeiro. Era recusado aqui pelo `_ne0(c0)`, e por isso a familia
        // inteira ficava inalcancavel: o Router SABE executa-la (KIND_V4_NATIVE,
        // `nativeMapVerified`, a costura JIT de unwrap/wrap no unlockCallback),
        // mas nenhuma porta de descoberta a deixava entrar no registo — e sem
        // registo o Solver nunca a propoe. Galo e ovo.
        //
        // A CHAVE DA POOL usa as currencies REAIS (nativo = address(0)); o
        // REGISTO fala WETH, para que o Solver a encontre ao rotear WETH->c1.
        // E a mesma divisao que o Router ja faz: "a rota fala WETH, a execucao
        // fala nativo".
        bool nat = c0 == address(0);
        address w;
        if (nat) {
            w = IRouterWeth($.router).weth();
            // Fail-closed: sem WETH cablado nao ha traducao possivel, e uma
            // pool WETH/WETH nao existe.
            if (w == address(0) || c1 == w) revert HubE(3);
        } else {
            _ne0(c0);
        }
        (address s0, address s1) = BPC.sortTokens(c0, c1);
        $.v4Entries.push(V4Entry({
            currency0: s0, currency1: s1, fee: fee,
            tickSpacing: tickSpacing, hooks: hooks
        }));
        // Register under the SAME key formula recordSwap will later look up
        // (keyOf, keyed on the truncated poolId-as-address). A prior version
        // hashed a bespoke (pid, t0, t1) tuple here (_poolKeyV4) whose
        // preimage width could never match keyOf's (pool, t0, t1) — so this
        // pool's first real swap silently created a duplicate registry entry
        // instead of ticking this one. keyOf is the single source of truth
        // for "how do we key a pool" now.
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, tickSpacing, hooks);
        address poolAddr = address(uint160(uint256(pid)));
        (address r0, address r1) = nat ? BPC.sortTokens(w, c1) : (s0, s1);
        key = keyOf(poolAddr, r0, r1);
        $.v4EntryOf[key] = $.v4Entries.length; // V1/I11: O(1) key -> V4Entry
        _register(key, poolAddr, nat ? BPC.KIND_V4_NATIVE : BPC.KIND_V4,
                  fee, hooks, r0, r1, true);
        // Se o WETH nao ficou em token0 pela ordenacao, marca a inversao para
        // que o `_readPoolInfo` a desfaca ao reportar.
        if (nat && r0 != w) $.slot[key] = _markNativeSwapped($.slot[key], true);
        emit V4Add($.v4Entries.length - 1, s0, s1, fee);
    }

    /// @notice Permissionless, on-chain-VERIFIED registration of a HOOKLESS V4
    ///         pool. Unlike addV4 (operator-trusted), anyone may call this: the
    ///         trust comes from the chain, not a role. Uniswap V4 has no
    ///         factory/pair enumeration (a singleton PoolManager), so the only
    ///         autonomous discovery shape is populate-once / read-forever — and
    ///         the population is made safe by proving the pool on-chain rather
    ///         than trusting the caller.
    ///
    ///         SAFE-GATE (quote == exec by construction):
    ///           - hookless only (the poolId is derived with hooks == 0), so the
    ///             vanilla V4 quote prices the pool exactly; delta-altering hooks
    ///             cannot be admitted here — their hookless poolId does not exist
    ///             and the existence proof below fails closed;
    ///           - native-currency keys are rejected (_ne0 on both currencies);
    ///           - a dynamic-fee pool is admitted only if its effective fee
    ///             resolves from slot0 (INV-20), else it fails closed;
    ///           - at least one side must be a protocol bridge anchor: anti-spam,
    ///             and it guarantees the pool composes with the routing graph;
    ///           - the pool must be initialized AND hold real liquidity in the
    ///             configured PoolManager (proven by extsload, unforgeable —
    ///             faking either costs capital).
    ///
    ///         Entries are provisional (trusted = false): a permissionlessly
    ///         claimed pool must earn fitness and is weighted by MEASURED
    ///         marginal output, so a thin or hostile venue self-weights toward
    ///         zero (INV-16).
    /// @return key The registry key. Idempotent: re-claiming a live pool returns
    ///         the existing key without creating a duplicate entry.
    function claimV4(address c0, address c1, uint24 fee, int24 tickSpacing)
        external returns (bytes32 key)
    {
        _ne0(c0); _ne0(c1);                 // native currency (address(0)) rejected
        if (c0 == c1) revert HubE(4);
        HubStore storage $ = _store();
        // Anchor gate: one side must be a ROUTABLE bridge. Nao basta ser uma ancora de
        // confianca — esta porta e permissionless, e admitir um par que o router nunca
        // consegue atravessar so serve para gastar um lugar no registo capado.
        if (!_isRoutableBridge($, c0) && !_isRoutableBridge($, c1)) revert HubE(9);
        (address s0, address s1) = BPC.sortTokens(c0, c1);
        // HOOKLESS ONLY — the poolId is derived with hooks == address(0).
        bytes32 pid = BPC.computeV4PoolId(s0, s1, fee, tickSpacing, address(0));
        // On-chain existence + liquidity proof (unforgeable).
        (uint160 sp, uint128 liq, uint24 lpF, uint24 pF, ) =
            BPC.v4SqrtAndLiq($.v4PoolManager, pid);
        if (sp == 0 || liq == 0) revert HubE(9);
        // Dynamic fee must resolve to a quotable value (INV-20), else fail closed.
        if (BPC.effV4Fee(fee, lpF, pF) >= 1_000_000) revert HubE(9);
        // Learn the token-side pattern code from every successful on-chain
        // proof — idempotent re-claims included, so a stale hint self-heals.
        _writeV4Code(s0, s1, fee, tickSpacing);
        address poolAddr = address(uint160(uint256(pid)));
        key = keyOf(poolAddr, s0, s1);
        // Idempotent: a live re-claim must not push a duplicate V4Entry nor
        // re-register (which would thrash the fitness-ranked eviction).
        if ($.poolOf[key] != address(0)) return key;
        // A4: a permissionless claim must clear the SAME admission margin a
        // swap-driven registration does (recordSwap -> _canInsert). _register
        // evicts the weakest incumbent UNCONDITIONALLY, so on a FULL pair a dust
        // claim would displace a healthy pool with no 25% margin. depth = the
        // pool's MEASURED liquidity (liq), the exact signal _recordHits feeds
        // recordSwap for a V4 leg. HONEST SCOPE (devil's-advocate): liq is read
        // live, so it is JIT / flash-liquidity-inflatable within one tx (the same
        // bound recordSwap already carries) — this RAISES the griefing bar, it is
        // NOT "unforgeable". Vitality floors at 1 and decays to 0 in ~9 days, so an
        // emptied squatter self-weights down (INV-16) and the pool it evicted
        // re-registers on its next routed swap.
        // UNIDADES: L é escala-raiz; profundidade aqui tem de ser token-denominada,
        // como min(r0,r1) do V2 — senão um pool num tier de preço extremo entra com
        // profundidade inflada por ~sqrt(preço), passa a margem de 25% do _canInsert
        // e despeja um pool legítimo mais fundo. Mesma conversão de universalQuote
        // (Core): reservas virtuais ao preço atual, lado curto. sp != 0 garantido acima.
        uint256 depthTok;
        {
            // Normalizado: o _canInsert compara buckets, e um bucket cego a
            // decimais faz a pool funda e a de po projectarem o mesmo psi.
            depthTok = BPC.depthFromL18(liq, sp, BPC.decimalsOf(s0), BPC.decimalsOf(s1));
        }
        if (!_canInsert($.pairKeys[s0][s1], depthTok)) return key;
        $.v4Entries.push(V4Entry({
            currency0: s0, currency1: s1, fee: fee,
            tickSpacing: tickSpacing, hooks: address(0)
        }));
        $.v4EntryOf[key] = $.v4Entries.length; // V1/I11: O(1) key -> V4Entry
        _register(key, poolAddr, BPC.KIND_V4, fee, address(0), s0, s1, false);
        // A4: persist the MEASURED depth bucket (mirrors recordSwap's new-pool
        // path) so a claimed pool is fitness-ranked on its real liquidity instead
        // of defaulting to bucket 0 (psi ~1) — otherwise the pool that just won
        // admission on its depth becomes the pair's weakest slot / next eviction
        // target the instant it is registered.
        $.slot[key] = _stampTs(BPC.tickSlot($.slot[key], uint32(block.number), depthTok, uint32(block.timestamp)));
        emit V4Add($.v4Entries.length - 1, s0, s1, fee);
    }

    // ─── Discovery ──────────────────────────────────────────────────────

    /// @notice Permissionless discovery for (t0, t1).  Iterates the factory
    ///         list, derives candidates, returns the live ones.
    function discoverFor(address tA, address tB) public view returns (PoolInfo[] memory hits) {
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        HubStore storage $ = _store();
        uint256 maxOut;
        for (uint256 i; i < $.factories.length; ) {
            Factory storage fac = $.factories[i];
            uint256 fc = fac.fees.length == 0 ? 1 : fac.fees.length;
            uint256 sc = fac.spacings.length == 0 ? 1 : fac.spacings.length;
            uint256 mul = (fac.mode == 2 || fac.mode == 6) ? 2 : 1;
            // O ramo do mode 8 saiu com a excisao; uma factory com esse mode so pode
            // existir num Hub legado e `_scanFactory` para nela sem produzir hits, logo nao
            // contribui para o teto. A contabilidade tem de espelhar o loop de scan: `_probe`
            // escreve em `hits[k]` sem bounds-check proprio.
            if (fac.mode == MODE_V4_DERIVE) { maxOut += V4_CAP; }
            else { maxOut += fc * sc * mul; }
            unchecked { ++i; }
        }
        hits = new PoolInfo[](maxOut);
        uint256 k;
        for (uint256 i; i < $.factories.length; ) {
            Factory storage fac = $.factories[i];
            k = _scanFactory(fac, t0, t1, hits, k);
            unchecked { ++i; }
        }
        assembly { mstore(hits, k) }
    }

    function _scanFactory(
        Factory storage fac, address t0, address t1, PoolInfo[] memory hits, uint256 k
    ) private view returns (uint256) {
        // GUARDA GENERALIZADA. Era um teste de IDENTIDADE contra a constante do mode 8, contra
        // uma lapide. Agora e o teste de PERTENCA contra a MESMA mascara que o
        // `addFactory` usa para admitir. Aqui o morfismo aplica-se de facto — os dois sitios
        // fazem literalmente a mesma pergunta ("este mode e admissivel?") — e passa a cobrir
        // qualquer mode que venha a ser retirado no futuro, sem ninguem ter de voltar aqui.
        //
        // PORQUE PARAR IMPORTA: uma factory de mode inadmissivel so pode existir num Hub legado
        // (o `addFactory` de hoje recusa-a). Se cair no `_probe` generico, o `deriveAddress`
        // calcula `sub = mode - 4` e cai no catch-all de salt do V3CL, derivando enderecos
        // fantasma a cada scan. Parar torna-a PROVAVELMENTE inerte em vez de
        // acidentalmente inerte.
        if (((MODES_VALID >> fac.mode) & 1) == 0) return k;
        if (fac.mode == MODE_V4_DERIVE)  return _scanV4(fac, t0, t1, hits, k);
        uint24[] storage fees = fac.fees;
        int24[]  storage sps  = fac.spacings;
        uint256 fc = fees.length == 0 ? 1 : fees.length;
        uint256 sc = sps.length == 0  ? 1 : sps.length;
        bool solidly = (fac.mode == 2 || fac.mode == 6);
        for (uint256 fi; fi < fc; ) {
            uint24 fee = fees.length == 0 ? 0 : fees[fi];
            for (uint256 si; si < sc; ) {
                int24 sp = sps.length == 0 ? int24(0) : sps[si];
                if (solidly) {
                    k = _probe(fac, t0, t1, fee, false, sp, hits, k);
                    k = _probe(fac, t0, t1, fee, true,  sp, hits, k);
                } else {
                    k = _probe(fac, t0, t1, fee, false, sp, hits, k);
                }
                unchecked { ++si; }
            }
            unchecked { ++fi; }
        }
        return k;
    }


    function _probe(
        Factory storage fac, address t0, address t1, uint24 fee,
        bool stable, int24 sp, PoolInfo[] memory hits, uint256 k
    ) private view returns (uint256) {
        // CREATE2 modes (≥4) require an init-code hash. Factory-call modes
        // (<4) work without one — the staticcall does the lookup.
        if (fac.mode >= 4 && fac.initHash == bytes32(0)) return k;
        address p = BPC.deriveAddress(fac.factory, t0, t1, fee, stable, sp, fac.mode, fac.initHash);
        if (p != address(0) && BPC.hasCode(p)) {
            // Dedup: the same pool address can be derived for several
            // (fee, spacing) combinations. Listing it multiple times saturates
            // the Solver's top-K with one venue and starves deeper pools.
            for (uint256 d; d < k; ) {
                if (hits[d].pool == p) return k;
                unchecked { ++d; }
            }
            hits[k] = PoolInfo({
                active: true, stable: stable, kind: fac.kind, fee: fee,
                tickSpacing: sp, token0: t0, token1: t1, pool: p, hooks: address(0)
            });
            unchecked { k++; }
        }
        return k;
    }

    // ─── V4 derive-scan (MODE_V4_DERIVE) ───────────────────────────────
    //
    //  Uniswap V4 has no factory enumeration, so candidates are DERIVED —
    //  hookless poolIds recomputed from (t0, t1, fee, tickSpacing, hooks=0) —
    //  and only the ones PROVEN live on the PoolManager (sqrtP != 0 &&
    //  liquidity != 0, unforgeable extsload reads) are emitted. Probe order
    //  is cheapest-first:
    //    (a) learned per-token pattern codes — the steady-state ONE-probe path
    //    (c) canonical Uniswap tiers, one batched extsload
    //    (d) the row's paired explicit extras, one batched extsload
    //    (e) generator Pi_K cold-start grid, one batched extsload, entered
    //        ONLY when (a)-(d) found nothing: the grid bootstraps unknown
    //        tokens, and once any pool is proven the residual exotic tiers
    //        are left to claimV4/learning instead of being paid on every scan
    //  Early-stop at V4_CAP emitted pools.
    //
    //  ETH NATIVO: o par (ETH, X) tem DUAS chaves de pool no V4 — nativa
    //  (currency0 = address(0)) e wrapped (currency0 = WETH). Sao pools
    //  DISTINTAS, com poolId e liquidez distintos, e a nativa e sistematicamente
    //  a funda: MEDIDO 292x na Robinhood (USDG/ETH 100/1) e 3,76x na Base
    //  (USDC/ETH 500/10). Derivar so a wrapped nunca da erro — da uma cotacao
    //  pior, em silencio. Emitem-se AS DUAS e o funil escolhe por profundidade.
    //  A hooked pool cannot be emitted: its HOOKLESS poolId does not exist in
    //  the PoolManager, so it fails the live proof by construction.
    //
    //  `kf` packs the two scan counters into one word — low 128 bits: the
    //  global hits write-cursor `k`; high 128 bits: pools found by THIS scan.

    function _scanV4(
        Factory storage fac, address t0, address t1, PoolInfo[] memory hits, uint256 k
    ) private view returns (uint256) {
        if (t0 == address(0)) return k;      // native currency: out of scope
        HubStore storage $ = _store();
        address mgr = $.v4PoolManager;
        if (mgr == address(0)) return k;     // unconfigured manager: fail closed
        uint256 kf = k;
        // (0) ETH NATIVO PRIMEIRO. Sondado antes da wrapped por causa do
        //     `V4_CAP` (8): um par com muitas pools wrapped esgotaria as
        //     ranhuras antes de a nativa ser sequer construida. A ordem e a
        //     politica.
        //
        //     NAO ha parametro novo nas funcoes de sondagem, e a razao e
        //     MEDIDA: a primeira versao disto passava um `address w` por
        //     `_probeV4Batch` e `_admitV4`, e custou 1.227 bytes — o optimizador
        //     deixa de inlinar e replica corpos inteiros. Aqui passa-se o par
        //     nativo DIRECTAMENTE como (address(0), other): o zero ja ordena
        //     primeiro, portanto o `computeV4PoolId` recebe-o na posicao certa
        //     sem um unico ternario. So a forma do PoolInfo emitido precisa de
        //     correccao, e essa cabe num ciclo aqui.
        address rt = $.router;
        address w = rt == address(0) ? address(0) : IRouterWeth(rt).weth();
        if (w != address(0) && (t0 == w || t1 == w)) {
            address other = t0 == w ? t1 : t0;
            uint256 ini = uint256(uint128(kf));
            // Canonicos E extras, tal como a passada wrapped. Cortar os extras
            // aqui poupava 33 bytes de Hub (medido, nao estimado) e abria um
            // buraco de cobertura em escaloes exoticos — o dono escolheu a
            // cobertura. A grelha de cold-start fica de fora: ela so entra
            // quando NADA foi encontrado, e a passada nativa corre primeiro.
            kf = _probeV4Batch(mgr, address(0), other, _v4CanonicalTiers(), hits, kf);
            kf = _probeV4Batch(mgr, address(0), other, _v4ExtraTiers(fac), hits, kf);
            // O `_admitV4` emitiu-as como KIND_V4 com token0 = address(0).
            // Reescreve para a forma WETH-canonica: o CONTRATO DE ORIENTACAO
            // exige token0 = lado wrapped-native, porque o Solver deriva
            // `zeroForOne = (token0 == tokenIn)` e mapeia a currency nativa por
            // ORIENTACAO. Sem isto a pool ficaria invisivel para metade do
            // espaco de tokens — o mesmo defeito do bit 6 do Monoslot.
            for (uint256 z = ini; z < uint256(uint128(kf)); ) {
                // `token1` NAO se reescreve: o `_admitV4` ja o gravou como
                // `other` (foi o t1 que lhe passamos). So `kind` e `token0`
                // e que mentem.
                hits[z].kind   = BPC.KIND_V4_NATIVE;
                hits[z].token0 = w;
                unchecked { ++z; }
            }
        }
        // (a) learned pattern codes of both tokens (identical codes dedup)
        uint256 cA = $.v4CodeOf[t0];
        uint256 cB = $.v4CodeOf[t1];
        if (cA != 0) kf = _admitV4(mgr, t0, t1, cA, hits, kf);
        if (cB != 0 && cB != cA) kf = _admitV4(mgr, t0, t1, cB, hits, kf);
        // (c) canonical tiers, then (d) paired extras — one batch each
        kf = _probeV4Batch(mgr, t0, t1, _v4CanonicalTiers(), hits, kf);
        kf = _probeV4Batch(mgr, t0, t1, _v4ExtraTiers(fac), hits, kf);
        // (e) generator cold-start — only when nothing was found above
        if (kf >> 128 == 0) kf = _probeV4Batch(mgr, t0, t1, _v4GridTiers(), hits, kf);
        return uint256(uint128(kf));
    }

    /// @dev Probe a packed tier list against (t0, t1) with ONE batched
    ///      extsload for all slot0 words, then fully verify only the non-zero
    ///      survivors — a miss costs one batched SLOAD, not a full read pair.
    function _probeV4Batch(
        address mgr, address t0, address t1, uint256[] memory tiers,
        PoolInfo[] memory hits, uint256 kf
    ) private view returns (uint256) {
        uint256 n = tiers.length;
        if (n == 0 || kf >> 128 >= V4_CAP) return kf;
        bytes32[] memory pids = new bytes32[](n);
        for (uint256 i; i < n; ) {
            pids[i] = BPC.computeV4PoolId(
                t0, t1, uint24(tiers[i] >> 24), int24(uint24(tiers[i])), address(0)
            );
            unchecked { ++i; }
        }
        bytes32[] memory w0 = BPC.v4Slot0Batch(mgr, pids);
        for (uint256 i; i < n; ) {
            if (kf >> 128 >= V4_CAP) break;
            // sqrtPriceX96 occupies slot0's low 160 bits; zero = uninitialized.
            if (uint160(uint256(w0[i])) != 0) {
                kf = _admitV4(mgr, t0, t1, tiers[i], hits, kf);
            }
            unchecked { ++i; }
        }
        return kf;
    }

    /// @dev Fully verify ONE hookless candidate tier and emit it if live:
    ///      re-reads slot0 + liquidity through the audited single-read path
    ///      (belt-and-braces over the batch filter; the re-read is warm),
    ///      applies the INV-20 dynamic-fee gate, and dedups by pool address
    ///      (existing doctrine — one venue must not saturate the top-K).
    ///      `code` is the packed tier (fee << 24 | uint24(tickSpacing)).
    function _admitV4(
        address mgr, address t0, address t1, uint256 code,
        PoolInfo[] memory hits, uint256 kf
    ) private view returns (uint256) {
        uint256 k = uint256(uint128(kf));
        if (kf >> 128 >= V4_CAP || k >= hits.length) return kf;
        uint24 fee = uint24(code >> 24);
        int24  ts  = int24(uint24(code));
        bytes32 pid = BPC.computeV4PoolId(t0, t1, fee, ts, address(0));
        (uint160 sp, uint128 liq, uint24 lpF, uint24 pF, ) = BPC.v4SqrtAndLiq(mgr, pid);
        if (sp == 0 || liq == 0) return kf;                      // not live: fail closed
        if (BPC.effV4Fee(fee, lpF, pF) >= 1_000_000) return kf;  // unresolvable dynamic fee
        address p = address(uint160(uint256(pid)));
        for (uint256 d; d < k; ) {
            if (hits[d].pool == p) return kf;
            unchecked { ++d; }
        }
        hits[k] = PoolInfo({
            active: true, stable: false, kind: BPC.KIND_V4, fee: fee,
            tickSpacing: ts, token0: t0, token1: t1, pool: p, hooks: address(0)
        });
        unchecked { return kf + 1 + (uint256(1) << 128); }
    }

    /// @dev Canonical Uniswap fee tiers — the most common hookless configs.
    function _v4CanonicalTiers() private pure returns (uint256[] memory t) {
        t = new uint256[](4);
        t[0] = _v4Code(500, 10);
        t[1] = _v4Code(3000, 60);
        t[2] = _v4Code(10_000, 200);
        t[3] = _v4Code(100, 1);
    }

    /// @dev The row's paired explicit extras: fees[i] with spacings[i], never
    ///      a cross-product. addFactory enforces equal length; min() is a
    ///      defensive belt for rows registered before that rule existed.
    function _v4ExtraTiers(Factory storage fac) private view returns (uint256[] memory t) {
        uint256 fn = fac.fees.length;
        uint256 sn = fac.spacings.length;
        uint256 n = fn < sn ? fn : sn;
        t = new uint256[](n);
        for (uint256 i; i < n; ) {
            t[i] = _v4Code(fac.fees[i], fac.spacings[i]);
            unchecked { ++i; }
        }
    }

    /// @dev Generator Pi_K cold-start grid: fee = 10_000*j, ts = 100*j, j
    ///      descending from V4_GRID_MAX, capped at V4_GRID_PROBES candidates
    ///      (j never underflows: V4_GRID_PROBES <= V4_GRID_MAX).
    function _v4GridTiers() private pure returns (uint256[] memory t) {
        t = new uint256[](V4_GRID_PROBES);
        uint256 j = V4_GRID_MAX;
        for (uint256 i; i < V4_GRID_PROBES; ) {
            t[i] = _v4Code(uint24(10_000 * j), int24(uint24(100 * j)));
            unchecked { ++i; --j; }
        }
    }

    /// @dev Pack a tier into a pattern code. A valid V4 tickSpacing is >= 1,
    ///      so a real code is never 0 (0 = "no code learned").
    function _v4Code(uint24 fee, int24 ts) private pure returns (uint256) {
        return (uint256(fee) << 24) | uint256(uint24(ts));
    }

    /// @dev True iff the hookless poolId of (t0, t1, fee, ts) truncates to
    ///      `pool` — the unforgeable link between a registry pool address and
    ///      a claimed tier.
    function _v4IdMatches(address pool, address t0, address t1, uint24 fee, int24 ts)
        private pure returns (bool)
    {
        return address(uint160(uint256(
            BPC.computeV4PoolId(t0, t1, fee, ts, address(0))
        ))) == pool;
    }

    // ─── V4 pattern-code learning (discovery-hint metadata ONLY) ───────
    //
    //  INV-16 BOUNDARY: everything below writes/reads $.v4CodeOf and nothing
    //  else. The code never feeds psi/fitness/eviction/route-ranking —
    //  routing weight comes exclusively from measured marginal output. A
    //  wrong code (staleness, manipulation) costs at most one wasted probe in
    //  _scanV4, because every candidate is re-proven live before emission and
    //  proven again at quote time. No revert paths: learning must never break
    //  a swap or a claim.

    /// @dev Write the pattern code on the pair's NON-BRIDGE side(s). Bridges
    ///      pair with many tokens at many tiers — a per-bridge code would
    ///      thrash — so the code is the launch-tier fingerprint of the minted
    ///      token only. Last proof wins: self-correcting toward the tier that
    ///      actually trades. Skips the SSTORE when the code is unchanged.
    function _writeV4Code(address t0, address t1, uint24 fee, int24 ts) private {
        HubStore storage $ = _store();
        uint256 c = _v4Code(fee, ts);
        if (!$.isBridge[t0] && $.v4CodeOf[t0] != c) $.v4CodeOf[t0] = c;
        if (!$.isBridge[t1] && $.v4CodeOf[t1] != c) $.v4CodeOf[t1] = c;
    }

    /// @dev recordSwap-side healer for an already-registered V4 pool: recover
    ///      the swapped pool's tickSpacing (steady state: one SLOAD + one
    ///      keccak — the learned code already describes the pool) and refresh
    ///      the non-bridge side(s). Fail-open: unrecoverable means no update.
    function _noteV4Code(address pool, address t0, address t1, uint24 fee) private {
        (int24 ts, bool ok) = _recoverV4Ts(pool, t0, t1, fee);
        if (ok) _writeV4Code(t0, t1, fee, ts);
    }

    /// @dev Recover the tickSpacing of a routed hookless V4 pool from
    ///      (pool, t0, t1, fee) — recordSwap does not carry tickSpacing and
    ///      the Router stays unchanged, so the missing coordinate is
    ///      reconstructed and VERIFIED against the truncated poolId before
    ///      being trusted. The sources mirror exactly what the derive-scan
    ///      can emit, so the loop is closed:
    ///        1. learned per-token codes (one SLOAD + one keccak steady state)
    ///        2. generator inverse (fee = 10_000*j  =>  ts = 100*j)
    ///        3. canonical tiers
    ///        4. MODE_V4_DERIVE rows' paired extras
    ///        5. the registered V4Entry — the backstop that always resolves a
    ///           pool admitted via claimV4/addV4
    ///      A hooked pool never matches (hookless derivation) => (0, false).
    function _recoverV4Ts(address pool, address t0, address t1, uint24 fee)
        private view returns (int24 ts, bool ok)
    {
        HubStore storage $ = _store();
        // 1) learned codes
        uint256 c = $.v4CodeOf[t0];
        if (c != 0 && uint24(c >> 24) == fee) {
            ts = int24(uint24(c));
            if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
        }
        c = $.v4CodeOf[t1];
        if (c != 0 && uint24(c >> 24) == fee) {
            ts = int24(uint24(c));
            if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
        }
        // 2) generator inverse
        if (fee != 0 && fee % 10_000 == 0 && fee / 10_000 <= V4_GRID_MAX) {
            ts = int24(uint24((fee / 10_000) * 100));
            if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
        }
        // 3) canonical tiers
        uint256[] memory tiers = _v4CanonicalTiers();
        for (uint256 i; i < tiers.length; ) {
            if (uint24(tiers[i] >> 24) == fee) {
                ts = int24(uint24(tiers[i]));
                if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
            }
            unchecked { ++i; }
        }
        // 4) V4_DERIVE rows' paired extras
        uint256 fn = $.factories.length;
        for (uint256 fi; fi < fn; ) {
            Factory storage fac = $.factories[fi];
            if (fac.mode == MODE_V4_DERIVE) {
                uint256 en = fac.fees.length < fac.spacings.length
                    ? fac.fees.length
                    : fac.spacings.length;
                for (uint256 i; i < en; ) {
                    if (fac.fees[i] == fee) {
                        ts = fac.spacings[i];
                        if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
                    }
                    unchecked { ++i; }
                }
            }
            unchecked { ++fi; }
        }
        // 5) the registered V4Entry backstop
        uint256 vn = $.v4Entries.length;
        for (uint256 vi; vi < vn; ) {
            V4Entry storage e = $.v4Entries[vi];
            if (
                e.currency0 == t0 && e.currency1 == t1 && e.fee == fee
                    && e.hooks == address(0)
            ) {
                ts = e.tickSpacing;
                if (_v4IdMatches(pool, t0, t1, fee, ts)) return (ts, true);
            }
            unchecked { ++vi; }
        }
        return (0, false);
    }

    // ─── Registry reads ────────────────────────────────────────────────

    function getActivePools(address tA, address tB) external view returns (PoolInfo[] memory out) {
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        bytes32[] storage ks = _store().pairKeys[t0][t1];
        uint256 n = ks.length;
        out = new PoolInfo[](n);
        uint256 w;
        for (uint256 i; i < n; ) {
            bytes32 key = ks[i];
            uint256 s = _store().slot[key];
            if (BPC.isActive(s)) {
                PoolInfo memory pi = _readPoolInfo(key, t0, t1, s);
                // A V4 pool whose hook is paused (code changed since admission,
                // or de-listed) stays in the registry (read-only) but is not a
                // routable candidate — resumes automatically once re-admitted.
                if ((pi.kind != BPC.KIND_V4 && pi.kind != BPC.KIND_V4_NATIVE)
                    || pi.hooks == address(0) || isHookLive(pi.hooks)) {
                    out[w] = pi;
                    unchecked { ++w; }
                }
            }
            unchecked { ++i; }
        }
        assembly { mstore(out, w) }
    }

    function _readPoolInfo(bytes32 key, address t0, address t1, uint256 s)
        private view returns (PoolInfo memory p)
    {
        HubStore storage $ = _store();
        p.active      = true;
        p.kind        = BPC.decodeKind(s);
        p.fee         = BPC.decodeFee(s);
        // Restaura o contrato de orientacao para pools V4-NATIVAS: token0 tem
        // de ser o lado wrapped-native, que e o que o Solver e o Quoter
        // pressupoem ao derivar a chave por `zeroForOne`. O indice continua
        // ordenado por endereco (as buscas dependem disso); so a ORIENTACAO
        // REPORTADA e corrigida, e o bit ja veio no slot que esta funcao recebe.
        bool _swap = p.kind == BPC.KIND_V4_NATIVE && _nativeSwapped(s);
        p.token0      = _swap ? t1 : t0;
        p.token1      = _swap ? t0 : t1;
        p.pool        = $.poolOf[key];
        p.hooks       = $.hooksOf[key];
        p.stable      = false;
        // tickSpacing is not packed in the pool slot. V3-style kinds derive
        // pools from the fee (0 is fine), but V4 needs the real tickSpacing —
        // it is part of the poolId the quote recomputes — so recover it from
        // the matching V4Entry.
        p.tickSpacing = 0;
        if (BPC.kindHas(p.kind, BPC.A_CONC_SING)) {
            // V1 / invariant I11: O(1) entry recovery by key (index+1), replacing
            // the linear scan below on the hot per-solve path. Every registered V4
            // pool has an entry recorded under its key at registration (v4EntryOf),
            // so this hits; on a miss it falls through to the scan (fail-closed,
            // unreachable for pools registered after this fix).
            uint256 ep = $.v4EntryOf[key];
            if (ep != 0) {
                V4Entry storage e0 = $.v4Entries[ep - 1];
                p.tickSpacing = e0.tickSpacing;
                if (p.kind == BPC.KIND_V4_NATIVE) {
                    // Native entry: currency0 == address(0), currency1 == the ERC20
                    // counterpart. Orient WETH-canonical (token0 = wrapped-native
                    // side, token1 = counterpart) exactly as the scan did.
                    p.token0 = e0.currency1 == t0 ? t1 : t0;
                    p.token1 = e0.currency1;
                }
                return p;
            }
            uint256 vn = $.v4Entries.length;
            for (uint256 vi; vi < vn; ) {
                V4Entry storage e = $.v4Entries[vi];
                if (p.kind == BPC.KIND_V4) {
                    if (e.currency0 == t0 && e.currency1 == t1 && e.fee == p.fee && e.hooks == p.hooks) {
                        p.tickSpacing = e.tickSpacing;
                        break;
                    }
                } else if (e.currency0 == address(0) && e.fee == p.fee && e.hooks == p.hooks
                    && (e.currency1 == t0 || e.currency1 == t1)) {
                    // Native entry (currency0 = address(0), currency1 = the
                    // ERC20 counterpart). Verify by the unforgeable truncated-
                    // poolId match — a same-fee native entry of another pair
                    // can then never mis-resolve this one — and ORIENT the
                    // WETH-canonical pair: token0 = the wrapped-native side,
                    // token1 = the counterpart. This orientation is the
                    // contract the Solver's zeroForOne / auxId / quote-ctx
                    // construction relies on (token0 == tIn ⇔ input is the
                    // pool's currency0).
                    if (address(uint160(uint256(BPC.computeV4PoolId(
                            address(0), e.currency1, p.fee, e.tickSpacing, p.hooks
                        )))) == p.pool) {
                        p.tickSpacing = e.tickSpacing;
                        p.token0 = e.currency1 == t0 ? t1 : t0;
                        p.token1 = e.currency1;
                        break;
                    }
                }
                unchecked { ++vi; }
            }
        }
    }

    function getPsi(bytes32 key) external view returns (uint256) { return _psi(key); }

    /// @dev NAO ERAM DUAS CADEIAS IGUAIS — ERAM DOIS CORPOS IGUAIS. Esta funcao e o
    ///      `_psiOfSlot` diferiam apenas em como obtinham o slot; tudo o resto era copia literal,
    ///      incluindo a cadeia de quatro kinds. Colapsar a cadeia e deixar as duas funcoes
    ///      curava o sintoma e mantinha o irmao. Agora ha UM corpo.
    function _psi(bytes32 key) private view returns (uint256) {
        return _psiOfSlot(_store().slot[key]);
    }

    /// @notice Batch fitness read: one external call for a whole candidate set
    ///         (each pool with its pair tokens), replacing two calls per
    ///         candidate (keyOf + getPsi) in the Solver's top-K selection.
    ///         Pure view addition — buys eth_call gas headroom and RPC latency
    ///         on the (free) planning path, zero new state surface.
    function psisOf(address[] calldata pools, address[] calldata tAs, address[] calldata tBs)
        external view returns (uint256[] memory ps)
    {
        uint256 n = pools.length;
        if (tAs.length != n || tBs.length != n) revert HubE(4);
        ps = new uint256[](n);
        for (uint256 i; i < n; ) {
            ps[i] = _psi(keyOf(pools[i], tAs[i], tBs[i]));
            unchecked { ++i; }
        }
    }

    /// @notice True when either side of the pair is a registered bridge token.
    ///         Packed at slot bit 7 (within the [7:1] reserved span) at the
    ///         moment of registration, so reading it is part of the same SLOAD
    ///         that fetches the rest of the pool state.
    function _isBridged(uint256 slot) private pure returns (bool) {
        return (slot >> 7) & 1 == 1;
    }

    /// @dev BIT 6 do Monoslot (dentro do span reservado [7:1]): "o lado
    ///      wrapped-native e o token1, nao o token0".
    ///
    ///      PORQUE EXISTE. O Solver e o Quoter derivam qual lado de uma pool
    ///      V4-NATIVA e o `address(0)` a partir de `zeroForOne`, e os seus
    ///      comentarios invocam um "contrato de orientacao: token0 e o lado
    ///      wrapped-native". Esse contrato NAO EXISTIA: o `_register` indexa
    ///      por `sortTokens`, ou seja por ENDERECO. Quando o outro token
    ///      ordena abaixo do WETH, `token0` deixa de ser o WETH, `zeroForOne`
    ///      inverte-se, e as duas derivacoes (Router por `nativeMapVerified`,
    ///      Quoter por orientacao) produzem poolIds DIFERENTES — a pool nativa
    ///      fica invisivel para metade do espaco de tokens. Fail-closed, mas
    ///      silenciosamente inalcancavel. Ver test/V4NativeOrientation.t.sol.
    ///
    ///      O caso que passava (USDC na Base, 0x8335... > WETH 0x4200...) era
    ///      o unico testado — por isso a prosa parecia verdadeira.
    ///
    ///      A flag torna o contrato REAL sem custo de leitura: o slot ja esta
    ///      carregado no `_readPoolInfo`, ler um bit e gratis.
    function _markNativeSwapped(uint256 slot, bool b) private pure returns (uint256) {
        return b ? (slot | (uint256(1) << 6)) : (slot & ~(uint256(1) << 6));
    }
    function _nativeSwapped(uint256 slot) private pure returns (bool) {
        return ((slot >> 6) & 1) == 1;
    }

    function _markBridged(uint256 slot, bool b) private pure returns (uint256) {
        return b ? (slot | (uint256(1) << 7)) : (slot & ~(uint256(1) << 7));
    }

    function getSlot(bytes32 key) external view returns (uint256) { return _store().slot[key]; }
    function getPool(bytes32 key) external view returns (address) { return _store().poolOf[key]; }
    function v4PoolManager() external view returns (address) { return _store().v4PoolManager; }
    function v4EntryCount() external view returns (uint256) { return _store().v4Entries.length; }
    /// @notice Learned V4 pattern code of a token: packed
    ///         (fee << 24 | uint24(tickSpacing)), 0 = none. Hint metadata
    ///         only — never a routing weight (INV-16).
    function v4CodeOf(address token) external view returns (uint256) { return _store().v4CodeOf[token]; }

    function keyOf(address pool, address tA, address tB) public pure returns (bytes32) {
        (address s0, address s1) = BPC.sortTokens(tA, tB);
        return keccak256(abi.encodePacked(pool, s0, s1));
    }

    // ─── Promotion via swap (Router-only) ──────────────────────────────

    /// @notice Called by the Router on every successful leg. If the pool is
    ///         already registered, we tick its slot. If not, and the pair has
    ///         room or the newcomer beats the weakest occupant by
    ///         EVICTION_IMPROVE_BPS, we register it.
    function recordSwap(
        address pool, uint8 kind, uint24 fee, address hooks,
        address tA, address tB, uint256 amtIn, uint256 amtOut, uint256 depthWad
    ) external onlyRouter whenLive {
        if (pool == address(0) || amtIn == 0) return;
        // CANAL IRMAO. O `addFactory` fecha os kinds que nao aceita; esta e a SEGUNDA porta de
        // registo do Hub e nao tinha fecho nenhum — a assinatura de defeito da casa ("um fix
        // aplicado a UM de dois canais simetricos") dentro da propria excisao.
        //
        // MAS CADA PORTA FECHA COM A SUA MASCARA. A primeira versao deste fecho reutilizou o
        // `KINDS_ROUTABLE` da factory, e isso trocou a pergunta: aqui nao se pergunta "que kinds
        // se registam por factory?" mas "que kinds pode o Router ter acabado de executar?". O
        // V4_NATIVE responde nao a primeira e SIM a segunda, e ficava de fora — ver
        // KINDS_EXECUTABLE.
        //
        // NAO e redundante com o `else { revert RouterE(8); }` do dispatch do Router: `$.router`
        // e trocavel (setRoles), logo o unico produtor destes kinds NAO e imutavel. Um Router
        // futuro que ganhe um braco novo sem que o Hub saiba escreveria no registo um kind que o
        // resto do sistema nao sabe ler. Esta e a defesa LOCAL, a que nao depende de outro
        // endereco continuar a ser o que era no dia do deploy.
        //
        // Salta o registo, NAO reverte: o swap do utilizador ja executou e nao pode falhar por
        // uma decisao de registo — a mesma disciplina do caso !okTs do V4 mais abaixo.
        if (((KINDS_EXECUTABLE >> kind) & 1) == 0) return;
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        bytes32 key = keyOf(pool, t0, t1);
        HubStore storage $ = _store();
        uint256 s = $.slot[key];
        if (s != 0) {
            // existing pool — tick + stamp wall-clock activity time
            uint256 newSlot = BPC.tickSlot(s, uint32(block.number), depthWad, uint32(block.timestamp));
            $.slot[key] = _stampTs(newSlot);
            // Hookless V4 leg: refresh the tokens' learned pattern code
            // (discovery-hint metadata only — never fitness; see INV-16
            // boundary at the learning section). Hooked pools are excluded:
            // the code describes a hookless derivation.
            if (kind == BPC.KIND_V4 && hooks == address(0)) _noteV4Code(pool, t0, t1, fee);
            emit Volume(key, amtIn, amtOut);
            return;
        }
        // unknown — attempt insert
        if (!_canInsert($.pairKeys[t0][t1], depthWad)) return;
        // Pair-shaped kinds: PROVE the pool really trades (t0, t1) before it
        // enters the registry. Every argument here is caller-controlled
        // calldata carried in the Router's Route — pool, kind AND depth — so
        // without this an attacker registers a contract they wrote under a
        // pair they picked, at a depth they picked, holding neither token.
        // This mirrors the authenticity proof the V4 branch below already has
        // (poolId recomputation); no other kind had one.
        // The mask is the Router's own "the pool field is a pair" taxonomy
        // (_legTokens) — see KINDS_PAIR_PROOF. Outside it: V4(4) and
        // V4_NATIVE(8), whose `pool` is a truncated poolId with no bytecode at
        // all, and which prove themselves in the branch below. kind > 8 shifts
        // the mask to 0 — a future kind stays unverified (today's behaviour)
        // instead of becoming silently unregistrable.
        // Cost: at most two staticcalls (short-circuited to one on the first
        // mismatch), on the COLD first-registration path ONLY — the hot path
        // returned at the tick above and pays nothing.
        // Mismatch => skip registration, NEVER revert: the user's swap has
        // already executed and must not fail over a registry decision — the
        // same fail-without-registering the V4 !okTs case takes.
        if (((KINDS_PAIR_PROOF >> kind) & 1) != 0
            && (BPC.token0Of(pool) != t0 || BPC.token1Of(pool) != t1)) return;
        if (kind == BPC.KIND_V4) {
            // A V4 pool reaching FIRST registration here was found by the
            // derive-scan (a view — it could not persist anything). The
            // registry's V4 reads REQUIRE a matching V4Entry (tickSpacing
            // recovery for quote-time poolId recomputation), and recordSwap
            // does not carry tickSpacing — so recover it and verify against
            // the truncated poolId. The derivation is hookless-only, so a
            // hooked pool never matches. Unrecoverable => skip registration
            // entirely: an entry-less V4 registration would be dead weight
            // that marks the pair "known" and starves rediscovery. The swap
            // itself is unaffected either way (fail closed, fail open).
            (int24 v4Ts, bool okTs) = _recoverV4Ts(pool, t0, t1, fee);
            if (!okTs) return;
            $.v4Entries.push(V4Entry({
                currency0: t0, currency1: t1, fee: fee,
                tickSpacing: v4Ts, hooks: address(0)
            }));
            $.v4EntryOf[key] = $.v4Entries.length; // V1/I11: O(1) key -> V4Entry
            _writeV4Code(t0, t1, fee, v4Ts);
        }
        if (kind == BPC.KIND_V4_NATIVE) {
            // Native V4 pool routed under its WETH-canonical pair (tA/tB are
            // the Router's hop tokens — routes speak WETH). Authenticity: the
            // truncated NATIVE poolId, derived from (address(0), T), must
            // match `pool`. recordSwap does not carry which side is the
            // wrapped-native one, so try both orientations — the 160-bit
            // truncation match is unforgeable, and the orientation that
            // matches identifies the ERC20 counterpart T. Reuses the exact
            // _recoverV4Ts ladder with the native pair (its steps are
            // pair-parametric; passing address(0) as one side derives native
            // poolIds throughout, and the entries backstop matches native
            // entries by currency0 == address(0)). Hookless-only by
            // construction, like V4. Unrecoverable => skip registration,
            // never revert (same doctrine as the V4 branch above). The entry
            // stores the REAL pool currencies; _readPoolInfo re-orients the
            // pair to WETH-canonical form for the Solver from it.
            address ncp = t1;
            (int24 nTs, bool okN) = _recoverV4Ts(pool, address(0), t1, fee);
            if (!okN) { ncp = t0; (nTs, okN) = _recoverV4Ts(pool, address(0), t0, fee); }
            if (!okN) return;
            $.v4Entries.push(V4Entry({
                currency0: address(0), currency1: ncp, fee: fee,
                tickSpacing: nTs, hooks: address(0)
            }));
            $.v4EntryOf[key] = $.v4Entries.length; // V1/I11: O(1) key -> V4Entry
            // Learn the tier on the ERC20 side only (passed twice: the second
            // write self-skips as unchanged) — a v4CodeOf[address(0)] entry
            // would be dead storage no scan ever reads (_scanV4 rejects
            // native-side pairs), costing a 20k SSTORE on a user's swap.
            _writeV4Code(ncp, ncp, fee, nTs);
        }
        // ─── REG-02 + REG-01: OS DATA DO PROPONENTE SAO COORDENADAS, NAO FACTOS ───
        // Esta linha gravava no registo a `fee` e os `hooks` VINDOS DO CALLDATA do
        // Router, na mesma transaccao em que a profundidade era MEDIDA. O CI ja
        // tem a guarda "Depth producer guard (profundidade nunca vem de calldata)"
        // com a razao escrita — "se um produtor grava um numero que o chamador
        // escolheu, o chamador passa a decidir o ranking do registo". A `fee` e os
        // `hooks` eram o canal irmao dessa guarda, por fechar.
        //
        // O QUE ISTO PERMITIA (medido em test/RegistryFeeFromCalldata.t.sol):
        // vigiar a mempool, correr a frente do primeiro swap numa pool honesta
        // ainda nao registada com um swap de po declarando `leg.fee = 9000`, e a
        // pool ficava cotada com 90% de fee (effV2Fee esta em BPS) ate ao despejo.
        // O `tickSlot` preserva os bits da fee, e o `recordSwap` auto-guarda em
        // `slot != 0`: nem um swap honesto posterior corrigia.
        //
        // A FEE, por origem da verdade:
        //   V4 / V4-nativo -> a do calldata, porque esta AUTENTICADA e nao
        //     confiada: entra no `computeV4PoolId`, e o `_recoverV4Ts` acima ja
        //     devolveu sem registar se o pid derivado nao bateu com a pool.
        //   Algebra (`dyn`) -> 0, o sentinela que manda o leitor MEDIR ao vivo
        //     (`effV3Fee`). E a regra R2 (L511-512), que so existia na porta
        //     `addFactory` — esta porta nunca a teve.
        //   V3 estatica -> `getV3Fee(pool)`, medida.
        //   V2 / Solidly -> `fee()` nao existe, logo 0, e `effV2Fee(0) = 30`: o
        //     produtor unico da casa responde, em vez do chamador.
        // O `dyn` do `v3StateAndDynFee` discrimina pela FORMA (slot0 falha e
        // globalState responde), nao por uma lista de venues.
        //
        // PORQUE NAO DISCRIMINAR PELO `kind`, que ja esta aqui de graca: porque
        // o `kind` TAMBEM vem do calldata. Esta porta so verifica que ele esta
        // no KINDS_EXECUTABLE — nunca que a pool E daquele tipo. Um
        // `kind = KIND_ALGEBRA` declarado numa pool V3 real com `fee = 3000`
        // executa limpo, gravaria o sentinela 0, e a partir dai o
        // `effV3Fee(0, 0, dyn=false)` devolve 0xFFFFFF fail-closed: a pool ficava
        // permanentemente incotavel. Trocar um campo de calldata por outro campo
        // de calldata nao fecha nada — so a leitura da FORMA da pool nao confia
        // em ninguem. Custa ~190 B do Hub, medidos: e o preco de nao ter
        // reintroduzido o defeito ao fecha-lo.
        //
        // OS HOOKS: address(0) sempre, e e provavel e nao conservador. Todo o
        // caminho que chega aqui vindo do `recordSwap` ou provou que a pool NAO
        // tem hook (os ramos V4 derivam o poolId hookless e fazem `return` se
        // falharem — tao explicito que a `V4Entry` fixa `hooks: address(0)` a
        // mao) ou pertence a um kind sem hooks. Gravar o `hooks` do calldata
        // deixava envenenar `hooksOf[key]`: um endereco nao allow-listado
        // fazia a pool LEGITIMA cair do filtro de `getActivePools` (L1156,
        // `pi.hooks == address(0) || isHookLive(pi.hooks)`).
        uint24 feeReg = fee;
        if (kind != BPC.KIND_V4 && kind != BPC.KIND_V4_NATIVE) {
            (, , bool dynShape) = BPC.v3StateAndDynFee(pool);
            feeReg = dynShape ? 0 : BPC.getV3Fee(pool);
        }
        _register(key, pool, kind, feeReg, address(0), t0, t1, false);
        // initial tick + stamp wall-clock activity time
        $.slot[key] = _stampTs(BPC.tickSlot($.slot[key], uint32(block.number), depthWad, uint32(block.timestamp)));
        emit Volume(key, amtIn, amtOut);
    }

    /// @dev Refresh the slot's lastUpdateTs (bits [95:64]) to the current
    ///      wall-clock time. The field is otherwise write-once at registration and
    ///      is read by nothing on-chain except the Solver's discovery-freshness
    ///      gate — so repurposing it as "last activity time" is behaviour-neutral
    ///      for fitness/eviction. NAO e o `lastBlk` que alimenta esse juizo, apesar de esta
    ///      linha ja o ter afirmado: o `vitality` e o `_decayedSwapCount` do Core leem
    ///      `decodeLastUpdateTs`, e o `decodeLastBlk` nao tem UM UNICO chamador em src/ — os
    ///      seus unicos leitores sao tres assercoes de teste sobre a propria codificacao. O
    ///      `lastBlk` e escrito em cada tick e nunca lido; esta registado como tal no censo de
    ///      bits mortos do Monoslot, e a decisao de o podar ou de o reservar para a vitalidade
    ///      estatistica e do dono.
    function _stampTs(uint256 s) private view returns (uint256) {
        return (s & ~(uint256(0xFFFFFFFF) << 64)) | (uint256(uint32(block.timestamp)) << 64);
    }

    function _canInsert(bytes32[] storage ks, uint256 newDepth) private view returns (bool) {
        if (ks.length < MAX_SLOTS) return true;
        // ─── Insertion ranking ───
        // Rank incumbents by full fitness (vitality × depth-bucket weight × bonuses),
        // not raw vitality, and admit the newcomer only if its projected fitness
        // strictly beats the weakest incumbent by a margin. A deep newcomer can
        // now displace a shallow-but-warm incumbent (as the design intends),
        // and an attacker can no longer keep a deep pool out merely by sending
        // dust through 16 shallow slots to hold their vitality at 1.
        if (newDepth == 0) return false;
        HubStore storage $ = _store();
        uint256 worstPsi = type(uint256).max;
        for (uint256 i; i < ks.length; ) {
            uint256 p = _psiOfSlot($.slot[ks[i]]);
            if (p < worstPsi) worstPsi = p;
            unchecked { ++i; }
        }
        // Newcomer's projected fitness: vitality starts at 1, weighted by the depth
        // bucket it will occupy. No bridge/conc bonus assumed (conservative).
        uint256 newcomerPsi = BPC.bucketWeight(BPC.depthBucket(newDepth));
        // Require a strict 25% margin so admission is decisive, not a knife-edge.
        return newcomerPsi > worstPsi + (worstPsi / 4);
    }

    /// @notice Fitness of a slot using its packed bridge bit and kind-derived conc.
    /// @dev O UNICO produtor de psi neste contrato. A pergunta "esta pool e de liquidez
    ///      concentrada?" e um teste de PERTENCA a uma classe de FORMA de estado (na pool ou no
    ///      singleton, tanto faz para o peso) — colapsa na theta sem violar a regra dos
    ///      predicados de aceitacao, porque psi e um peso de LEITURA e nao decide admissao.
    function _psiOfSlot(uint256 s) private view returns (uint256) {
        if (s == 0) return 0;
        bool conc = BPC.kindHasAny(BPC.decodeKind(s), BPC.A_CONC_POOL | BPC.A_CONC_SING);
        return BPC.psi(s, uint32(block.timestamp), _isBridged(s), conc);
    }

    function _register(
        bytes32 key, address pool, uint8 kind, uint24 fee, address hooks,
        address t0, address t1, bool trusted
    ) private {
        HubStore storage $ = _store();
        bytes32[] storage ks = $.pairKeys[t0][t1];
        // KEY-EXISTENCE GUARD: re-registering a key already listed for this
        // pair (addV4/seedPool called twice with identical params) must refresh
        // the slot in place, never append a second copy. getActivePools does
        // not dedup, so a duplicate both double-lists the pool to the Solver
        // and inflates the O(n) scan every quote walks. poolOf is the O(1)
        // witness of presence — written only below, cleared only on eviction,
        // which is the same moment the key leaves ks. recordSwap and the
        // permissionless V4 path already self-guard (slot != 0 / poolOf != 0),
        // so this only closes the operator entry-points.
        if ($.poolOf[key] == address(0)) {
            if (ks.length >= MAX_SLOTS) {
                // Evict the lowest-scoring slot (rank by fitness, not vitality,
                // consistent with _canInsert so the pool we admit is the pool we
                // chose to make room for).
                uint256 worstIdx;
                uint256 worst = type(uint256).max;
                for (uint256 i; i < ks.length; ) {
                    uint256 v = _psiOfSlot($.slot[ks[i]]);
                    if (v < worst) { worst = v; worstIdx = i; }
                    unchecked { ++i; }
                }
                bytes32 evictKey = ks[worstIdx];
                address evictPool = $.poolOf[evictKey];
                $.slot[evictKey] = 0;
                $.poolOf[evictKey] = address(0);
                // hooksOf: clear only when set — non-V4 pools never wrote it, and
                // a 0→0 SSTORE still costs 2.2k cold for nothing.
                if ($.hooksOf[evictKey] != address(0)) $.hooksOf[evictKey] = address(0);
                ks[worstIdx] = key;
                emit Evicted(evictKey, evictPool);
            } else {
                ks.push(key);
            }
        }
        // ROTEAVEL, nao apenas ancora: a flag vale +25% de fitness no `psi`, e o fitness decide
        // despejos num registo capado. Pagar o bonus a uma pool que o router nao alcanca era
        // despejar liquidez util em favor de liquidez inalcancavel.
        bool bridged = _isRoutableBridge($, t0) || _isRoutableBridge($, t1);
        uint256 s = BPC.encodeSlot(
            true, fee, kind, trusted ? 0 : 2, 0,
            uint32(block.timestamp), 0, 0, 0,
            uint32(block.number), uint32(block.number)
        );
        $.slot[key]    = _markBridged(s, bridged);
        $.poolOf[key]  = pool;
        if (hooks != address(0)) $.hooksOf[key] = hooks;
        emit Registered(key, pool, kind);
    }

    /// @notice Operator entry-point for seeding the registry up-front.
    function seedPool(
        address pool, uint8 kind, uint24 fee, address hooks,
        address tA, address tB
    ) external onlyOperator returns (bytes32 key) {
        _ne0(pool); _ne0(tA); _ne0(tB);
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        key = keyOf(pool, t0, t1);
        _register(key, pool, kind, fee, hooks, t0, t1, true);
    }
}
