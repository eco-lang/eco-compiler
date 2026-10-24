// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// SD-7: the typed papExtend newarg check (CGEN_003, PapExtendOp::verifySymbolUses
// in EcoOps.cpp) walks the closure operand's defining ops back to an
// eco.papCreate and returns success as soon as the walk hits anything else, so
// a closure that arrives as a function parameter is never checked. Here the
// evaluator's signature is nonetheless known: the site is stamped with
// `_fast_evaluator = @lam$cap` and `_capture_abi = [i64]` (one capture), so the
// newarg fills @lam$cap's parameter 1, an i64. The newarg is an f64, so the
// fast call (emitFastClosureCall) passes it in the wrong register class. The
// _capture_abi check (CGEN_CLOSURE_005) passes; the newarg is not checked.
// The verifier must report the newarg type mismatch.

module {
  func.func private @lam$cap(%cap: i64, %x: i64) -> i64 {
    %t = eco.int.add %cap, %x : i64
    eco.return %t : i64
  }

  func.func @consume(%pap: !eco.value, %y: f64) -> i64 {
    %r = "eco.papExtend"(%pap, %y) {
      remaining_arity = 1 : i64,
      slot_kinds = array<i8: 2>,
      _call_kind = "singleton_fast",
      _fast_evaluator = @lam$cap,
      _capture_abi = [i64],
      _pap_prefix = 1 : i64
    } : (!eco.value, f64) -> i64
    eco.return %r : i64
  }
}

// CHECK: error: 'eco.papExtend' op {{.*}}newarg 0 has type 'f64'
