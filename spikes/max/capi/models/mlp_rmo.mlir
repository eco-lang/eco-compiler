// Hand-written: relu(x @ w + b) with a symbolic batch dim, at the rmo level
// that MAX's own Python API emits.
mo.graph @mlp<batch>(%x: !mo.tensor<[batch, 4], f32>, %w: !mo.tensor<[4, 3], f32>, %b: !mo.tensor<[3], f32>) -> !mo.tensor<[batch, 3], f32> attributes {argument_names = ["x", "w", "b"], result_names = ["y"]} {
  %0 = rmo.matmul(%x, %w) : (!mo.tensor<[batch, 4], f32>, !mo.tensor<[4, 3], f32>) -> !mo.tensor<[batch, 3], f32>
  %1 = rmo.add(%0, %b) : (!mo.tensor<[batch, 3], f32>, !mo.tensor<[3], f32>) -> !mo.tensor<[batch, 3], f32>
  %2 = rmo.mo.relu(%1) : (!mo.tensor<[batch, 3], f32>) -> !mo.tensor<[batch, 3], f32>
  mo.output %2 : !mo.tensor<[batch, 3], f32>
}
