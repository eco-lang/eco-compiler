// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.2 #1 partial-demotion pin: both SCC members have two
// aggregate-shaped slots; one slot in @partner is blocked by flowing
// into a non-eligible callee (@sink). The looser semantics demote
// that slot AND the matching slot in @two_slots (via shape-mismatch
// propagation) but keep the OTHER slot promoted in both members —
// per-slot demotion granularity, not whole-SCC rejection.
//
// This fixture pins which semantics we ship. If the strict "any
// blocked member ⇒ entire SCC ineligible" reading is ever preferred,
// the CHECK-DAG lines for the $unboxed workers below need to flip
// to CHECK-NOT.

module {
  // Non-candidate sink. No eco.logical_param_types ⇒ not a cross-spec
  // candidate. Flowing %t into here blocks t's aggregate promotion in
  // the caller's slot.
  func.func private @sink(%v: !eco.value) -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }

  func.func @two_slots(%t1: !eco.value, %t2: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %a = eco.project.tuple2 %t1[0] : !eco.value -> i64
    %b = eco.project.tuple2 %t2[1] : !eco.value -> i64
    %sum = arith.addi %a, %b : i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t1, %t2, %nm1) {callee = @partner}
        : (!eco.value, !eco.value, i64) -> i64
    %out = arith.select %is_zero, %sum, %r : i64
    return %out : i64
  }

  func.func @partner(%t1: !eco.value, %t2: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %a = eco.project.tuple2 %t1[0] : !eco.value -> i64
    // %t2 flows into @sink (non-eligible callee) ⇒ blocks t2 in @partner.
    // Shape-mismatch propagation: @two_slots's call to @partner at
    // position [1] then sees a Boxed tentative slot, so @two_slots's
    // t2 also demotes. t1 remains promoted in both members.
    %_ = "eco.call"(%t2) {callee = @sink}
        : (!eco.value) -> i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t1, %t2, %nm1) {callee = @two_slots}
        : (!eco.value, !eco.value, i64) -> i64
    %out = arith.select %is_zero, %a, %r : i64
    return %out : i64
  }
}

// Both members are workers — loose semantics keep the SCC partially
// promoted even though one slot is blocked:
// CHECK-DAG: llvm.func @two_slots$unboxed
// CHECK-DAG: llvm.func @partner$unboxed
//
// Each worker signature shows the surviving per-slot promotion: t1
// expands into two i64 scalars (post-flatten), t2 stays as a single
// ptr addrspace(1), %n is i64. Regex tolerates SSA register numbering:
// CHECK-DAG: @two_slots$unboxed(i64 %{{[0-9]+}}, i64 %{{[0-9]+}}, ptr addrspace(1) %{{[0-9]+}}, i64 %{{[0-9]+}})
// CHECK-DAG: @partner$unboxed(i64 %{{[0-9]+}}, i64 %{{[0-9]+}}, ptr addrspace(1) %{{[0-9]+}}, i64 %{{[0-9]+}})
//
// Wrappers still preserve the boxed ABI for external callers:
// CHECK-DAG: llvm.func @two_slots(
// CHECK-DAG: llvm.func @partner(
//
// Intra-SCC calls go to worker variants (the t1 aggregate flows through
// without re-boxing; t2 stays boxed in both):
// CHECK-DAG: llvm.call{{.*}}@two_slots$unboxed
// CHECK-DAG: llvm.call{{.*}}@partner$unboxed
