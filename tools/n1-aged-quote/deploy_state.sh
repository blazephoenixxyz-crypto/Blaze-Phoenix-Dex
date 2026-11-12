#!/usr/bin/env bash
# N1 step 1: build the V2 override state per chain.
# For each chain: anvil fork at a pinned block -> N1Deploy.s.sol with a throwaway key ->
# anvil_dumpState -> <out>/<chain>.state.json (code + storage + nonce of every account the
# deployment created). The RPC key is read from $DRPC_KEY_FILE (default ~/.drpc-key) and is
# never written anywhere.
# Usage: tools/n1-aged-quote/deploy_state.sh <outdir> <chain>[:<forkblock>] ...
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath "$1"); shift
mkdir -p "$OUT"
KEY=$(tr -d ' \n' < "${DRPC_KEY_FILE:-$HOME/.drpc-key}")
export PATH="$HOME/.foundry/bin:$PATH"
PORT=${N1_ANVIL_PORT:-$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')}
cd "$ROOT"
for spec in "$@"; do
  chain=${spec%%:*}; blk=${spec#*:}; [ "$blk" = "$spec" ] && blk=""
  net=$chain
  url="https://lb.drpc.live/$net/$KEY"
  fb=()
  [ -n "$blk" ] && fb=(--fork-block-number "$blk")
  anvil --fork-url "$url" "${fb[@]}" --port "$PORT" --silent --no-rate-limit --retries 8 --timeout 60000 &
  APID=$!
  sleep 1; kill -0 $APID 2>/dev/null || { echo "anvil did not start on port $PORT"; exit 1; }
  trap 'kill $APID 2>/dev/null || true' EXIT
  for _ in $(seq 60); do cast block-number --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 1; done
  forkblk=$(cast block-number --rpc-url "http://127.0.0.1:$PORT")
  cid=$(cast chain-id --rpc-url "http://127.0.0.1:$PORT")
  PK=$(python3 -c 'import secrets;print("0x"+secrets.token_hex(32))')
  ME=$(cast wallet address --private-key "$PK")
  cast rpc --rpc-url "http://127.0.0.1:$PORT" anvil_setBalance "$ME" 0x56BC75E2D63100000 >/dev/null
  N1_CHAIN=$chain N1_PK=$PK forge script tools/n1-aged-quote/N1Deploy.s.sol --tc N1Deploy --skip test \
     --rpc-url "http://127.0.0.1:$PORT" --broadcast --slow > "$OUT/$chain.deploy.log" 2>&1 || { echo "deploy failed: $chain"; tail -20 "$OUT/$chain.deploy.log"; exit 1; }
  grep "N1ADDR" "$OUT/$chain.deploy.log" | awk '{print $2"\t"$3}' > "$OUT/$chain.addrs.tsv"
  cast rpc --rpc-url "http://127.0.0.1:$PORT" anvil_dumpState > "$OUT/$chain.dump.hex"
  python3 -I "$ROOT/tools/n1-aged-quote/extract_state.py" "$OUT/$chain.dump.hex" "$ME" "$forkblk" "$chain" \
     "$ROOT/broadcast/N1Deploy.s.sol/$cid" > "$OUT/$chain.state.json"
  rm -f "$OUT/$chain.dump.hex"
  kill $APID; wait $APID 2>/dev/null || true
  echo "ok $chain forkblock=$forkblk deployer=$ME"
done
