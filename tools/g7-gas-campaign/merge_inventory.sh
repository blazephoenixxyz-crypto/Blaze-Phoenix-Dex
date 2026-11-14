#!/usr/bin/env bash
# Merge per-chain inventory outputs (g7/inv/<chain>/X.tsv) into g7/X.tsv, header once.
# Built in a temp dir and moved into place at the end, so a reader waiting on g7/inventory.tsv
# never sees a partial or pre-refinalize file.
set -euo pipefail
D=${1:-/home/blaze/reports/selar-1112/g7}
T=$(mktemp -d "$D/.merge.XXXX")
for f in inventory tokens venues scan_log; do
  ls "$D"/inv/*/"$f".tsv >/dev/null 2>&1 || continue
  awk 'FNR==1 && NR!=1 {next} {print}' "$D"/inv/*/"$f".tsv > "$T/$f.tsv"
  echo "$f: $(($(wc -l < "$T/$f.tsv") - 1)) rows from $(ls "$D"/inv/*/"$f".tsv | wc -l) chains"
done
# gate_top3 only in gate families + virtual label (runs started before finalize() marked every family)
python3 -I "$(dirname "$0")/inventory.py" --refinalize "$T/inventory.tsv"
echo "inventory: refinalized (gate_top3 rows: $(awk -F'\t' 'NR>1 && $18 ~ /gate_top3/' "$T/inventory.tsv" | wc -l))"
for f in scan_log tokens venues inventory; do [ -f "$T/$f.tsv" ] && mv "$T/$f.tsv" "$D/$f.tsv"; done
rm -rf "$T"
