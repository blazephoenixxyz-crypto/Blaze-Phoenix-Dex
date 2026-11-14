# G8: isolated per-pool and bridge cases (quote + execution, moonslot vs Discovery)

Every case seeds ONE pool (or the two hop pools of a forced bridge) and measures the quote and
the execution of the G7 runner over it, in every mode (D, the moonslot ages, the forced ages),
both directions, three amounts (balance // 10^5, 10^3, 10^1). The cases are pre-registered
in `spec.json` / `prereg/` before any measurement; `results.tsv` carries chain, label (tree
commit), block, tokens, amount, mode, calldata segments and gas by segment, so every row can
be redone with the command below.

Files: `build_cases.py` (cases from the G7 inventory and spec), `bridges.tsv` (the bridges of
each chain, read in the deploy scripts: `source` column), `g8.py` (runner and report over
`../g7-gas-campaign/g7.py`), `test_g8.py` + `mutants_g8.py` (offline tests, one mutant each),
`spec.json` + `prereg/{strata,not_covered}.tsv` (the pre-registration).

## Run it with your own RPC

The runner reads the dRPC key from `$DRPC_KEY_FILE` (default `~/.drpc-key`) and builds
`https://lb.drpc.live/<chain>/<key>`; the key is never printed or written. With your own node,
`G7_RPC_URL_<CHAIN>` (e.g. `G7_RPC_URL_BASE=http://127.0.0.1:8545`) replaces that URL and the
key file is not read for that chain. Otherwise put your own key in a 0600 file:

```sh
umask 077; printf '%s' "<your dRPC key>" > ~/.drpc-key
export DRPC_KEY_FILE=~/.drpc-key
D=tools/g8-pool-tests; G7=tools/g7-gas-campaign
pip install requests==2.32.3

# offline: tests and mutants (no RPC, no key)
python3 -I "$D/test_g8.py"
python3 -I "$D/mutants_g8.py"

# offline: rebuild the cases from the G7 inventory (<g7dir>/inventory.tsv) and spec
python3 -I "$D/build_cases.py" build <g7dir> "$G7/spec.json" "$D" --bridges "$D/bridges.tsv" --pairs "$D/pair_tokens.tsv"

# measure one chain (seed = the G7 seed; -j 2 keeps the RPC within its rate)
python3 -I "$D/g8.py" measure "$D/spec.json" "$G7/state" out/results-base.tsv "$(cat "$G7/seed.txt")" -j 2 --chains base

# report: the G7 tables, one line per (chain, stratum, mode), the split per (ms_case, segment)
python3 -I "$D/g8.py" report "$D/spec.json" out/results-base.tsv > out/report-base.tsv
```

CI: `.github/workflows/g8-pool-tests.yml` (dispatch only, one leg per chain, the key from
`secrets.DRPC_KEY` masked and never uploaded; the offline job runs the tests and the mutants).

## Reading the results

* Absent is not zero. A chain without a bridge in `bridges.tsv`, a pair without a pool, a
  gate pool without a G7 wrapper or a pool without a measured balance is a `not_covered` row
  with its reason, never an empty case. A row with `outcome != ok` (noquote, revert, rpc_err,
  timeout) is published with the reason, not dropped; the per-case lines count every outcome.
* Failures are published: the report job runs even when a leg failed, and a leg with zero
  rows is red.
* `bridges.tsv` provenance: base/optimism/arbitrum from `G7Deploy.s.sol` (`_base`,
  `_optimism`, `_arbitrum`: WETH, USDC, wstETH); robinhood WETH, USDG, VIRTUAL (`_robinhood`;
  VIRTUAL `0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31` is the pool token of the G7 inventory,
  added on 13/11, so `state/robinhood.state.json` must be rebuilt with `deploy_state.sh` before
  the robinhood bridge cases are measured); avalanche and bsc
  from `G7DeployAvax.s.sol` / `G7DeployBsc.s.sol`; ethereum WETH, USDC, USDT added to
  `G7Deploy.s.sol:_ethereum` and `prereg/wiring.tsv` on 13/11, so `state/ethereum.state.json`
  must be rebuilt with `deploy_state.sh` before the ethereum bridge cases are measured.
* `pair_tokens.tsv`: tokens that get the exotic -> bridge cases (`xb-pair-<bridge>-<token>`)
  without being bridges. Base VIRTUAL `0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b` comes from
  the site token list (`src/config/tokens.ts:77`); the Base bridges stay WETH, USDC, wstETH.
