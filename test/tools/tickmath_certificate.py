#!/usr/bin/env python3
"""TickMath certificate: BlazePhoenixCore.sqrtPriceAtTick against its definition, on every tick.

WHAT IS CERTIFIED. `sqrtPriceAtTick(t)` is meant to be sqrt(1.0001)^t * 2^96. It multiplies up to
twenty Q128 constants selected by the bits of |t|, inverts for t > 0 and rounds the Q128 ratio up to
Q96. This script, with the standard library alone and integer arithmetic only:

  constants  recomputes each of the twenty constants from the definition - the integer nearest to
             2^128 / sqrt(1.0001)^(2^i), i = 0..19 - and compares it with the table in the Core
             source. The table is DERIVED from that definition; it is not taken on trust from any
             other codebase. Exit 1 on any difference, or if the function's shape moved.
  write      walks every tick in [MIN_TICK, MAX_TICK] and writes docs/assurance/tickmath-certificate.tsv:
             the error of the integer pipeline against the true value, bracketed by exact interval
             arithmetic (P = 256 fractional bits), strict monotonicity, and four sha256 chains of the
             outputs that test/TickMathCertificate.t.sol recomputes from the compiled Core.
  check      constants + regenerates the certificate and requires it byte-identical to the committed
             one + requires the pins in test/TickMathCertificate.t.sol to be the certificate's and its
             twenty table lines to be the definition's.

THE BRIDGE TO THE BYTECODE. The walk here reimplements the pipeline in Python with the constants it
reads from the source. That the compiled function is that pipeline is not assumed: the Solidity test
recomputes, from the Core itself, the sha256 chain h = sha256(h || uint160 value) over each quarter
of the tick range and compares it with the chain written here. One output differing anywhere turns
the test red.

Run: python3 -I test/tools/tickmath_certificate.py {constants|write|check}   (about 30 s)
"""
import hashlib, os, re, sys
from math import isqrt

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CORE = os.path.join(ROOT, "src", "BlazePhoenixCore.sol")
TSV = os.path.join(ROOT, "docs", "assurance", "tickmath-certificate.tsv")
SOL = os.path.join(ROOT, "test", "TickMathCertificate.t.sol")
MIN_TICK, MAX_TICK = -887272, 887272
P = 256  # fractional bits of the interval walk
QUARTERS = [("Q0", MIN_TICK, -443637), ("Q1", -443636, 0), ("Q2", 1, 443636), ("Q3", 443637, MAX_TICK)]
M256 = (1 << 256) - 1


