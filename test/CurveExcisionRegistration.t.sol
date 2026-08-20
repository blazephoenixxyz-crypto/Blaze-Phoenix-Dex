// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// EXCISAO CURVE/BALANCER — a porta de registo (PASSO 1 do plano, red-first).
//
// DECISAO DO DONO (2026-08-20): remover Balancer e Curve de todo o codigo. Razao: quase nenhuma
// L2 os tem, e custavam bytecode em cinco contratos.
//
// PORQUE O REGISTO E A PORTA CERTA PARA COMECAR. O corte nao e so poda: remove tres superficies
// que eram cada uma a UNICA da sua classe — o unico `approve` do Router (`_execCurveAmt`, onde
// vivia o HUNT-001), o unico produtor de `depthWad` atestado pelo caller, e o unico buraco
// deliberado na prova de autenticidade do Hub (a mascara 0x6b exclui os kinds 2 e 7: para esses a
// pool NAO e verificada E a profundidade e atestada). Se o Hub continuar a aceitar o registo de
// factories curve, o Solver volta a rotear por la mesmo com o codigo de execucao removido — e a
// falha deixa de ser "revert claro" para ser "rota que nunca liquida".
//
// O ESTADO DE HOJE, lido no codigo (Hub L338-345):
//     if (kind > KIND_CURVE)                                              revert HubE(5);
//     if ((kind == KIND_STABLE || kind == KIND_CURVE) && mode != MODE_CURVE_META) revert HubE(5);
//     if (mode > MODE_V4_DERIVE)                                          revert HubE(5);
// O segundo gate e CONDICIONAL: so rejeita curve quando o mode NAO e o meta. Logo `kind=2` com
// `mode=8` passa hoje. E `mode=8` com `kind=0` tambem passa, porque o unico limite de mode e
// `> MODE_V4_DERIVE (9)` — o 8 cabe la dentro. Este segundo caso e um bug de registo encontrado
// de passagem: um mode que so faz sentido para curve fica aberto a qualquer kind.
//
// O QUE ESTES TESTES EXIGEM DEPOIS DO CORTE:
//   - o gate de kind passa a INCONDICIONAL (`kind == STABLE || kind == CURVE` -> revert sempre).
//     ATENCAO: apagar a linha inteira, como dois dos desenhos propunham, tornaria `kind=2` com
//     mode 0-3 REGISTAVEL — os checks de coerencia de L353-373 so constrangem os modes 4,5,6,9.
//   - `MODE_CURVE_META` deixa de ser um mode valido para qualquer kind.
//   - o limite superior `kind > KIND_CURVE` (L338) FICA e a constante KIND_CURVE=7 FICA: e a UNICA
//     expressao do limite superior de kind, e `KIND_V4_NATIVE=8` nem sequer existe nas constantes
//     do Hub. Apaga-la abriria o registo ao kind 8 por factory.
//
// Os NUMEROS dos kinds nunca se reutilizam: `decodeKind` le o kind dos bits do Monoslot, e
// renumerar reinterpretaria slots ja gravados. Ficam como lapides.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract CurveExcisionRegistrationTest is Test {
    BlazePhoenixHub hub;

    address admin   = address(0xA11CE);
    address factory = address(0xFAC7);

    /// Espelho da constante `internal` do Hub — o mode que so existia para o Curve meta-registry.
    uint8 constant MODE_CURVE_META = 8;
    /// Modes que nao sao curve, para provar que o corte nao os afeta.
    uint8 constant MODE_CREATE2_V2 = 4;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0xBEEF));
        hub.setRoles(address(this), address(this), address(this));
    }

    function _empty() internal pure returns (uint24[] memory f, int24[] memory s) {
        f = new uint24[](0);
        s = new int24[](0);
    }

    /// KIND_STABLE (2) com o mode meta e a porta que hoje esta aberta: o gate de L344 e
    /// condicional ao mode, logo esta combinacao exata escapa-lhe.
    function test_AddFactory_RejectsStableEvenWithCurveMetaMode() public {
        (uint24[] memory f, int24[] memory s) = _empty();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(factory, BPC.KIND_STABLE, MODE_CURVE_META, bytes32(0), f, s);
    }

    /// KIND_CURVE_CRYPTO (7) pela mesma porta.
    function test_AddFactory_RejectsCurveCryptoEvenWithCurveMetaMode() public {
        (uint24[] memory f, int24[] memory s) = _empty();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(factory, BPC.KIND_CURVE_CRYPTO, MODE_CURVE_META, bytes32(0), f, s);
    }

    /// O bug encontrado de passagem: `MODE_CURVE_META` e aceite com QUALQUER kind, porque o unico
    /// limite de mode e `> MODE_V4_DERIVE (9)` e o 8 cabe la dentro. Um mode que so faz sentido
    /// para curve nao deve sobreviver ao corte para kind nenhum.
    function test_AddFactory_RejectsCurveMetaModeForAnyKind() public {
        (uint24[] memory f, int24[] memory s) = _empty();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(factory, BPC.KIND_V2, MODE_CURVE_META, bytes32(0), f, s);
    }

    /// ANTI-REGRESSAO, tem de continuar VERDE antes e depois do corte: o limite superior de kind
    /// e a UNICA barreira que impede registar KIND_V4_NATIVE (8) por factory — o Hub nem tem essa
    /// constante. Apagar `if (kind > KIND_CURVE)` junto com o resto do Curve abriria essa porta.
    function test_AddFactory_StillRejectsKindAboveUpperBound() public {
        (uint24[] memory f, int24[] memory s) = _empty();
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, uint16(5)));
        hub.addFactory(factory, 8, MODE_CREATE2_V2, bytes32(0), f, s);
    }
}
