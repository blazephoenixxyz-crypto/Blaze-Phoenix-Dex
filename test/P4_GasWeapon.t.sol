// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  P4 — THE GAS AS A WEAPON
//
//  Hypothesis: a venue the Gate admits by identity (its family has a live adapter)
//  burns gas inside its `quote`. The fitness read that discovery runs over it,
//  `Gate.vitalOf`, would then spend the caller's whole gas before it ranks the
//  venue — exhausting the discovery budget and pushing the swap into OOG or a worse route.
//
//  The defence is BPC.GATE_QUOTE_GAS (500_000): `vitalOf` reads the adapter's
//  `quote` under that cap (BlazePhoenixGate:255), so a hostile venue can only
//  burn its own stipend and is ranked at depth 0 — it removes ONLY itself, and
//  the read answers. Relation (verde): vitalOf returns, and the gas it spends is
//  bounded by the cap, not by the frame the caller brought.
//
//  MUTANT (kills this test): drop the `{gas: BPC.GATE_QUOTE_GAS}` at
//  BlazePhoenixGate.sol:255 so the adapter's quote runs on all the gas vitalOf
//  was given. The hostile loop then burns the whole budget -> `used` jumps from
//  ~0.6M to the frame's ~5M -> assertLt fails. Apply, red; revert, green.
//
//  Scope: a single Gate behind the real wrapper; no fork. The companion fork
//  proof of the BalV2 10,000-gas probe (DEX-13) is
//  test/fork/AdaptersFork.t.sol::testFork_BalV2_Base_DepthProbe_QuietOutside_ZeroInside.
// =============================================================================

import {AdapterHarness} from "./adapters/AdapterHarness.sol";
import {ExtAdapterBase} from "../src/adapters/ExtAdapterBase.sol";
import {IExtAdapter} from "../src/adapters/IExtAdapter.sol";

/// A venue that passes the Gate's code scan (no DELEGATECALL/CALLCODE/SELFDESTRUCT, no approve
/// selector) and resolves to a pool, but whose on-chain `quote`/`quoteCall` spin the gas it is
/// handed down to a floor. venuePool = itself: `vitalOf` reads balanceOf there and finds 0, so
/// the declared depth is capped to 0 anyway — the test is about gas, not the depth value.
contract GasBombAdapter is ExtAdapterBase, IExtAdapter {
    constructor(address gate) ExtAdapterBase(gate) {}

    function resolve(address, address, uint24, bytes calldata)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1)
    {
        return (address(this), bytes32(0), bytes32(0));
    }

    function exec(address, bytes32, bytes32, bool, uint256, address) external pure returns (uint256) {
        return 0;
    }

    function quote(address, bytes32, bytes32, bool, uint256) external view returns (uint256, uint256) {
        _burn();
        return (0, 1e18);
    }

    function quoteCall(address, bytes32, bytes32, bool, uint256) external view returns (uint256) {
        _burn();
        return 0;
    }

    /// Spend everything handed in, down to a floor that lets the caller's catch run.
    function _burn() private view {
        assembly ("memory-safe") {
            for {} gt(gas(), 2000) {} {}
        }
    }
}

interface IVitalGate {
    function vitalOf(address w) external view returns (uint256 v, uint256 depth18, uint256 psi);
}

/// Calls `vitalOf` under a FIXED gas budget so "all the gas available" is a known number, and
/// reports whether it answered and what it spent. A view call, measured across the boundary.
contract VitalMeter {
    function measure(address gate, address w, uint256 budget) external view returns (bool ok, uint256 used) {
        uint256 g = gasleft();
        try IVitalGate(gate).vitalOf{gas: budget}(w) returns (uint256, uint256, uint256) {
            ok = true;
        } catch {
            ok = false;
        }
        used = g - gasleft();
    }
}

contract P4GasWeaponTest is AdapterHarness {
    /// A hostile venue burning gas in its quote only removes itself: vitalOf answers, and the gas
    /// it spends is bounded by GATE_QUOTE_GAS, not by the 5M frame the caller brought.
    function test_P4_HostileVenueQuoteBurnsGas_OnlyRemovesItself() public {
        _tokens();
        GasBombAdapter bomb = new GasBombAdapter(address(gate));
        _accept(9, address(bomb));
        address w = gate.create(address(t0), address(t1), uint24(9) << 16 | 1, "");

        VitalMeter m = new VitalMeter();
        (bool ok, uint256 used) = m.measure(address(gate), w, 5_000_000);

        emit log_named_uint("vitalOf gas used (hostile quote, capped)", used);
        assertTrue(ok, "vitalOf answers despite the hostile quote (it removes only itself)");
        // Capped: ~0.6M. Mutant (no GATE_QUOTE_GAS cap at Gate:255): the loop eats the 5M frame.
        assertLt(used, 1_500_000, "GATE_QUOTE_GAS bounds the hostile quote");
    }
}
