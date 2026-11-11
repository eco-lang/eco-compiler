import sys
import os
HERE = os.path.dirname(os.path.abspath(__file__))
DUMPS = os.environ.get("INVENTORY_DUMPS", os.path.join(HERE, "..", "..", "..", "work", "inventory"))
os.makedirs(DUMPS, exist_ok=True)
sys.path.insert(0, HERE)
from harness import *  # noqa
from max.graph.type import ConvInputLayout, FilterLayout

f32 = DType.float32
i64 = DType.int64

# ---- 7. conv / pool ----
g = Group(os.path.join(DUMPS, "g7_conv.txt"))
X = T(f32, (1, 8, 8, 3))     # NHWC
W = T(f32, (3, 3, 3, 4))     # RSCF: R=kh, S=kw, C=in, F=out
g.case("conv2d NHWC/RSCF default", (X, W), lambda gr, x, w: ops.conv2d(x, w))
g.case("conv2d stride(2,2) dilation(1,1) padding(1,1,1,1)", (X, W), lambda gr, x, w: ops.conv2d(x, w, stride=(2, 2), padding=(1, 1, 1, 1)), want_generic=False)
g.case("conv2d stride(1,2) dilation(2,1) padding(0,1,2,3) + bias", (X, W, T(f32, (4,))),
       lambda gr, x, w, b: ops.conv2d(x, w, stride=(1, 2), dilation=(2, 1), padding=(0, 1, 2, 3), bias=b))
g.case("conv2d groups=3 filter [3,3,1,6]", (X, T(f32, (3, 3, 1, 6))), lambda gr, x, w: ops.conv2d(x, w, groups=3), want_generic=False)
g.case("conv2d filter_layout=FCRS filter [4,3,3,3]", (X, T(f32, (4, 3, 3, 3))), lambda gr, x, w: ops.conv2d(x, w, filter_layout=FilterLayout.FCRS), want_generic=True)
g.case("conv2d input_layout=NCHW x[1,3,8,8] (probe)", (T(f32, (1, 3, 8, 8)), W), lambda gr, x, w: ops.conv2d(x, w, input_layout=ConvInputLayout.NCHW), want_generic=False)
# conv2d_transpose filter layout RSCF: (kh, kw, out, in)?
g.case("conv2d_transpose NHWC/RSCF filter [3,3,4,3] stride 2", (X, T(f32, (3, 3, 4, 3))),
       lambda gr, x, w: ops.conv2d_transpose(x, w, stride=(2, 2)))
g.case("conv2d_transpose with padding(1,1,1,1) output_paddings(1,1) + bias", (X, T(f32, (3, 3, 4, 3)), T(f32, (4,))),
       lambda gr, x, w, b: ops.conv2d_transpose(x, w, stride=(2, 2), padding=(1, 1, 1, 1), output_paddings=(1, 1), bias=b), want_generic=False)
g.case("avg_pool2d k(2,2) stride 2", (X,), lambda gr, x: ops.avg_pool2d(x, (2, 2), stride=2))
g.case("avg_pool2d k(3,3) stride(1,2) dil 1 padding(1,0) ceil_mode count_boundary=False", (X,),
       lambda gr, x: ops.avg_pool2d(x, (3, 3), stride=(1, 2), padding=(1, 0), ceil_mode=True, count_boundary=False), want_generic=False)
g.case("max_pool2d k(2,2) stride 2", (X,), lambda gr, x: ops.max_pool2d(x, (2, 2), stride=2))
g.case("max_pool2d k(3,3) stride 1 dilation 2 padding 1", (X,), lambda gr, x: ops.max_pool2d(x, (3, 3), stride=1, dilation=2, padding=1), want_generic=False)
g.write()

# ---- 8. random ----
g = Group(os.path.join(DUMPS, "g8_random.txt"))
like = T(f32, (2, 3))


def r1(gr):
    ops.random.set_seed(42)
    return ops.random.gaussian(like, mean=0.0, std=1.0)


def r2(gr):
    ops.random.set_seed(42)
    a = ops.random.uniform(like, range=(0.0, 1.0))
    b = ops.random.uniform(like, range=(-1.0, 1.0))
    c = ops.random.normal(like)
    return a, b, c


def r3(gr, seed):
    ops.random.set_seed(seed)
    return ops.random.uniform(like)


def r4(gr):
    ops.random.set_seed(7)
    return ops.random.gaussian(T(i64, (2, 3)))


def r5(gr):
    return ops.random.uniform(like)


g.case("set_seed(42); gaussian(f32[2,3], mean 0, std 1)", (), r1)
g.case("set_seed(42); uniform x2 then normal (seed rotation)", (), r2, want_generic=False)
g.case("seed as graph input SeedType(CPU) ([1] ui64)", (ops.random.SeedType(C),), r3)
g.case("gaussian with integer like (si64)", (), r4, want_generic=False)
g.case("uniform without set_seed (probe)", (), r5, want_generic=False)
import inspect
g.out.append("=" * 100)
g.out.append("### random module public names: %s" % [n for n in dir(ops.random) if not n.startswith("_")])
g.out.append("### SeedType(CPU) = %r" % (ops.random.SeedType(C),))
g.write()

