#!/usr/bin/env python3
"""Is the binary another compiler would emit the binary we tested? Runtime identity modulo relocation.

The suite is evidence about one compiler's output (profile_parity.py pins it). A compiler bump is a
new binary, and the question before taking one is what moved: nothing (identical), only where
code sits (the same instructions, jump targets shifted), or the instructions themselves. Size
alone cannot tell; this tool answers per contract.

Method (ported from the morf-1106 compiler lens, tools/bcdiff.py):
 1. strip the CBOR metadata tail (its length is the last 2 bytes; it carries the solc version);
 2. disassemble both runtimes, PUSH immediates kept; unlinked library placeholders read as zero;
 3. align the two opcode sequences (difflib, no autojunk): every non-equal block is an
    instruction change;
 4. inside equal blocks map A's instruction offsets to B's; a PUSH immediate that differs counts as
    a constant change unless it is an A offset whose mapped B offset is the B immediate (a jump
    target the alignment relocated).
Verdict: IDENTICAL (bytes equal once CBOR is stripped), RELOCATED (no instruction block and no
constant changed, targets moved), CHANGED (instruction blocks and/or constants; counts printed).

Every file in src/ pins `pragma solidity 0.8.36;` exactly, so `compile` relaxes the pragma IN
MEMORY (the files are not touched) and builds src/ with the release settings read from
foundry.toml - only the compiler differs.

Usage: solc_identity.py compile <solc-version> <outdir> [repo_root]   -> <outdir>/<Contract>.rt.hex
       solc_identity.py diff A.rt.hex B.rt.hex
       solc_identity.py matrix <dirA> <dirB>
       solc_identity.py --self-test
"""
import difflib, json, os, re, subprocess, sys, tomllib


def strip_cbor(b):
    if len(b) < 2:
        return b
    n = int.from_bytes(b[-2:], "big")
    if 0 < n + 2 <= len(b) and b[-(n + 2)] in (0xA1, 0xA2, 0xA3):
        return b[:-(n + 2)]
    return b


def disasm(b):
    out, i = [], 0
    while i < len(b):
        op = b[i]
        if 0x60 <= op <= 0x7F:
            k = op - 0x5F
            out.append((i, op, int.from_bytes(b[i + 1:i + 1 + k].ljust(k, b"\x00"), "big")))
            i += 1 + k
        else:
            out.append((i, op, None))
            i += 1
    return out


def load_hex(h):
    h = h.strip()
    h = h[2:] if h.startswith("0x") else h
    return strip_cbor(bytes.fromhex(re.sub(r"__\$[0-9a-fA-F]{34}\$__", "0" * 40, h)))


def compare(a_bytes, b_bytes):
    """(verdict, blocks, instrA, instrB, constants) for two CBOR-stripped runtimes."""
    if a_bytes == b_bytes:
        return "IDENTICAL", 0, 0, 0, 0
    A, B = disasm(a_bytes), disasm(b_bytes)
    ops = difflib.SequenceMatcher(None, [x[1] for x in A], [x[1] for x in B], autojunk=False).get_opcodes()
    offmap, blocks, da, db = {}, 0, 0, 0
    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            for k in range(i2 - i1):
                offmap[A[i1 + k][0]] = B[j1 + k][0]
        else:
            blocks, da, db = blocks + 1, da + i2 - i1, db + j2 - j1
    consts = 0
    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            for k in range(i2 - i1):
                a, b = A[i1 + k], B[j1 + k]
                if a[2] is not None and a[2] != b[2] and offmap.get(a[2]) != b[2]:
                    consts += 1
    return ("RELOCATED" if blocks == 0 and consts == 0 else "CHANGED"), blocks, da, db, consts


def fmt(name, r):
    v, blocks, da, db, consts = r
    return f"{name}\t{v}\tblocks={blocks}\tinstrA={da}\tinstrB={db}\tconstants={consts}"


def solc_path(v):
    for p in (os.environ.get("SOLC", ""), f"~/.local/share/svm/{v}/solc-{v}", f"~/solc-bin/{v}/solc-{v}"):
        if p and os.path.exists(os.path.expanduser(p)):
            return os.path.expanduser(p)
    sys.exit(f"solc {v} not found (set SOLC, or install it with svm)")


