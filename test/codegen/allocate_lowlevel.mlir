// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test low-level allocation operations.
// Note: eco.allocate_closure requires a function reference, but user-defined
// functions can't be translated to LLVM IR in current setup, so we test
// only allocate_ctor and allocate_string here.

module {
  func.func @main() -> i64 {
    // eco.allocate_ctor - allocate constructor object
    // tag=5, size=2 fields, 0 scalar bytes
    %ctor_obj = eco.allocate_ctor {tag = 5 : i64, size = 2 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor_obj : !eco.value
    // CHECK: Ctor5

    // eco.allocate_ctor with different tag
    %ctor_obj2 = eco.allocate_ctor {tag = 0 : i64, size = 3 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor_obj2 : !eco.value
    // CHECK: Ctor0

    // eco.allocate_ctor with tag 10
    %ctor_obj3 = eco.allocate_ctor {tag = 10 : i64, size = 1 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor_obj3 : !eco.value
    // CHECK: Ctor10

    // eco.allocate_string - allocate string storage
    %str_storage = eco.allocate_string {length = 5 : i64} : !eco.value
    eco.dbg %str_storage : !eco.value
    // CHECK: "

    // eco.allocate_string with different length
    %str_storage2 = eco.allocate_string {length = 10 : i64} : !eco.value
    eco.dbg %str_storage2 : !eco.value
    // CHECK: "

    // Test construct with allocated ctor - fill fields after allocation
    // First allocate a 2-field ctor
    %ctor = eco.allocate_ctor {tag = 7 : i64, size = 2 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor : !eco.value
    // CHECK: Ctor7

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
