"""A small ABI codec for the structs the gas case study reads and writes (no eth_abi dependency).

Types are nested Python values: a base type string ("address", "uint256", "int24", "bool",
"bytes32", "bytes"), ("array", T) for T[], or ("tuple", [(name, T), ...]) for a struct, decoded
to a dict in declaration order. The struct layouts are src/BlazePhoenixCore.sol:70-119 (PoolInfo,
Leg, Hop, Route, RoutePlan) and src/BlazePhoenixQuoter.sol:193-209 (Preview); a change there must
be mirrored here, and test_gcs.py pins the field order against hand-encoded words.
"""

LEG = ("tuple", [("pool", "address"), ("hooks", "address"), ("kind", "uint8"), ("fee", "uint24"),
                 ("tickSpacing", "int24"), ("zeroForOne", "bool"), ("stable", "bool"),
                 ("amountIn", "uint256"), ("expectedOut", "uint256"), ("auxId", "bytes32")])
HOP = ("tuple", [("tokenIn", "address"), ("tokenOut", "address"), ("amountIn", "uint256"),
                 ("expectedOut", "uint256"), ("legs", ("array", LEG))])
ROUTE = ("tuple", [("hops", ("array", HOP)), ("totalOut", "uint256"), ("singleOut", "uint256"),
                   ("singleOutFloor", "uint256"), ("expectedImpactBps", "uint256"),
                   ("confidenceWad", "uint256"), ("estGas", "uint256"), ("hasSurplus", "bool"),
                   ("isV4Bundle", "bool")])
PREVIEW = ("tuple", [("route", ROUTE), ("grossOut", "uint256"), ("protocolFee", "uint256"),
                     ("safetyBuffer", "uint256"), ("netOut", "uint256"), ("ironFloor", "uint256"),
                     ("userMinOut", "uint256"), ("effectiveMinOut", "uint256"), ("estGas", "uint256"),
                     ("hops", "uint256"), ("legs", "uint256"), ("topology", "uint8"),
                     ("bridgeUsed", "address"), ("canExecute", "bool")])
POOLINFO = ("tuple", [("active", "bool"), ("stable", "bool"), ("kind", "uint8"), ("fee", "uint24"),
                      ("tickSpacing", "int24"), ("token0", "address"), ("token1", "address"),
                      ("pool", "address"), ("hooks", "address")])
# Quoter.previewPlan returns (Preview pv, Route fallbackRoute, bool hasFallback): the route to
# execute is pv.route, the FIRST value. The second is the runner-up, empty when there is none.
PREVIEW_PLAN_OUT = [PREVIEW, ROUTE, "bool"]
ROUTE_EXACT_OUT = [ROUTE, "uint256"]


def _dynamic(t):
    if isinstance(t, str):
        return t in ("bytes", "string")
    if t[0] == "array":
        return True
    return any(_dynamic(ft) for _, ft in t[1])


def _head_words(t):
    """Words a static type occupies in place (a dynamic one takes one offset word)."""
    if _dynamic(t):
        return 1
    if isinstance(t, str):
        return 1
    return sum(_head_words(ft) for _, ft in t[1])


def _word(d, i):
    return int(d[64 * i:64 * i + 64], 16)


def _base_dec(t, v):
    if t == "address":
        return "0x" + format(v & ((1 << 160) - 1), "040x")
    if t == "bool":
        return v != 0
    if t.startswith("int"):
        bits = int(t[3:] or 256)
        v &= (1 << bits) - 1
        return v - (1 << bits) if v >> (bits - 1) else v
    if t == "bytes32":
        return "0x" + format(v, "064x")
    return v


def _dec(t, d, base):
    """Decode type t whose encoding starts at word `base` of hex string d (no 0x)."""
    if isinstance(t, str):
        if t == "bytes":
            n = _word(d, base)
            return "0x" + d[64 * (base + 1):64 * (base + 1) + 2 * n]
        return _base_dec(t, _word(d, base))
    if t[0] == "array":
        n = _word(d, base)
        return _dec_seq([t[1]] * n, d, base + 1)
    vals = _dec_seq([ft for _, ft in t[1]], d, base)
    return {name: v for (name, _), v in zip(t[1], vals)}


def _dec_seq(types, d, base):
    out, pos = [], base
    for t in types:
        if _dynamic(t):
            out.append(_dec(t, d, base + _word(d, pos) // 32))
            pos += 1
        else:
            out.append(_dec(t, d, pos))
            pos += _head_words(t)
    return out


def decode(types, hexdata):
    """Decode a return blob (or calldata after its selector) as the sequence `types`."""
    d = hexdata[2:] if hexdata.startswith("0x") else hexdata
    return _dec_seq(types, d, 0)


def _base_enc(t, v):
    if t == "address":
        return format(int(v, 16), "064x")
    if t == "bool":
        return format(1 if v else 0, "064x")
    if t == "bytes32":
        return format(int(v, 16) if isinstance(v, str) else v, "064x")
    if t.startswith("int"):
        return format(v % (1 << 256), "064x")
    if not 0 <= v < (1 << 256):
        raise ValueError(f"{t} out of range: {v}")
    return format(v, "064x")


def _enc(t, v):
    if isinstance(t, str):
        if t == "bytes":
            h = v[2:] if v.startswith("0x") else v
            return format(len(h) // 2, "064x") + h + "0" * ((64 - len(h) % 64) % 64)
        return _base_enc(t, v)
    if t[0] == "array":
        return format(len(v), "064x") + _enc_seq([t[1]] * len(v), v)
    return _enc_seq([ft for _, ft in t[1]], [v[name] for name, _ in t[1]])


def _enc_seq(types, vals):
    head_len = sum(_head_words(t) for t in types) * 32
    heads, tails = [], []
    for t, v in zip(types, vals):
        if _dynamic(t):
            heads.append(format(head_len + sum(len(x) // 2 for x in tails), "064x"))
            tails.append(_enc(t, v))
        else:
            heads.append(_enc(t, v))
    return "".join(heads) + "".join(tails)


def encode(types, vals):
    return _enc_seq(types, vals)


def calldata(selector, types, vals):
    """0x + 4-byte selector (hex, with or without 0x) + the encoded arguments."""
    s = selector[2:] if selector.startswith("0x") else selector
    return "0x" + s + encode(types, vals)


# ── keccak-256 (the Ethereum variant, padding 0x01), for selectors and mapping slots ──
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
       0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
       0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
       0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
       0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14]]
_M64 = (1 << 64) - 1


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _M64 if n else x


def _f1600(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        dd = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ dd[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    if len(data) % rate == rate - 1:  # one padding byte: 0x01 and 0x80 share it
        p = bytearray(data) + b"\x81"
    else:
        p = bytearray(data) + b"\x01" + b"\x00" * ((-len(data) - 2) % rate) + b"\x80"
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(p), rate):
        blk = p[off:off + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            a[x][y] ^= int.from_bytes(blk[8 * i:8 * i + 8], "little")
        a = _f1600(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out


def selector(sig: str) -> str:
    return keccak256(sig.encode()).hex()[:8]
