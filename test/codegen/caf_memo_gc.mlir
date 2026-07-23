// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// CAF memoization × GC (HEAP_035): the memoized value is published to a
// rooted eco.global slot, so forced minor + major GCs between the first and
// second call must (a) keep it alive and (b) rewrite the slot when the
// nursery scavenge moves the object (NurserySpace evacuateJitPtr). The
// second call reads the post-GC pointer through the guard's hit path and
// projects correct field values; the body marker printing once proves the
// hit path (not a re-evaluation) served it.

module {
  eco.global @__eco_caf$make_pair

  llvm.func @eco_minor_gc()
  llvm.func @eco_major_gc()

  func.func private @make_pair() -> !eco.value attributes { eco.caf_memo } {
    %marker = arith.constant 888 : i64
    eco.dbg %marker : i64
    %a = arith.constant 41 : i64
    %b = arith.constant 43 : i64
    %ba = eco.box %a : i64 -> !eco.value
    %bb = eco.box %b : i64 -> !eco.value
    %t = eco.construct.tuple2 %ba, %bb {unboxed_bitmap = 0} : !eco.value, !eco.value -> !eco.value
    eco.return %t : !eco.value
  }

  func.func @main() -> i64 {
    %p1 = "eco.call"() {callee = @make_pair} : () -> !eco.value
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_major_gc() : () -> ()
    %p2 = "eco.call"() {callee = @make_pair} : () -> !eco.value
    %f0 = eco.project.tuple2 %p2[0] : !eco.value -> !eco.value
    %u0 = eco.unbox %f0 : !eco.value -> i64
    eco.dbg %u0 : i64
    %f1 = eco.project.tuple2 %p2[1] : !eco.value -> !eco.value
    %u1 = eco.unbox %f1 : !eco.value -> i64
    eco.dbg %u1 : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: 888
// CHECK-NEXT: 41
// CHECK-NEXT: 43
