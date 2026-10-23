// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// CGEN_CLOSURE_005: a saturated typed eco.papExtend stamped with _fast_evaluator and
// _capture_abi lowers (emitFastClosureCall) to a direct call of the fast clone, loading
// one closure value slot per _capture_abi entry AT that type. So the _capture_abi types
// must equal the clone's leading parameter types. Here the stamp claims the first
// capture is f64 while @lam$cap takes i64: the fast call is AddressOf+indirect with a
// site-derived signature, so LLVM would not reject it; the capture would be passed in
// the wrong register class. Same shape as fast_dispatch_pap_prefix.mlir, with
// _capture_abi = [f64, i64] instead of [i64, i64].

module {
  func.func private @lam$cap(%cap: i64, %x: i64, %y: i64) -> i64 {
    %t0 = eco.int.add %cap, %x : i64
    %t1 = eco.int.add %t0, %y : i64
    eco.return %t1 : i64
  }

  func.func @consume(%pap: !eco.value, %y: i64) -> i64 {
    %r = "eco.papExtend"(%pap, %y) {
      remaining_arity = 1 : i64,
      slot_kinds = array<i8: 1>,
      _call_kind = "singleton_fast",
      _fast_evaluator = @lam$cap,
      _capture_abi = [f64, i64],
      _pap_prefix = 1 : i64
    } : (!eco.value, i64) -> i64
    eco.return %r : i64
  }
}

// CHECK: CGEN_CLOSURE_005: _capture_abi entry 0 has type 'f64' but fast evaluator 'lam$cap' expects 'i64' at parameter 0
