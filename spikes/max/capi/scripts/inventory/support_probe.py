"""Which primitive compiles for which dtype on MAX (CPU): the table the tensor package's build-time
dtype check uses (tensor/src/Tensor/Internal/Support.elm, written by tensor/scripts/gen_support.py).

One graph per dtype holds every primitive under test; a graph that fails to compile is bisected
until each failing primitive is found. Writes support.json: {dtype: {primitive: true|false}}.

    support_probe.py OUT.json
"""
import json
import sys
import time

from max.driver import CPU
from max.dtype import DType
from max.engine import InferenceSession
from max.graph import DeviceRef, Graph, TensorType, ops

DTYPES = {
    "f16": DType.float16, "bf16": DType.bfloat16, "f32": DType.float32, "f64": DType.float64,
    "si8": DType.int8, "si32": DType.int32, "si64": DType.int64, "ui8": DType.uint8,
    "ui64": DType.uint64,
}
FLOATS = {"f16", "bf16", "f32", "f64"}

# primitive name (as tensor/src/Tensor/Internal/Prim.elm's `name`) -> how to apply it to x, y
UNARY_ANY = {
    "abs": lambda x: ops.abs(x), "negate": lambda x: ops.negate(x), "relu": lambda x: ops.relu(x),
}
UNARY_FLOAT = {
    "exp": ops.exp, "log": ops.log, "log1p": ops.log1p, "sqrt": ops.sqrt, "rsqrt": ops.rsqrt,
    "sin": ops.sin, "cos": ops.cos, "acos": ops.acos, "atanh": ops.atanh, "erf": ops.erf,
    "floor": ops.floor, "round": ops.round, "truncate": ops.trunc, "sigmoid": ops.sigmoid,
    "tanh": ops.tanh, "gelu": ops.gelu, "geluTanh": lambda x: ops.gelu(x, approximate="tanh"),
    "silu": ops.silu, "isInfinite": ops.is_inf, "isNaN": ops.is_nan,
}
BINARY_ANY = {
    "plus": ops.add, "minus": ops.sub, "times": ops.mul, "max": ops.max, "min": ops.min,
    "equals": ops.equal, "notEquals": ops.not_equal, "greaterThan": ops.greater,
    "atLeast": ops.greater_equal,
}
BINARY_FLOAT = {"dividedBy": ops.div, "pow": ops.pow}
BINARY_INT = {"modBy": ops.mod}
OTHER = {
    "sum": lambda x: ops.sum(x, axis=1), "mean": lambda x: ops.mean(x, axis=1),
    "maximum": lambda x: ops.max(x, axis=1), "minimum": lambda x: ops.min(x, axis=1),
    "argMax": lambda x: ops.argmax(x, axis=1), "argMin": lambda x: ops.argmin(x, axis=1),
    "cumsum": lambda x: ops.cumsum(x, axis=1), "matmul": lambda x: x @ ops.transpose(x, 0, 1),
    "triu/tril": lambda x: ops.band_part(x, None, 0),
    "take": lambda x: ops.gather(x, ops.constant([0, 1], DType.int64, device=DeviceRef.CPU()), axis=0),
}
OTHER_FLOAT = {
    "softmax": lambda x: ops.softmax(x), "logSoftmax": lambda x: ops.logsoftmax(x),
}


def candidates(dt):
    c = dict()
    for k, f in UNARY_ANY.items():
        c[k] = ("u", f)
    for k, f in BINARY_ANY.items():
        c[k] = ("b", f)
    for k, f in OTHER.items():
        c[k] = ("u", f)
    if dt in FLOATS:
        for k, f in UNARY_FLOAT.items():
            c[k] = ("u", f)
        for k, f in BINARY_FLOAT.items():
            c[k] = ("b", f)
        for k, f in OTHER_FLOAT.items():
            c[k] = ("u", f)
    else:
        for k, f in BINARY_INT.items():
            c[k] = ("b", f)
    return c


def compiles(session, dt, names, table):
    t = TensorType(DTYPES[dt], (3, 3), device=DeviceRef.CPU())
    try:
        with Graph("probe", input_types=(t, t)) as g:
            x, y = (v.tensor for v in g.inputs)
            outs = []
            for n in names:
                kind, f = table[n]
                outs.append(f(x) if kind == "u" else f(x, y))
            g.output(*outs)
        session.load(g)
        return True
    except Exception:
        return False


def probe(session, dt, names, table, result):
    if not names:
        return
    if compiles(session, dt, names, table):
        for n in names:
            result[n] = True
    elif len(names) == 1:
        result[names[0]] = False
    else:
        mid = len(names) // 2
        probe(session, dt, names[:mid], table, result)
        probe(session, dt, names[mid:], table, result)


def main():
    session = InferenceSession(devices=[CPU()])
    out = {}
    for dt in DTYPES:
        t0 = time.time()
        table = candidates(dt)
        result = {}
        probe(session, dt, sorted(table), table, result)
        out[dt] = result
        bad = sorted(k for k, v in result.items() if not v)
        print(f"{dt:5s} {len(result) - len(bad)}/{len(result)} compile ({time.time() - t0:.0f} s); refused: {', '.join(bad) or 'none'}", flush=True)
    json.dump(out, open(sys.argv[1], "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