# ---- 9. control flow ----
g = Group(os.path.join(DUMPS, "g9_control.txt"))
P = T(DType.bool, ())
XF = T(f32, (2, 3))
g.case("cond(pred, [f32[2,3]], x+1, x*2)", (P, XF),
       lambda gr, p, x: tuple(ops.cond(p, [XF], lambda: x + 1.0, lambda: x * 2.0)))
g.case("cond with out_types=None (no results)", (P, XF),
       lambda gr, p, x: (ops.cond(p, None, lambda: None, lambda: None), x)[1], want_generic=False)
g.case("cond with two results", (P, XF),
       lambda gr, p, x: tuple(ops.cond(p, [XF, XF], lambda: (x, x + 1.0), lambda: (x * 2.0, x))), want_generic=False)


def wl(gr, n, x):
    res = ops.while_loop((n, x), lambda i, v: i < 5, lambda i, v: (i + 1, v * 2.0))
    return tuple(res)


g.case("while_loop((i si64[], x f32[2,3]), i<5, (i+1, x*2))", (T(i64, ()), XF), wl)
g.write()

# ---- 10. subgraphs ----
g = Group(os.path.join(DUMPS, "g10_subgraph.txt"))


def sg(gr, x):
    with gr.add_subgraph("add_one", input_types=[XF]) as sub:
        y = sub.inputs[0].tensor
        sub.output(ops.relu(y + 1.0))
    a = ops.call(sub, x)[0]
    b = ops.call(sub, a)[0]
    return b


g.case("subgraph add_one called twice", (XF,), sg, whole_module=True)


def sg2(gr, x, w):
    def fwd(a, b):
        return a @ b, a
    sub = gr.add_subgraph("two_out", forward=fwd, input_types=[XF, T(f32, (3, 3))])
    r = ops.call(sub, x, w, prefix="layer0.")
    r2 = ops.call(sub, r[0], w, prefix="layer1.")
    return r2[0], r2[1]


g.case("subgraph two inputs two outputs, forward=, prefix=", (XF, T(f32, (3, 3))), sg2, whole_module=True)
g.write()

# ---- 11. symbolic dims ----
g = Group(os.path.join(DUMPS, "g11_symbolic.txt"))
g.case("matmul [batch,4]@[4,3]", (T(f32, ("batch", 4)), T(f32, (4, 3))), lambda gr, a, b: a @ b)
g.case("matmul [batch,k]@[k,n] all symbolic", (T(f32, ("batch", "k")), T(f32, ("k", "n"))), lambda gr, a, b: a @ b)
g.case("matmul [batch,k]@[j,n] mismatched symbols (probe)", (T(f32, ("batch", "k")), T(f32, ("j", "n"))), lambda gr, a, b: a @ b, want_generic=False)
g.case("rebind [batch,k] -> [batch,j] then matmul", (T(f32, ("batch", "k")), T(f32, ("j", "n"))),
       lambda gr, a, b: ops.rebind(a, ("batch", "j")) @ b)
g.case("reshape [batch,3]->[batch*3] and [n] output param (range out_dim)", (T(f32, ("batch", 3)), T(i64, ())),
       lambda gr, x, n: (ops.reshape(x, (-1,)), ops.range(0, n, 1, out_dim="m", dtype=i64, device=C)))
g.case("sum over symbolic axis [batch,3] axis=0", (T(f32, ("batch", 3)),), lambda gr, x: ops.sum(x, axis=0), want_generic=False)
g.case("broadcast [batch,1] + [1,n]", (T(f32, ("batch", 1)), T(f32, (1, "n"))), lambda gr, a, b: a + b, want_generic=False)
g.case("concat [a,3]+[b,3]", (T(f32, ("a", 3)), T(f32, ("b", 3))), lambda gr, a, b: ops.concat([a, b]), want_generic=False)
g.write()

# ---- 12. custom ----
g = Group(os.path.join(DUMPS, "g12_custom.txt"))
g.case("custom('my_kernel', CPU, [x, y], [f32[2,3]])", (XF, XF),
       lambda gr, x, y: ops.custom("my_kernel", C, [x, y], [XF])[0].tensor)
g.case("custom with parameters {bool,int,float,str,dtype}", (XF,),
       lambda gr, x: ops.custom("my_kernel", C, [x], [XF, T(i64, (2,))],
                                parameters={"flag": True, "n": 3, "eps": 0.5, "mode": "fast", "dt": DType.float32})[0].tensor)


def ip(gr, x):
    from max.graph import BufferType
    buf = ops.buffer_create(BufferType(f32, (2, 3), device=C))
    ops.inplace_custom("my_inplace", C, [buf, x])
    return ops.buffer_load(buf)


g.case("inplace_custom on a buffer (side-effecting, chains)", (XF,), ip)
g.write()
