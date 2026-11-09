mo.graph @bad<batch>(%x: !mo.tensor<[batch, 4], f32>) -> !mo.tensor<[batch, 4], f32> attributes {argument_names = ["x"], result_names = ["y"]} {
  %0 = rmo.add(%x, %x : !mo.tensor<[batch, 4], f32>
  mo.output %0 : !mo.tensor<[batch, 4], f32>
}
