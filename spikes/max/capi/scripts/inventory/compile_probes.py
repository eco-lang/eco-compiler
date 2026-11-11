"""Does MAX *compile* (not just build) a few questionable graphs? One InferenceSession.load each."""
import sys
import time
import traceback

import os
HERE = os.path.dirname(os.path.abspath(__file__))
DUMPS = os.environ.get("INVENTORY_DUMPS", os.path.join(HERE, "..", "..", "..", "work", "inventory"))
os.makedirs(DUMPS, exist_ok=True)
sys.path.insert(0, HERE)
from harness import *  # noqa
from max.driver import CPU
from max.engine import InferenceSession

f32, i64 = DType.float32, DType.int64
I = T(i64, (2, 3))
X = T(f32, (2, 3, 4))
probes = [
    ("exp on si64", (I,), lambda x: ops.exp(x)),
    ("sqrt on si64", (I,), lambda x: ops.sqrt(x)),
    ("sigmoid on si64", (I,), lambda x: ops.sigmoid(x)),
    ("mean on si64", (I,), lambda x: ops.mean(x, axis=1)),
    ("softmax axis=-2 (negative axis passed through)", (X,), lambda x: ops.softmax(x, axis=-2)),
    ("concat axis=-1", (T(f32, (2, 3)), T(f32, (2, 1))), lambda a, b: ops.concat([a, b], axis=-1)),
]
sess = InferenceSession(devices=[CPU()])
out = []
for i, (title, types, fn) in enumerate(probes):
    t0 = time.time()
    try:
        with Graph("probe%d" % i, input_types=types) as g:
            g.output(fn(*[v.tensor for v in g.inputs]))
        sess.load(g)
        res = "COMPILED OK"
    except Exception as e:
        res = "FAILED: %s: %s" % (type(e).__name__, str(e)[:1500])
    out.append("### %s  (%.1fs)\n%s\n" % (title, time.time() - t0, res))
    print(out[-1], flush=True)
open(os.path.join(DUMPS, "compile_probes.txt"), "w").write("\n".join(out))
