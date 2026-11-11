"""Print the structure of an MLIR bytecode file: version, producer, sections, dialects, op names, and
every attribute and type entry with its dialect and encoding (text fallback, or a dialect's custom
encoding). Stdlib only; reads the format in mlir/docs/BytecodeFormat.md (versions 5 and 6).

    python3 -I bc_dump.py FILE.mlirbc
"""
import sys

SECTIONS = ["string", "dialect", "attrType", "attrTypeOffset", "ir", "resource", "resourceOffset",
            "dialectVersions", "properties"]


class Reader:
    def __init__(self, data, pos=0):
        self.data, self.pos = data, pos

    def byte(self):
        b = self.data[self.pos]
        self.pos += 1
        return b

    def varint(self):
        first = self.data[self.pos]
        if first == 0:
            v = int.from_bytes(self.data[self.pos + 1:self.pos + 9], "little")
            self.pos += 9
            return v
        n = (first & -first).bit_length()  # bytes used = index of the lowest set bit + 1
        v = int.from_bytes(self.data[self.pos:self.pos + n], "little") >> n
        self.pos += n
        return v

    def cstring(self):
        end = self.data.index(0, self.pos)
        s = self.data[self.pos:end].decode()
        self.pos = end + 1
        return s

    def section(self):
        code = self.byte()
        size = self.varint()
        if code & 0x80:
            align = self.varint()
            while self.pos % align:
                assert self.byte() == 0xCB, "bad padding"
        start = self.pos
        self.pos += size
        return code & 0x7F, self.data[start:start + size]


def main(path):
    data = open(path, "rb").read()
    assert data[:4] == b"ML\xefR", "not MLIR bytecode"
    r = Reader(data, 4)
    version = r.varint()
    producer = r.cstring()
    print(f"version {version}, producer {producer!r}, {len(data)} bytes")
    sections = {}
    while r.pos < len(data):
        sid, body = r.section()
        sections[sid] = body
        print(f"  section {SECTIONS[sid]}: {len(body)} bytes")

    s = Reader(sections[0])
    n = s.varint()
    lengths = [s.varint() for _ in range(n)][::-1]
    strings, p = [], s.pos
    for ln in lengths:
        strings.append(sections[0][p:p + ln - 1].decode())
        p += ln

    d = Reader(sections[1])
    dialects = []
    for _ in range(d.varint()):
        v = d.varint()
        dialects.append(strings[v >> 1])
        if v & 1:
            d.section()
    print("dialects:", dialects)
    if version >= 4:
        d.varint()
    ops = []
    while d.pos < len(sections[1]):
        dia, count = d.varint(), d.varint()
        for _ in range(count):
            v = d.varint()
            name, reg = (v >> 1, v & 1) if version >= 5 else (v, None)
            ops.append(f"{dialects[dia]}.{strings[name]}" + ("" if reg is None else f" (registered={reg})"))
    print("ops:", *ops, sep="\n  ")

    o = Reader(sections[3])
    n_attrs, n_types = o.varint(), o.varint()
    body, offset = sections[2], 0
    for kind, count in (("attr", n_attrs), ("type", n_types)):
        i = 0
        while i < count:
            dia, k = o.varint(), o.varint()
            for _ in range(k):
                v = o.varint()
                size, custom = v >> 1, v & 1
                entry = body[offset:offset + size]
                offset += size
                text = f"custom, {size} bytes" if custom else entry[:-1].decode()
                print(f"  {kind} #{i} [{dialects[dia]}] {text}")
                i += 1


main(sys.argv[1])
