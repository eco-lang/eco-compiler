"""A2.3: the UNet-shaped block of ApiCheck.elm in NumPy, from the parameters and inputs the Elm program
saved, compared with the output MAX computed.

    ref_block.py DIR      (DIR/block/: param*.bin, in.*.bin, out.y.bin, manifest.json)
"""
import json
import os
import sys

import numpy as np

d = os.path.join(sys.argv[1], "block")
manifest = json.load(open(os.path.join(d, "manifest.json")))
names = manifest["params"]
load = lambda name: np.fromfile(os.path.join(d, name + ".bin"), dtype=np.float32).astype(np.float64)

# Block's fields in order (Param.names): conv1 filter, bias; norm scale, bias; time weight, bias;
# conv2 filter, bias; cross query, key, value (no biases), out weight, bias; conv3 filter, bias.
assert len(names) == 15, names
p = [load(n) for n in names]
c1f, c1b = p[0].reshape(3, 3, 16, 16), p[1]
gs, gb = p[2], p[3]
tw, tb = p[4].reshape(16, 16), p[5]
c2f, c2b = p[6].reshape(3, 3, 16, 16), p[7]
wq, wk, wv = p[8].reshape(16, 16), p[9].reshape(24, 16), p[10].reshape(24, 16)
wo, bo = p[11].reshape(16, 16), p[12]
c3f, c3b = p[13].reshape(1, 1, 16, 16), p[14]

x = load("in.x").reshape(2, 8, 8, 16)
t = load("in.t")
mem = load("in.memory").reshape(6, 24)
got = load("out.y").reshape(2, 16, 16, 16)


def conv_same(x, f, b):
    """NHWC correlation with an RSCF filter, stride 1, padding k // 2 (an odd kernel)."""
    kh, kw = f.shape[:2]
    xp = np.pad(x, ((0, 0), (kh // 2, kh // 2), (kw // 2, kw // 2), (0, 0)))
    n, h, w, _ = x.shape
    out = np.zeros((n, h, w, f.shape[3]))
    for i in range(kh):
        for j in range(kw):
            out += xp[:, i:i + h, j:j + w, :] @ f[i, j]
    return out + b


def group_norm(x, g, b, groups, eps):
    n, h, w, c = x.shape
    r = x.reshape(n, h * w, groups, c // groups)
    mu = r.mean(axis=(1, 3), keepdims=True)
    var = ((r - mu) ** 2).mean(axis=(1, 3), keepdims=True)
    return ((r - mu) / np.sqrt(var + eps)).reshape(n, h, w, c) * g + b


def timestep_embedding(t, dim, max_period=10000.0):
    half = dim // 2
    freqs = np.exp(-np.log(max_period) * np.arange(half) / half)
    args = t[:, None] * freqs[None, :]
    return np.concatenate([np.cos(args), np.sin(args)], axis=1)  # cosFirst


def softmax(z, axis):
    z = z - z.max(axis=axis, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=axis, keepdims=True)


def cross(seq, mem):
    heads, hd = 2, 8
    q = (seq @ wq).reshape(-1, heads, hd).transpose(1, 0, 2)
    k = (mem @ wk).reshape(-1, heads, hd).transpose(1, 0, 2)
    v = (mem @ wv).reshape(-1, heads, hd).transpose(1, 0, 2)
    o = softmax(q @ k.transpose(0, 2, 1) / np.sqrt(hd), 2) @ v
    return o.transpose(1, 0, 2).reshape(-1, heads * hd) @ wo + bo


h = conv_same(x, c1f, c1b)
h = group_norm(h, gs, gb, 4, 1e-5)
h = h / (1 + np.exp(-h))  # silu
h = h + (timestep_embedding(t, 16) @ tw + tb)[:, None, None, :]
h = conv_same(h, c2f, c2b)
h3 = h.repeat(2, axis=1).repeat(2, axis=2)
att = np.stack([cross(h3[i].reshape(256, 16), mem) for i in range(2)]).reshape(2, 16, 16, 16)
want = conv_same(att + h3, c3f, c3b)

err = np.abs(got - want).max() / np.abs(want).max()
ok = err <= 1e-4
print(f"{'PASS' if ok else 'FAIL'} block forward against NumPy: max |Δ| / max |ref| = {err:.3g}")
sys.exit(0 if ok else 1)
