# Certora formal verification

Top of the formal ladder (SMTChecker → Halmos → Kontrol → **Certora**).

## Current proofs
- **`specs/EffV4Fee.spec`** — INV-20 (V4-FEE-MEASURED) fail-closed guarantees on
  `effV4Fee`, via `harness/EffV4FeeHarness.sol`. Proves the dynamic-fee sentinel
  can never survive as a usable fee, a non-zero protocolFee always fails closed
  to `>= 1e6`, and a live pool prices from the measured slot0 `lpFee`. Runs in
  `.github/workflows/security.yml` (job `certora`), gated on the `CERTORAKEY`
  repo secret — the job skips gracefully until the key is set.

## Run locally
```
pip install certora-cli solc-select
solc-select install 0.8.36 && solc-select use 0.8.36
export CERTORAKEY=<your key>
certoraRun certora/conf/effv4fee.conf
```

## Expansion queue (verify-before-claim)
Add rules on the external surface as harnesses are built: BP-04 (`swapExactIn`
reverts on `userMinOut==0 && amountIn>0`), the Router holds-nothing invariant,
`outV3` monotonicity, and the iron-floor bound. Assembly / transient-storage
paths (extsload, the reentrancy `tstore`) need munging or summaries — add those
deliberately, not blindly.
