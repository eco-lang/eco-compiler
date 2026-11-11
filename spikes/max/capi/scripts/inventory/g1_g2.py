import sys
import os
HERE = os.path.dirname(os.path.abspath(__file__))
DUMPS = os.environ.get("INVENTORY_DUMPS", os.path.join(HERE, "..", "..", "..", "work", "inventory"))
os.makedirs(DUMPS, exist_ok=True)
sys.path.insert(0, HERE)
from harness import *  # noqa

F = T(DType.float32, (2, 3))
I = T(DType.int64, (2, 3))
B = T(DType.bool, (2, 3))

g = Group(os.path.join(DUMPS, "g1_unary.txt"))
for name in ["abs", "negate", "exp", "log", "log1p", "sqrt", "rsqrt", "sin", "cos", "acos",
             "atanh", "erf", "floor", "ceil", "round", "trunc", "relu", "sigmoid", "tanh", "silu",
             "is_inf", "is_nan"]:
    fn = getattr(ops, name)
    g.case("%s f32[2,3]" % name, (F,), lambda gr, x, fn=fn: fn(x), want_generic=(name in ("exp", "relu", "is_nan", "acos")))
g.case("gelu approximate='none' f32", (F,), lambda gr, x: ops.gelu(x), want_generic=False)
g.case("gelu approximate='tanh' f32", (F,), lambda gr, x: ops.gelu(x, approximate="tanh"), want_generic=False)
g.case("gelu approximate='quick' f32", (F,), lambda gr, x: ops.gelu(x, approximate="quick"), want_generic=False)
g.case("logical_not bool", (B,), lambda gr, x: ops.logical_not(x))
g.case("logical_not on f32 (probe)", (F,), lambda gr, x: ops.logical_not(x), want_generic=False)
# float-only probes on int input
for name in ["exp", "log", "sqrt", "sin", "tanh", "erf", "floor", "sigmoid", "relu", "abs", "negate", "is_nan", "acos", "gelu"]:
    fn = getattr(ops, name)
    g.case("PROBE %s on si64" % name, (I,), lambda gr, x, fn=fn: fn(x), want_generic=False)
# casts
g.case("cast f32->i64", (F,), lambda gr, x: ops.cast(x, DType.int64))
g.case("cast i64->f32", (I,), lambda gr, x: ops.cast(x, DType.float32), want_generic=False)
g.case("cast u8->f32", (T(DType.uint8, (2, 3)),), lambda gr, x: ops.cast(x, DType.float32), want_generic=False)
g.case("cast f32->bf16", (F,), lambda gr, x: ops.cast(x, DType.bfloat16), want_generic=False)
g.case("cast f32->f32 (no-op?)", (F,), lambda gr, x: ops.cast(x, DType.float32), want_generic=False)
g.case("cast bool->f32", (B,), lambda gr, x: ops.cast(x, DType.float32), want_generic=False)
g.write()

g = Group(os.path.join(DUMPS, "g2_binary.txt"))
for name in ["add", "sub", "mul", "div", "mod", "pow", "max", "min", "equal", "not_equal", "greater",
             "greater_equal", "less", "less_equal"]:
    fn = getattr(ops, name, None)
    if fn is None:
        g.out.append("### %s: ops.%s does not exist" % (name, name))
        continue
    g.case("%s f32[2,3] f32[2,3]" % name, (F, F), lambda gr, a, b, fn=fn: fn(a, b),
           want_generic=(name in ("add", "less", "max")))
for name in ["logical_and", "logical_or", "logical_xor"]:
    fn = getattr(ops, name)
    g.case("%s bool bool" % name, (B, B), lambda gr, a, b, fn=fn: fn(a, b), want_generic=False)
g.case("floor_div f32", (F, F), lambda gr, a, b: ops.floor_div(a, b), want_generic=False)
g.case("floor_div si64 (composition)", (I, I), lambda gr, a, b: ops.floor_div(a, b), want_generic=False)
g.case("div si64 si64 (promotes to f64)", (I, I), lambda gr, a, b: ops.div(a, b), want_generic=False)
g.case("mod si64", (I, I), lambda gr, a, b: ops.mod(a, b), want_generic=False)
g.case("max (python builtin-like ops.max with two tensors)", (F, F), lambda gr, a, b: ops.max(a, b), want_generic=False)
# operators
g.case("python operators a+b a-b a*b a/b a**b -a a<b a<=b a//b a%b", (F, F),
       lambda gr, a, b: (a + b, a - b, a * b, a / b, a ** b, -a, a < b, a <= b, a // b, a % b), want_generic=False)
# broadcasting
g.case("BROADCAST add f32[2,3] + f32[3]", (F, T(DType.float32, (3,))), lambda gr, a, b: ops.add(a, b))
g.case("BROADCAST add f32[2,1] + f32[1,3]", (T(DType.float32, (2, 1)), T(DType.float32, (1, 3))), lambda gr, a, b: ops.add(a, b), want_generic=False)
g.case("BROADCAST add f32[2,3] + python scalar 2.0", (F,), lambda gr, a: a + 2.0, want_generic=False)
g.case("BROADCAST incompatible f32[2,3] + f32[4] (probe)", (F, T(DType.float32, (4,))), lambda gr, a, b: a + b, want_generic=False)
g.case("BROADCAST symbolic f32[n,3] + f32[3]", (T(DType.float32, ("n", 3)), T(DType.float32, (3,))), lambda gr, a, b: a + b)
# dtype promotion
g.case("PROMO f32 + si64 tensors (probe)", (F, I), lambda gr, a, b: a + b, want_generic=False)
g.case("PROMO si64 tensor + python float 0.5 (probe)", (I,), lambda gr, a: a + 0.5, want_generic=False)
g.case("PROMO f32 + f64 tensors (probe)", (F, T(DType.float64, (2, 3))), lambda gr, a, b: a + b, want_generic=False)
g.case("PROMO si32 + si64 tensors (probe)", (T(DType.int32, (2, 3)), I), lambda gr, a, b: a + b, want_generic=False)
g.case("logical_and on f32 (probe)", (F, F), lambda gr, a, b: ops.logical_and(a, b), want_generic=False)
g.write()
