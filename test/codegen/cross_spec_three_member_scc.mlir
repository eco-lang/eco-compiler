// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.2 #1 multi-member SCC test: 3-function cycle a → b → c → a,
// each consuming a tuple2 and threading through to the next. Tarjan
// must group all three into one SCC; the inner fixpoint must converge
// with three simultaneously-promoted members. This closes the
// coverage gap left by cross_spec_mutual_recursive.mlir (2 members).

module {
  func.func @a(%t: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %x = eco.project.tuple2 %t[0] : !eco.value -> i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t, %nm1) {callee = @b}
        : (!eco.value, i64) -> i64
    %out = arith.select %is_zero, %x, %r : i64
    return %out : i64
  }
  func.func @b(%t: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %x = eco.project.tuple2 %t[1] : !eco.value -> i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t, %nm1) {callee = @c}
        : (!eco.value, i64) -> i64
    %out = arith.select %is_zero, %x, %r : i64
    return %out : i64
  }
  func.func @c(%t: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %x = eco.project.tuple2 %t[0] : !eco.value -> i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t, %nm1) {callee = @a}
        : (!eco.value, i64) -> i64
    %out = arith.select %is_zero, %x, %r : i64
    return %out : i64
  }
}

// All three SCC members get $unboxed workers:
// CHECK-DAG: llvm.func @a$unboxed
// CHECK-DAG: llvm.func @b$unboxed
// CHECK-DAG: llvm.func @c$unboxed
//
// Wrappers exist for the external ABI:
// CHECK-DAG: llvm.func @a(
// CHECK-DAG: llvm.func @b(
// CHECK-DAG: llvm.func @c(
//
// Intra-SCC calls thread directly through worker variants — each
// member's body calls the next member's $unboxed worker, never the
// wrapper. With regex matching enabled we use {{.*}} so any return
// type / surrounding context flows cleanly:
// CHECK-DAG: llvm.call{{.*}}@b$unboxed
// CHECK-DAG: llvm.call{{.*}}@c$unboxed
// CHECK-DAG: llvm.call{{.*}}@a$unboxed
