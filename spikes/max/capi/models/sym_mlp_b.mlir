// Same op kinds as sym_mlp, different graph: relu(x@w + b) + b.
mo.graph @symmlpb<batch, k, n>(%x: !mo.tensor<[batch, k], f32>, %w: !mo.tensor<[k, n], f32>, %b: !mo.tensor<[n], f32>) -> !mo.tensor<[batch, n], f32> attributes {argument_names = ["x", "w", "b"], result_names = ["y"]} {
  %0 = rmo.matmul(%x, %w) : (!mo.tensor<[batch, k], f32>, !mo.tensor<[k, n], f32>) -> !mo.tensor<[batch, n], f32>
  %1 = rmo.add(%0, %b) : (!mo.tensor<[batch, n], f32>, !mo.tensor<[n], f32>) -> !mo.tensor<[batch, n], f32>
  %2 = rmo.mo.relu(%1) : (!mo.tensor<[batch, n], f32>) -> !mo.tensor<[batch, n], f32>
  %3 = rmo.add(%2, %b) : (!mo.tensor<[batch, n], f32>, !mo.tensor<[n], f32>) -> !mo.tensor<[batch, n], f32>
  mo.output %3 : !mo.tensor<[batch, n], f32>
}
