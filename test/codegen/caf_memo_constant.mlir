// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// CAF memoization × embedded constants: a thunk whose value is an embedded
// constant (True = 0x5 — nonzero, so distinguishable from the slot's
// 0-uninitialized sentinel) caches and replays it correctly, and the GC's
// root scan skips the constant word (isConstantBits) instead of chasing it
// as a heap pointer.

module {
  eco.global @__eco_caf$make_true

  llvm.func @eco_minor_gc()
  llvm.func @eco_major_gc()

  func.func private @make_true() -> !eco.value attributes { eco.caf_memo } {
    %marker = arith.constant 777 : i64
    eco.dbg %marker : i64
    %t = eco.constant True : !eco.value
    eco.return %t : !eco.value
  }

  func.func @main() -> i64 {
    %a = "eco.call"() {callee = @make_true} : () -> !eco.value
    %ua = eco.unbox %a : !eco.value -> i1
    %ia = arith.extui %ua : i1 to i64
    eco.dbg %ia : i64
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_major_gc() : () -> ()
    %b = "eco.call"() {callee = @make_true} : () -> !eco.value
    %ub = eco.unbox %b : !eco.value -> i1
    %ib = arith.extui %ub : i1 to i64
    eco.dbg %ib : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: 777
// CHECK-NEXT: 1
// CHECK-NEXT: 1
