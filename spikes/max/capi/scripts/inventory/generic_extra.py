import sys
import os
HERE = os.path.dirname(os.path.abspath(__file__))
DUMPS = os.environ.get("INVENTORY_DUMPS", os.path.join(HERE, "..", "..", "..", "work", "inventory"))
os.makedirs(DUMPS, exist_ok=True)
sys.path.insert(0, HERE)
from harness import *  # noqa
f32, i64 = DType.float32, DType.int64
g = Group(os.path.join(DUMPS, "g14_generic_extra.txt"))
g.case("gather_nd", (T(f32, (5, 3)), T(i64, (4, 2))), lambda gr, x, i: ops.gather_nd(x, i))
g.case("scatter_nd_add", (T(f32, (5, 3)), T(f32, (2, 3)), T(i64, (2, 1))), lambda gr, x, u, i: ops.scatter_nd_add(x, u, i))
g.case("bottom_k", (T(f32, (3, 5)),), lambda gr, x: tuple(ops.bottom_k(x, 2)))
g.case("nonzero", (T(f32, (3, 5)),), lambda gr, x: ops.nonzero(x, "nz"))
g.case("rebind", (T(f32, ("n", 3)),), lambda gr, x: ops.rebind(x, ("m", 3)))
g.case("shape_to_tensor symbolic", (T(f32, ("n", 3)),), lambda gr, x: ops.shape_to_tensor(x.shape))
g.case("argsort", (T(f32, (5,)),), lambda gr, x: ops.argsort(x))
g.case("cast to bf16 + constant bf16", (T(f32, (2,)),), lambda gr, x: ops.cast(x, DType.bfloat16) + ops.constant([1.0, 2.0], DType.bfloat16, device=C))
g.case("mean", (T(f32, (2, 3)),), lambda gr, x: ops.mean(x, axis=0))
g.case("max reduce", (T(f32, (2, 3)),), lambda gr, x: ops.max(x, axis=0))
g.write()
