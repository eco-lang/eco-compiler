"""Round 2 (plans/tensor-api-round2.md): how MAX spells the operations the new primitives lower to.

Writes work/inventory/g15_round2.txt (custom and generic forms of each case).
"""
import sys
import os
HERE = os.path.dirname(os.path.abspath(__file__))
DUMPS = os.environ.get("INVENTORY_DUMPS", os.path.join(HERE, "..", "..", "..", "work", "inventory"))
os.makedirs(DUMPS, exist_ok=True)
sys.path.insert(0, HERE)
from harness import *  # noqa
f32, i64 = DType.float32, DType.int64
g = Group(os.path.join(DUMPS, "g15_round2.txt"))
# element-wise scatter along an axis: indices shaped like the updates
g.case("scatter axis 1", (T(f32, (2, 5, 3)), T(f32, (2, 2, 3)), T(i64, (2, 2, 3))), lambda gr, x, u, i: ops.scatter(x, u, i, axis=1))
g.case("scatter_add axis 1", (T(f32, (2, 5, 3)), T(f32, (2, 2, 3)), T(i64, (2, 2, 3))), lambda gr, x, u, i: ops.scatter_add(x, u, i, axis=1))
g.case("top_k middle axis", (T(f32, (2, 5, 3)),), lambda gr, x: tuple(ops.top_k(x, 2, axis=1)))
g.case("bottom_k middle axis", (T(f32, (2, 5, 3)),), lambda gr, x: tuple(ops.bottom_k(x, 2, axis=1)))
g.write()
