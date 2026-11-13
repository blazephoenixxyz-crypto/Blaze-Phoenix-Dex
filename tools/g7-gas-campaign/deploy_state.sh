#!/usr/bin/env bash
# G7 step 1: build the V2 override state of one chain (method of tools/n1-aged-quote/deploy_state.sh).
#
#   deploy_state.sh <tree> <outdir> <chain> <forkblock> <prereg_dir>
#   deploy_state.sh --accept-fams <chain> "<prereg families>"   (prints the accept list; tested)
#   deploy_state.sh --tx-flags                                   (prints the broadcast flags; tested)
#
# <tree>      source tree to build from: the selar-G7 worktree (base, optimism, arbitrum,
#             robinhood, ethereum), a worktree of avax-adapters-1106 (avalanche) or of
#             bsc-infinity-1106 (bsc). The G7 scripts are copied into <tree>/tools/g7-gas-campaign/.
# <forkblock> a block BEFORE every sampled block (spec.json "state_fork"): every row the wiring
#             writes is stamped with the anvil clock, and Solver._registryFresh computes
#             block.timestamp - lastUpdateTs checked, so a stamp later than a measured block
#             would panic (0x11). The runner refuses a draw with ts(b - age) <= stateTs.
# <prereg_dir> holds wiring.tsv (rows added by cast: ethereum), gate_adapters.tsv and
#             gate_wrappers.tsv (the pre-registered gates stratum). Rows of other chains are ignored.
#
# Steps: anvil fork -> phase A (forge script: stack + Gate + wiring of the repo's tests) ->
# extra wiring rows (cast) -> gate adapters (forge create + proposeAdapter) -> clock +48 h
# (ADAPTER_DELAY) -> acceptAdapter -> Gate.create per wrapper row (dry-run first: a row the
# adapter refuses is skipped and logged, never broadcast) -> Hub row of the Gate (KIND_EXTERNAL,
# MODE_CREATE2_V3, WRAPPER_INIT_HASH, the venue keys used) -> anvil_dumpState -> extract_state.py.
# Outputs in <outdir>: <chain>.state.json, <chain>.manifest.tsv, <chain>.gates.tsv, <chain>.deploy.log.
# The RPC key is read from $DRPC_KEY_FILE (default ~/.drpc-key) and is never written anywhere.
set -euo pipefail
# Families to accept after ADAPTER_DELAY: avalanche's phase A proposed 1..4 (LB 2.1, LB 2.2,
# Pharaoh DLMM, Algebra Integral); the prereg families (gate_adapters.tsv) come after them.
accept_fams() { local CHAIN=$1 FAMS=$2
  [ "$CHAIN" = avalanche ] && FAMS="1 2 3 4$FAMS"
  echo $FAMS; }
# Transaction flags of every forge broadcast (phase A script and the adapters' forge create):
# legacy gasPrice from the local anvil. Without it forge fills EIP-1559 fees with eth_feeHistory,
# which anvil forwards to the fork RPC while the newest block is the fork block; a public node
# refuses that past its depth limit (dRPC avalanche: "max depth 25000", fork 96488900).
TXF="--legacy"
if [ "${1:-}" = --accept-fams ]; then accept_fams "$2" "${3:-}"; exit 0; fi
if [ "${1:-}" = --tx-flags ]; then echo "$TXF"; exit 0; fi
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$(realpath "$1"); OUT=$(realpath "$2"); CHAIN=$3; FORKBLK=$4; PRE=$(realpath "$5")
mkdir -p "$OUT"
KEY=$(tr -d ' \n' < "${DRPC_KEY_FILE:-$HOME/.drpc-key}")
export PATH="$HOME/.foundry/bin:$PATH"
PORT=${G7_ANVIL_PORT:-$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')}
L="http://127.0.0.1:$PORT"
LOG="$OUT/$CHAIN.deploy.log"; : > "$LOG"
mask() { sed -u "s#$KEY#<KEY>#g"; }
say() { echo "$*" | tee -a "$LOG"; }

mkdir -p "$TREE/tools/g7-gas-campaign"
if [ "$TREE" != "$(cd "$HERE/../.." && pwd)" ]; then
  cp "$HERE/G7Probe.sol" "$HERE"/G7Deploy*.s.sol "$TREE/tools/g7-gas-campaign/"
fi
case "$CHAIN" in
  avalanche) SCRIPT=G7DeployAvax.s.sol; TC=G7DeployAvax ;;
  bsc)       SCRIPT=G7DeployBsc.s.sol;  TC=G7DeployBsc ;;
  *)         SCRIPT=G7Deploy.s.sol;     TC=G7Deploy ;;
