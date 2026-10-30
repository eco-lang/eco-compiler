// RUN: not %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// UNSETENV: ECO_CAPHOIST_VALIDATE ECO_GCFREE_VALIDATE
//
// EcoJIT::create (EcoJIT.cpp) wraps the IR transformer (eco::runEcoBackend) and addIRModule in
// llvm::cantFail, so a backend error under -emit=jit aborts the process ("Failure value returned
// from cantFail wrapped call") instead of reaching ecoc's "Failed to create execution engine"
// report; in the test binary (EcoRunner) the same error would kill the whole process. The trigger is
// the plan-stamp mismatch of gcfree_plan_veq_mismatch.mlir, which -emit=llvm reports cleanly.
//
// The result is now a clean non-zero exit with the backend's message (`not` does not accept a crash).
//
// CHECK: Failed to create execution engine
// CHECK: disagree on value-eq leafness

module {
  llvm.module_flags [#llvm.mlir.module_flag<warning, "eco-cap-plan", "v1;K=512;m2=1;cw=0;veq=0">, #llvm.mlir.module_flag<warning, "eco-gcfree-plan", "v1;veq=1;cov=1">]
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
