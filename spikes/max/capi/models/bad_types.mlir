// Shape error: [batch,4] @ [3,3] has mismatched inner dims.
mo.graph @badt<batch>(%x: !mo.tensor<[batch, 4], f32>, %w: !mo.tensor<[3, 3], f32>) -> !mo.tensor<[batch, 3], f32> attributes {argument_names = ["x", "w"], result_names = ["y"]} {
  %0 = rmo.matmul(%x, %w) : (!mo.tensor<[batch, 4], f32>, !mo.tensor<[3, 3], f32>) -> !mo.tensor<[batch, 3], f32>
  mo.output %0 : !mo.tensor<[batch, 3], f32>
}
