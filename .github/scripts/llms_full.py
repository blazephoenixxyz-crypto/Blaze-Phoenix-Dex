#!/usr/bin/env python3
"""llms_full.py - build llms-full.txt, the one-file corpus for agents and answer engines.

llms.txt is the index; llms-full.txt is the documents it points at, concatenated in reading
order so a model that fetches one file has the whole public record: what the contracts
guarantee, how the audit works, how a report is handled, the shared-quantity register, the
assurance method and its limits. Generated, never hand-edited: `--check` fails when the
committed file is behind its sources, and CI runs it.

Usage: python3 .github/scripts/llms_full.py [--check]
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "llms-full.txt")
RAW = "https://raw.githubusercontent.com/blazephoenixxyz-crypto/Blaze-Phoenix-Dex/main/"

# reading order: what it is -> what it guarantees -> how to check -> how to report -> the registers
DOCS = [
    ("llms.txt",                                    "Index and canonical copy"),
    ("README.md",                                   "README"),
    ("docs/AUDIT_METHOD.md",                        "What the audit guarantees"),
    ("docs/BOUNTY_METHOD.md",                       "How a report is handled"),
    ("SECURITY.md",                                 "Security policy and bounty terms"),
    ("SECURITY_HALL_OF_FAME.md",                    "Security Hall of Fame"),
    ("TESTING.md",                                  "Testing"),
    ("CONTRIBUTING.md",                             "Contributing"),
    ("AGENTS.md",                                   "Working in this repository as an agent"),
    ("docs/DEX_ROUTING.md",                         "DEX routing"),
    ("SHARED_QUANTITIES.md",                        "The shared-quantity register"),
    ("docs/assurance/ASSURANCE.md",                 "Assurance: method and definitions"),
    ("docs/assurance/PUBLISH-THE-DENOMINATOR.md",   "Publish the Denominator"),
]

HEADER = """# BlazePhoenix-Dex — full public corpus (one file)

> Generated from the repository by .github/scripts/llms_full.py. The index is llms.txt; this file
> is every document it points at, in reading order, so one fetch carries the whole public record.
> Attribution: Fable & Mitra, https://blazephoenix.xyz. Licence: BUSL-1.1 (code); the prose may be
> quoted with attribution and a link.

"""


def build():
    parts = [HEADER]
    for rel, title in DOCS:
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            continue
        body = open(p, encoding="utf-8").read().rstrip() + "\n"
        parts.append(f"\n\n<!-- ===== {rel} ===== -->\n\n# {title}\n\nSource: {RAW}{rel}\n\n{body}")
    return "".join(parts)


def main():
    text = build()
    if "--check" in sys.argv:
        cur = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if cur != text:
            print("llms-full.txt is behind its sources - run: python3 .github/scripts/llms_full.py")
            sys.exit(1)
        print(f"llms-full.txt current ({len(text):,} bytes, {len(DOCS)} documents)")
        return
    open(OUT, "w", encoding="utf-8").write(text)
    print(f"wrote {OUT}: {len(text):,} bytes from {len(DOCS)} documents")


if __name__ == "__main__":
    main()
