// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test PAP with 0 captured arguments initially.
// Creates a closure that captures no arguments, then extends with all at once.

module {
  // Function that adds three integers
  llvm.func @add_three(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load args[0], args[1], args[2]
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %c_i64 = llvm.load %ptr2 : !llvm.ptr -> i64

    // Unbox (values are boxed ElmInt pointers)
    %a_ptr = llvm.inttoptr %a_i64 : i64 to !llvm.ptr
    %b_ptr = llvm.inttoptr %b_i64 : i64 to !llvm.ptr
    %c_ptr = llvm.inttoptr %c_i64 : i64 to !llvm.ptr

    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %c_val_ptr = llvm.getelementptr %c_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64
    %c = llvm.load %c_val_ptr : !llvm.ptr -> i64

    // Add all three
    %sum1 = llvm.add %a, %b : i64
    %sum = llvm.add %sum1, %c : i64

    // Box result
    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value

    // Create PAP with 0 captured arguments
    // arity = 3, num_captured = 0
    %pap0 = "eco.papCreate"() {
      function = @add_three,
      arity = 3 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    eco.dbg %pap0 : !eco.value
    // CHECK: <fn>

    // Extend with first argument
    %pap1 = "eco.papExtend"(%pap0, %b1) {
      remaining_arity = 3 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %pap1 : !eco.value
    // CHECK: <fn>

    // Extend with second argument
    %pap2 = "eco.papExtend"(%pap1, %b2) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %pap2 : !eco.value
    // CHECK: <fn>

    // Extend with third (final) argument - saturates and calls
    // 1 + 2 + 3 = 6
    %result = "eco.papExtend"(%pap2, %b3) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: 6

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
