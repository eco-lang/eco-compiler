// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// CAF memoization M4 (plans/caf-memoization-implementation.md): nullary
// custom constructors. The thunk body is exactly what generateEnum emits
// for a non-well-known nullary ctor — `eco.construct.custom` with size 0 —
// which pre-M4 allocated a fresh object per reference. With the guard, the
// allocation happens once; the second call (after forced minor + major GC)
// serves the cached object through the rooted slot, and tag dispatch reads
// the same tag off it.

module {
  eco.global @__eco_caf$make_enum

  llvm.func @eco_minor_gc()
  llvm.func @eco_major_gc()

  func.func private @make_enum() -> !eco.value attributes { eco.caf_memo } {
    %marker = arith.constant 555 : i64
    eco.dbg %marker : i64
    %v = "eco.construct.custom"() {tag = 7 : i64, size = 0 : i64, unboxed_bitmap = 0 : i64} : () -> !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %a = "eco.call"() {callee = @make_enum} : () -> !eco.value
    %ta = eco.get_tag %a : !eco.value -> i32
    %ia = arith.extui %ta : i32 to i64
    eco.dbg %ia : i64
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_major_gc() : () -> ()
    %b = "eco.call"() {callee = @make_enum} : () -> !eco.value
    %tb = eco.get_tag %b : !eco.value -> i32
    %ib = arith.extui %tb : i32 to i64
    eco.dbg %ib : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// Allocation marker printed ONCE; both calls observe tag 7:
// CHECK: 555
// CHECK-NEXT: 7
// CHECK-NEXT: 7
