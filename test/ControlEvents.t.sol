// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// E4 — TRES PODERES DE CONTROL SEM RASTO, E UM DELES E O APARELHO DE MEDICAO.
//
// TODOS os outros setters dos dois contratos emitem: o Router emite `Cfg` em setAdmin,
// setTreasuries, setPermit2, setWeth e renounceControl; o Hub emite `RoleSet` em setAdmin,
// setRoles e setOperator. Tres nao emitiam nada: `Router.setPaused`, `Hub.setPaused` e
// `Hub.setV4Manager`. Assinatura de defeito da casa a vista — um comportamento aplicado a N-3 de
// N canais simetricos.
//
// PORQUE O setV4Manager E MAIS DO QUE HIGIENE. O `v4PoolManager` e o singleton contra o qual
// correm os `extsload` que CONSTITUEM a prova de autenticidade do claimV4, e e lido no caminho de
// execucao. O Axioma Meta-Supremo diz "nunca ajas sobre um valor modelado havendo medicao
// on-chain" — e pressupoe TACITAMENTE que o aparelho de medicao e fixo. Um instrumento mutavel e
// INOBSERVAVEL nao invalida a medicao: a medicao continua fiel, ao sitio errado. Nao ha sintoma,
// porque o extsload devolve um numero perfeitamente valido do singleton perfeitamente errado.
//
// Num sistema cuja doutrina de rescue existe para que QUALQUER uso de poder seja publicamente
// observavel, este era o unico poder que trocava o instrumento em silencio.
//
// E o `paused` e o interruptor de emergencia dos dois contratos.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";

contract ControlEventsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0x7451), address(0x7452)
        );
    }

    function test_RouterSetPaused_Emits() public {
        vm.expectEmit(false, false, false, true, address(router));
        emit BlazePhoenixRouter.PausedSet(true);
        router.setPaused(true);

        vm.expectEmit(false, false, false, true, address(router));
        emit BlazePhoenixRouter.PausedSet(false);
        router.setPaused(false);
    }

    function test_HubSetPaused_Emits() public {
        vm.expectEmit(false, false, false, true, address(hub));
        emit BlazePhoenixHub.PausedSet(true);
        hub.setPaused(true);
    }

    /// O que interessa: trocar o singleton contra o qual corre a prova do claimV4 tem de deixar
    /// rasto. Reutiliza o `RoleSet` existente com um id novo — o v4PoolManager E um endereco de
    /// protocolo, cabe na forma sem gastar um evento novo.
    function test_HubSetV4Manager_Emits() public {
        address novo = address(0xB0B);
        vm.expectEmit(false, false, false, true, address(hub));
        emit BlazePhoenixHub.RoleSet(5, novo);
        hub.setV4Manager(novo);
    }
}
