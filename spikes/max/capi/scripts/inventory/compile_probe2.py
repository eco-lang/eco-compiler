import sys
import os
HERE = os.path.dirname(os.path.abspath(__file__))
DUMPS = os.environ.get("INVENTORY_DUMPS", os.path.join(HERE, "..", "..", "..", "work", "inventory"))
os.makedirs(DUMPS, exist_ok=True)
sys.path.insert(0, HERE)
from harness import *  # noqa
from max.driver import CPU
from max.engine import InferenceSession
sess = InferenceSession(devices=[CPU()])
for title, ty, fn in [("exp si64", T(DType.int64, (2, 3)), lambda x: ops.exp(x)),
                      ("softmax axis=-2", T(DType.float32, (2, 3, 4)), lambda x: ops.softmax(x, axis=-2)),
                      ("softmax axis=1 (control)", T(DType.float32, (2, 3, 4)), lambda x: ops.softmax(x, axis=1))]:
    with Graph("p_" + title.split()[0], input_types=(ty,)) as g:
        g.output(fn(g.inputs[0].tensor))
    try:
        sess.load(g); print("###", title, "COMPILED OK")
    except Exception as e:
        print("###", title, "FAILED:", str(e)[:3000])
