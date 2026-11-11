import sys
import os
HERE = os.path.dirname(os.path.abspath(__file__))
DUMPS = os.environ.get("INVENTORY_DUMPS", os.path.join(HERE, "..", "..", "..", "work", "inventory"))
os.makedirs(DUMPS, exist_ok=True)
sys.path.insert(0, HERE)
from harness import *  # noqa
from max.graph import BufferType
from max.graph.graph import KernelLibrary

f32 = DType.float32
i64 = DType.int64
XF = T(f32, (2, 3))

g = Group(os.path.join(DUMPS, "g12_custom.txt"))
g.out.append("NOTE: ops.custom/inplace_custom verify the symbol against the loaded kernel library;")
g.out.append("for the arbitrary names below KernelLibrary.verify_custom_op is stubbed to a no-op so the")
g.out.append("IR shape can be printed. Built-in kernels reached via mo.custom (mo.acos, mx.argsort,")
g.out.append("repeat_interleave) are shown unstubbed in g1/g4/g6.")
g.case("UNSTUBBED custom('my_kernel', ...) -> error", (XF, XF),
       lambda gr, x, y: ops.custom("my_kernel", C, [x, y], [XF])[0].tensor, want_generic=False)
_orig = KernelLibrary.verify_custom_op
KernelLibrary.verify_custom_op = lambda self, op: None
g.case("custom('my_kernel', CPU, [x, y], [f32[2,3]])", (XF, XF),
       lambda gr, x, y: ops.custom("my_kernel", C, [x, y], [XF])[0].tensor)
g.case("custom with parameters {bool,int,float,str,dtype} and two results", (XF,),
       lambda gr, x: tuple(v.tensor for v in ops.custom("my_kernel", C, [x], [XF, T(i64, (2,))],
                           parameters={"flag": True, "n": 3, "eps": 0.5, "mode": "fast", "dt": DType.float32})))


def ip(gr, x):
    buf = ops.buffer_create(BufferType(f32, (2, 3), device=C))
    ops.inplace_custom("my_inplace", C, [buf, x])
    return ops.buffer_load(buf)


g.case("inplace_custom on a buffer (side-effecting, chains)", (XF,), ip)
KernelLibrary.verify_custom_op = _orig
g.write()

g = Group(os.path.join(DUMPS, "g13_extra.txt"))
X = T(f32, (1, 8, 8, 3))
g.case("conv2d_transpose stride 2 padding(1,1,1,1) output_paddings(1,1), NO bias", (X, T(f32, (3, 3, 4, 3))),
       lambda gr, x, w: ops.conv2d_transpose(x, w, stride=(2, 2), padding=(1, 1, 1, 1), output_paddings=(1, 1)), want_generic=False)
g.case("conv2d_transpose stride 1 + bias [4] (bias path permutes as if NCHW)", (X, T(f32, (3, 3, 4, 3)), T(f32, (4,))),
       lambda gr, x, w, b: ops.conv2d_transpose(x, w, bias=b), want_generic=False)


def wl_capture(gr, n, x, y):
    return tuple(ops.while_loop((n, x), lambda i, v: i < 3, lambda i, v: (i + 1, v + y)))


g.case("while_loop body captures outer value y", (T(i64, ()), XF, XF), wl_capture, want_generic=True)


def cond_in_loop_side_effect(gr, p, x):
    buf = ops.buffer_create(BufferType(f32, (2, 3), device=C))
    ops.buffer_store(buf, x)
    ops.cond(p, None, lambda: ops.buffer_store(buf, x * 2.0), lambda: None)
    return ops.buffer_load(buf)


g.case("cond with a buffer side effect (chain threading)", (T(DType.bool, ()), XF), cond_in_loop_side_effect)
g.case("mean f32 -> composition? axis=0 [2,3]", (XF,), lambda gr, x: ops.mean(x, axis=0), want_generic=False)
g.case("abs(x) via python abs()", (XF,), lambda gr, x: abs(x), want_generic=False)
g.case("x.cast / x.reshape / x.transpose method spellings", (XF,), lambda gr, x: (x.cast(i64), x.reshape((3, 2)), x.transpose(0, 1)), want_generic=False)
g.case("ops.print (debug) side effect", (XF,), lambda gr, x: (ops.print(x, "x"), x)[1], want_generic=True)
g.case("ops.transfer_to CPU->CPU (no-op?)", (XF,), lambda gr, x: ops.transfer_to(x, C), want_generic=False)
g.write()
