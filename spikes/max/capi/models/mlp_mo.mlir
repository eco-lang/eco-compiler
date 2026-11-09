// Hand-written at the lower mo level: no rmo sugar, so the bias broadcast is
// explicit (b reshaped to [1,3] then implicit-broadcast by mo.add).
mo.graph @mlp_mo<batch>(%x: !mo.tensor<[batch, 4], f32>, %w: !mo.tensor<[4, 3], f32>, %b: !mo.tensor<[1, 3], f32>) -> !mo.tensor<[batch, 3], f32> attributes {argument_names = ["x", "w", "b"], result_names = ["y"]} {
  %0 = mo.matmul(%x, %w) : (!mo.tensor<[batch, 4], f32>, !mo.tensor<[4, 3], f32>) -> !mo.tensor<[batch, 3], f32>
  %1 = mo.add(%0, %b) : (!mo.tensor<[batch, 3], f32>, !mo.tensor<[1, 3], f32>) -> !mo.tensor<[batch, 3], f32>
  %2 = mo.relu(%1) : !mo.tensor<[batch, 3], f32>
  mo.output %2 : !mo.tensor<[batch, 3], f32>
}
