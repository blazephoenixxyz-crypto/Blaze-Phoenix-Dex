// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Leg, PoolInfo} from "../../src/BlazePhoenixCore.sol";

/// @notice A DESCOBERTA V4 NAO PODE ASSUMIR WETH — TEM DE ASSUMIR ETH NATIVO.
///
/// ─────────────────────────────────────────────────────────────────────────
///  O DEFEITO, E PORQUE ELE E SILENCIOSO
/// ─────────────────────────────────────────────────────────────────────────
///  A V4 e um SINGLETON: nao ha factory que derive a pool a partir do par.
///  Cada pool e um `PoolKey` explicito, e o par (ETH, X) tem DUAS chaves
///  distintas e nao intercambiaveis:
///
///     nativa : currency0 = address(0)   <- o ETH nativo E address(0) no V4
///     wrapped: currency0 = WETH
///
///  Sao pools DIFERENTES, com `PoolId` diferente e liquidez diferente. Quem
///  registar a segunda quando a liquidez esta na primeira nao recebe erro
///  nenhum: recebe uma cotacao pior. O sintoma e silencioso — e o modo de
///  falha mais caro que existe, porque nao ha nada para depurar.
///
///  MEDIDO na Robinhood (4663), pool USDG/ETH fee 100 / ts 1:
///     nativa   L = 919.244.443.791.993
///     wrapped  L =   3.149.675.462.530     <- a que `_wireRobinhood` regista
///  A nativa e ~292x mais funda. Na Base o mesmo par e 3,76x. O sinal aponta
///  sempre para o mesmo lado, e o dono nomeou a razao antes de eu a medir: no
///  V4 o ETH nativo e mais usado que o WETH.
///
/// ─────────────────────────────────────────────────────────────────────────
///  DESENHO DO TESTE: ISOLAR A V4
/// ─────────────────────────────────────────────────────────────────────────
///  Estes casos registam SO a V4 — sem V2, sem V3. Nao e descuido: com as
///  outras familias cabladas, uma V3 funda ganha as duas variantes e os dois
///  ramos devolvem o mesmo numero. O teste ficaria verde sem medir nada, que
///  e a Lei do Aparelho outra vez. Isolar e o que torna a diferenca visivel.
contract RobinhoodV4NativeTest is Test {
    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint24  constant FEE  = 100;
    int24   constant TS   = 1;

    address constant T1 = address(0x7E51111111111111111111111111111111111111);
    address constant T2 = address(0x7e52222222222222222222222222222222222222);

    bool ligado;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }   // a bare return reports PASSED on a test that ran nothing
        // BLOCO FIXADO, o mesmo do RobinhoodV4Derive (decisao de 2026-08-21).
        // Sem pino, este teste compara liquidez ao vivo e fica vermelho quando
        // o mercado se mexe — um vermelho falso que ja custou uma sessao. Com
        // pino, ele so fica vermelho quando o CODIGO regride, que e a unica
        // razao pela qual um teste deve falhar.
        vm.createSelectFork("robinhood", 42518592);
        ligado = true;
    }

    /// Stack limpa por variante — o registo e imutavel na pratica, e reutilizar
    /// o mesmo Hub deixaria a primeira variante a competir com a segunda.
    function _stack() internal returns (BlazePhoenixHub h, BlazePhoenixQuoter q) {
        h = new BlazePhoenixHub(address(this));
        h.initialize(address(this), PM);
        BlazePhoenixSolver s = new BlazePhoenixSolver(address(h));
        BlazePhoenixRouter r = new BlazePhoenixRouter(address(h), address(s), address(this), T1, T2);
        q = new BlazePhoenixQuoter(address(h), address(s));
        h.setRoles(address(r), address(s), address(q));
        // Sem isto o `addV4` nativo falha em HubE(3): a traducao nativo->WETH
        // do registo nao tem para onde apontar.
        r.setWeth(WETH);
        h.addBridge(WETH); h.addBridge(USDG);
    }

    function _out(BlazePhoenixQuoter q, uint256 amt) internal view returns (uint256 gross, uint256 legs) {
        try q.previewPlan(WETH, USDG, amt) returns (BlazePhoenixQuoter.Preview memory pv, Route memory, bool) {
            return (pv.grossOut, pv.legs);
        } catch { return (0, 0); }
    }

    /// @notice O NUCLEO. As duas variantes existem; a nativa tem de entregar
    ///         materialmente mais. Se este teste ficar verde com as duas iguais,
    ///         ou o par deixou de ter pool nativa ou o registo nao a alcancou.
    function test_NativaEntregaMaisQueWrapped() public {
        if (!ligado) { vm.skip(true); return; }   // skip, not pass: the key is absent, nothing was exercised
        uint256 amt = 1e18; // 1 WETH

        (BlazePhoenixHub hW, BlazePhoenixQuoter qW) = _stack();
        hW.addV4(USDG, WETH, FEE, TS, address(0));          // como `_wireRobinhood` faz hoje
        (uint256 outW, uint256 lW) = _out(qW, amt);

        (BlazePhoenixHub hN, BlazePhoenixQuoter qN) = _stack();
        hN.addV4(address(0), USDG, FEE, TS, address(0));     // a variante NATIVA
        (uint256 outN, uint256 lN) = _out(qN, amt);

        console2.log("wrapped  grossOut / legs:", outW, lW);
        console2.log("NATIVA   grossOut / legs:", outN, lN);

        assertGt(outW, 0, "a variante wrapped devia cotar (a pool existe, so e rasa)");
        assertGt(outN, 0, "a variante NATIVA devia cotar");
        assertGt(outN, outW, "a pool nativa e ~292x mais funda: tem de entregar mais");
    }

    /// @notice O CONTROLO que impede o teste acima de ficar verde por acidente.
    ///         Se o `previewPlan` devolvesse zero nas duas, `assertGt(outN,outW)`
    ///         falhava — mas se devolvesse zero so na wrapped, passaria sem a
    ///         nativa provar nada. Aqui exige-se que a V4 EXECUTE mesmo.
    function test_V4RoteiaDeFactoNaRobinhood() public {
        if (!ligado) { vm.skip(true); return; }   // skip, not pass: the key is absent, nothing was exercised
        (BlazePhoenixHub h, BlazePhoenixQuoter q) = _stack();
        h.addV4(address(0), USDG, FEE, TS, address(0));
        // `pv.route` e a rota ESCOLHIDA. O segundo retorno e `fallbackRoute`
        // (a de recurso) e vem vazia quando nao ha — ler dali dava 0 legs com
        // `grossOut` > 0, que foi como este controlo apanhou o erro.
        (BlazePhoenixQuoter.Preview memory pv, , ) = q.previewPlan(WETH, USDG, 1e18);
        Route memory rt = pv.route;
        assertGt(pv.grossOut, 0, "sem cotacao nao ha V4 nenhuma a funcionar");
        assertEq(pv.hops, 1, "USDG e ponte: tem de sair directo");
        uint256 v4legs;
        for (uint256 hh; hh < rt.hops.length; ++hh) {
            Leg[] memory ls = rt.hops[hh].legs;
            for (uint256 l; l < ls.length; ++l) {
                if (ls[l].kind == BPC.KIND_V4 || ls[l].kind == BPC.KIND_V4_NATIVE) v4legs++;
            }
        }
        assertGt(v4legs, 0, "a unica venue registada e V4: a perna TEM de ser V4");
        console2.log("V4 legs:", v4legs, "| grossOut:", pv.grossOut);
    }

    // ─── A DESCOBERTA DERIVADA (MODE_V4_DERIVE) ────────────────────────────
    uint8 constant KIND_V4_ROW     = 4;
    uint8 constant MODE_V4_DERIVE  = 9;

    /// @notice O DEFEITO DE PRODUCAO, ao nivel onde ele vive.
    ///
    ///         O `addV4` explicito ate sabe registar nativo — o que nao sabe e
    ///         DESCOBRIR. O `_scanV4` deriva sempre os poolIds a partir do par
    ///         do registo, que fala WETH, portanto so constroi a chave wrapped.
    ///         A nativa nunca chega a ser candidata, e o sintoma e ausencia
    ///         silenciosa: nenhum erro, so uma cotacao pior.
    ///
    ///         Medido neste par: a nativa e ~292x mais funda, e vale 17,9x mais
    ///         output. Enquanto este teste estiver vermelho, e isso que se perde
    ///         em qualquer chain onde a liquidez V4 esteja em ETH nativo.
    function test_DeriveScanTemDeEncontrarAPoolNativa() public {
        if (!ligado) { vm.skip(true); return; }   // skip, not pass: the key is absent, nothing was exercised
        (BlazePhoenixHub h, ) = _stack();
        uint24[] memory f = new uint24[](0);
        int24[]  memory sp = new int24[](0);
        h.addFactory(PM, KIND_V4_ROW, MODE_V4_DERIVE, bytes32(0), f, sp);

        // `getActivePools` le o REGISTO; a varredura derivada vive no
        // `discoverFor` (descoberta sem permissao). Interrogar o primeiro dava
        // 0 e parecia o defeito — era a pergunta errada.
        PoolInfo[] memory ps = h.discoverFor(WETH, USDG);
        uint256 wrapped; uint256 nativas;
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].kind == BPC.KIND_V4)        wrapped++;
            if (ps[i].kind == BPC.KIND_V4_NATIVE) nativas++;
        }
        console2.log("derive-scan achou -> wrapped:", wrapped, "| nativas:", nativas);

        // PINAR A CONTAGEM, nao so a existencia. `assertGt(x, 0)` ficaria verde
        // se a cobertura caisse de 4 para 1 — e foi exactamente essa a pergunta
        // quando se cortou a sondagem de escaloes extra da passada nativa.
        //
        // Quatro e o numero de escaloes CANONICOS (100/1, 500/10, 3000/60,
        // 10000/200) e este par tem pool viva em todos. `assertGe` e nao
        // `assertEq` porque o fork e no bloco corrente: pools novas podem
        // aparecer, e isso nao e uma regressao.
        assertGe(wrapped, 4, "a passada wrapped tem de manter os 4 escaloes canonicos");
        assertGe(nativas, 4, "a passada NATIVA tem de manter os 4: o corte dos extras nao pode custar cobertura");
    }

    /// @notice DIAGNOSTICO: onde e que a varredura derivada se perde?
    ///         Chama cada degrau isoladamente, do mais baixo ao mais alto.
    function test_Diag_ScanV4() public {
        if (!ligado) { vm.skip(true); return; }   // skip, not pass: the key is absent, nothing was exercised
        bytes32 pid = BPC.computeV4PoolId(WETH, USDG, FEE, TS, address(0));
        console2.log("pid:", vm.toString(pid));

        bytes32[] memory ids = new bytes32[](1); ids[0] = pid;
        bytes32[] memory w0 = BPC.v4Slot0Batch(PM, ids);
        console2.log("1) v4Slot0Batch word0:", vm.toString(w0[0]));

        (uint160 sp, uint128 lq, uint24 lpf, uint24 pf, ) = BPC.v4SqrtAndLiq(PM, pid);
        console2.log("2) v4SqrtAndLiq sqrtP:", sp);
        console2.log("   liq:", lq);
        console2.log("   lpFee / protoFee:", lpf, pf);
        console2.log("3) effV4Fee:", BPC.effV4Fee(FEE, lpf, pf));

        (BlazePhoenixHub h, ) = _stack();
        uint24[] memory f = new uint24[](0);
        int24[]  memory sp2 = new int24[](0);
        uint8 idx = h.addFactory(PM, KIND_V4_ROW, MODE_V4_DERIVE, bytes32(0), f, sp2);
        console2.log("4) factory idx / count:", idx, h.factoryCount());

        PoolInfo[] memory ps = h.getActivePools(WETH, USDG);
        console2.log("5) getActivePools (REGISTO) len:", ps.length);
        PoolInfo[] memory ds = h.discoverFor(WETH, USDG);
        console2.log("6) discoverFor (DESCOBERTA) len:", ds.length);
        for (uint256 i; i < ds.length; ++i) {
            console2.log("   kind / fee / pool:", ds[i].kind, ds[i].fee, ds[i].pool);
        }
        for (uint256 i; i < ps.length; ++i) {
            console2.log("   kind / pool:", ps[i].kind, ps[i].pool);
        }
    }
}
