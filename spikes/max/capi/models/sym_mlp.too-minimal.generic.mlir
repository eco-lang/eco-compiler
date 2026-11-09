"builtin.module"() ({
  "mo.graph"() ({
  ^bb0(%arg0: !mo.tensor<[batch, k], f32>, %arg1: !mo.tensor<[k, n], f32>, %arg2: !mo.tensor<[n], f32>):
    %0 = "rmo.matmul"(%arg0, %arg1) : (!mo.tensor<[batch, k], f32>, !mo.tensor<[k, n], f32>) -> !mo.tensor<[batch, n], f32>
    %1 = "rmo.add"(%0, %arg2) : (!mo.tensor<[batch, n], f32>, !mo.tensor<[n], f32>) -> !mo.tensor<[batch, n], f32>
    %2 = "rmo.mo.relu"(%1) : (!mo.tensor<[batch, n], f32>) -> !mo.tensor<[batch, n], f32>
    "mo.output"(%2) : (!mo.tensor<[batch, n], f32>) -> ()
  }) {functionType = (!mo.tensor<[batch, k], f32>, !mo.tensor<[k, n], f32>, !mo.tensor<[n], f32>) -> !mo.tensor<[batch, n], f32>, inputParameters = #kgen<param.decls[batch : !kgen.scalar<si64>, k : !kgen.scalar<si64>, n : !kgen.scalar<si64>]>, sym_name = "symmlpmin", argument_names = ["x", "w", "b"], result_names = ["y"]} : () -> ()
}) : () -> ()
