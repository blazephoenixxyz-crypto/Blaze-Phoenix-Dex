#!/usr/bin/env bash
# Gas case study 1114: one chain, end to end, on one local anvil fork.
#
#   bash tools/gas-case-study/run.sh <chain> <gas-1114.tsv> <outdir> [--aged <gas-1114-aged.tsv>]
#        [--only-aged] [--nprime 8] [--allow-unlocked]
#   bash tools/gas-case-study/run.sh __deploy <chain> <anvil_url>   (prints the G7ADDR lines)
#
# Steps: free RAM check (>= 2500 MiB available, else exit 3) -> a free port of its own (several
# chains may run side by side) -> anvil --fork-url <real RPC> --fork-block-number <grid block>
# (killed by the EXIT/INT/TERM trap) -> one throwaway G7_PK for the whole run (the same key on
# every fork, so the deploy addresses repeat [derived: CREATE(sender, nonce)]) -> deploy
# (tools/g7-gas-campaign/G7Deploy*.s.sol through ~/jarvis/safe-forge.sh; exit 75 = busy, wait and
# retry) -> harness.py cells -> aged.py run (with --aged) -> stats.py.
# Real RPC: G7_RPC_URL_<CHAIN> if set, else dRPC with the key in ${DRPC_KEY_FILE:-~/.drpc-key};
# the URL holds a key and is never echoed (anvil's log is masked).
# --allow-unlocked: the grid is read even without its `lock` row (dry runs; for data, the owner
# decides). Exit: 0 ok, 3 not enough RAM, 1 any step failed.
#
# Local use (not a requirement): on the VPS the L6 session wraps each chain in its 3-slot
# semaphore, e.g.
#   /tmp/claude-1001/-home-blaze-cofre/7ec5bc6d-a2bc-5b80-962c-426232415b7e/scratchpad/anvil-slot.sh \
#     bash tools/gas-case-study/run.sh base docs/prereg/gas-1114.tsv /tmp/gcs/base --aged docs/prereg/gas-1114-aged.tsv
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TREE=$(cd "$HERE/../.." && pwd)
export PATH="$HOME/.foundry/bin:$PATH"
SAFE_FORGE=${SAFE_FORGE:-/home/blaze/jarvis/safe-forge.sh}
PY=(python3 -I)

forge_safe() {  # safe-forge exit 75 = not admitted (lock or RAM): wait and retry
  local rc
  while :; do
    set +e; "$SAFE_FORGE" -- forge "$@"; rc=$?; set -e
    [ "$rc" -ne 75 ] && return "$rc"
    sleep 30
  done
}

if [ "${1:-}" = "__deploy" ]; then
  [ $# -eq 3 ] || { echo "usage: $0 __deploy <chain> <anvil_url>" >&2; exit 64; }
  CHAIN=$2; L=$3
  : "${G7_PK:?export G7_PK (one throwaway key for every fork of the run)}"
  case "$CHAIN" in  # tools/g7-gas-campaign/deploy_state.sh:53-57
    avalanche) SCRIPT=G7DeployAvax.s.sol; TC=G7DeployAvax ;;
    bsc)       SCRIPT=G7DeployBsc.s.sol;  TC=G7DeployBsc ;;
    *)         SCRIPT=G7Deploy.s.sol;     TC=G7Deploy ;;
  esac
  ME=$(cast wallet address --private-key "$G7_PK")
  cast rpc --rpc-url "$L" anvil_setBalance "$ME" 0x56BC75E2D63100000 >/dev/null
  LOG=$(mktemp)
  cd "$TREE"
  if ! G7_CHAIN=$CHAIN G7_PHASE=A forge_safe script "tools/g7-gas-campaign/$SCRIPT" --tc "$TC" --skip test \
      --rpc-url "$L" --broadcast --slow --legacy > "$LOG" 2>&1; then
    tail -5 "$LOG" >&2; rm -f "$LOG"; exit 1
  fi
  grep "G7ADDR" "$LOG" || { echo "deploy: no G7ADDR line" >&2; rm -f "$LOG"; exit 1; }
  rm -f "$LOG"
  exit 0
fi

