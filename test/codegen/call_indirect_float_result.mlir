// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test indirect closure calls (eco.call without callee attribute) returning f64.
// This exercises the ptr -> i64 -> f64 result conversion path in CallOpLowering.

module {
  // Evaluator function that doubles a float argument.
  // Takes pointer to args array (single f64 stored as i64 bits), returns ptr.
  llvm.func @double_float_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64

    // Load args[0] - it's an unboxed f64 stored as i64 bits
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %x_i64 = llvm.load %ptr0 : !llvm.ptr -> i64

    // Bitcast i64 bits to f64
    %x = llvm.bitcast %x_i64 : i64 to f64

    // Double it
    %c2 = llvm.mlir.constant(2.0 : f64) : f64
    %result = llvm.fmul %x, %c2 : f64

    // Convert back: f64 -> i64 -> ptr (wrapper ABI)
    %result_i64 = llvm.bitcast %result : f64 to i64
    %result_ptr = llvm.inttoptr %result_i64 : i64 to !llvm.ptr
    llvm.return %result_ptr : !llvm.ptr
  }

  func.func @main() -> i64 {
    // Create a closure wrapping @double_float_eval
    // arity = 1, expects unboxed f64 argument
    %closure = "eco.papCreate"() {
      function = @double_float_eval,
      arity = 1 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    // The argument: 21.5
    %arg = arith.constant 21.5 : f64

    // Indirect call: pass closure as first operand, no callee attr
    // This should dispatch through the closure's evaluator and return f64
    %result = "eco.call"(%closure, %arg) {
      remaining_arity = 1 : i64,
      _operand_types = [!eco.value, f64]
    } : (!eco.value, f64) -> f64

    // Expected: 43.0 (21.5 * 2)
    eco.dbg %result : f64
    // CHECK: 43

    // Test with another value: 3.5 * 2 = 7.0
    %arg2 = arith.constant 3.5 : f64
    %result2 = "eco.call"(%closure, %arg2) {
      remaining_arity = 1 : i64,
      _operand_types = [!eco.value, f64]
    } : (!eco.value, f64) -> f64
    eco.dbg %result2 : f64
    // CHECK: 7

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