esac
COMMIT=$(git -C "$TREE" rev-parse HEAD)
BRANCH=$(git -C "$TREE" branch --show-current 2>/dev/null || true)

anvil --fork-url "https://lb.drpc.live/$CHAIN/$KEY" --fork-block-number "$FORKBLK" --port "$PORT" \
  --silent --no-rate-limit --retries 8 --timeout 60000 2>&1 | mask >> "$LOG" &
APID=$!
trap 'pkill -P $$ anvil 2>/dev/null || true; kill $APID 2>/dev/null || true' EXIT
for _ in $(seq 90); do cast block-number --rpc-url "$L" >/dev/null 2>&1 && break; sleep 1; done
cid=$(cast chain-id --rpc-url "$L")
forkts=$(cast block "$FORKBLK" --field timestamp --rpc-url "$L")
PK=$(python3 -I -c 'import secrets;print("0x"+secrets.token_hex(32))')
ME=$(cast wallet address --private-key "$PK")
cast rpc --rpc-url "$L" anvil_setBalance "$ME" 0x56BC75E2D63100000 >/dev/null
send() { cast send --rpc-url "$L" --private-key "$PK" "$@" >> "$LOG" 2>&1; }

# ── phase A: the repo's wiring (forge script) ──
cd "$TREE"
G7_CHAIN=$CHAIN G7_PK=$PK G7_PHASE=A forge script "tools/g7-gas-campaign/$SCRIPT" --tc "$TC" --skip test \
  --rpc-url "$L" --broadcast --slow $TXF 2>&1 | mask >> "$LOG" || { say "phase A failed: $CHAIN"; exit 1; }
grep "G7ADDR" "$LOG" | awk '{print $2"\t"$3}' > "$OUT/$CHAIN.addrs.tsv"
get() { awk -v k="$1" '$1==k{print $2}' "$OUT/$CHAIN.addrs.tsv" | tail -1; }
HUB=$(get hub); GATE=$(get gate)
RUNS="$TREE/broadcast/$SCRIPT/$cid/run-latest.json"
cp "$RUNS" "$OUT/$CHAIN.runA.json"

# ── extra wiring rows (data: prereg/wiring.tsv chain<TAB>signature<TAB>args...) ──
if [ -f "$PRE/wiring.tsv" ]; then
  while IFS=$'\t' read -r c sig args; do
    [ "$c" = "$CHAIN" ] || continue
    # shellcheck disable=SC2086
    send "$HUB" "$sig" $args || { say "wiring row failed: $sig $args"; exit 1; }
    say "wired $sig $args"
  done < "$PRE/wiring.tsv"
fi

