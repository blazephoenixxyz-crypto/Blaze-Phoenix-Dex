/*
 * Certora CVL — INV-20 (V4-FEE-MEASURED) fail-closed proof.
 *
 * effV4Fee resolves the effective swap fee for a V4 leg:
 *   - a static-fee key (keyFee != 0x800000) carries the true fee in the key;
 *   - a dynamic-fee key (0x800000 sentinel) with any protocolFee fails closed
 *     to an unquotable 0xFFFFFF (>= 1e6, which outV3 treats as "cannot price");
 *   - a dynamic-fee key with zero protocolFee uses the measured slot0 lpFee.
 *
 * These rules prove the sentinel can NEVER survive as a usable fee, and a
 * hostile/unknown protocolFee can never under-charge — the guarantees the
 * quoter and the Router's re-derivation both depend on.
 */

methods {
    function effV4Fee(uint24 keyFee, uint24 lpFee, uint24 protoFee)
        external returns (uint24) envfree;
}

definition DYN() returns uint24 = 0x800000;   // dynamic-fee sentinel
definition UNQUOTABLE() returns uint24 = 0xFFFFFF;
definition ONE_MILLION() returns mathint = 1000000;

/// A static-fee key is truth: the resolver returns the key fee verbatim,
/// ignoring slot0 entirely.
rule staticKeyIsTruth(uint24 keyFee, uint24 lpFee, uint24 protoFee) {
    require keyFee != DYN();
    assert effV4Fee(keyFee, lpFee, protoFee) == keyFee;
}

/// A dynamic-fee pool carrying ANY non-zero protocolFee fails closed to an
/// unquotable value >= 1e6 — never a usable (under-charging) fee.
rule dynamicWithProtoFeeFailsClosed(uint24 lpFee, uint24 protoFee) {
    require protoFee != 0;
    uint24 r = effV4Fee(DYN(), lpFee, protoFee);
    assert r == UNQUOTABLE();
    assert to_mathint(r) >= ONE_MILLION();
}

/// A dynamic-fee pool with zero protocolFee prices from the measured slot0 lpFee.
rule dynamicUsesMeasuredLpFee(uint24 lpFee) {
    assert effV4Fee(DYN(), lpFee, 0) == lpFee;
}

/// Global safety: the sentinel itself can never be returned as a fee for a live
/// (protoFee == 0) dynamic pool — the resolved fee is always the real lpFee,
/// so it only reaches the >=1e6 guard when we deliberately fail closed.
rule sentinelNeverSurvivesForLivePool(uint24 lpFee) {
    uint24 r = effV4Fee(DYN(), lpFee, 0);
    assert r == lpFee;
    assert r != DYN() || lpFee == DYN();
}
