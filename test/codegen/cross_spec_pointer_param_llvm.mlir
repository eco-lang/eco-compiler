// RUN: %ecoc %s -emit=llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.2 #2 LLVM-IR validation for the pointer-element case —
// the most important harness fixture because it's the scenario the
// Phase 3.1 #3 flatten pass specifically targets. A pre-3.1 worker
// signature would have been (struct{i64, ptr addrspace(1)}) and
// would trip RewriteStatepointsForGC's "FCA unimplemented" assertion.
// After flatten + SROA, the boundary becomes (i64, ptr addrspace(1)).
//
// The CHECK assertions confirm this scalarisation actually happens
// at the LLVM IR level, not just at MLIR.

module {
  func.func @sum_int_with_extra(%t: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:v"],
          eco.logical_result_types = ["i64"]
      } {
    %a = eco.project.tuple2 %t[0] : !eco.value -> i64
    return %a : i64
  }
}

// Worker signature is scalar (i64, ptr addrspace(1)) — never a
// struct containing a ptr<1>, which would trip RS4GC:
// CHECK: define i64 @"sum_int_with_extra$unboxed"(i64 %0, ptr addrspace(1) %1)
//
// Wrapper preserves the boxed ABI:
// CHECK: define i64 @sum_int_with_extra(ptr addrspace(1)
//
// No FCA struct of (i64, ptr addrspace(1)) survives anywhere:
// CHECK-NOT: { i64, ptr addrspace(1) }
// CHECK-NOT: alloca
