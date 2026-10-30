// RUN: env ECO_FCA_SCAN=1 %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// XFAIL: cpp-review-bugs.md "make.closure keeps an env aggregate with GC pointers live across the allocation" -- not fixed yet
//
// `eco.make.closure` reads its captures out of the `!eco.closure_env` aggregate with extractvalue.
// FoldExtractValuePass (EcoPtrIntVerify.cpp) folds those only through an insertvalue chain built in
// the same function (value_make_closure.mlir, whose FCA leg is the control). An env that arrives as
// a function argument (or through a block argument / scf.if result) stays an aggregate holding
// `ptr addrspace(1)` into RS4GC, which cannot relocate aggregate members: a collection at the
// closure's allocation, or at the function's entry capacity check (eco-cap-budget), leaves the
// captured pointer stale. The front end never emits closure_env / make.closure, so only
// hand-written MLIR reaches it. ECO_FCA_SCAN lists such aggregates and stops the compile.
//
// Today: "FCA-SCAN: 2 aggregate-with-gc-pointer instruction(s) survived the pre-RS4GC fold".
//
// CHECK: FCA-SCAN: clean

module {
  llvm.func @stub_evaluator(%args: !llvm.ptr) -> !llvm.ptr {
    %r = llvm.mlir.zero : !llvm.ptr
    llvm.return %r : !llvm.ptr
  }

  func.func @mk(%env: !eco.closure_env<i64, !eco.value>) -> !eco.value {
    %clo = eco.make.closure @stub_evaluator, %env {arity = 3 : i64}
         : (!eco.closure_env<i64, !eco.value>) -> !eco.value
    return %clo : !eco.value
  }
}
