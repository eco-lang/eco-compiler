// The graph of graph.mlir as MAX's Python API prints it in generic form: its inherent attributes as
// MLIR properties (<{...}>). MAX reads this as text; written as bytecode by eco's MLIR, which does
// not know MAX's ops, the properties become one dictionary that MAX's reader rejects and then
// crashes on, so eco must refuse that bytecode (max-smoke-test checks it does).
"builtin.module"() ({
  "mo.graph"() <{counter = 0 : i64, functionType = (!mo.tensor<[2, 2], f32>, !mo.tensor<[2, 2], f32>) -> !mo.tensor<[2, 2], f32>, inputParameters = #kgen<param.decls[]>, resultParameters = #kgen<param.decls[]>, signature = !kgen.generator<(!mo.tensor<[2, 2], f32>, !mo.tensor<[2, 2], f32>) -> !mo.tensor<[2, 2], f32>>, sym_name = "eco_max_smoke"}> ({
  ^bb0(%arg0: !mo.tensor<[2, 2], f32>, %arg1: !mo.tensor<[2, 2], f32>):
    %0 = "mo.chain.create"() : () -> !mo.chain
    %1 = "rmo.matmul"(%arg0, %arg1) : (!mo.tensor<[2, 2], f32>, !mo.tensor<[2, 2], f32>) -> !mo.tensor<[2, 2], f32>
    %2 = "rmo.add"(%1, %arg0) <{outputParamDecls = #kgen<param.decls[]>}> : (!mo.tensor<[2, 2], f32>, !mo.tensor<[2, 2], f32>) -> !mo.tensor<[2, 2], f32>
    "mo.output"(%2) <{parameters = #kgen<exprs[]>}> : (!mo.tensor<[2, 2], f32>) -> ()
  }) {_kernel_library_paths = [], argument_names = ["input0", "input1"], result_names = ["output0"]} : () -> ()
}) {mo.device_info_mapping = {cpu = #M.device_info<"cpu", "cpu", "unknown", "cpu">}} : () -> ()
