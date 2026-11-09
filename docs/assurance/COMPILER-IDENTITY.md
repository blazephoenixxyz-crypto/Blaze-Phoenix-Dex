# Compiler identity and bug exposure (solc 0.8.36, release settings)

The suite is evidence about ONE binary: solc 0.8.36, via-IR, optimizer on, 200 runs, cancun,
`bytecode_hash = "none"` (`foundry.toml`, held there by `.github/scripts/assurance/profile_parity.py`).
This page answers two questions before any compiler bump: which shipped runtimes the next
compiler would change, and which known compiler bugs the current one carries under these settings.

## 1. What a bump would move (runtime identity modulo relocation)

Tool: `.github/scripts/assurance/solc_identity.py` (`compile <version> <dir>`, then `matrix <dirA> <dirB>`;
`--self-test` proves each verdict on one-thing mutants: an opcode, a constant, a CBOR byte, a moved
jump target). IDENTICAL = same bytes once the CBOR tail is stripped; CHANGED = instruction blocks
and/or constants that are not relocated jump targets.

Measured 2026-11-09 on the runtimes the morf-1106 compiler lens built at DEX cb1d7d9 (the tool
reproduces the lens's own table on all 26 pairs it held):

| contract | 0.8.36 -> 0.8.37 | 0.8.37 -> 0.8.38 |
|---|---|---|
| BlazePhoenixCore | IDENTICAL | CHANGED (1 block, 1 constant) |
| BlazePhoenixGate | CHANGED (1 block, 0 constants) | CHANGED (3 blocks, 66 constants) |
| BlazePhoenixGateWrapper | IDENTICAL | CHANGED (1 block, 1 constant) |
| BlazePhoenixHub | CHANGED (9 blocks, 0 constants) | CHANGED (1 block, 1 constant) |
| BlazePhoenixMath | CHANGED (127 blocks, 31 constants) | CHANGED (1 block, 1 constant) |
| BlazePhoenixQuoter | IDENTICAL | CHANGED (1 block, 1 constant) |
| BlazePhoenixRouter | CHANGED (13 blocks, 28 constants) | CHANGED (1 block, 29 constants) |
| BlazePhoenixSolver | IDENTICAL | CHANGED (1 block, 1 constant) |
| BlazePhoenixAdapterBalancerV2 | CHANGED (6 blocks, 0 constants) | CHANGED (1 block, 1 constant) |
| BlazePhoenixAdapterBalancerV3 | CHANGED (6 blocks, 0 constants) | CHANGED (1 block, 1 constant) |
| BlazePhoenixAdapterCurveCryptoNG | IDENTICAL | CHANGED (1 block, 1 constant) |
| BlazePhoenixAdapterCurveNG | IDENTICAL | CHANGED (1 block, 1 constant) |

Reading: no bump is free. 0.8.37 rewrites the Math library (127 instruction blocks) and the Router;
0.8.38 touches every runtime. A bump is a new binary: the full suite, the n-version lane and the
size snapshot run again on it, and WRAPPER_INIT_HASH moves with the Gate (pinned in
`test/BlazePhoenixGate.t.sol`).

## 2. Known solc bugs in 0.8.36 (solidity `bugs_by_version.json`, 0.8.36 released 2026-07-09)

| bug | severity | fixed in | condition | release settings meet it? | the code |
|---|---|---|---|---|---|
| YulOptimizerKnowledgeBaseStaleBookkeeping | low | 0.8.38 | Yul optimizer on | yes | not evaluated: a reassigned variable computing two coinciding memory/storage addresses |
| MisorderedNamedParametersInRequireWithCustomErrors | very low | 0.8.37 | via-IR | yes | not exposed: no `require(cond, Error({...}))` in src/ (grep, 0 hits) |
| MemoryByteArrayElementDeleteClearsWholeWord | low/medium | 0.8.37 | legacy pipeline (via-IR off) | no (via-IR on) | not exposed by settings |
| SpillSlotCollisionAcrossMutualRecursion | low/medium | 0.8.37 | via-IR, mutual recursion, stack limit evader | yes | not evaluated: needs the call graph of every via-IR unit |

0.8.37 still carries the first; 0.8.38 lists none. The two "not evaluated" rows are open work
for whoever proposes the bump, not a clearance.
