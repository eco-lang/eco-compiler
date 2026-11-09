from max.dtype import DType
from max.graph import DeviceRef, Graph, TensorType, ops
C = DeviceRef.CPU()
B = 4
with Graph("allops", input_types=(TensorType(DType.uint8, (B, 6), device=C),
                                   TensorType(DType.uint8, (B,), device=C),
                                   TensorType(DType.float32, (6, 3), device=C),
                                   TensorType(DType.float32, (3,), device=C))) as g:
    x8, y8, w, b = (v.tensor for v in g.inputs)
    x = ops.cast(x8, DType.float32) * (1.0 / 255.0)
    z = x @ w + b
    h = ops.relu(z)
    mask = ops.cast(ops.greater(z, 0.0), DType.float32)
    sm = ops.softmax(z)
    lsm = ops.logsoftmax(z)
    yi = ops.reshape(ops.cast(y8, DType.int64), (B, 1))
    iota = ops.range(0, 3, 1, dtype=DType.int64, device=C)
    onehot = ops.cast(ops.equal(yi, iota), DType.float32)
    loss = -ops.sum(ops.sum(onehot * lsm, axis=1), axis=0) / float(B)
    xt = ops.transpose(x, 0, 1)
    gw = xt @ (sm - onehot)
    gb = ops.reshape(ops.sum(sm - onehot, axis=0), (3,))
    am = ops.argmax(z, axis=1)
    g.output(h * mask, loss, gw, gb, am, w - gw * 0.1)
print(g)
