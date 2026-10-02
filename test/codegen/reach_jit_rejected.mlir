// RUN: not %ecoc %s -emit=jit --exe-reachability 2>&1 | %FileCheck %s
//
// plans/mlir-split-backend-03-reachability.md fixture (R9): internalizing
// would silently change the JIT interface (packFunctionArguments skips
// local-linkage functions), so the combination is an error.
//
// CHECK: --exe-reachability cannot be used with -emit=jit

module {
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
