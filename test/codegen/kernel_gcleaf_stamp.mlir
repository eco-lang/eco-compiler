// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=STAMP
//
// kernel-opt-08 / CGEN_072(f): the backend reflection step. A kernel `func.func`
// stub carrying the `eco.gc_leaf` UnitAttr must come out of KernelFuncOpLowering
// as an `llvm.func` whose `passthrough` array contains "gc-leaf-function"; a stub
// WITHOUT the attr must not.
//
// This pins the half of the channel that lives in C++. The other half — which
// kernels are eligible — is data, pinned by the KernelFacts elm-test golden, and
// deliberately has no name list anywhere in the backend.
//
// The attr is a UnitAttr because the C++ side tests hasAttr: a BoolAttr false
// would read as "present" and stamp an ineligible kernel, which is the failure
// mode that turns into heap corruption rather than a wrong answer.
//
// gc-leaf is the ONLY attribute such a declaration may carry before RS4GC
// (REP_LLVM_002), so the negative CHECKs below are load-bearing, not decoration.

module {
  // An eligible kernel: the stub carries the attr, the llvm.func gets stamped.
  func.func private @Elm_Kernel_Utils_equal(!eco.value, !eco.value) -> !eco.value
      attributes { is_kernel = true, eco.gc_leaf }

  // An INELIGIBLE kernel: no attr on the stub, so no stamp on the decl.
  func.func private @Elm_Kernel_Utils_append(!eco.value, !eco.value) -> !eco.value
      attributes { is_kernel = true }

  func.func @main() -> i64 {
    %a = eco.string_literal "x" : !eco.value
    %b = eco.string_literal "y" : !eco.value
    %e = eco.call @Elm_Kernel_Utils_equal(%a, %b) : (!eco.value, !eco.value) -> !eco.value
    %c = eco.call @Elm_Kernel_Utils_append(%a, %b) : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %c : !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }

  // STAMP: llvm.func @Elm_Kernel_Utils_equal
  // STAMP-SAME: passthrough
  // STAMP-SAME: gc-leaf-function
  //
  // The eligible decl must NOT acquire any motion-enabling attribute.
  // STAMP-NOT: memory{{.*}}@Elm_Kernel_Utils_equal
  // STAMP-NOT: speculatable
  // STAMP-NOT: willreturn
}
