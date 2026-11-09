"builtin.module"() ({
  "mo.graph"() <{counter = 0 : i64, functionType = (!mo.tensor<[batch, k], f32>, !mo.tensor<[k, n], f32>, !mo.tensor<[n], f32>) -> !mo.tensor<[batch, n], f32>, inputParameters = #kgen<param.decls[batch : !kgen.scalar<si64>, k : !kgen.scalar<si64>, n : !kgen.scalar<si64>]>, resultParameters = #kgen<param.decls[]>, signature = !kgen.generator<<scalar<si64>, scalar<si64>, scalar<si64>>(!mo.tensor<[*(0,0), *(0,1)], f32>, !mo.tensor<[*(0,1), *(0,2)], f32>, !mo.tensor<[*(0,2)], f32>) -> !mo.tensor<[*(0,0), *(0,2)], f32>>, sym_name = "symmlp"}> ({
  ^bb0(%arg0: !mo.tensor<[batch, k], f32>, %arg1: !mo.tensor<[k, n], f32>, %arg2: !mo.tensor<[n], f32>):
    %0 = "rmo.matmul"(%arg0, %arg1) : (!mo.tensor<[batch, k], f32>, !mo.tensor<[k, n], f32>) -> !mo.tensor<[batch, n], f32>
    %1 = "rmo.add"(%0, %arg2) <{outputParamDecls = #kgen<param.decls[]>}> : (!mo.tensor<[batch, n], f32>, !mo.tensor<[n], f32>) -> !mo.tensor<[batch, n], f32>
    %2 = "rmo.mo.relu"(%1) <{outputParamDecls = #kgen<param.decls[]>}> : (!mo.tensor<[batch, n], f32>) -> !mo.tensor<[batch, n], f32>
    "mo.output"(%2) <{parameters = #kgen<exprs[]>}> : (!mo.tensor<[batch, n], f32>) -> ()
  }) {argument_names = ["x", "w", "b"], result_names = ["y"]} : () -> ()
}) : () -> ()
