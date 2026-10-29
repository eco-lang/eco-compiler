// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=PLAN
// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=LLVM
//
// `eco_list_pos_view` allocates a chunk view when idx > 0 (alloc::consChunkView), so it can collect.
// EcoListCursor emits it after a rewritten walk whose loop result at the walked position is used. This
// is `skipSmall limit xs` (drop elements below `limit`), returning the walked position itself. Its only
// GC-capable call after the rewrite is `eco_list_pos_view`. It must be neither stamped gc-leaf nor given
// a capacity budget of 0, and the LLVM lowering must succeed with the call statepointed.
// (Once mis-classified as leaf: the plan stamped it and the backend refused the budget-0 plan.)
//
// PLAN: llvm.func @skipSmall({{.*}}passthrough = ["eco-cap-top"]
// PLAN: llvm.call @__eco_list_step_node_inline
// PLAN: llvm.call @eco_list_pos_view
// LLVM: define {{.*}}@skipSmall(
// LLVM: gc.statepoint{{.*}}@eco_list_pos_view

module {
  "func.func"() ({
      ^bb0(%limit: i64, %xs: !eco.value):
        %2 = "arith.constant"() {value = false} : () -> i1 
        %3 = "eco.constant"() {kind = 2 : i32} : () -> !eco.value 
        %4, %5, %6, %7 = "scf.while"(%limit, %xs, %2, %3) ({
            ^bb0(%8: i64, %9: !eco.value, %10: i1, %11: !eco.value):
              %13 = "arith.constant"() {value = true} : () -> i1 
              %12 = "arith.xori"(%10, %13) {_operand_types = [i1, i1]} : (i1, i1) -> i1 
              "scf.condition"(%12, %8, %9, %10, %11) {_operand_types = [i1, i64, !eco.value, i1, !eco.value]} : (i1, i64, !eco.value, i1, !eco.value) -> () 
        }, {
            ^bb0(%14: i64, %15: !eco.value, %16: i1, %17: !eco.value):
              %18 = "eco.get_tag"(%15) {_operand_types = [!eco.value]} : (!eco.value) -> i32 
              %19 = "arith.constant"() {value = 1 : i32} : () -> i32 
              %20 = "arith.cmpi"(%18, %19) {_operand_types = [i32, i32], predicate = 0 : i64} : (i32, i32) -> i1 
              %33, %34, %35, %36 = "eco.case"(%20) ({
                    %21 = "eco.project.list_head"(%15) {_operand_types = [!eco.value]} : (!eco.value) -> i64 
                    %22 = "eco.project.list_tail"(%15) {_operand_types = [!eco.value]} : (!eco.value) -> !eco.value 
                    %23 = "eco.int.lt"(%21, %14) {_operand_types = [i64, i64]} : (i64, i64) -> i1 
                    %27, %28, %29, %30 = "eco.case"(%23) ({
                          %24 = "arith.constant"() {value = false} : () -> i1 
                          %25 = "eco.constant"() {kind = 2 : i32} : () -> !eco.value 
                          "eco.yield"(%14, %22, %24, %25) {_operand_types = [i64, !eco.value, i1, !eco.value]} : (i64, !eco.value, i1, !eco.value) -> () 
                    }, {
                          %26 = "arith.constant"() {value = true} : () -> i1 
                          %25 = "eco.constant"() {kind = 2 : i32} : () -> !eco.value 
                          "eco.yield"(%14, %15, %26, %25) {_operand_types = [i64, !eco.value, i1, !eco.value]} : (i64, !eco.value, i1, !eco.value) -> () 
                    }) {_operand_types = [i1], case_kind = "bool", tags = array<i64: 1, 0>} : (i1) -> (i64, !eco.value, i1, !eco.value) 
                    "eco.yield"(%27, %28, %29, %30) {_operand_types = [i64, !eco.value, i1, !eco.value]} : (i64, !eco.value, i1, !eco.value) -> () 
              }, {
                    %31 = "eco.constant"() {kind = 2 : i32} : () -> !eco.value 
                    %32 = "arith.constant"() {value = true} : () -> i1 
                    "eco.yield"(%14, %15, %32, %31) {_operand_types = [i64, !eco.value, i1, !eco.value]} : (i64, !eco.value, i1, !eco.value) -> () 
              }) {_operand_types = [i1], case_kind = "bool", tags = array<i64: 1, 0>} : (i1) -> (i64, !eco.value, i1, !eco.value) 
              "scf.yield"(%33, %34, %35, %36) {_operand_types = [i64, !eco.value, i1, !eco.value]} : (i64, !eco.value, i1, !eco.value) -> () 
        }) {_operand_types = [i64, !eco.value, i1, !eco.value]} : (i64, !eco.value, i1, !eco.value) -> (i64, !eco.value, i1, !eco.value) 
        "eco.return"(%5) {_operand_types = [!eco.value]} : (!eco.value) -> () 
  }) {eco.logical_param_types = ["i64", "cons:i:v"], eco.logical_result_types = ["cons:i:v"], function_type = (i64, !eco.value) -> (!eco.value), sym_name = "skipSmall", sym_visibility = "private"} : () -> () 
  "func.func"() ({
        %3 = "arith.constant"() {value = 5 : i64} : () -> i64 
        %6 = "eco.constant"() {kind = 2 : i32} : () -> !eco.value 
        %0 = "eco.call"(%3, %6) <{_operand_types = [i64, !eco.value], callee = @skipSmall}> : (i64, !eco.value) -> !eco.value 
        "eco.return"(%0) {_operand_types = [!eco.value]} : (!eco.value) -> () 
  }) {eco.list_chunks, function_type = () -> (!eco.value), sym_name = "main", sym_visibility = "private"} : () -> () 
  "eco.type_table"() {ctors = [], fields = [], func_args = [], strings = [], types = [[0, 0, 4], [1, 0, 0], [2, 1, 1]]} : () -> () 
}
