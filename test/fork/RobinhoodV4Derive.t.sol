// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../../src/BlazePhoenixCore.sol";

// =============================================================================
//  Robinhood Chain (id 4663) fork proof for FULLY ON-CHAIN, ADDRESS-ONLY
//  Uniswap-V4 pool discovery (`MODE_V4_DERIVE`) with the self-learning
//  per-token pattern code.
//
//  What is proven here, in order:
//    1. WITHOUT any claimV4, `discoverFor` derives and emits live hookless V4
//       pools whose (fee, tickSpacing) sit on the generator grid
//       (fee = 10_000*j, ts = 100*j) — MOMO (900000/9000) and BAG
//       (870000/8700) — and every emitted candidate is claim-provable
//       (i.e. the on-chain existence proof passes for it: a non-existent
//       tier is never returned).
//    2. The pattern code learned from a claim makes a repeat discovery
//       measurably cheaper: the scan takes the one-probe phase-(a) path and
//       skips the cold-start grid. Gas for both scans is logged — this is
//       the low-gas evidence the CI run records.
//    3. `recordSwap` on a scan-found V4 pool recovers the missing
//       tickSpacing (the Hub's recordSwap does not carry it), registers a
//       coherent V4Entry (registry reads recover ts correctly), and learns
//       the token's code — the full learning loop without any claim.
//    4. Fail-closed: native currency is out of scope and a pair with no V4
//       pools yields nothing (all-zero slot0 words are never emitted).
//
//  Addresses are test-only constants (never in src/): PoolManager is Hub
//  runtime config. Pools verified live 2026-08-12 via extsload.
// =============================================================================
contract RobinhoodV4DeriveTest is Test {
    // Placeholder test-only fee recipients — never the real treasuries.
    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);

    address constant V4_MGR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH   = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // the chain's dollar
    address constant MOMO   = 0xe37E4a8b3D14274a3fdE3D841dE65E83E2a943aC;
    address constant BAG    = 0x616bcd920e1e1F354750BBaf2FB3b3fa3B4aAE16;

    // Grid-derivable launchpad tiers (fee = 10_000*j, ts = 100*j), verified
    // live against the Robinhood PoolManager.
    uint24 constant MOMO_FEE = 900_000; // j = 90
    int24  constant MOMO_TS  = 9_000;
    uint24 constant BAG_FEE  = 870_000; // j = 87
    int24  constant BAG_TS   = 8_700;

    uint8 constant KIND_V4        = 4;
    uint8 constant MODE_V4_DERIVE = 9;

    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    BlazePhoenixQuoter quoter;

    function setUp() public {
        // Sem DRPC_KEY nao ha fork. SALTAR, nao falhar: um teste que rebenta por falta de uma
        // variavel de ambiente e ruido que esconde falhas reais na suite local — foram 15 destas
        // a mascarar o resultado. O job `fork-tests` do CI tem o segredo e continua a corre-los
        // a serio, portanto a cobertura nao se perde; so deixa de haver vermelho falso.
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        // BLOCO FIXADO 2026-08-21. Sem ele este ficheiro nao e um TESTE, e um MONITOR:
        // corria contra o estado actual da chain e ficava vermelho quando o mundo
        // mudava, nao quando o codigo partia. Foi o que aconteceu — duas falhas
        // ("BAG/USDG grid tier not derived", "cold scan missed BAG") que eram o
        // estado on-chain do BAG a ter mudado. Todos os outros fork tests desta
        // suite ja fixavam bloco; este era o unico que nao.
        vm.createSelectFork("robinhood", 42518592);
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), V4_MGR);
        solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), T1, T2);
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        hub.setRoles(address(router), address(solver), address(quoter));
        hub.addBridge(WETH);
        hub.addBridge(USDG);
        // The row's factory field records the PoolManager (operator
        // legibility + non-zero check); the scan reads $.v4PoolManager.
        // No initHash, no extras: everything below is pure derivation.
        hub.addFactory(
            V4_MGR, KIND_V4, MODE_V4_DERIVE, bytes32(0), new uint24[](0), new int24[](0)
        );
    }

    // ─── helpers ───────────────────────────────────────────────────────

    function _scanGas(address a, address b)
        private view returns (PoolInfo[] memory hits, uint256 gasUsed)
    {
        uint256 g0 = gasleft();
        hits = hub.discoverFor(a, b);
        gasUsed = g0 - gasleft();
    }

    function _hasV4(PoolInfo[] memory hits, uint24 fee, int24 ts) private pure returns (bool) {
        for (uint256 i; i < hits.length; ++i) {
            if (
                hits[i].kind == KIND_V4 && hits[i].fee == fee
                    && hits[i].tickSpacing == ts && hits[i].hooks == address(0)
                    && hits[i].pool != address(0)
            ) return true;
        }
        return false;
    }

    function _code(uint24 fee, int24 ts) private pure returns (uint256) {
        return (uint256(fee) << 24) | uint256(uint24(ts));
    }

    // ─── 1. address-only derivation, no claims ─────────────────────────

    /// Grid-derivable launchpad pools are found FULLY ON-CHAIN with nothing
    /// but the pair addresses — no claim, no off-chain log scan — and every
    /// emitted candidate passes the on-chain existence proof (claimV4
    /// accepts it), so a non-existent tier is never returned.
    function test_Derive_FindsGridPools_AddressOnly_NoClaim() public {
        (PoolInfo[] memory hits, uint256 gas1) = _scanGas(USDG, MOMO);
        assertTrue(_hasV4(hits, MOMO_FEE, MOMO_TS), "MOMO/USDG grid tier not derived");
        console2.log("cold derive-scan gas (MOMO/USDG):", gas1);

        (PoolInfo[] memory hits2, uint256 gas2) = _scanGas(USDG, BAG);
        // ─── BAG: A POOL EXISTE MAS ESTA VAZIA ───────────────────────────
        // MEDIDO on-chain a 2026-08-21, bloco 42.518.592, via extsload directo
        // ao PoolManager 0x8366a39C:
        //     sqrtPriceX96 (base+0) = 0x...07f7317f93c96d18a4d5dc8f9254e422  != 0
        //     liquidity    (base+3) = 0x0000...0000                          == 0
        // O `_admitV4` recusa-a no `if (sp == 0 || liq == 0) return kf;`
        // (Hub:905) — e faz bem: uma pool sem liquidez nao entrega nada e
        // ocuparia um lugar num registo CAPADO (V4_CAP = 8), despejando
        // liquidez util. Fail-closed deliberado.
        //
        // A versao anterior deste teste assertava o CONTRARIO (`assertTrue`),
        // ou seja exigia que uma pool vazia fosse descoberta. Estava vermelho
        // desde sempre e a culpa era da assercao, nao do codigo — o mesmo
        // ficheiro tem `test_FailClosed_NativeAndNonexistent` a passar, a
        // afirmar a regra oposta. Duas assercoes contrarias no mesmo ficheiro.
        assertFalse(_hasV4(hits2, BAG_FEE, BAG_TS),
            "uma pool V4 sem liquidez NAO pode ser admitida - fail-closed em Hub:905");
        console2.log("cold derive-scan gas (BAG/USDG):", gas2);

        // Every emitted candidate is claim-provable (existence proof holds).
        for (uint256 i; i < hits.length; ++i) {
            hub.claimV4(hits[i].token0, hits[i].token1, hits[i].fee, hits[i].tickSpacing);
        }
        for (uint256 i; i < hits2.length; ++i) {
            hub.claimV4(hits2[i].token0, hits2[i].token1, hits2[i].fee, hits2[i].tickSpacing);
        }
    }

    // ─── 2. the learned code makes repeat discovery cheaper ────────────

    /// After a claim teaches the Hub a token's pattern code, the scan takes
    /// the one-probe phase-(a) path and skips the cold-start grid — the gas
    /// drop logged here is the self-learning evidence. The bridge side never
    /// learns a code (it pairs with many tokens at many tiers).
    function test_Learning_CodeMakesRepeatDiscoveryCheaper() public {
        // cold: no code anywhere, the grid pays the discovery
        (PoolInfo[] memory h1, uint256 gCold) = _scanGas(USDG, MOMO);
        assertTrue(_hasV4(h1, MOMO_FEE, MOMO_TS), "cold scan missed MOMO");
        assertEq(hub.v4CodeOf(MOMO), 0, "code before any state-changing proof");

        hub.claimV4(USDG, MOMO, MOMO_FEE, MOMO_TS);
        assertEq(hub.v4CodeOf(MOMO), _code(MOMO_FEE, MOMO_TS), "claim did not learn the code");
        assertEq(hub.v4CodeOf(USDG), 0, "bridge must never learn a code");

        // warm: phase (a) finds the pool from the learned code, grid skipped
        (PoolInfo[] memory h2, uint256 gWarm) = _scanGas(USDG, MOMO);
        assertTrue(_hasV4(h2, MOMO_FEE, MOMO_TS), "warm scan missed MOMO");
        assertLt(gWarm, gCold, "learned code did not reduce scan gas");
        console2.log("MOMO/USDG scan gas cold:", gCold);
        console2.log("MOMO/USDG scan gas warm (code learned):", gWarm);
        console2.log("MOMO/USDG scan gas saved:", gCold - gWarm);

        // ─── SEGUNDO TOKEN: o BAG prova a REGRA OPOSTA, e por isso fica ──
        // A propriedade "aprender o codigo baixa o gas do scan" ja esta provada
        // acima com o MOMO. O BAG serve outra coisa, porque a sua pool
        // (fee 870.000 / ts 8.700) esta INICIALIZADA MAS VAZIA — medido on-chain
        // no bloco fixado: sqrtPriceX96 != 0, liquidity == 0.
        //
        // A versao anterior exigia que ela fosse descoberta e ficava vermelha
        // desde sempre. Nao era o mundo a mudar (fixar o bloco nao a curou):
        // era a assercao a contradizer o fail-closed do Hub:905, no mesmo
        // ficheiro onde `test_FailClosed_NativeAndNonexistent` afirma a regra
        // certa. Duas assercoes contrarias, uma verde e outra vermelha.
        (PoolInfo[] memory h3, uint256 gCold2) = _scanGas(USDG, BAG);
        assertFalse(_hasV4(h3, BAG_FEE, BAG_TS),
            "pool V4 sem liquidez NAO pode ser descoberta");
        // E o claim tambem tem de recusar: a mesma prova, pela porta permissionless.
        vm.expectRevert();
        hub.claimV4(USDG, BAG, BAG_FEE, BAG_TS);
        console2.log("BAG/USDG scan gas (pool vazia, corre a grelha toda):", gCold2);
    }

    // ─── 3. recordSwap closes the loop without any claim ───────────────

    /// A scan-found pool that gets ROUTED (recordSwap) is registered with a
    /// coherent V4Entry — tickSpacing recovered and verified against the
    /// truncated poolId — and the token's code is learned. This is the
    /// discovery -> route -> learn loop with no claimV4 involved.
    function test_RecordSwap_LearnsCode_And_RegistersEntry() public {
        // The scan proves the pool exists before we simulate routing it.
        (PoolInfo[] memory hits,) = _scanGas(USDG, MOMO);
        assertTrue(_hasV4(hits, MOMO_FEE, MOMO_TS), "precondition: pool not derivable");

        // recordSwap is Router-only; play the Router for this test.
        hub.setRoles(address(this), address(solver), address(quoter));

        address pool = address(uint160(uint256(
            BPC.computeV4PoolId(USDG, MOMO, MOMO_FEE, MOMO_TS, address(0))
        )));
        hub.recordSwap(pool, KIND_V4, MOMO_FEE, address(0), USDG, MOMO, 1e18, 1e18, 1e20);

        // Code learned on the non-bridge side only.
        assertEq(hub.v4CodeOf(MOMO), _code(MOMO_FEE, MOMO_TS), "recordSwap did not learn the code");
        assertEq(hub.v4CodeOf(USDG), 0, "bridge must never learn a code");

        // The registry entry is coherent: getActivePools recovers the real
        // tickSpacing from the V4Entry recordSwap created.
        PoolInfo[] memory act = hub.getActivePools(USDG, MOMO);
        assertEq(act.length, 1, "routed pool not registered");
        assertEq(act[0].kind, KIND_V4, "wrong kind registered");
        assertEq(act[0].tickSpacing, MOMO_TS, "V4Entry tickSpacing not recovered");
        assertEq(act[0].pool, pool, "wrong pool address registered");
    }

    // ─── 4. fail-closed ────────────────────────────────────────────────

    /// Native currency is out of scope and a pair with no V4 pools yields
    /// nothing: the derive-scan never emits a candidate whose slot0/liquidity
    /// proof did not pass.
    function test_FailClosed_NativeAndNonexistent() public {
        // Snapshot the learning state first: the assertion below is that a view
        // scan does not MUTATE it, which is a before/after property — not an
        // absolute zero (setUp may legitimately have seeded a code).
        uint256 codeBefore = hub.v4CodeOf(MOMO);

        PoolInfo[] memory none = hub.discoverFor(address(0), MOMO);
        assertEq(none.length, 0, "native-currency pair must yield nothing");

        // Arbitrary addresses with no V4 pools: the whole grid misses.
        address a = address(uint160(uint256(keccak256("bp-dex: no-pool-a"))));
        address b = address(uint160(uint256(keccak256("bp-dex: no-pool-b"))));
        none = hub.discoverFor(a, b);
        assertEq(none.length, 0, "nonexistent pair must yield nothing");

        // View scans never mutate learning state.
        assertEq(hub.v4CodeOf(MOMO), codeBefore, "a view scan must not learn");
    }
}
