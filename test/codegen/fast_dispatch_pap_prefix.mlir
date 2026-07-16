// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// E2 PAP-prefix fast dispatch (LSS_011, plans/lss-dispatch-value-extraction.md §6).
// A PAP of a 1-capture 2-param lambda holding k=1 applied arg crosses a
// function boundary (so no EcoPAPSimplify pattern can see its papCreate), and
// the consumer carries the E2 stamp: a saturated singleton_fast papExtend whose
// _capture_abi is the MERGED [real capture, k=1 prefix arg]. The unchanged
// emitFastClosureCall must load the PAP's two filled value slots in slot order
// [capture, prefix] and call @lam$cap directly with (cap, x, site-arg).
//
// Pins E2.0 premise 1 (slot order): result 753 = 7*100 + 5*10 + 3 requires
// slot0=7 (capture) and slot1=5 (prefix); a swapped order would give 573.
//
// papCreate arity = 3 is the TOTAL slot count (1 capture + 2 params) — the
// packed header is max_values=3, n_values=1; the grow-extend appends the
// prefix arg (n_values=2), and the stamped site saturates the remaining 1.

// CHECK: [eco.dbg] 753

module {
  func.func private @lam$cap(%cap: i64, %x: i64, %y: i64) -> i64 {
    %c100 = arith.constant 100 : i64
    %c10 = arith.constant 10 : i64
    %t0 = eco.int.mul %cap, %c100 : i64
    %t1 = eco.int.mul %x, %c10 : i64
    %t2 = eco.int.add %t0, %t1 : i64
    %t3 = eco.int.add %t2, %y : i64
    eco.return %t3 : i64
  }

  // Generic clone stand-in: never invoked in this test (the only apply is the
  // stamped fast site), but papCreate needs a valid evaluator symbol.
  func.func private @lam$clo(%clo: !eco.value, %x: i64, %y: i64) -> i64 {
    %c0 = arith.constant 0 : i64
    eco.return %c0 : i64
  }

  // The PAP arrives as an opaque value — its creation is invisible here, so
  // this is exactly the Channel-B shape only the stamp can convert.
  func.func @consume(%pap: !eco.value, %y: i64) -> i64 {
    %r = "eco.papExtend"(%pap, %y) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _call_kind = "singleton_fast",
      _fast_evaluator = @lam$cap,
      _capture_abi = [i64, i64],
      _pap_prefix = 1 : i64
    } : (!eco.value, i64) -> i64
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    %c7 = arith.constant 7 : i64
    %c5 = arith.constant 5 : i64
    %c3 = arith.constant 3 : i64

    // 1-capture closure over @lam (capture = 7); total slots = 3.
    %pap0 = "eco.papCreate"(%c7) {
      function = @lam$clo,
      _fast_evaluator = @lam$cap,
      arity = 3 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    // Grow the PAP with one applied arg (5): non-saturating typed extend
    // (remaining 2, 1 newarg) -> runtime eco_pap_extend appends slot 1.
    %pap1 = "eco.papExtend"(%pap0, %c5) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> !eco.value

    %r = func.call @consume(%pap1, %c3) : (!eco.value, i64) -> i64
    eco.dbg %r : i64
    // CHECK: [eco.dbg] 753

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
