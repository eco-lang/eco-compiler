// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=INL
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// E1.2 + E1.3 (plans/lss-dispatch-value-extraction.md §5).
//
// The MLIR-level fast call stays AddressOf+indirect (a direct MLIR call is
// translation-asserted against the callee's REAL signature, and stamped-ABI
// site views can differ benignly — the erased/boxed i64<->ptr classes). The
// backend prepass (`runCapInlinePrepass`, EcoBackend.cpp) then, pre-RS4GC:
//   1. folds `$cap` call sites to well-typed DIRECT calls against the
//      callee's true signature (bit-identical i64<->ptr/f64 coercions), and
//   2. force-inlines small `$cap` bodies (alwaysinline + AlwaysInlinerPass).
//
// INL pin: in the post-prepass/post-RS4GC IR dump, @consume contains NO
// reference to @lam$cap — the fold made the site direct and the inliner ate
// it. (@main still references @lam$cap via the papCreate evaluator field —
// that address-taken use is what keeps the body alive.)
//
// JIT: behavior unchanged (same fixture math as fast_dispatch_pap_prefix).

// INL-LABEL: define {{.*}}@consume
// INL-NOT: @lam$cap
// INL-LABEL: define {{.*}}@main

// JIT: [eco.dbg] 753

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

  func.func private @lam$clo(%clo: !eco.value, %x: i64, %y: i64) -> i64 {
    %c0 = arith.constant 0 : i64
    eco.return %c0 : i64
  }

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

    %pap0 = "eco.papCreate"(%c7) {
      function = @lam$clo,
      _fast_evaluator = @lam$cap,
      arity = 3 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    %pap1 = "eco.papExtend"(%pap0, %c5) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> !eco.value

    %r = func.call @consume(%pap1, %c3) : (!eco.value, i64) -> i64
    eco.dbg %r : i64

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
