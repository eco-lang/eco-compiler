// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// XFAIL: cpp-review-bugs.md "Closure eval layout labels new args PK_Boxed but primitives are stored raw" -- not fixed yet
//
// A saturating typed `eco.papExtend` that carries `_capture_abi` but no `_fast_evaluator` is lowered
// by the `_capture_abi`-only branch of EcoToLLVMClosures, which builds the evaluator layout as
// [capture kinds..., 0 x new args] and passes it with num_newargs = the new-arg count. The runtime
// (RuntimeExports.cpp, eco_apply_closure_eval / spliceArgsForSaturatedCall) reads the first
// num_newargs kinds as the kinds of the NEW arguments, so it reads the capture's kind instead. Here
// the capture is boxed (kind 0) and the new argument is a raw Int: the runtime treats 21 as a heap
// pointer. The front end always emits `_capture_abi` together with `_fast_evaluator` (the fast
// path), so only hand-written MLIR reaches the branch; with an Int capture, as in
// fast_dispatch_direct_call.mlir, the kinds happen to agree.
//
// Today: the assert in spliceArgsForSaturatedCall ("cannot un-box null/embedded HPointer").
//
// CHECK: [eco.dbg] 42

module {
  func.func private @lam$cap(%s: !eco.value, %y: i64) -> i64 {
    %c2 = arith.constant 2 : i64
    %r = eco.int.mul %y, %c2 : i64
    eco.return %r : i64
  }

  func.func @consume(%pap: !eco.value, %y: i64) -> i64 {
    %r = "eco.papExtend"(%pap, %y) {
      remaining_arity = 1 : i64,
      slot_kinds = array<i8: 1>,
      _capture_abi = [!eco.value]
    } : (!eco.value, i64) -> i64
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    %s = eco.string_literal "captured" : !eco.value
    %pap = "eco.papCreate"(%s) {
      function = @lam$cap,
      arity = 2 : i64,
      num_captured = 1 : i64,
      slot_kinds = array<i8: 0>
    } : (!eco.value) -> !eco.value
    %c21 = arith.constant 21 : i64
    %r = func.call @consume(%pap, %c21) : (!eco.value, i64) -> i64
    eco.dbg %r : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
