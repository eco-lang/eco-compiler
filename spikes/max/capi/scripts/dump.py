from max.dtype import DType
from max.graph import DeviceRef, Graph, TensorType, ops
x = TensorType(DType.float32, ("batch", 4), device=DeviceRef.CPU())
w = TensorType(DType.float32, (4, 3), device=DeviceRef.CPU())
b = TensorType(DType.float32, (3,), device=DeviceRef.CPU())
with Graph("mlp", input_types=(x, w, b)) as g:
    xi, wi, bi = g.inputs
    g.output(ops.relu(xi.tensor @ wi.tensor + bi.tensor))
print(g)
