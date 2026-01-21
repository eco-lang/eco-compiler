// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test papCreate with unboxed captured values (i64, f64).

module {
  // Function that uses captured unboxed integers
  // Computes: captured_a + captured_b + arg
  llvm.func @add_three_ints(%args: !llvm.ptr) -> i64 {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load args[0] (first captured int, already raw i64)
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a = llvm.load %ptr0 : !llvm.ptr -> i64

    // Load args[1] (second captured int)
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b = llvm.load %ptr1 : !llvm.ptr -> i64

    // Load args[2] (call arg, boxed - need to unbox)
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %c_i64 = llvm.load %ptr2 : !llvm.ptr -> i64
    %c_ptr = llvm.call @eco_resolve_hptr(%c_i64) : (i64) -> !llvm.ptr
    %c_val_ptr = llvm.getelementptr %c_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %c = llvm.load %c_val_ptr : !llvm.ptr -> i64

    // Compute sum
    %sum1 = llvm.add %a, %b : i64
    %result_val = llvm.add %sum1, %c : i64

    // Box result
    %result = llvm.call @eco_alloc_int(%result_val) : (i64) -> i64
    llvm.return %result : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create unboxed integers to capture
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64

    // Create PAP with two unboxed captured values
    // arity = 3 (2 captured + 1 remaining)
    // unboxed_bitmap = 0b11 = 3 (both operands are i64)
    %pap = "eco.papCreate"(%i10, %i20) {
      function = @add_three_ints,
      arity = 3 : i64,
      num_captured = 2 : i64,
      unboxed_bitmap = 3 : i64
    } : (i64, i64) -> !eco.value
    eco.dbg %pap : !eco.value
    // CHECK: <fn>

    // Call with remaining arg (boxed)
    %i5 = arith.constant 5 : i64
    %b5 = eco.box %i5 : i64 -> !eco.value

    %result = "eco.papExtend"(%pap, %b5) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    // Expected: 10 + 20 + 5 = 35
    eco.dbg %result : !eco.value
    // CHECK: 35

    // Test with different captured values
    %i100 = arith.constant 100 : i64
    %i200 = arith.constant 200 : i64
    %pap2 = "eco.papCreate"(%i100, %i200) {
      function = @add_three_ints,
      arity = 3 : i64,
      num_captured = 2 : i64,
      unboxed_bitmap = 3 : i64
    } : (i64, i64) -> !eco.value

    %i50 = arith.constant 50 : i64
    %b50 = eco.box %i50 : i64 -> !eco.value

    %result2 = "eco.papExtend"(%pap2, %b50) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    // Expected: 100 + 200 + 50 = 350
    eco.dbg %result2 : !eco.value
    // CHECK: 350

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