def definition(i):
    """The integer nearest to 2^128 / sqrt(1.0001)^(2^i), exactly. Returns (nearest, floor)."""
    if i == 0:
        # x = 2^128 * sqrt(10000/10001), x^2 = N/D. n is nearest iff (n - 1/2)^2 <= x^2 < (n + 1/2)^2.
        N, D = (1 << 256) * 10000, 10001
        fl = isqrt(N // D)  # floor(sqrt(floor(q))) == floor(sqrt(q))
        for n in (fl, fl + 1):
            if (2 * n - 1) ** 2 * D <= 4 * N < (2 * n + 1) ** 2 * D:
                return n, fl
        raise AssertionError("no nearest integer")
    k = 1 << (i - 1)  # sqrt(1.0001)^(2^i) = 1.0001^k, a rational number
    N, D = (1 << 128) * 10000 ** k, 10001 ** k
    fl, rem = divmod(N, D)
    assert 2 * rem != D  # never a tie: D is odd
    return fl + (1 if 2 * rem > D else 0), fl


LINE0 = re.compile(r"uint256 r = a & 0x1 != 0 \? (0x[0-9a-f]+) : 0x100000000000000000000000000000000;")
LINEI = re.compile(r"if \(a & (0x[0-9a-f]+) != 0\) r = \(r \* (0x[0-9a-f]+)\) >> 128;")
TAIL = ["if (tick > 0) r = type(uint256).max / r;",
        "return uint160((r >> 32) + (r % (1 << 32) == 0 ? 0 : 1));"]


def core_table():
    """The twenty constants as the Core source writes them. Any change of shape is a failure: the
    certificate describes this pipeline and no other."""
    src = open(CORE).read()
    i = src.index("function sqrtPriceAtTick(int24 tick)")
    body = [l.strip() for l in src[i:src.index("\n    }\n", i)].splitlines()]
    body = [l for l in body if l and not l.startswith("//")]
    want_head = ["function sqrtPriceAtTick(int24 tick) internal pure returns (uint160) {",
                 "uint256 a = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));",
                 'require(a <= uint256(int256(V4_MAX_TICK)), "BPC:tick");']
    if body[:3] != want_head or body[-2:] != TAIL or len(body) != 3 + 20 + 2:
        sys.exit("sqrtPriceAtTick changed shape: the certificate no longer describes it")
    m = LINE0.fullmatch(body[3])
    if not m:
        sys.exit("sqrtPriceAtTick: the bit-0 line changed shape")
    table = [int(m.group(1), 16)]
    for j, l in enumerate(body[4:23], 1):
        m = LINEI.fullmatch(l)
        if not m or int(m.group(1), 16) != 1 << j:
            sys.exit(f"sqrtPriceAtTick: the line for bit {j} changed shape: {l}")
        table.append(int(m.group(2), 16))
    if not re.search(r"int24\s+internal constant V4_MAX_TICK =\s+887_272;", src):
        sys.exit("V4_MAX_TICK moved: the certificate covers [-887272, 887272]")
    return table


def constants():
    table, bad, rows = core_table(), 0, []
    for i, c in enumerate(table):
        near, fl = definition(i)
        rows.append((i, near, "floor" if near == fl else "floor+1", c == near))
        if c != near:
            bad += 1
            print(f"bit {i}: Core 0x{c:x} != definition 0x{near:x}")
    if bad:
        sys.exit(f"{bad}/20 constants are not the integer nearest to 2^128/sqrt(1.0001)^(2^i)")
    print("20/20 constants are the integer nearest to 2^128/sqrt(1.0001)^(2^i)")
    return rows


def sqrt_price(t, C):
    a = -t if t < 0 else t
    r = C[0] if a & 1 else 1 << 128
    for i in range(1, 20):
        if a >> i & 1:
            r = (r * C[i]) >> 128
    if t > 0:
        r = M256 // r
    return (r >> 32) + (1 if r & 0xFFFFFFFF else 0)


class Ticks(list):
    """ours(t) for t in [MIN_TICK, MAX_TICK], indexed by the tick itself."""

    def __init__(self, v0):
        super().__init__([0] * (MAX_TICK - MIN_TICK + 1))
        self[0] = v0

    def __getitem__(self, t):
        return list.__getitem__(self, t - MIN_TICK)

    def __setitem__(self, t, v):
        list.__setitem__(self, t - MIN_TICK, v)


def certify(C):
    """Exhaustive walk. lo <= 2^P * 2^96 * sqrt(1.0001)^t <= hi, stepped from t = 0 outwards with
    the step factor bracketed from both sides; err(t) = ours - true lies in [ours*2^P - hi, ours*2^P - lo] / 2^P."""
    out = Ticks(sqrt_price(0, C))
    s = {}
    for sign in (-1, 1):
        f_lo = isqrt((10001 if sign > 0 else 10000) * (1 << (2 * P)) // (10000 if sign > 0 else 10001))
        f_hi = f_lo + 1  # the factor is irrational, so it lies strictly inside [f_lo, f_lo + 1)
        lo = hi = 1 << (96 + P)
        st = dict(ceil_exact=0, below=0, last_within=None, first_out=None, max_err=0, max_err_tick=None,
                  rel_k=10 ** 9, rel_tick=None, ndet=0)
        for a in range(1, MAX_TICK + 1):
            lo = (lo * f_lo) >> P
            hi = -((-hi * f_hi) >> P)
            t = sign * a
            v = sqrt_price(t, C)
            out[t] = v
            V = v << P
            if lo >> P != hi >> P:
                st["ndet"] += 1  # the bracket straddles an integer: floor(true) undetermined
            fl = lo >> P
            if v == fl + 1:
                st["ceil_exact"] += 1
            if v <= fl:
                st["below"] += 1
            m = max(abs(V - lo), abs(V - hi))  # |err| * 2^P, upper bound
            if m < 1 << P:
                if st["first_out"] is None:
                    st["last_within"] = t
            elif st["first_out"] is None:
                st["first_out"] = t
            if m > st["max_err"]:
                st["max_err"], st["max_err_tick"] = m, t
            k = (lo.bit_length() - 1) - m.bit_length()  # m < 2^bitlen(m) <= 2^-k * lo  =>  rel < 2^-k
            if k < st["rel_k"]:
                st["rel_k"], st["rel_tick"] = k, t
        s[sign] = st
    mono = all(out[t] < out[t + 1] for t in range(MIN_TICK, MAX_TICK))
    chains = []
    for name, a, b in QUARTERS:
        h = b"\x00" * 32
        for t in range(a, b + 1):
            h = hashlib.sha256(h + out[t].to_bytes(20, "big")).digest()
        chains.append((name, a, b, "0x" + h.hex()))
    return out, s, mono, chains


def definition_lines():
    """The twenty lines of the table as the definition writes them: test/TickMathCertificate.t.sol
    requires each, verbatim, in the Core source (a constant can move without moving any output)."""
    L = [f"uint256 r = a & 0x1 != 0 ? 0x{definition(0)[0]:x} : 0x100000000000000000000000000000000;"]
    L += [f"if (a & 0x{1 << i:x} != 0) r = (r * 0x{definition(i)[0]:x}) >> 128;" for i in range(1, 20)]
    return L


def preregistered():
    ts = {0, MIN_TICK, MIN_TICK + 1, MAX_TICK - 1, MAX_TICK}
    for k in range(20):
        ts |= {1 << k, -(1 << k)}
    for k in (4, 8, 12, 16, 19):
        ts |= {(1 << k) - 1, -((1 << k) - 1)}
    return sorted(ts)


def render():
    rows = constants()
    C = core_table()
    out, s, mono, chains = certify(C)
    neg, pos = s[-1], s[1]
    L = ["# tickmath-certificate.tsv - generated by test/tools/tickmath_certificate.py write; do not edit by hand.",
         "# Subject: BlazePhoenixCore.sqrtPriceAtTick on every tick of [-887272, 887272] (1774545 ticks).",
         "# true(t) = 2^96 * sqrt(1.0001)^t, bracketed by exact integer interval arithmetic with 256 fractional bits;",
         "# err(t) = ours(t) - true(t) in units of 2^-96 (ulp Q96).",
         "kind\tkey\tvalue\tnote"]
    for i, near, rnd, eq in rows:
        L.append(f"constant\tbit{i}\t0x{near:x}\tnearest integer to 2^128/sqrt(1.0001)^(2^{i}) ({rnd}); equals Core: {'yes' if eq else 'NO'}")
    undet = neg["ndet"] + pos["ndet"]
    L += [f"claim\tmonotone\t{'strict' if mono else 'BROKEN'}\tours(t) < ours(t+1) for every t in [-887272, 887271]",
          f"claim\tbracket_resolved\t{1774544 - undet}/1774544\tticks t != 0 whose bracket fixes floor(true)",
          f"claim\ttick0\t{out[0]}\tours(0) == 2^96 exactly: {'yes' if out[0] == 1 << 96 else 'NO'}",
          f"claim\tneg_rounded_up\t{neg['ceil_exact']}/887272\tt < 0 with ours == ceil(true), i.e. 0 < err < 1 ulp",
          f"claim\tneg_max_err_ulp\t<1\tlargest |err| for t < 0 at t={neg['max_err_tick']}",
          f"claim\tpos_within_1ulp_through\t{pos['last_within']}\tevery t in [0, this] has |err| < 1 ulp",
          f"claim\tpos_first_err_ge_1ulp\t{pos['first_out']}\tfirst t > 0 with |err| >= 1 ulp (upper bound of the bracket)",
          f"claim\tpos_rounded_up\t{pos['ceil_exact']}/887272\tt > 0 with ours == ceil(true)",
          f"claim\tpos_below_true\t{pos['below']}/887272\tt > 0 with ours <= floor(true)",
          f"claim\tpos_max_err_ulp_lt\t2^{pos['max_err'].bit_length() - P}\tlargest |err| for t > 0, at t={pos['max_err_tick']}",
          f"claim\tpos_max_err_ulp\t{pos['max_err'] >> P}\tfloor of the bracket's upper bound on |err| at t={pos['max_err_tick']}",
          f"claim\tneg_rel_err_lt\t2^-{neg['rel_k']}\t|err|/true for every t < 0 (tightest at t={neg['rel_tick']}; 1 ulp at the bottom of the range)",
          f"claim\tpos_rel_err_lt\t2^-{pos['rel_k']}\t|err|/true for every t > 0 (tightest at t={pos['rel_tick']})"]
    for name, a, b, h in chains:
        L.append(f"chain\t{name}\t{h}\tsha256 chain h = sha256(h || uint160 ours(t)) from 0x00..00 over t in [{a}, {b}]")
    for t in preregistered():
        L.append(f"tick\t{t}\t{out[t]}\t")
    return "\n".join(L) + "\n", out, chains


def check():
    text, out, chains = render()
    if not os.path.exists(TSV) or open(TSV).read() != text:
        sys.exit("docs/assurance/tickmath-certificate.tsv is not what the certificate produces: run `write`")
    sol = open(SOL).read()
    for name, a, b, h in chains:
        if not re.search(rf"bytes32 internal constant CHAIN_{name} = {h};", sol):
            sys.exit(f"test/TickMathCertificate.t.sol: CHAIN_{name} is not the certificate's {h}")
    pins = [(int(t), int(v)) for t, v in re.findall(r"_pin\((-?\d+), (\d+)\);", sol)]
    want = [(t, out[t]) for t in preregistered()]
    if pins != want:
        sys.exit("test/TickMathCertificate.t.sol: the pinned ticks are not the certificate's")
    if re.findall(r'_table\("([^"]+)"\);', sol) != definition_lines():
        sys.exit("test/TickMathCertificate.t.sol: the table lines are not the definition's")
    print(f"certificate current: {len(chains)} chains, {len(pins)} pinned ticks and 20 table lines match")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "constants":
        constants()
    elif cmd == "write":
        text, out, chains = render()
        open(TSV, "w").write(text)
        print(text, end="")
        for t in preregistered():
            print(f"        _pin({t}, {out[t]});")
        for l in definition_lines():
            print(f'        _table("{l}");')
    elif cmd == "check":
        check()
    else:
        sys.exit(__doc__)
