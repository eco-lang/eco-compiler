// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test papExtend saturation returning f64.
// This exercises the inline closure call with f64 result conversion in PapExtendOpLowering.

module {
  // Evaluator function that adds two floats.
  // Takes pointer to args array (two f64 values stored as i64 bits), returns ptr.
  llvm.func @add_floats_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64

    // Load args[0] - first f64 as i64 bits
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %a = llvm.bitcast %a_i64 : i64 to f64

    // Load args[1] - second f64 as i64 bits
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %b = llvm.bitcast %b_i64 : i64 to f64

    // Add them
    %result = llvm.fadd %a, %b : f64

    // Convert back: f64 -> i64 -> ptr (wrapper ABI)
    %result_i64 = llvm.bitcast %result : f64 to i64
    %result_ptr = llvm.inttoptr %result_i64 : i64 to !llvm.ptr
    llvm.return %result_ptr : !llvm.ptr
  }

  func.func @main() -> i64 {
    // Create a PAP with one captured f64 value
    %captured = arith.constant 10.5 : f64

    // arity = 2 (one captured + one remaining)
    // unboxed_bitmap = 1 (bit 0 set = first captured is unboxed f64)
    %pap = "eco.papCreate"(%captured) {
      function = @add_floats_eval,
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (f64) -> !eco.value

    // Extend with second f64 argument - should saturate and return f64
    %arg = arith.constant 5.25 : f64

    // newargs_unboxed_bitmap = 1 (arg 0 is unboxed f64)
    %result = "eco.papExtend"(%pap, %arg) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _operand_types = [!eco.value, f64]
    } : (!eco.value, f64) -> f64

    // Expected: 10.5 + 5.25 = 15.75
    eco.dbg %result : f64
    // CHECK: 15.75

    // Test another case: create PAP with no captures, saturate with both args
    %pap2 = "eco.papCreate"() {
      function = @add_floats_eval,
      arity = 2 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    %arg1 = arith.constant 100.0 : f64
    %arg2 = arith.constant 23.5 : f64

    // Extend with both args at once - saturates immediately
    %result2 = "eco.papExtend"(%pap2, %arg1, %arg2) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 3 : i64,
      _operand_types = [!eco.value, f64, f64]
    } : (!eco.value, f64, f64) -> f64

    // Expected: 100.0 + 23.5 = 123.5
    eco.dbg %result2 : f64
    // CHECK: 123.5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
