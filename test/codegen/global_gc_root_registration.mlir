// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that eco.global generates GC root registration code.
// This verifies that:
// 1. __eco_init_globals function is generated with external linkage
// 2. eco_gc_add_root is called for each global
//
// Note: llvm.global_ctors is NOT generated because for JIT mode,
// ecoc.cpp calls __eco_init_globals manually after symbol registration.

module {
  // Declare multiple globals to test they all get registered
  eco.global @global_a
  eco.global @global_b
  eco.global @global_c

  // CHECK: @global_a = internal global i64 0
  // CHECK: @global_b = internal global i64 0
  // CHECK: @global_c = internal global i64 0

  // CHECK: declare void @eco_gc_add_root(ptr)

  // CHECK: define void @__eco_init_globals()
  // CHECK-DAG: call void @eco_gc_add_root(ptr @global_a)
  // CHECK-DAG: call void @eco_gc_add_root(ptr @global_b)
  // CHECK-DAG: call void @eco_gc_add_root(ptr @global_c)
  // CHECK: ret void

  func.func @main() -> i64 {
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
