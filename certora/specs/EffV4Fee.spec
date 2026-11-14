/*
 * Certora CVL - INV-20 (V4-FEE-MEASURED) fail-closed proof.
 * Target: BlazePhoenixCore.effV4Fee(keyFee, lpFee, protoFee, zeroForOne), through
 * certora/harness/EffV4FeeHarness.sol. Mirrors test/formal/EffV4FeeFormalSpec.t.sol (Halmos).
 *
 *   - a static key (keyFee != 0x800000) is the LP fee; a protocol fee p in the swap's
 *     direction composes p + lp - p*lp/1e6 (v4-core calculateSwapFee);
 *   - a dynamic key (0x800000) with any protocolFee fails closed to 0xFFFFFF (>= 1e6,
 *     which outV3 treats as "cannot price");
 *   - a dynamic key with zero protocolFee uses the measured slot0 lpFee.
 */

methods {
    function effV4Fee(uint24, uint24, uint24, bool) external returns (uint24) envfree;
}

definition DYN() returns uint24 = 0x800000;
definition UNQUOTABLE() returns uint24 = 0xFFFFFF;
definition PIPS() returns mathint = 1000000;

/// The protocol fee nibble of the swap's direction: low 12 bits zeroForOne, high 12 bits otherwise.
function dirProto(uint24 protoFee, bool zfo) returns mathint {
    return zfo ? to_mathint(protoFee) % 4096 : to_mathint(protoFee) / 4096;
}

/// A static key with no protocol fee in the swap's direction returns the key fee verbatim.
rule staticKeyIsTruthWithoutProtocolFee(uint24 keyFee, uint24 lpFee, uint24 protoFee, bool zfo) {
    require keyFee != DYN();
    require dirProto(protoFee, zfo) == 0;
    assert effV4Fee(keyFee, lpFee, protoFee, zfo) == keyFee;
}

/// A static key composes the directional protocol fee exactly, never below the key fee,
/// never above key + p, and never into the unquotable band for an admissible LP fee.
rule staticKeyComposesProtocolFee(uint24 keyFee, uint24 lpFee, uint24 protoFee, bool zfo) {
    require keyFee != DYN();
    require to_mathint(keyFee) <= PIPS();
    mathint p = dirProto(protoFee, zfo);
    mathint r = effV4Fee(keyFee, lpFee, protoFee, zfo);
    assert r == p + keyFee - (p * keyFee) / PIPS();
    assert r >= to_mathint(keyFee);
    assert r <= keyFee + p;
    assert r <= PIPS();
}

/// A dynamic-fee pool with ANY non-zero protocolFee fails closed in both directions.
rule dynamicWithProtoFeeFailsClosed(uint24 lpFee, uint24 protoFee, bool zfo) {
    require protoFee != 0;
    uint24 r = effV4Fee(DYN(), lpFee, protoFee, zfo);
    assert r == UNQUOTABLE();
    assert to_mathint(r) >= PIPS();
}

/// A live dynamic-fee pool (protoFee == 0) prices from the measured slot0 lpFee.
rule dynamicUsesMeasuredLpFee(uint24 lpFee, bool zfo) {
    assert effV4Fee(DYN(), lpFee, 0, zfo) == lpFee;
}

/// The sentinel is never the resolved fee of a live dynamic pool unless slot0 reports it.
rule sentinelNeverSurvivesForLivePool(uint24 lpFee, bool zfo) {
    uint24 r = effV4Fee(DYN(), lpFee, 0, zfo);
    assert r != DYN() || lpFee == DYN();
}
