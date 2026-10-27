#!/usr/bin/env bash
# identity-guard.sh — a venue is derived, never declared (AUDIT_METHOD §5a, rizki-3107).
#
# A pool that reports the right token0()/token1() has declared its pair, not proved
# where it came from: any contract can return two addresses. The swap door therefore
# seats a pair-shaped pool only if a wired factory derives it (`_derivedByFactory`,
# which asks `discoverFor`). This guard fails CI when that stops being true in the
# source, whichever way it stops:
#
#   1. recordSwap seats a row without first running the origin proof
#      (the proof line removed, commented out, moved below `_register`, or replaced
#      by a token0Of/token1Of comparison, which is a declaration and not a proof);
#   2. `_derivedByFactory` stops asking discovery, or answers from the pool's own
#      token0Of/token1Of reads;
#   3. a function that is not one of the four known doors calls `_register`. Each
#      known door carries its proof by name:
#        recordSwap        derivation by a wired factory (non-V4) or the V4 poolId
#        addV4, claimV4    the V4 poolId, recomputed from the key (V4 only)
#        seedPool          the operator's curation (tier 0); no derivation is claimed
#      A new door must be added here together with its proof, in review.
#
# The pair check `token0Of(pool) != t0 || token1Of(pool) != t1` in recordSwap is NOT a
# violation: it says which tokens the pool trades, and stays next to the proof of
# origin (a CREATE2 derivation proves deployer and salt, not tokens; measured by
# test_Create2HitOnOtherTokens_IsRefusedByThePairCheck). The guard reads code lines only:
# everything after `//` is dropped before matching.
#
# Its own proof that it can fail: AUDIT_METHOD §5a records the red runs against a
# scratch copy with each violation reintroduced.
set -uo pipefail

HUB="${1:-src/BlazePhoenixHub.sol}"
[ -f "$HUB" ] || { echo "::error::identity guard: $HUB not found"; exit 1; }

awk '
function bad(msg) { print "::error::Identity guard: " msg; fails++ }
{
  code = $0
  sub(/\/\/.*/, "", code)
}
/^    function [A-Za-z_0-9]+\(/ {
  match($0, /function [A-Za-z_0-9]+/)
  fn = substr($0, RSTART + 9, RLENGTH - 9)
}
fn == "recordSwap" && code ~ /if \(!_derivedByFactory\(pool, t0, t1\)\) return;/ { proved = NR }
# Since aero-nova (2026-10-26) the proof also hands back the tier its derivation is keyed by:
# the destructured call, then the refusal on the very next line, is the same proof.
fn == "recordSwap" && code ~ /\(proven, idFee\) = _derivedByFactory\(pool, t0, t1\);/ { asked = NR }
fn == "recordSwap" && asked && NR == asked + 1 && code ~ /if \(!proven\) return;/ { proved = NR }
fn == "_derivedByFactory" {
  seenDerived = 1
  if (code ~ /discoverFor\(/) asks = 1
  if (code ~ /\.pool == pool\)/) matches = 1
  if (code ~ /token[01]Of\(|\.token[01]\(\)/)
    bad("line " NR ": _derivedByFactory reads the pool own token0/token1. Those are a declaration, not a proof of origin.")
}
code ~ /[^A-Za-z_0-9]_register\(/ && fn != "_register" {
  if (fn == "recordSwap") {
    seated = NR
    if (!proved) bad("line " NR ": recordSwap seats a row with no origin proof before it (if (!_derivedByFactory(pool, t0, t1)) return;).")
  } else if (fn != "addV4" && fn != "claimV4" && fn != "seedPool") {
    bad("line " NR ": " fn " calls _register but is not a known door. Add it to identity-guard.sh with its proof of origin, in review.")
  }
}
END {
  if (!seenDerived) bad("_derivedByFactory is gone: the swap door has no proof of origin.")
  else {
    if (!asks)    bad("_derivedByFactory no longer asks discoverFor: origin must be derived by a wired factory.")
    if (!matches) bad("_derivedByFactory no longer matches the pool against the derived hits (.pool == pool).")
  }
  if (!seated) bad("recordSwap no longer calls _register: the guard lost its anchor; re-anchor it, never delete it.")
  if (fails) exit 1
  print "identity guard: every pair-shaped seat through the swap door is derived by a wired factory"
}
' "$HUB"
