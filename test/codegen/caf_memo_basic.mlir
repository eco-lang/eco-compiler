// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=GUARD
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// CAF memoization (plans/caf-memoization-implementation.md, CGEN_068):
// a nullary thunk tagged `eco.caf_memo` evaluates its body at most once —
// the result is published to its `__eco_caf$<name>` eco.global slot and the
// second call returns the cached value through the guard's hit path.
// The body's eco.dbg proves single evaluation.

module {
  eco.global @__eco_caf$make_val

  func.func private @make_val() -> !eco.value attributes { eco.caf_memo } {
    %marker = arith.constant 999 : i64
    eco.dbg %marker : i64
    %c = arith.constant 111 : i64
    %v = eco.box %c : i64 -> !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %a = "eco.call"() {callee = @make_val} : () -> !eco.value
    %ua = eco.unbox %a : !eco.value -> i64
    eco.dbg %ua : i64
    %b = "eco.call"() {callee = @make_val} : () -> !eco.value
    %ub = eco.unbox %b : !eco.value -> i64
    eco.dbg %ub : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// ---- Guard shape (post-EcoToLLVM MLIR) -------------------------------------
// The slot is an internal i64 global initialized to 0:
// GUARD: llvm.mlir.global internal @__eco_caf$make_val(0 : i64)
// The thunk entry loads the slot, tests non-zero, and branches hit/body;
// the hit path returns the barrier-converted cached word, and the body's
// return publishes through the store barrier first:
// GUARD: llvm.func @make_val
// GUARD: llvm.mlir.addressof @__eco_caf$make_val
// GUARD: llvm.load
// GUARD: llvm.icmp "ne"
// GUARD: llvm.cond_br
// GUARD: llvm.call @__eco_hptr_to_slot
// GUARD: llvm.store
// GUARD: llvm.call @__eco_slot_to_hptr
// The init function roots the slot:
// GUARD: llvm.func @__eco_init_globals
// GUARD: llvm.call @eco_gc_add_root

// ---- Runtime behavior ------------------------------------------------------
// Body marker printed ONCE, then both calls observe the same cached value:
// JIT: 999
// JIT-NEXT: 111
// JIT-NEXT: 111