# ── gates stratum ──
: > "$OUT/$CHAIN.gates.tsv"; echo -e "family\tadapter\tvenue_key\ttA\ttB\tpool\twrapper\tstatus" >> "$OUT/$CHAIN.gates.tsv"
FAMS=""
if [ -n "$GATE" ] && [ "$GATE" != "0x0000000000000000000000000000000000000000" ]; then
  if [ -f "$PRE/gate_adapters.tsv" ]; then
    while IFS=$'\t' read -r c fam contract args _src; do
      [ "$c" = "$CHAIN" ] || continue
      # shellcheck disable=SC2086
      a=$(forge create "$contract" --rpc-url "$L" --private-key "$PK" --broadcast $TXF \
            --constructor-args "$GATE" $args 2>&1 | mask | tee -a "$LOG" | awk '/Deployed to:/{print $3}')
      [ -n "$a" ] || { say "adapter deploy failed: $fam $contract"; exit 1; }
      send "$GATE" "proposeAdapter(uint8,address)" "$fam" "$a"
      echo -e "adapter\t$fam\t$a" >> "$OUT/$CHAIN.addrs.tsv"
      FAMS="$FAMS $fam"
    done < "$PRE/gate_adapters.tsv"
  fi
  FAMS=$(accept_fams "$CHAIN" "$FAMS")
  cast rpc --rpc-url "$L" evm_increaseTime 172801 >/dev/null; cast rpc --rpc-url "$L" evm_mine >/dev/null
  for f in $FAMS; do send "$GATE" "acceptAdapter(uint8)" "$f"; done
  KEYS=""
  if [ -f "$PRE/gate_wrappers.tsv" ]; then
    while IFS=$'\t' read -r c fam vkey ta tb hint pool _rest; do
      [ "$c" = "$CHAIN" ] || continue
      if cast call --rpc-url "$L" --from "$ME" "$GATE" "create(address,address,uint24,bytes)(address)" \
           "$ta" "$tb" "$vkey" "$hint" > "$OUT/.g7w.$$" 2>>"$LOG"; then
        wr=$(cat "$OUT/.g7w.$$")
        send "$GATE" "create(address,address,uint24,bytes)" "$ta" "$tb" "$vkey" "$hint"
        echo -e "$fam\t-\t$vkey\t$ta\t$tb\t$pool\t$wr\tcreated" >> "$OUT/$CHAIN.gates.tsv"
        echo -e "wrapper\t$vkey\t$wr" >> "$OUT/$CHAIN.addrs.tsv"
        case " $KEYS " in *" $vkey "*) ;; *) KEYS="$KEYS $vkey" ;; esac
      else
        echo -e "$fam\t-\t$vkey\t$ta\t$tb\t$pool\t-\trefused" >> "$OUT/$CHAIN.gates.tsv"
      fi
    done < "$PRE/gate_wrappers.tsv"
    rm -f "$OUT/.g7w.$$"
  fi
  if [ -n "$KEYS" ]; then
    ih=$(cast call --rpc-url "$L" "$GATE" "WRAPPER_INIT_HASH()(bytes32)")
    kl="[$(echo $KEYS | tr ' ' ',')]"
    send "$HUB" "addFactory(address,uint8,uint8,bytes32,uint24[],int24[])" "$GATE" 9 5 "$ih" "$kl" "[]"
    say "gate row keys=$kl"
  fi
fi

statets=$(cast block latest --field timestamp --rpc-url "$L")
statenum=$(cast block-number --rpc-url "$L")
cast rpc --rpc-url "$L" anvil_dumpState > "$OUT/$CHAIN.dump.hex"
awk -F'\t' '$1=="adapter"{print $3} $1=="wrapper"{print $3}' "$OUT/$CHAIN.addrs.tsv" > "$OUT/$CHAIN.extra.txt"
python3 -I "$HERE/extract_state.py" "$OUT/$CHAIN.dump.hex" "$ME" "$FORKBLK" "$CHAIN" "$OUT/$CHAIN.extra.txt" \
  "$OUT/$CHAIN.runA.json" > "$OUT/$CHAIN.state.json"
rm -f "$OUT/$CHAIN.dump.hex"
{
  echo -e "key\tvalue"
  echo -e "chain\t$CHAIN"; echo -e "chainid\t$cid"
  echo -e "tree_commit\t$COMMIT"; echo -e "tree_branch\t${BRANCH:-detached}"
  echo -e "forkBlock\t$FORKBLK"; echo -e "forkTs\t$forkts"; echo -e "stateTs\t$statets"; echo -e "stateLocalBlock\t$statenum"
  echo -e "admin\t$ME"
  awk -F'\t' '{print $1"\t"$2}' "$OUT/$CHAIN.addrs.tsv" | grep -v "^adapter\|^wrapper"
} > "$OUT/$CHAIN.manifest.tsv"
say "ok $CHAIN forkblock=$FORKBLK forkTs=$forkts stateTs=$statets admin=$ME commit=$COMMIT"
