#!/usr/bin/env bash
# Size lottery tripwire. Under via-IR, Yul names carry AST IDs, and the order the optimizer
# meets functions in follows them; an inlining decision can flip with it. Measured on 10a6053:
# appending 3 unused constants to Core.sol (Hub source untouched) moved the Hub from 23,956 B
# to 24,728 B, past EIP-170. The CI size gate only ever sees the N of the commit at hand, so
# the jump surfaces in an unrelated change. This script builds the release profile N+1 times,
# with N = 0..MAX unused file-level constants appended to src/BlazePhoenixCore.sol, in a
# throwaway copy of the tree, and fails if any BlazePhoenix* contract reaches LIMIT bytes in
# any variant, or if its size moves across the variants by more than SPREAD bytes.
#
# Usage: tools/hub-lottery.sh [MAX=6] [LIMIT=24000] [SPREAD=64]
#   FORGE  forge command (default "forge"; e.g. a wrapper that rations memory)
#   KEEP=1 keep the throwaway tree and the per-variant logs
set -euo pipefail
MAX=${1:-6}; LIMIT=${2:-24000}; SPREAD=${3:-64}
FORGE=${FORGE:-forge}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
[ "${KEEP:-0}" = 1 ] || trap 'rm -rf "$TMP"' EXIT
cp -r "$ROOT/src" "$ROOT/lib" "$ROOT/foundry.toml" "$ROOT/remappings.txt" "$TMP/"
cp "$TMP/src/BlazePhoenixCore.sol" "$TMP/core.orig"
TSV="$TMP/sizes.tsv"
printf 'n\tcontract\truntime\n' > "$TSV"
for n in $(seq 0 "$MAX"); do
  cp "$TMP/core.orig" "$TMP/src/BlazePhoenixCore.sol"
  for i in $(seq 1 "$n"); do
    echo "uint256 constant ZZ_LOTTERY_$i = $i;" >> "$TMP/src/BlazePhoenixCore.sol"
  done
  rm -rf "$TMP/out" "$TMP/cache"
  # forge exits 1 when a contract passes EIP-170: the table is still printed, so judge the table.
  (cd "$TMP" && FOUNDRY_PROFILE=release $FORGE build --sizes --skip test --skip script) \
    > "$TMP/build-$n.txt" 2>&1 || true
  awk -v n="$n" -F'|' '/^\| BlazePhoenix[A-Za-z]* +\|/ {
      c=$2; r=$3; gsub(/[ ,]/,"",c); gsub(/[ ,]/,"",r); print n "\t" c "\t" r }' \
    "$TMP/build-$n.txt" >> "$TSV"
  if ! grep -q "^$n	" "$TSV"; then
    echo "LOTTERY ERROR: no size table for N=$n (see $TMP/build-$n.txt with KEEP=1)"; exit 2
  fi
done
cat "$TSV"
awk -F'\t' -v limit="$LIMIT" -v spread="$SPREAD" -v max="$MAX" '
  NR == 1 { next }
  { k[$2] = 1; c[$2]++; if (!($2 in lo) || $3 < lo[$2]) lo[$2] = $3; if ($3 > hi[$2]) hi[$2] = $3
    if ($3 >= limit) { print "OVER: " $2 " = " $3 " B at N=" $1 " (limit " limit ")"; bad = 1 } }
  END {
    for (x in k) {
      printf "%-24s min %6d max %6d spread %4d\n", x, lo[x], hi[x], hi[x] - lo[x]
      if (hi[x] - lo[x] > spread) { print "SPREAD: " x " moves " hi[x] - lo[x] " B across N (tolerance " spread ")"; bad = 1 }
      if (c[x] != max + 1) { print "MISSING: " x " measured " c[x] " of " max + 1 " variants"; bad = 1 }
    }
    if (bad) exit 1
    print "No contract reaches " limit " B or moves more than " spread " B across N = 0.." max ". OK."
  }' "$TSV"
