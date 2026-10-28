#!/usr/bin/env python3
"""Door prologue census for the Router (M7, 2026-10-20): every value door opens the same way.

The Router has four public doors that take a user's funds (swapExactIn, swapExactInWithPermit2,
swapExactInNative, swapBestExactIn). Their prologue is not one function: it is a set of clauses
copied into each door or into the private helper the door goes through. A1 (a zero minOut is
refused) and #45 (an inflated pull is clamped to what was asked for) were each fixed in one door
first and found missing in a sibling. Since 2026-10-28 the measured pull (PULL0, the #45 clamp and
the FOT note) is one producer, `_received`, which the three doors that pull a token reach (the two
`transferFrom` doors through `_pull`); CAP and A1 are still one copy per door. This census makes
"every door carries every clause" a tested fact instead of an accident of copying.

Pinned per door, over the door's body plus the helpers it reaches (comments stripped):
  - the modifiers `whenLive nrEntrant`;
  - CAP  `amountIn > type(uint128).max) revert RouterE(3)`  and  A1  `userMinOut == 0) revert
    RouterE(10)`, once each, both BEFORE the first pull of funds;
  - PULL0 `if (received == 0) revert RouterE(8);`, once, after the pull;
  - FOT  `if (received > amountIn) received = amountIn;` once, or 0 where CENSUS says why;
  - the terminal call: `_swap(`, `_swapPrePulled(` or the self-call into selfExecutePrePulled.
Router-wide: `_swap` and `_swapPrePulled` open with the deadline check and are the only callers
of `_execute` (whose first statement, the SELF check, frame_custody_guard.py pins);
selfExecutePrePulled opens with its self-only check; and every external function that takes a
`deadline` is a door named below. A new door, a door that loses a clause, or a second copy of
the clamp goes red until it is reviewed and the census moves with it.

Exit 0 when the census holds, 1 with ::error:: lines otherwise.
Usage: door_prologue_guard.py [router.sol]
"""
import re
import sys

ROUTER = sys.argv[1] if len(sys.argv) > 1 else "src/BlazePhoenixRouter.sol"

# door -> (functions whose bodies form its prologue, in call order; FOT copies expected, why)
DOORS = {
    "swapExactIn": (["swapExactIn", "_checkedSwap", "_swap", "_pull", "_received"], 1,
                    "clamped in _received, through _pull"),
    "swapExactInWithPermit2": (["swapExactInWithPermit2", "_received"], 1, "clamped in _received"),
    "swapExactInNative": (["swapExactInNative"], 0,
                          "no clamp: the input is msg.value wrapped by WETH.deposit, measured as "
                          "the Router's WETH balance delta; nothing is pulled from a token that "
                          "could over-deliver [inferred from WETH9's deposit, not a Router check]"),
    "swapBestExactIn": (["swapBestExactIn", "_pull", "_received"], 1, "clamped in _received, through _pull"),
}
SELF_ONLY = "selfExecutePrePulled"
DEADLINE_HELPERS = ("_swap", "_swapPrePulled")

CLAUSE = {
    "CAP": r"amountIn\s*>\s*type\(uint128\)\.max\)\s*revert\s+RouterE\(3\);",
    "A1": r"userMinOut\s*==\s*0\)\s*revert\s+RouterE\(10\);",
    "PULL0": r"if\s*\(received\s*==\s*0\)\s*revert\s+RouterE\(8\);",
    "FOT": r"if\s*\(received\s*>\s*amountIn\)\s*received\s*=\s*amountIn;",
}
PULL = re.compile(r"safeTransferFrom\(|permitTransferFrom\(|\.deposit\{")
TERMINAL = re.compile(r"\b(?:return\s+)(?:this\.selfExecutePrePulled|_swapPrePulled|_swap)\(")
DEADLINE = "if (block.timestamp > deadline) revert RouterE(4);"
SELF_CHECK = "if (msg.sender != address(this)) revert RouterE(1);"


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


code = strip_comments(open(ROUTER).read())
errors = []


def function(name):
    """(header, body) of function `name`, or (None, None)."""
    m = re.search(rf"\bfunction\s+{name}\s*\(", code)
    if not m:
        return None, None
    open_brace = code.find("{", m.end())
    depth, i = 1, open_brace + 1
    while i < len(code) and depth:
        depth += {"{": 1, "}": -1}.get(code[i], 0)
        i += 1
    return code[m.start():open_brace], code[open_brace + 1:i - 1]


