"""The op-check harness, Python side: run every family graph on MAX and check each output against
NumPy (in f64): values directly, gradients by central differences on the same NumPy function.

    ref.py MANIFEST.json [FAMILY ...]

A gradient output is d/dx sum(f(x) * w) with w = cos(f(x0)) held fixed (the Elm side writes
`stopGradient (cos y)`).
"""
import json
import os
import math
import sys
import time
import zlib

import numpy as np
from max.driver import CPU
from max.engine import InferenceSession

erf = np.vectorize(math.erf)


def softmax(x, axis):
    e = np.exp(x - x.max(axis=axis, keepdims=True))
    return e / e.sum(axis=axis, keepdims=True)


def log_softmax(x, axis):
    m = x.max(axis=axis, keepdims=True)
    return x - m - np.log(np.exp(x - m).sum(axis=axis, keepdims=True))


def sigmoid(x):
    return 1 / (1 + np.exp(-x))


def gelu_tanh(x):
    return 0.5 * x * (1 + np.tanh(math.sqrt(2 / math.pi) * (x + 0.044715 * x ** 3)))


def cumsum(x, axis, exclusive, reverse):
    if reverse:
        x = np.flip(x, axis)
    c = np.cumsum(x, axis=axis)
    if exclusive:
        c = c - x
    if reverse:
        c = np.flip(c, axis)
    return c


def put(x, idx, upd):
    r = x.copy()
    r[idx.astype(int)] = upd
    return r


def put_add(x, idx, upd):
    r = x.copy()
    np.add.at(r, idx.astype(int), upd)
    return r


def slice_update(x, upd):
    r = x.copy()
    r[1:1 + upd.shape[0]] = upd
    return r


def attention(q, k, v, mask=None):
    s = q @ np.swapaxes(k, -1, -2) / math.sqrt(q.shape[-1])
    if mask is not None:
        s = np.where(mask, s, -1e9)
    return softmax(s, -1) @ v


def layer_norm(x, g, b, eps=1e-5):
    mu = x.mean(-1, keepdims=True)
    var = ((x - mu) ** 2).mean(-1, keepdims=True)
    return (x - mu) / np.sqrt(var + eps) * g + b


def conv2d(x, f, b, p):
    sh, sw, pt, pb, pl, pr = [int(v) for v in p[:6]]
    xp = np.pad(x, ((0, 0), (pt, pb), (pl, pr), (0, 0)))
    kh, kw, c, o = f.shape
    oh = (xp.shape[1] - kh) // sh + 1
    ow = (xp.shape[2] - kw) // sw + 1
    y = np.zeros((x.shape[0], oh, ow, o))
    for i in range(oh):
        for j in range(ow):
            patch = xp[:, i * sh:i * sh + kh, j * sw:j * sw + kw, :]
            y[:, i, j, :] = np.tensordot(patch, f, axes=([1, 2, 3], [0, 1, 2]))
    return y + (b if b is not None else 0)


def conv2d_transpose(x, f, p):
    # f: (kh, kw, out, in); the adjoint of conv2d with the same geometry
    sh, sw, pt, pb, pl, pr = [int(v) for v in p[:6]]
    n, h, w, _ = x.shape
    kh, kw, o, _ = f.shape
    full = np.zeros((n, (h - 1) * sh + kh, (w - 1) * sw + kw, o))
    for i in range(h):
        for j in range(w):
            full[:, i * sh:i * sh + kh, j * sw:j * sw + kw, :] += np.tensordot(x[:, i, j, :], f, axes=([1], [3]))
    return full[:, pt:full.shape[1] - pb, pl:full.shape[2] - pr, :]


