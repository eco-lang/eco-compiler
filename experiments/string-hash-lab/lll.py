#!/usr/bin/env python3
"""lll.py: short additive differences that cancel in the polynomial hashes. For each `name p B` line on
stdin (hashlab params), finds integers d_0..d_{m-1}, |d_j| < 30000, with sum d_j B^(m-1-j) = 0 mod p, by
LLL reduction (exact rationals) of the lattice {(d, W * sum d_j c_j + W * p * t)}. Prints `name d...`."""
import sys
from fractions import Fraction as F

def lll(b, delta=Fraction if False else F(99, 100)):
    b = [list(map(int, r)) for r in b]
    n = len(b)
    def dot(x, y): return sum(F(a) * c for a, c in zip(x, y))
    def gs():
        bs, mu = [], [[F(0)] * n for _ in range(n)]
        for i in range(n):
            v = [F(x) for x in b[i]]
            for j in range(i):
                mu[i][j] = dot(b[i], bs[j]) / dot(bs[j], bs[j])
                v = [a - mu[i][j] * c for a, c in zip(v, bs[j])]
            bs.append(v)
        return bs, mu
    bs, mu = gs()
    k = 1
    while k < n:
        for j in range(k - 1, -1, -1):
            q = round(mu[k][j])
            if q:
                b[k] = [a - q * c for a, c in zip(b[k], b[j])]
                bs, mu = gs()
        if dot(bs[k], bs[k]) >= (delta - mu[k][k - 1] ** 2) * dot(bs[k - 1], bs[k - 1]):
            k += 1
        else:
            b[k], b[k - 1] = b[k - 1], b[k]
            bs, mu = gs()
            k = max(k - 1, 1)
    return b

for line in sys.stdin:
    t = line.split()
    if len(t) != 3 or not t[0].startswith("poly"): continue
    name, p, B = t[0], int(t[1]), int(t[2])
    best = None
    for m in range(4, 9):
        c = [pow(B, m - 1 - j, p) for j in range(m)]
        W = 1 << 40
        basis = [[1 if i == j else 0 for j in range(m)] + [W * c[i]] for i in range(m)] + [[0] * m + [W * p]]
        for r in lll(basis):
            d = r[:m]
            if r[m] == 0 and any(d) and max(map(abs, d)) < 30000 and sum(x * y for x, y in zip(d, c)) % p == 0:
                if best is None or max(map(abs, d)) < max(map(abs, best)):
                    best = d
        if best: break
    print(name, *best) if best else print("#", name, "none found", file=sys.stderr)
