// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Control for make_closure_env_arg_fca.mlir: EcoToLLVM rejects a value aggregate holding a GC pointer at
// a function or block boundary, but an aggregate whose fields are all unboxed (i64 / f64 / i32) has
// nothing for RS4GC to relocate and still compiles as a function argument. (An aggregate through an
// scf.if result is not lowered at all today, GC pointer or not: the scf.if result types are not
// converted. plans/aggregate-boundary-scalarization.md covers block boundaries.)
//
// CHECK-NOT: error
// CHECK: define {{.*}}@pairArg

module {
  func.func @pairArg(%t: !eco.tuple2<i64, i64>) -> !eco.value {
    %h = eco.to_heap %t : (!eco.tuple2<i64, i64>) -> !eco.value
    return %h : !eco.value
  }
}
