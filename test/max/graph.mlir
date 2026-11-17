// A 2x2 matmul-plus-add graph for MAX (max-smoke-test): out = in0 x in1 + in0. Generic MLIR, with
// everything as plain attributes, the form eco writes for MAX (runtime/src/max/MaxVerify.hpp).
// Printed by MAX 26.7's Python graph API, its properties then moved into attributes.
"builtin.module"() ({
  "mo.graph"() ({
  ^bb0(%arg0: !mo.tensor<[2, 2], f32>, %arg1: !mo.tensor<[2, 2], f32>):
    %0 = "mo.chain.create"() : () -> !mo.chain
    %1 = "rmo.matmul"(%arg0, %arg1) : (!mo.tensor<[2, 2], f32>, !mo.tensor<[2, 2], f32>) -> !mo.tensor<[2, 2], f32>
    %2 = "rmo.add"(%1, %arg0) {outputParamDecls = #kgen<param.decls[]>} : (!mo.tensor<[2, 2], f32>, !mo.tensor<[2, 2], f32>) -> !mo.tensor<[2, 2], f32>
    "mo.output"(%2) {parameters = #kgen<exprs[]>} : (!mo.tensor<[2, 2], f32>) -> ()
  }) {counter = 0 : i64, functionType = (!mo.tensor<[2, 2], f32>, !mo.tensor<[2, 2], f32>) -> !mo.tensor<[2, 2], f32>, inputParameters = #kgen<param.decls[]>, resultParameters = #kgen<param.decls[]>, signature = !kgen.generator<(!mo.tensor<[2, 2], f32>, !mo.tensor<[2, 2], f32>) -> !mo.tensor<[2, 2], f32>>, sym_name = "eco_max_smoke", _kernel_library_paths = [], argument_names = ["input0", "input1"], result_names = ["output0"]} : () -> ()
}) {mo.device_info_mapping = {cpu = #M.device_info<"cpu", "cpu", "unknown", "cpu">}} : () -> ()
