// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test papExtend with typed (unboxed) arguments that saturate the closure.
// This tests the typed closure ABI where arguments are passed in their actual
// SSA types rather than boxed to !eco.value.

module {
  // Lambda that takes i64 and returns i64 (typed ABI)
  llvm.func @double_eval(%args: !llvm.ptr) -> i64 {
    %c0 = llvm.mlir.constant(0 : i64) : i64

    // Load args[0] - it's an unboxed i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %x = llvm.load %ptr0 : !llvm.ptr -> i64

    // Double it
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %result = llvm.mul %x, %c2 : i64

    // Return raw i64 (typed return)
    llvm.return %result : i64
  }

  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64

    // Create PAP with no captured args, arity 1
    %pap = "eco.papCreate"() {
      function = @double_eval,
      arity = 1 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    // Extend with typed (unboxed) i64 argument - should saturate and return i64
    // newargs_unboxed_bitmap = 1 indicates arg 0 is unboxed
    %result = "eco.papExtend"(%pap, %c42) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _operand_types = [!eco.value, i64]
    } : (!eco.value, i64) -> i64

    eco.dbg %result : i64
    // CHECK: 84

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
