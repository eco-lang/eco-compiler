// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.papCreate with high capture ratio (num_captured = arity - 1).
// Tests closures that capture all but one argument.

module {
  // A function that adds two boxed integers
  llvm.func @add_two(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load args[0]
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %a_ptr = llvm.inttoptr %a_i64 : i64 to !llvm.ptr
    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64

    // Load args[1]
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %b_ptr = llvm.inttoptr %b_i64 : i64 to !llvm.ptr
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64

    %sum = llvm.add %a, %b : i64
    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  // A function that takes 3 arguments
  llvm.func @sum_three(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %a_ptr = llvm.inttoptr %a_i64 : i64 to !llvm.ptr
    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64

    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %b_ptr = llvm.inttoptr %b_i64 : i64 to !llvm.ptr
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64

    %c2 = llvm.mlir.constant(2 : i64) : i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %c_i64 = llvm.load %ptr2 : !llvm.ptr -> i64
    %c_ptr = llvm.inttoptr %c_i64 : i64 to !llvm.ptr
    %c_val_ptr = llvm.getelementptr %c_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %c = llvm.load %c_val_ptr : !llvm.ptr -> i64

    %ab = llvm.add %a, %b : i64
    %result_val = llvm.add %ab, %c : i64
    %result = llvm.call @eco_alloc_int(%result_val) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %i5 = arith.constant 5 : i64
    %i7 = arith.constant 7 : i64
    %i3 = arith.constant 3 : i64
    %b5 = eco.box %i5 : i64 -> !eco.value
    %b7 = eco.box %i7 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value

    // Create PAP with arity=2, captured=1, remaining=1
    %pap1 = "eco.papCreate"(%b5) {
      function = @add_two,
      arity = 2 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value
    eco.dbg %pap1 : !eco.value
    // CHECK: <fn>

    // Saturate with one more argument: 5 + 7 = 12
    %result1 = "eco.papExtend"(%pap1, %b7) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result1 : !eco.value
    // CHECK: 12

    // Create PAP with arity=3, captured=2, remaining=1 (high capture ratio)
    %pap2 = "eco.papCreate"(%b5, %b7) {
      function = @sum_three,
      arity = 3 : i64,
      num_captured = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pap2 : !eco.value
    // CHECK: <fn>

    // Saturate with one more argument: 5 + 7 + 3 = 15
    %result2 = "eco.papExtend"(%pap2, %b3) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result2 : !eco.value
    // CHECK: 15

    // Different values
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value

    %pap3 = "eco.papCreate"(%b10) {
      function = @add_two,
      arity = 2 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value

    // 10 + 20 = 30
    %result3 = "eco.papExtend"(%pap3, %b20) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result3 : !eco.value
    // CHECK: 30

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
