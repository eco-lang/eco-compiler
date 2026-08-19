// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Nullary ctors under HEAP_044 (plans/null-cons-hpointer-embedding.md): the
// thunk body is exactly what generateEnum emits for a non-well-known nullary
// ctor — `eco.constant.null_cons` — which replaced the M4 CAF-memoized
// size-0 allocation (a constant-returning body needs no once-guard, so enum
// specs no longer carry eco.caf_memo). Both calls — the second after forced
// minor + major GC — observe the embedded declaration index through
// eco.get_tag: constants are GC-immune by construction.

module {
  llvm.func @eco_minor_gc()
  llvm.func @eco_major_gc()

  func.func private @make_enum() -> !eco.value {
    %v = eco.constant.null_cons 7 : !eco.value
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

// Both calls observe the embedded tag 7:
// CHECK: 7
// CHECK-NEXT: 7