def first_statement(body):
    return " ".join(body.strip().split(";")[0].split()) + ";" if body and body.strip() else ""


# --- every external function that takes a deadline is a known door ----------------------------
for m in re.finditer(r"\bfunction\s+([A-Za-z_0-9]+)\s*\(([^)]*)\)([^{;]*)\{", code):
    name, params, attrs = m.groups()
    if re.search(r"\b(external|public)\b", attrs) and re.search(r"\buint256\s+deadline\b", params):
        if name not in DOORS and name != SELF_ONLY:
            errors.append(f"Door guard: {name} is an external function that takes a deadline and is "
                          f"not in DOORS. Give it the prologue and pin it here.")

# --- per door: modifiers, clauses, order, terminal ---------------------------------------------
fot_total = 0
for door, (chain, fot_want, _why) in DOORS.items():
    header, _ = function(door)
    if header is None:
        errors.append(f"Door guard: door {door} not found; if it was renamed, the census must follow.")
        continue
    for mod in ("whenLive", "nrEntrant"):
        if not re.search(rf"\b{mod}\b", header):
            errors.append(f"Door guard: {door} has lost the `{mod}` modifier.")
    bodies = []
    for fn in chain:
        _, b = function(fn)
        if b is None:
            errors.append(f"Door guard: {door} reaches {fn}, which is gone.")
            b = ""
        bodies.append(b)
    text = "\n".join(bodies)
    pull = PULL.search(text)
    for clause, rx in CLAUSE.items():
        hits = [h.start() for h in re.finditer(rx, text)]
        want = fot_want if clause == "FOT" else 1
        if clause == "FOT":
            fot_total += len(hits)
        if len(hits) != want:
            errors.append(f"Door guard: {door} carries {clause} {len(hits)}x along {' -> '.join(chain)} "
                          f"(pinned {want}).")
            continue
        if clause in ("CAP", "A1") and pull and hits and hits[0] > pull.start():
            errors.append(f"Door guard: {door} checks {clause} after it pulls the user's funds.")
        if clause in ("PULL0", "FOT") and hits and (not pull or hits[0] < pull.start()):
            errors.append(f"Door guard: {door} checks {clause} before any pull, so it measures nothing.")
    if not pull:
        errors.append(f"Door guard: {door} pulls no funds along {' -> '.join(chain)}; the census is stale.")
    if not TERMINAL.search(text):
        errors.append(f"Door guard: {door} does not end in _swap / _swapPrePulled / selfExecutePrePulled.")

# Every copy of the clamp sits in a function some door reaches. Counted per distinct function, so
# the one producer that three doors share counts once.
clamps = len(re.findall(CLAUSE["FOT"], code))
in_doors = sum(len(re.findall(CLAUSE["FOT"], function(fn)[1] or ""))
               for fn in {f for chain, _, _ in DOORS.values() for f in chain})
if clamps != in_doors:
    errors.append(f"Door guard: the #45 clamp appears {clamps}x in the Router, {in_doors}x in functions the "
                  f"doors reach; a copy outside a door is a channel nobody pinned.")

# --- the two helpers own the deadline and are the only way into _execute -----------------------
for fn in DEADLINE_HELPERS:
    _, b = function(fn)
    if first_statement(b) != DEADLINE:
        errors.append(f"Door guard: {fn} does not open with `{DEADLINE}`.")
calls = [m.start() for m in re.finditer(r"(?<![\w.])(?<!function )_execute\(", code)]
owners = set()
for pos in calls:
    owner = None
    for m in re.finditer(r"\bfunction\s+([A-Za-z_0-9]+)\s*\(", code[:pos]):
        owner = m.group(1)
    owners.add(owner)
if owners != set(DEADLINE_HELPERS):
    errors.append(f"Door guard: _execute is reached from {sorted(o or '?' for o in owners)}, not only "
                  f"from {list(DEADLINE_HELPERS)}; a path that skips the deadline check.")
_, b = function(SELF_ONLY)
if first_statement(b) != SELF_CHECK or not re.search(r"\b_swapPrePulled\(", b or ""):
    errors.append(f"Door guard: {SELF_ONLY} must open with `{SELF_CHECK}` and go through _swapPrePulled.")

if errors:
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1)
print(f"door prologue census: {len(DOORS)} doors, each with whenLive+nrEntrant, CAP and A1 before the "
      f"pull, PULL0, {fot_total} door(s) through {clamps} #45 clamp(s), and the deadline in "
      f"{'/'.join(DEADLINE_HELPERS)}")