def pool(x, k, how):
    n, h, w, c = x.shape
    r = x.reshape(n, h // k, k, w // k, k, c)
    return r.max(axis=(2, 4)) if how == "max" else r.mean(axis=(2, 4))


def sq(v):
    return v ** 2 + np.sin(v)


def while_halve(x):
    x = x.astype(np.float32).astype(np.float64)
    while np.abs(x).max() > 0.1:
        x = x * 0.5
    return x


def vgrad_outer(x):
    # d/dx sum(softmax(x, -1) * x) = s + s * (x - sum(s * x))
    s = softmax(x, -1)
    return s + s * (x - (s * x).sum(-1, keepdims=True))


NF4 = [-1.0, -0.6961928009986877, -0.5250730514526367, -0.39491748809814453, -0.28444138169288635,
       -0.18477343022823334, -0.09105003625154495, 0.0, 0.07958029955625534, 0.16093020141124725,
       0.24611230194568634, 0.33791524171829224, 0.44070982933044434, 0.5626170039176941,
       0.7229568362236023, 1.0]


def bf16(x):
    b = np.asarray(x, np.float32).view(np.uint32)
    b = ((b + 0x7FFF + ((b >> 16) & 1)) >> 16) << 16
    return b.astype(np.uint32).view(np.float32).astype(np.float64)


# Each reference: (args by name, params, base args) -> array. `base` holds the unperturbed inputs,
# for functions the Elm side closes over (held fixed while one input is differentiated).
REF = {
    "abs": lambda a, p, b: np.abs(a["x"]),
    "negate": lambda a, p, b: -a["x"],
    "sign": lambda a, p, b: np.sign(a["x"]),
    "exp": lambda a, p, b: np.exp(a["x"]),
    "sin": lambda a, p, b: np.sin(a["x"]),
    "cos": lambda a, p, b: np.cos(a["x"]),
    "erf": lambda a, p, b: erf(a["x"]),
    "floor": lambda a, p, b: np.floor(a["x"]),
    "round": lambda a, p, b: np.round(a["x"]),
    "truncate": lambda a, p, b: np.trunc(a["x"]),
    "relu": lambda a, p, b: np.maximum(a["x"], 0),
    "sigmoid": lambda a, p, b: sigmoid(a["x"]),
    "tanh": lambda a, p, b: np.tanh(a["x"]),
    "gelu": lambda a, p, b: 0.5 * a["x"] * (1 + erf(a["x"] / math.sqrt(2))),
    "geluTanh": lambda a, p, b: gelu_tanh(a["x"]),
    "silu": lambda a, p, b: a["x"] * sigmoid(a["x"]),
    "scale": lambda a, p, b: a["x"] * p[0],
    "shift": lambda a, p, b: a["x"] + p[0],
    "isInfinite": lambda a, p, b: np.isinf(a["x"]),
    "isNaN": lambda a, p, b: np.isnan(a["x"]),
    "square": lambda a, p, b: a["x"] ** 2,
    "log": lambda a, p, b: np.log(a["x"]),
    "log1p": lambda a, p, b: np.log1p(a["x"]),
    "sqrt": lambda a, p, b: np.sqrt(a["x"]),
    "rsqrt": lambda a, p, b: 1 / np.sqrt(a["x"]),
    "acos": lambda a, p, b: np.arccos(a["x"]),
    "atanh": lambda a, p, b: np.arctanh(a["x"]),
    "plus": lambda a, p, b: a["x"] + a["y"],
    "minus": lambda a, p, b: a["x"] - a["y"],
    "times": lambda a, p, b: a["x"] * a["y"],
    "max": lambda a, p, b: np.maximum(a["x"], a["y"]),
    "min": lambda a, p, b: np.minimum(a["x"], a["y"]),
    "dividedBy": lambda a, p, b: a["x"] / a["p"],
    "pow": lambda a, p, b: a["p"] ** a["y"],
    "greaterThan": lambda a, p, b: a["x"] > a["y"],
    "atLeast": lambda a, p, b: a["x"] >= a["y"],
    "lessThan": lambda a, p, b: a["x"] < a["y"],
    "atMost": lambda a, p, b: a["x"] <= a["y"],
    "equals": lambda a, p, b: np.round(a["x"]) == np.round(a["y"]),
    "notEquals": lambda a, p, b: np.round(a["x"]) != np.round(a["y"]),
    "and": lambda a, p, b: (a["x"] > 0) & (a["y"] > 0),
    "or": lambda a, p, b: (a["x"] > 0) | (a["y"] > 0),
    "xor": lambda a, p, b: (a["x"] > 0) ^ (a["y"] > 0),
    "not": lambda a, p, b: ~(a["x"] > 0),
    "select": lambda a, p, b: np.where(b["x"] > b["y"], a["x"], 3 * a["y"]),
    "iplus": lambda a, p, b: a["i"] + a["m"],
    "itimes": lambda a, p, b: a["i"] * a["m"],
    "inegate": lambda a, p, b: -a["i"],
    "iabs": lambda a, p, b: np.abs(a["i"]),
    "irelu": lambda a, p, b: np.maximum(a["i"], 0),
    "imax": lambda a, p, b: np.maximum(a["i"], a["m"]),
    "modBy": lambda a, p, b: np.mod(a["i"], a["m"]),
    "toInt": lambda a, p, b: np.trunc(np.float32(3) * a["x"].astype(np.float32)),
    "isum1": lambda a, p, b: a["i"].sum(1),
    "argMax0": lambda a, p, b: a["x"].argmax(0),
    "argMax1": lambda a, p, b: a["x"].argmax(1),
    "argMin0": lambda a, p, b: a["x"].argmin(0),
    "argMin1": lambda a, p, b: a["x"].argmin(1),
    "castU8": lambda a, p, b: np.abs(a["i"]),
    "castI32": lambda a, p, b: a["i"],
    "iota": lambda a, p, b: np.arange(5),
    "arange": lambda a, p, b: 2 + 3 * np.arange(5),
    "sum": lambda a, p, b: a["x"].sum(int(p[0])),
    "mean": lambda a, p, b: a["x"].mean(int(p[0])),
    "maximum": lambda a, p, b: a["x"].max(int(p[0])),
    "minimum": lambda a, p, b: a["x"].min(int(p[0])),
    "logSumExp": lambda a, p, b: np.log(np.exp(a["x"]).sum(int(p[0]))),
    "cumsum": lambda a, p, b: cumsum(a["x"], int(p[0]), False, False),
    "cumsumExclusive": lambda a, p, b: cumsum(a["x"], int(p[0]), True, False),
    "cumsumReverse": lambda a, p, b: cumsum(a["x"], int(p[0]), False, True),
    "cumsumExclusiveReverse": lambda a, p, b: cumsum(a["x"], int(p[0]), True, True),
    "softmax": lambda a, p, b: softmax(a["x"], int(p[0])),
    "logSoftmax": lambda a, p, b: log_softmax(a["x"], int(p[0])),
    "sumAll": lambda a, p, b: a["x"].sum(),
    "meanAll": lambda a, p, b: a["x"].mean(),
    "maximumAll": lambda a, p, b: a["x"].max(),
    "minimumAll": lambda a, p, b: a["x"].min(),
    "minMaxMin": lambda a, p, b: a["x"].min(),
    "minMaxMax": lambda a, p, b: a["x"].max(),
    "matmul": lambda a, p, b, names=None: None,  # filled per check below (argument names vary)
    "outer": lambda a, p, b: None,
    "reshape": lambda a, p, b: a["x"].reshape(4, 3),
    "flatten": lambda a, p, b: a["z"].reshape(-1),
    "factorLast3": lambda a, p, b: a["x"].reshape(3, 2, 2),
    "mergeLast3": lambda a, p, b: a["z"].reshape(3, 20),
    "transpose": lambda a, p, b: a["x"].T,
    "permute01": lambda a, p, b: a["z"].transpose(1, 0, 2),
    "permute12": lambda a, p, b: a["z"].transpose(0, 2, 1),
    "permute02then12": lambda a, p, b: a["z"].transpose(2, 0, 1),
    "rowsPlus": lambda a, p, b: a["x"] + a["v"][None, :],
    "columnsTimes": lambda a, p, b: a["x"] * a["u"][:, None],
    "broadcastTo": lambda a, p, b: np.broadcast_to(a["v"], (3, 4)),
    "insertDrop": lambda a, p, b: 2 * a["x"],
    "slice": lambda a, p, b: a["x"][:, 1:3],
    "sliceUpdate": lambda a, p, b: slice_update(a["x"], a["upd"]),
    "concat": lambda a, p, b: np.concatenate([a["x"], a["y"]], 0),
    "concat2": lambda a, p, b: np.concatenate([a["x"], a["upd"]], 0),
    "chunk1": lambda a, p, b: a["x"][:, 2:4],
    "stack": lambda a, p, b: np.stack([a["x"], a["y"]]),
    "unstack1": lambda a, p, b: a["z"][1],
    "flip": lambda a, p, b: a["x"][:, ::-1],
    "pad": lambda a, p, b: np.pad(a["x"], ((1, 2), (0, 0)), constant_values=0.5),
    "take": lambda a, p, b: a["x"][a["idx"].astype(int)],
    "take1": lambda a, p, b: a["x"][:, a["idx"].astype(int)],
    "pick": lambda a, p, b: a["x"][np.arange(3), a["lab"].astype(int)],
    "put": lambda a, p, b: put(a["x"], a["idx"], a["upd"]),
    "putAdd": lambda a, p, b: put_add(a["x"], a["idx"], a["upd"]),
    "triu0": lambda a, p, b: np.triu(a["x"], 0),
    "triu1": lambda a, p, b: np.triu(a["x"], 1),
    "trilm1": lambda a, p, b: np.tril(a["x"], -1),
    "tril0": lambda a, p, b: np.tril(a["x"], 0),
    "lowerTriangle": lambda a, p, b: np.tril(np.ones((3, 3))),
    "hann": lambda a, p, b: 0.5 - 0.5 * np.cos(2 * math.pi * np.arange(5) / 5),
    "fromList": lambda a, p, b: np.array([[1, 2], [3, 4]]),
    "fillLike": lambda a, p, b: np.full((3, 4), a["x"].sum()),
    "crossEntropy": lambda a, p, b: -(softmax(a["soft"], 1) * log_softmax(a["logits"], 1)).sum(1).mean(),
    "crossEntropyIndices": lambda a, p, b: -log_softmax(a["logits"], 1)[np.arange(3), a["lab"].astype(int)].mean(),
    "mseLoss": lambda a, p, b: ((a["logits"] - a["soft"]) ** 2).mean(),
    "layerNorm": lambda a, p, b: layer_norm(a["x"], b["x"].sum(0) * 0.3 + 1, b["x"].sum(0) * -0.2),
    "attention": lambda a, p, b: attention(a["q"], a["kk"], a["vv"]),
    "causalAttention": lambda a, p, b: attention(a["q"], a["q"], a["q"], np.tril(np.ones((3, 3))) > 0),
    "identity": lambda a, p, b: a["x"],
    "confusion": lambda a, p, b: a["x"],
    "gradOfGrad": lambda a, p, b: 6 * a["x"],
    "hessianVectorSelf": lambda a, p, b: 18 * a["x"] ** 3,
    "hessianVector": lambda a, p, b: 6 * a["x"] * a["v"],
    "ones": lambda a, p, b: np.ones(4),
    "jvpSin": lambda a, p, b: np.cos(a["x"]) * a["v"],
    "jacobianSin": lambda a, p, b: np.diag(np.cos(a["x"])),
    "softmaxRows": lambda a, p, b: softmax(a["m"], 1),
    "rowsTimesX": lambda a, p, b: a["m"] * a["x"][None, :],
    "gradOfRecord": lambda a, p, b: 2 * a["x"] * a["v"],
    "cumsumRows": lambda a, p, b: np.cumsum(a["m"], 0),
    "times8": lambda a, p, b: 8 * a["x"],
    "condPos": lambda a, p, b: np.maximum(a["x"], 0) if a["x"].sum() > 0 else -a["x"],
    "bf16": lambda a, p, b: 2 * bf16(a["x"]),
    "f16": lambda a, p, b: a["x"].astype(np.float16).astype(np.float64) ** 2,
    "f64": lambda a, p, b: np.exp(a["x"]),
    "linear": lambda a, p, b: a["x"] @ (0.1 * a["x"].T @ a["x"]) + a["x"].sum(0),
    "convSame": lambda a, p, b: conv2d(a["x"], a["param0"], a["param1"], p),
    "convStride2": lambda a, p, b: conv2d(a["x"], a["param0"], a["param1"], p),
    "convStride2Pad": lambda a, p, b: conv2d(a["x"], a["param0"], a["param1"], p),
    "convTranspose": lambda a, p, b: conv2d_transpose(a["x"], a["param2"], p),
    "maxPool": lambda a, p, b: pool(a["x"], 2, "max"),
    "avgPool": lambda a, p, b: pool(a["x"], 2, "mean"),
    "condRelu": lambda a, p, b: np.maximum(a["x"], 0) if b["x"].sum() > 0 else -2 * a["x"],
    "condCapture": lambda a, p, b: a["x"] * a["y"] if b["x"].sum() > 0 else a["x"] + a["y"],
    "whileHalve": lambda a, p, b: while_halve(a["x"]),
    "sharedSquare": lambda a, p, b: a["x"] ** 2 + np.sin(a["x"]),
    "sharedTwice": lambda a, p, b: sq(sq(a["x"])),
    "sharedInCond": lambda a, p, b: sq(a["x"]) if b["x"].sum() > 0 else -a["x"],
    "vSin": lambda a, p, b: np.sin(a["m"]),
    "vPlusPlain": lambda a, p, b: a["m"] + a["v"],
    "vSumAll": lambda a, p, b: a["mm"].sum((1, 2)),
    "vSoftmax": lambda a, p, b: softmax(a["mm"], 2),
    "vCumsum": lambda a, p, b: np.cumsum(a["mm"], 1),
    "vVecMat": lambda a, p, b: a["m"] @ a["w"],
    "vMatVec": lambda a, p, b: a["mm"] @ a["u"],
    "vMatmulBoth": lambda a, p, b: a["mm"] @ a["nn"],
    "vMatmulPlainX": lambda a, p, b: a["px"] @ a["nn"],
    "vDot": lambda a, p, b: a["m"] @ a["v"],
    "vReshape": lambda a, p, b: a["mm"].reshape(3, 5, 4),
    "vTranspose": lambda a, p, b: a["mm"].transpose(0, 2, 1),
    "vBroadcastTo": lambda a, p, b: np.broadcast_to(a["m"][:, None, :], (3, 3, 4)),
    "vSlice": lambda a, p, b: a["mm"][:, :, 1:3],
    "vConcatPlain": lambda a, p, b: np.concatenate([a["mm"], np.broadcast_to(a["px"], (3, 4, 5))], 1),
    "vPad": lambda a, p, b: np.pad(a["mm"], ((0, 0), (1, 2), (0, 0)), constant_values=0.5),
    "vTake": lambda a, p, b: a["mm"][:, a["idx"].astype(int)],
    "vTril": lambda a, p, b: np.tril(a["sq"]),
    "vLayerNorm": lambda a, p, b: layer_norm(a["mm"], a["u"] * 0.5 + 1, a["u"] * 0.1),
    "vGrad": lambda a, p, b: 3 * a["m"] ** 2,
    "vCond": lambda a, p, b: np.stack([np.maximum(r, 0) if r.sum() > 0 else -r for r in a["m"]]),
    "vSinMM": lambda a, p, b: np.sin(a["mm"]),
    "vGradOuter": lambda a, p, b: vgrad_outer(a["mm"]),
    "nf4": lambda a, p, b: np.array([[NF4[0] * 2, NF4[7] * 2], [NF4[15] * 0.5, NF4[3] * 0.5]]),
}

TOLERANCE = {"bf16": (2e-2, 2e-2), "f16": (2e-3, 2e-3), "nf4": (1e-6, 1e-6)}

STATS = {"zerosStats", "uniformStats", "normalStats", "bernoulliStats", "dropoutStats", "rowsDiffer"}


def reference(check, args, base):
    ref, names, p = check["ref"], check["args"], check["params"]
    if ref == "matmul":
        return np.matmul(args[names[0]], args[names[1]])
    if ref == "outer":
        return np.outer(args[names[0]], args[names[1]])
    return REF[ref](args, p, base)


def inputs_for(family, rng):
    out = {}
    for spec in family["inputs"]:
        shape, dom, name = tuple(spec["shape"]), spec["domain"], spec["name"]
        dtype = {"f32": np.float32, "si64": np.int64, "ui64": np.uint64, "ui8": np.uint8}[spec["dtype"]]
        if dom == "pos":
            v = rng.uniform(0.5, 3, shape)
        elif dom == "unit":
            v = rng.uniform(-0.9, 0.9, shape)
        elif dom == "int":
            v = rng.integers(-5, 6, shape)
        elif dom == "posint":
            v = rng.integers(1, 5, shape)
        elif dom == "idx3":
            v = rng.permutation(3)[: shape[0]]
        elif dom.startswith("label"):
            v = rng.integers(0, int(dom[5:]), shape)
        elif dom == "seed":
            v = np.full(shape, 12345)
        else:
            v = rng.uniform(-2, 2, shape)
        out[name] = np.asarray(v).astype(dtype)
    return out


def check_stats(check, got, all_outputs):
    p = check["params"]
    if check["ref"] == "uniformStats":
        lo, hi = p
        ok = got.min() >= lo and got.max() < hi and abs(got.mean() - (lo + hi) / 2) < 0.03 * (hi - lo)
        if check["name"] == "uniformAgain":
            ok = ok and np.array_equal(got, all_outputs["uniform"])
        if check["name"] == "uniformSalted":
            ok = ok and not np.array_equal(got, all_outputs["uniform"])
        return ok, f"mean {got.mean():.4f} min {got.min():.4f} max {got.max():.4f}"
    if check["ref"] == "zerosStats":
        return bool((got == 0).all()), "all zero" if (got == 0).all() else "not all zero"
    if check["ref"] == "normalStats":
        m, s = p
        return abs(got.mean() - m) < 0.15 and abs(got.std() - s) < 0.15, f"mean {got.mean():.3f} std {got.std():.3f}"
    if check["ref"] == "bernoulliStats":
        return abs(got.mean() - p[0]) < 0.03 and set(np.unique(got)) <= {0.0, 1.0}, f"mean {got.mean():.4f}"
    if check["ref"] == "dropoutStats":
        keep = 1 / (1 - p[0])
        zeros = (got == 0).mean()
        ok = abs(zeros - p[0]) < 0.03 and np.allclose(got[got != 0], keep)
        return ok, f"zeroed {zeros:.4f}"
    if check["ref"] == "rowsDiffer":
        rows = got.reshape(3, -1)
        ok = all(not np.array_equal(rows[i], rows[j]) for i in range(3) for j in range(i + 1, 3)) and got.min() >= 0 and got.max() < 1
        return ok, "rows " + ("differ" if ok else "repeat")
    return False, "unknown statistic"


def main():
    manifest = json.load(open(sys.argv[1]))
    only = set(sys.argv[2:])
    session = InferenceSession(devices=[CPU()])
    failures, passed = [], 0
    for fam in manifest:
        if only and fam["graph"] not in only:
            continue
        t0 = time.time()
        model = session.load(fam["file"] + ("bc" if os.environ.get("OPCHECK_FORMAT") == "bytecode" else ""))
        compile_s = time.time() - t0
        rng = np.random.default_rng(zlib.crc32(fam["graph"].encode()))
        ins = inputs_for(fam, rng)
        outs = model.execute(*[ins[s["name"]] for s in fam["inputs"]])
        outs = [o.to_numpy() if hasattr(o, "to_numpy") else np.asarray(o) for o in outs]
        base = {k: v.astype(np.float64) for k, v in ins.items()}
        by_name = {c["name"]: o.reshape(-1).astype(np.float64) for c, o in zip(fam["checks"], outs)}
        fam_fail = 0
        for check, out in zip(fam["checks"], outs):
            got = out.reshape(-1).astype(np.float64)
            if check["ref"] in STATS:
                ok, detail = check_stats(check, got, by_name)
            elif check["wrt"] == "":
                want = np.asarray(reference(check, base, base), dtype=np.float64).reshape(-1)
                rtol, atol = TOLERANCE.get(check["ref"], (1e-4, 1e-5))
                ok = want.shape == got.shape and np.allclose(got, want, rtol=rtol, atol=atol)
                detail = f"max err {np.max(np.abs(got - want)) if want.shape == got.shape else 'shape ' + str(want.shape)}"
            else:
                w = np.cos(np.asarray(reference(check, base, base), dtype=np.float64))
                x0 = base[check["wrt"]]
                fd = np.zeros_like(x0)
                eps = 1e-4
                for i in np.ndindex(x0.shape):
                    for sgn in (1, -1):
                        a = dict(base)
                        xp = x0.copy()
                        xp[i] += sgn * eps
                        a[check["wrt"]] = xp
                        fd[i] += sgn * (np.asarray(reference(check, a, base)) * w).sum()
                fd /= 2 * eps
                want = fd.reshape(-1)
                ok = want.shape == got.shape and np.allclose(got, want, rtol=2e-3, atol=2e-4)
                detail = f"max err {np.max(np.abs(got - want)) if want.shape == got.shape else 'shape ' + str(want.shape)}"
            if ok:
                passed += 1
            else:
                fam_fail += 1
                failures.append(f"{fam['graph']}: {check['name']}: {detail}")
        print(f"{fam['graph']:12s} {len(fam['checks']) - fam_fail:3d}/{len(fam['checks']):3d} passed  (compile {compile_s:.1f} s)", flush=True)
    for f in failures:
        print("FAIL", f)
    print(f"{passed} passed, {len(failures)} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
