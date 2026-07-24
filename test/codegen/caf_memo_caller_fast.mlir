// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=FAST
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// CAF caller-side fast path (benchmarks/runtime-calls.md Run W): a call
// site of an eco.caf_memo thunk is rewritten into a load/icmp diamond —
// the hit edge takes the barrier-cast cached slot word with NO call; the
// miss edge keeps the original call (the callee guard still publishes).
// Behavior is identical to the callee-only guard: body runs once, both
// calls observe the same value (the JIT leg proves it end-to-end through
// BOTH the miss path — first call — and the hit path — second call).

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

// ---- Site diamond (post-EcoToLLVM MLIR) ------------------------------------
// Inside @main, BEFORE the first thunk call: slot load + non-zero test +
// conditional branch; the hit edge barrier-casts and jumps to a merge block
// carrying the value as a block argument; the call survives on the miss edge.
// FAST: llvm.func @main
// FAST: llvm.mlir.addressof @__eco_caf$make_val
// FAST: llvm.load
// FAST: llvm.icmp "ne"
// FAST: llvm.cond_br
// FAST: llvm.call @__eco_slot_to_hptr
// FAST: llvm.call @make_val
// Second site gets its own diamond:
// FAST: llvm.mlir.addressof @__eco_caf$make_val
// FAST: llvm.icmp "ne"
// FAST: llvm.call @make_val

// ---- Runtime behavior ------------------------------------------------------
// Body marker printed ONCE (first call = miss path publishes; second call =
// hit path serves the cache without calling):
// JIT: 999
// JIT-NEXT: 111
// JIT-NEXT: 111
