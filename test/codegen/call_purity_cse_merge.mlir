// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// kernel-opt-12 F5: with MLIR CSE ON, two identical `eco.cse_safe` calls
// merge — the callee's dbg marker prints ONCE. Stamping the attr on a
// dbg-ing callee is a deliberate fixture lie (the same device
// caf_memo_basic.mlir uses to observe single evaluation).
//
// ECO_MLIR_CSE is DEFAULT-OFF — a default-on attempt (2026-08-13) was
// REVERTED after CSE merged NaN-containing allocations and flipped structural
// equality through the kernel's pointer-eq fast path (see
// ContainerEquality*FloatTest.elm and EcoPipeline.cpp's comment). The CHECKs
// below are flag-independent; the merge itself is asserted by the manual leg
// ECO_MLIR_CSE=1 build/test/test --filter call_purity_cse (111 exactly once
// before 222).

module {
  func.func private @marked(%v: !eco.value) -> !eco.value {
    %m = arith.constant 111 : i64
    eco.dbg %m : i64
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %c = arith.constant 5 : i64
    %v = eco.box %c : i64 -> !eco.value
    %a = "eco.call"(%v) {callee = @marked, eco.cse_safe} : (!eco.value) -> !eco.value
    %b = "eco.call"(%v) {callee = @marked, eco.cse_safe} : (!eco.value) -> !eco.value
    %s = arith.constant 222 : i64
    eco.dbg %s : i64
    eco.dbg %a : !eco.value
    eco.dbg %b : !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: [eco.dbg] 111
// CHECK: [eco.dbg] 222
