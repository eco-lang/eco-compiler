"""Round 2, A3: how a graph's IR changes when it runs on a GPU. Builds one small graph per lowering
pattern eco-lab/tensor uses with DeviceRef.GPU() (no GPU needed to build) and writes
work/inventory/g16_gpu.txt (custom and generic forms).
"""
import sys
import os
HERE = os.path.dirname(os.path.abspath(__file__))
DUMPS = os.environ.get("INVENTORY_DUMPS", os.path.join(HERE, "..", "..", "..", "work", "inventory"))
os.makedirs(DUMPS, exist_ok=True)
sys.path.insert(0, HERE)
import harness  # noqa
from harness import *  # noqa

G = DeviceRef.GPU()
harness.C = G  # every T(...) input on the GPU
f32, i64 = DType.float32, DType.int64
g = Group(os.path.join(DUMPS, "g16_gpu.txt"))
g.case("elementwise + constant", (T(f32, (2, 3)),), lambda gr, x: x * 2 + ops.exp(x))
g.case("matmul", (T(f32, (2, 3)), T(f32, (3, 4))), lambda gr, x, w: x @ w)
g.case("reduce sum keep", (T(f32, (2, 3)),), lambda gr, x: ops.sum(x, axis=1))
g.case("reshape, transpose, broadcast", (T(f32, (2, 3)),), lambda gr, x: ops.broadcast_to(ops.transpose(x, 0, 1).reshape((3, 2, 1)), (3, 2, 4)))
g.case("slice and concat", (T(f32, (4, 3)),), lambda gr, x: ops.concat([x[1:3], x[0:1]], axis=0))
g.case("pad", (T(f32, (2, 3)),), lambda gr, x: ops.pad(x, [1, 0, 0, 2]))
g.case("gather", (T(f32, (5, 3)), T(i64, (2,))), lambda gr, x, i: ops.gather(x, i, axis=0))
g.case("scatter", (T(f32, (2, 5, 3)), T(f32, (2, 2, 3)), T(i64, (2, 2, 3))), lambda gr, x, u, i: ops.scatter(x, u, i, axis=1))
g.case("scatter_add", (T(f32, (2, 5, 3)), T(f32, (2, 2, 3)), T(i64, (2, 2, 3))), lambda gr, x, u, i: ops.scatter_add(x, u, i, axis=1))
g.case("top_k last axis", (T(f32, (3, 5)),), lambda gr, x: tuple(ops.top_k(x, 2, axis=-1)))
g.case("top_k middle axis", (T(f32, (2, 5, 3)),), lambda gr, x: tuple(ops.top_k(x, 2, axis=1)))
g.case("bottom_k", (T(f32, (3, 5)),), lambda gr, x: tuple(ops.bottom_k(x, 2)))
g.case("range", (), lambda gr: ops.range(0, 5, 1, dtype=i64, device=G))
g.case("random uniform", (T(f32, (2, 3)),), lambda gr, x: (ops.random.set_seed(5), x + ops.random.uniform(TensorType(f32, (2, 3), device=G)))[1])
g.case("layer_norm", (T(f32, (2, 4)), T(f32, (4,)), T(f32, (4,))), lambda gr, x, a, b: ops.layer_norm(x, a, b, 1e-5))
g.case("softmax, cumsum", (T(f32, (2, 4)),), lambda gr, x: ops.cumsum(ops.softmax(x), axis=1))
g.case("conv", (T(f32, (1, 5, 5, 2)), T(f32, (3, 3, 2, 4))), lambda gr, x, f: ops.conv2d(x, f))
g.case("max_pool", (T(f32, (1, 4, 4, 2)),), lambda gr, x: ops.max_pool2d(x, (2, 2), stride=2))
g.case("band_part", (T(f32, (3, 3)),), lambda gr, x: ops.band_part(x, None, 0))
g.case("cast, where", (T(f32, (2, 3)),), lambda gr, x: ops.where(x > 0, ops.cast(x, i64), ops.cast(x * 0, i64)))
g.case("argmax", (T(f32, (2, 3)),), lambda gr, x: ops.argmax(x, axis=1))
g.case("acos (mo.custom)", (T(f32, (2, 3)),), lambda gr, x: ops.acos(x))
g.case("transfer to the CPU", (T(f32, (2, 3)),), lambda gr, x: ops.transfer_to(x, DeviceRef.CPU()))
# every other op family the package lowers to
for fn in ["abs", "atanh", "cos", "erf", "floor", "gelu", "log", "log1p", "negate", "relu", "round", "rsqrt", "sigmoid", "silu", "sin", "sqrt", "tanh", "trunc"]:
    g.case("unary " + fn, (T(f32, (2, 3)),), lambda gr, x, fn=fn: getattr(ops, fn)(x))
g.case("gelu tanh", (T(f32, (2, 3)),), lambda gr, x: ops.gelu(x, approximate="tanh"))
g.case("is_inf, is_nan, logical not", (T(f32, (2, 3)),), lambda gr, x: ops.logical_not(ops.is_inf(x) | ops.is_nan(x)))
g.case("binary sub div pow max min mod", (T(f32, (2, 3)), T(f32, (2, 3))), lambda gr, x, y: ops.mod(ops.min(ops.max(ops.pow(ops.div(x - y, y), y), x), y), y))
g.case("comparisons", (T(f32, (2, 3)), T(f32, (2, 3))), lambda gr, x, y: ops.logical_xor(ops.logical_or(ops.equal(x, y), ops.not_equal(x, y)), ops.logical_and(ops.greater_equal(x, y), x > y)))
g.case("reduce mean max min arg_min", (T(f32, (2, 3)),), lambda gr, x: (ops.mean(x, axis=1), ops.max(x, axis=1), ops.min(x, axis=1), ops.argmin(x, axis=1)))
g.case("logsoftmax", (T(f32, (2, 3)),), lambda gr, x: ops.logsoftmax(x))
g.case("random normal", (T(f32, (2, 3)),), lambda gr, x: (ops.random.set_seed(5), x + ops.random.normal(TensorType(f32, (2, 3), device=G)))[1])
g.case("conv_transpose", (T(f32, (1, 3, 3, 2)), T(f32, (3, 3, 4, 2))), lambda gr, x, f: ops.conv2d_transpose(x, f))
g.case("avg_pool", (T(f32, (1, 4, 4, 2)),), lambda gr, x: ops.avg_pool2d(x, (2, 2), stride=2))
g.case("scatter_nd_add", (T(f32, (5, 3)), T(f32, (2, 3)), T(i64, (2, 1))), lambda gr, x, u, i: ops.scatter_nd_add(x, u, i))
# predicates must be on the CPU: MAX refuses a GPU predicate, so they are transferred
g.case("cond (predicate transferred to the CPU)", (T(DType.bool, ()), T(f32, (2, 3))), lambda gr, p, x: ops.cond(ops.transfer_to(p, DeviceRef.CPU()), [TensorType(f32, (2, 3), device=G)], lambda: x * 2, lambda: x * 3))
g.case("while_loop (predicate transferred to the CPU)", (T(f32, (2, 3)),), lambda gr, x: ops.while_loop([x], lambda v: ops.transfer_to(ops.sum(ops.sum(v, axis=1), axis=0).reshape(()) < 100, DeviceRef.CPU()), lambda v: [v * 2])[0])
g.write()