[ $# -ge 3 ] || { sed -n '2,7p' "$0" >&2; exit 64; }
CHAIN=$1; PREREG=$2; OUT=$3; shift 3
AGED=""; ONLY_AGED=0; NPRIME=8; ALLOW=()
while [ $# -gt 0 ]; do
  case "$1" in
    --aged) AGED=$2; shift 2 ;;
    --only-aged) ONLY_AGED=1; shift ;;
    --nprime) NPRIME=$2; shift 2 ;;
    --allow-unlocked) ALLOW=(--allow-unlocked); shift ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
done
[ "$ONLY_AGED" -eq 0 ] || [ -n "$AGED" ] || { echo "--only-aged needs --aged" >&2; exit 64; }

avail=$(free -m | awk '/^Mem/{print $7}')
if [ "${avail:-0}" -lt 2500 ]; then
  echo "run.sh: ${avail:-?} MiB available, need >= 2500 MiB for one anvil fork; try later (exit 3)" >&2
  exit 3
fi

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
up=$(echo "$CHAIN" | tr '[:lower:]' '[:upper:]')
var="G7_RPC_URL_$up"
if [ -n "${!var:-}" ]; then
  URL=${!var}; KEY=""
else
  KEY=$(tr -d ' \n' < "${DRPC_KEY_FILE:-$HOME/.drpc-key}")
  URL="https://lb.drpc.live/$CHAIN/$KEY"
fi
mask() { if [ -n "$KEY" ]; then sed -u "s#$KEY#<KEY>#g"; else sed -u "s#$URL#<RPC>#g"; fi; }

cd "$TREE"
if [ "$ONLY_AGED" -eq 1 ]; then
  BLOCK=$("${PY[@]}" "$HERE/aged.py" block "$CHAIN" "$AGED" "${ALLOW[@]}")
else
  BLOCK=$("${PY[@]}" "$HERE/harness.py" block "$CHAIN" "$PREREG" "${ALLOW[@]}")
fi
PORT=$("${PY[@]}" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
L="http://127.0.0.1:$PORT"

anvil --fork-url "$URL" --fork-block-number "$BLOCK" --port "$PORT" --silent --no-rate-limit \
  --retries 8 --timeout 60000 > >(mask >> "$OUT/anvil.log") 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT INT TERM
for _ in $(seq 90); do cast block-number --rpc-url "$L" >/dev/null 2>&1 && break; sleep 1; done
cast block-number --rpc-url "$L" >/dev/null 2>&1 || { echo "anvil did not answer on $L" >&2; exit 1; }

G7_PK=$("${PY[@]}" -c 'import secrets;print("0x"+secrets.token_hex(32))')
export G7_PK
date -u +"%F %T start $CHAIN block $BLOCK port $PORT" >> "$OUT/run.log"

if [ "$ONLY_AGED" -eq 0 ]; then
  bash "$HERE/run.sh" __deploy "$CHAIN" "$L" | awk '{print $(NF-1)"\t"$NF}' > "$OUT/addrs.tsv"
  ANVIL_PID=$ANVIL_PID "${PY[@]}" "$HERE/harness.py" cells "$CHAIN" "$PREREG" "$OUT" "$L" "$OUT/addrs.tsv" \
    "$BLOCK" --nprime "$NPRIME" "${ALLOW[@]}" | tee -a "$OUT/run.log"
  "${PY[@]}" "$HERE/stats.py" "$OUT/results.tsv" "$OUT/stats.tsv" --nprime "$NPRIME" | tee -a "$OUT/run.log"
fi
if [ -n "$AGED" ]; then
  "${PY[@]}" "$HERE/aged.py" run "$CHAIN" "$AGED" "$OUT" "$L" --deploy "bash $HERE/run.sh __deploy $CHAIN" \
    --nprime "$NPRIME" "${ALLOW[@]}" | tee -a "$OUT/run.log"
fi
[ -f "$HERE/market.py" ] && "${PY[@]}" "$HERE/market.py" "$CHAIN" "$PREREG" "$OUT" "$BLOCK" | tee -a "$OUT/run.log"
date -u +"%F %T done $CHAIN" >> "$OUT/run.log"
