"""A2.2: a synthetic safetensors checkpoint in PyTorch's layouts, and the parameters it should become in
eco-lab/tensor's layouts (one file per resident name, as Param.names gives them).

    make_checkpoint.py OUT_DIR
"""
import json
import os
import sys

import numpy as np

out = sys.argv[1]
os.makedirs(os.path.join(out, "expected"), exist_ok=True)
rng = np.random.default_rng(0)
f32 = lambda *s: rng.standard_normal(s).astype(np.float32)

tensors = {
    "lin.weight": f32(5, 4),                       # nn.Linear: [out, in]
    "lin.bias": f32(5),
    "conv.weight": f32(6, 3, 3, 3),                # nn.Conv2d: OIHW
    "conv.bias": f32(6),
    "qkv.weight": f32(24, 8),                      # fused q, k, v: [3 * 8, 8]
    "qkv.bias": f32(24),
    "half.weight": f32(5, 4).astype(np.float16),   # a half-precision linear without bias
}

header = {"__metadata__": {"format": "pt"}}
data = b""
for name, t in tensors.items():
    b = t.tobytes()
    header[name] = {"dtype": {np.float32: "F32", np.float16: "F16"}[t.dtype.type], "shape": list(t.shape),
                    "data_offsets": [len(data), len(data) + len(b)]}
    data += b
text = json.dumps(header).encode()
text += b" " * (-len(text) % 8)
with open(os.path.join(out, "synthetic.safetensors"), "wb") as f:
    f.write(len(text).to_bytes(8, "little") + text + data)

q, k, v = (tensors["qkv.weight"][i * 8:(i + 1) * 8] for i in range(3))
qb, kb, vb = (tensors["qkv.bias"][i * 8:(i + 1) * 8] for i in range(3))
expected = {
    "param0": tensors["lin.weight"].T,                       # Linear: [in, out]
    "param1": tensors["lin.bias"],
    "param2": tensors["conv.weight"].transpose(2, 3, 1, 0),  # RSCF: [kh, kw, in, out]
    "param3": tensors["conv.bias"],
    "qkv.param0": q.T, "qkv.param1": qb,
    "qkv.param2": k.T, "qkv.param3": kb,
    "qkv.param4": v.T, "qkv.param5": vb,
    "half.param": tensors["half.weight"].astype(np.float32).T,
}
for name, t in expected.items():
    np.ascontiguousarray(t, dtype=np.float32).tofile(os.path.join(out, "expected", name + ".bin"))
print(f"wrote {len(tensors)} tensors ({len(data)} bytes of data) and {len(expected)} expected parameters to {out}")