def compile_src(version, outdir, root):
    rel = tomllib.load(open(os.path.join(root, "foundry.toml"), "rb"))["profile"]["release"]
    opt = {"enabled": bool(rel.get("optimizer", False)), "runs": int(rel.get("optimizer_runs", 200))}
    if "optimizer_details" in rel:
        d = rel["optimizer_details"]
        opt["details"] = {"yul": d.get("yul", True), "yulDetails": d.get("yulDetails", {})}
    meta = {"bytecodeHash": rel.get("bytecode_hash", "ipfs")}
    if "cbor_metadata" in rel:
        meta["appendCBOR"] = bool(rel["cbor_metadata"])
    sources = {}
    for dp, _, fs in os.walk(os.path.join(root, "src")):
        for f in sorted(fs):
            if f.endswith(".sol"):
                p = os.path.join(dp, f)
                text = re.sub(r"pragma solidity [^;]+;", "pragma solidity >=0.8.0;", open(p).read(), count=1)
                sources[os.path.relpath(p, root)] = {"content": text}
    remaps = [l.strip() for l in open(os.path.join(root, "remappings.txt"))] if os.path.exists(os.path.join(root, "remappings.txt")) else []
    settings = {"optimizer": opt, "viaIR": bool(rel.get("via_ir", False)), "evmVersion": rel.get("evm_version", "cancun"),
                "metadata": meta, "remappings": [r for r in remaps if r],
                "outputSelection": {"*": {"*": ["evm.deployedBytecode.object"]}}}
    r = subprocess.run([solc_path(version), "--standard-json", "--base-path", root, "--allow-paths", root],
                       input=json.dumps({"language": "Solidity", "sources": sources, "settings": settings}),
                       capture_output=True, text=True, cwd=root)
    out = json.loads(r.stdout)
    errs = [e for e in out.get("errors", []) if e.get("severity") == "error"]
    if errs:
        sys.exit("\n".join(e.get("formattedMessage", str(e))[:400] for e in errs[:5]))
    os.makedirs(outdir, exist_ok=True)
    n = 0
    for unit, cs in sorted(out["contracts"].items()):
        for name, c in sorted(cs.items()):
            rt = c["evm"]["deployedBytecode"]["object"]
            if rt:
                open(os.path.join(outdir, name + ".rt.hex"), "w").write(rt)
                n += 1
    print(f"solc {version}: {n} runtimes in {outdir}")


def self_test():
    """Synthetic runtime: each one-thing mutant must get the verdict the method promises."""
    cbor = bytes.fromhex("a164736f6c6343000824000a")
    def prog(extra=b"", const=0x1234, op=0x01, target=None):
        head = bytes([0x60, 0x80, 0x60, 0x40, 0x52])             # PUSH1 80 PUSH1 40 MSTORE
        body_pre = bytes([0x61, 0, 0, 0x56, 0x00]) + extra      # PUSH2 <target> JUMP STOP <extra>
        tgt = len(head) + len(body_pre) if target is None else target
        jd = bytes([0x5B, 0x60, 0x01, 0x60, 0x02, op, 0x61]) + const.to_bytes(2, "big") + bytes([0x00])
        code = head + bytes([0x61]) + tgt.to_bytes(2, "big") + body_pre[3:] + jd
        return code + cbor
    base = prog()
    flipped = bytearray(base); flipped[-5] ^= 0xFF
    cases = {
        "M0 none -> IDENTICAL": (base, lambda r: r[0] == "IDENTICAL"),
        "M1 ADD->SUB -> CHANGED (instruction)": (prog(op=0x03), lambda r: r[0] == "CHANGED" and r[1] >= 1),
        "M2 CBOR byte flipped -> IDENTICAL": (bytes(flipped), lambda r: r[0] == "IDENTICAL"),
        "M3 constant +7 -> CHANGED (constant)": (prog(const=0x1234 + 7), lambda r: r[0] == "CHANGED" and r[4] >= 1),
        "M4 code inserted, jump target relocated -> no constant": (prog(extra=bytes([0x5F, 0x50])),
                                                                 lambda r: r[0] == "CHANGED" and r[1] == 1 and r[4] == 0),
        "M5 jump target NOT relocated -> constant": (prog(extra=bytes([0x5F, 0x50]), target=11),
                                                    lambda r: r[4] >= 1),
    }
    bad = []
    for name, (mut, ok) in cases.items():
        r = compare(load_hex(base.hex()), load_hex(mut.hex()))
        if not ok(r):
            bad.append(f"{name}: got {fmt('', r).strip()}")
    for b in bad:
        print(f"::error::solc identity self-test: {b}")
    print(f"solc identity self-test: {len(cases)} cases, {len(cases) - len(bad)} classified as they must be")
    sys.exit(1 if bad else 0)


def main():
    a = sys.argv[1:]
    if a[:1] == ["--self-test"]:
        self_test()
    if a[:1] == ["compile"] and len(a) >= 3:
        return compile_src(a[1], a[2], a[3] if len(a) > 3 else ".")
    if a[:1] == ["diff"] and len(a) == 3:
        return print(fmt(os.path.basename(a[2]), compare(load_hex(open(a[1]).read()), load_hex(open(a[2]).read()))))
    if a[:1] == ["matrix"] and len(a) == 3:
        names = sorted(f[:-7] for f in os.listdir(a[1]) if f.endswith(".rt.hex") and os.path.exists(os.path.join(a[2], f)))
        for n in names:
            print(fmt(n, compare(load_hex(open(os.path.join(a[1], n + ".rt.hex")).read()),
                                 load_hex(open(os.path.join(a[2], n + ".rt.hex")).read()))))
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
