import sys, time
from max import engine
from max.driver import CPU
from max.dtype import DType
from max.graph import DeviceRef, Graph, TensorType, ops
k, n = int(sys.argv[1]), int(sys.argv[2])
t = lambda s: TensorType(DType.float32, s, device=DeviceRef.CPU())
with Graph(f"mlp_{k}_{n}", input_types=(t(("batch", k)), t((k, n)), t((n,)))) as g:
    x, w, b = g.inputs
    g.output(ops.relu(x.tensor @ w.tensor + b.tensor))
s = engine.InferenceSession(devices=[CPU()])
t0 = time.time(); s.load(g); print(f"python load k={k} n={n}: {(time.time()-t0)*1000:.0f} ms")
