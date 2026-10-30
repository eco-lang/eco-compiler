// RUN: not %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// A value aggregate holding a GC pointer must not cross a function or block boundary
// (cpp-review-bugs.md "make.closure keeps an env aggregate with GC pointers live across the
// allocation"; plans/review-likely-bugs-fixes.md step 3c).
//
// Such an aggregate lowers to an LLVM struct holding a `ptr addrspace(1)`, which RS4GC cannot relocate.
// FoldExtractValuePass (EcoPtrIntVerify.cpp) removes an aggregate only when it is built and consumed in
// one function, so one that arrives as a function argument, or through an scf.if result, used to reach
// RS4GC whole (ECO_FCA_SCAN flagged it), and a collection at the closure's allocation or at the
// function's entry capacity check left the captured pointer stale. The problem is not specific to
// closures: a plain tuple does the same. The front end never produces such a boundary, so EcoToLLVM now
// rejects it with a hard error until the boundaries are scalarized
// (plans/aggregate-boundary-scalarization.md). aggregate_boundary_unboxed_ok.mlir is the control: an
// aggregate with no GC pointer still compiles, and value_make_closure.mlir's FCA leg keeps the
// in-function closure env clean.
//
// CHECK-DAG: error: argument 0 of @mk has type '!eco.closure_env<i64, !eco.value>': an aggregate holding a GC pointer
// CHECK-DAG: error: argument 0 of @tupleArg has type '!eco.tuple2<i64, !eco.value>'
// CHECK-DAG: error: a result of 'scf.if' has type '!eco.tuple2<i64, !eco.value>'

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

  func.func @tupleArg(%t: !eco.tuple2<i64, !eco.value>) -> !eco.value {
    %h = eco.to_heap %t : (!eco.tuple2<i64, !eco.value>) -> !eco.value
    return %h : !eco.value
  }

  func.func @ifResult(%c: i1, %n: i64, %p: !eco.value, %q: !eco.value) -> !eco.value {
    %t = scf.if %c -> (!eco.tuple2<i64, !eco.value>) {
      %a = eco.make.tuple2 %n, %p : (i64, !eco.value) -> !eco.tuple2<i64, !eco.value>
      scf.yield %a : !eco.tuple2<i64, !eco.value>
    } else {
      %b = eco.make.tuple2 %n, %q : (i64, !eco.value) -> !eco.tuple2<i64, !eco.value>
      scf.yield %b : !eco.tuple2<i64, !eco.value>
    }
    %h = eco.to_heap %t : (!eco.tuple2<i64, !eco.value>) -> !eco.value
    return %h : !eco.value
  }
}
