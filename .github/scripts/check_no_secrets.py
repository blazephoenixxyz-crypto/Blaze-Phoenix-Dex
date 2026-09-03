#!/usr/bin/env python3
"""Refuse to publish infrastructure, credentials or a private address.

WHY THIS EXISTS. Everything in this repository is public the instant it is
pushed, and public is not a state you can take back: a deleted line stays in
the history, in every clone, and in whatever crawled it first. Three kinds of
string therefore must never reach a commit, and none of them is a bug the
compiler or the test suite can see:

  1. A CREDENTIAL. A token, a key, a PEM block. Rotating it afterwards is the
     only remedy, and the remedy costs whatever ran on it in the meantime.
  2. A PRIVATE ADDRESS. The verification runner these scripts drive is one
     machine on one account. Naming it here hands strangers an endpoint to
     probe, and the gate in front of it becomes the only thing between them
     and it. Address and secret are operator configuration, read from the
     environment (see mcdc.py) and never from the tree.
  3. AN OPERATOR'S ENVIRONMENT. An absolute path under /root or /home says
     who ran it and from where. It is also a script that only works on one
     machine, which is the smaller of the two problems.

And one house rule with the same shape: every address on a public surface is
a project address. A personal mailbox in a commit is a personal mailbox in
the history for ever.

The check is a second, needs no compiler, and runs before every other gate.
An exemption is allowed, but it is DECLARED — path, the exact string, and a
written reason — so the list of things we chose to publish stays readable
instead of becoming whatever the pattern happened to miss.

  python3 .github/scripts/check_no_secrets.py

Exit code: non-zero on the first undeclared hit, with the file, the line and
what matched (credentials are reported by SHAPE, never echoed).
"""
import os, re, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Mail domains a public surface may carry. The project's own, and the
# disclosure mailbox published in SECURITY.md.
MAIL_OK = ("blazephoenix.xyz", "proton.me")

# ── the patterns ────────────────────────────────────────────────────────────
# `echo` False means the finding names the shape and NOT the text: a guard that
# prints the secret it found has published it a second time, into the CI log.
RULES = [
    ("private key block", re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"), False),
    ("AWS access key id", re.compile(r"\bAKIA[0-9A-Z]{16}\b"), False),
    ("GitHub token",      re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b"), False),
    ("Slack token",       re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"), False),
    ("private runner host", re.compile(r"\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.workers\.dev\b"), True),
    # A header with a literal value. The interpolated forms — "X-CI-Token: " +
    # token, or an f-string — are how the value is supposed to arrive, so they
    # must not trip it.
    ("runner token, literal", re.compile(r"X-CI-Token:\s*(?![\"'{]|\s*\+)\S"), False),
    ("operator absolute path", re.compile(r"(?<![\w./-])/root/|(?<![\w./-])/home/[a-z_][a-z0-9_-]*/"), True),
]

# 64 hex characters is a secp256k1 private key, and also every keccak constant
# in a Solidity test. The shape only carries information where a key would
# plausibly be written down, so it is asked of configuration and scripts only.
KEYISH = re.compile(r"(?<![0-9a-fA-Fx])(?:0x)?[0-9a-fA-F]{64}(?![0-9a-fA-F])")
KEYISH_EXT = (".py", ".sh", ".bash", ".yml", ".yaml", ".toml", ".ini", ".cfg", ".env")

MAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")

TEXT_EXT = (".sol", ".py", ".sh", ".bash", ".yml", ".yaml", ".toml", ".ini", ".cfg",
            ".md", ".txt", ".json", ".js", ".ts", ".tsx", ".env",
            # the two files named after CERTORAKEY. Neither extension was listed, so the one
            # secret this scanner is most specifically about was never in the scanned set.
            ".conf", ".spec")

# Dotfiles cannot be matched by extension: os.path.splitext(".gitignore") returns ("", "") on the
# basename, so these three sat in TEXT_EXT and were never selected, and the "no dot in basename"
# fallback below misses them too because the leading dot IS a dot. Matched by name instead.
TEXT_NAMES = (".gitignore", ".gitattributes", ".editorconfig")

# ── declared exemptions ─────────────────────────────────────────────────────
# (path suffix, exact substring that may appear, why). All three are required:
# an exemption without a reason is a silencer.
ALLOW = [
    (".github/scripts/check_no_secrets.py", "AKIA",
     "This file. The patterns have to be written down somewhere to be checked."),
    (".github/scripts/check_no_secrets.py", "workers.dev",
     "As above: the pattern, not an address."),
    (".github/scripts/check_no_secrets.py", "/root/",
     "As above: the pattern, not a path."),
    (".github/scripts/check_no_secrets.py", "X-CI-Token",
     "As above: the header name the rule looks for."),
    (".github/scripts/check_no_secrets.py", "PRIVATE KEY",
     "As above: the PEM banner the rule looks for."),
    (".github/scripts/check_no_secrets.py", "xox",
     "As above."),
]


def allowed(rel, line):
    for path, needle, _why in ALLOW:
        if rel.endswith(path) and needle in line:
            return True
    return False


def tracked_files():
    # Tracked AND not-yet-tracked-but-not-ignored. In CI the two are the same
    # set; locally the second half is the one that matters, because the file
    # about to be added is exactly the file nobody has reviewed yet.
    args = [["git", "-C", REPO, "ls-files"],
            ["git", "-C", REPO, "ls-files", "--others", "--exclude-standard"]]
    out = "".join(subprocess.run(a, capture_output=True, text=True, check=True).stdout
                  for a in args)
    for rel in out.splitlines():
        if not rel:
            continue
        if rel.startswith(("lib/", "out/", "cache/")):
            continue
        base = os.path.basename(rel)
        if os.path.splitext(rel)[1] in TEXT_EXT or base in TEXT_NAMES or "." not in base:
            yield rel


def main():
    findings = []
    for rel in tracked_files():
        path = os.path.join(REPO, rel)
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        ext = os.path.splitext(rel)[1]
        for n, line in enumerate(text.splitlines(), 1):
            if allowed(rel, line):
                continue
            for name, rx, echo in RULES:
                m = rx.search(line)
                if m:
                    shown = m.group(0) if echo else "<redacted>"
                    findings.append((rel, n, name, shown))
            if ext in KEYISH_EXT and KEYISH.search(line):
                findings.append((rel, n, "32-byte key-shaped literal", "<redacted>"))
            for m in MAIL.finditer(line):
                if not m.group(1).lower().endswith(MAIL_OK):
                    findings.append((rel, n, "non-project mail domain", m.group(1)))

    for rel, n, name, shown in findings:
        print(f"SECRET {rel}:{n}  {name}  {shown}")
    if findings:
        print(f"\n{len(findings)} thing(s) that must not be published are in the tree.")
        print("Move an address or a secret to the environment (see mcdc.py), or, if it is")
        print("genuinely publishable, declare it in ALLOW with a reason.")
        return 1
    print(f"check_no_secrets: clean — no credential, private address or foreign "
          f"mail domain in the tree ({len(ALLOW)} declared exemptions).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
