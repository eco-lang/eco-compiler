#!/usr/bin/env python3
"""v4ref.py: an independent reference for value-hash definition v4's String hash (CRC32C, bit by bit),
the walker steps the String pins need, and a constructor of colliding Strings.

    v4ref.py pins        the HashIdentityTest values that involve Strings, under v3 (v3ref.py: must
                         match the committed pins) and under v4
    v4ref.py collide N   three printable-ASCII Strings of N units with one raw CRC32C, so one hash

Not part of eco; see design_docs/string-hash-algorithm.md and plans/hash-reuse-explicit-vs-cached.md B5a.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v3ref import string_hash as v3_string_hash

M32 = 0xFFFFFFFF
POLY = 0x82F63B78
K_INT, K_STRING, K_EMPTY, K_TUPLE = 1, 4, 5, 7


def units(s):
    b = s.encode("utf-16-le")
    return [b[i] | b[i + 1] << 8 for i in range(0, len(b), 2)]


def crc_raw(us, c=0xFFFFFFFF):
    """The CRC32C register over the units' little-endian bytes, without the final inversion."""
    for u in us:
        for byte in (u & 0xFF, u >> 8):
            c ^= byte
            for _ in range(8):
                c = (c >> 1) ^ (POLY if c & 1 else 0)
    return c


def fmix32(h):
    h ^= h >> 16
    h = (h * 0x85EBCA6B) & M32
    h ^= h >> 13
    h = (h * 0xC2B2AE35) & M32
    h ^= h >> 16
    return h


def nonzero(h):
    return h or 1


def v4_string_hash(s):
    us = units(s)
    return nonzero(fmix32(crc_raw(us) ^ (len(us) & M32)))


class Walker:
    def __init__(self, string_hash):
        self.h = 2166136261
        self.sh = string_hash

    def mix(self, x):
        self.h = ((self.h ^ (x & M32)) * 16777619) & M32

    def mix64(self, x):
        x &= (1 << 64) - 1
        self.mix(x & M32)
        self.mix(x >> 32)

    def int(self, i):
        self.mix(K_INT)
        self.mix64(i)

    def string(self, s):
        if s == "":
            self.mix(K_EMPTY)
        else:
            self.mix(K_STRING)
            self.mix(self.sh(s))

    def finish(self):
        return nonzero(fmix32(self.h))


def hash_string(s, sh):
    w = Walker(sh)
    w.string(s)
    return w.finish()


def hash_int_string_tuple(i, s, sh):
    w = Walker(sh)
    w.mix(K_TUPLE)
    w.int(i)
    w.string(s)
    return w.finish()


def pins():
    strings = ["", "a", "hello world", "xy" * 5000]
    for name, sh in (("v3", v3_string_hash), ("v4", v4_string_hash)):
        print(name, "strings:", [hash_string(s, sh) for s in strings])
        print(name, "collide:", [hash_string(s, sh) for s in ("c600662", "c5330492", "c11005860")])
        print(name, "values[0] (1, \"a\"):", hash_int_string_tuple(1, "a", sh))


def collide(n, base="collisionkey"):
    """Three printable-ASCII Strings of n units with one raw CRC32C. CRC is linear over GF(2): for
    Strings of one length, raw(k ^ d) = raw(k) ^ L(d), so any d in L's kernel keeps the raw state.
    Only the low 5 bits of each unit are allowed to change (letters stay letters)."""
    key = [ord(base[i % len(base)]) for i in range(n)]
    r0 = crc_raw(key)
    cols = []  # (unit index, bit) and L(e_bit)
    for u in range(n):
        for bit in range(5):
            k = list(key)
            k[u] ^= 1 << bit
            cols.append(((u, bit), crc_raw(k) ^ r0))
    # Gaussian elimination over GF(2): kernel vectors as sets of columns.
    rows = []  # (pivot bit, value, combination mask)
    kernel = []
    for idx, (_, v) in enumerate(cols):
        comb = 1 << idx
        for pb, pv, pc in rows:
            if v >> pb & 1:
                v ^= pv
                comb ^= pc
        if v == 0:
            kernel.append(comb)
        else:
            rows.append((v.bit_length() - 1, v, comb))
    found = [key]
    for comb in kernel:
        k = list(key)
        for idx in range(len(cols)):
            if comb >> idx & 1:
                (u, bit), _ = cols[idx]
                k[u] ^= 1 << bit
        if all(0x41 <= c <= 0x7A and not 0x5B <= c <= 0x60 for c in k) and k not in found:
            found.append(k)
        if len(found) == 3:
            break
    strs = ["".join(map(chr, k)) for k in found]
    for s in strs:
        print(s, hex(crc_raw(units(s))), v4_string_hash(s), hash_string(s, v4_string_hash))
    return strs


if __name__ == "__main__":
    if sys.argv[1:2] == ["collide"]:
        collide(int(sys.argv[2]) if len(sys.argv) > 2 else 8)
    else:
        pins()
