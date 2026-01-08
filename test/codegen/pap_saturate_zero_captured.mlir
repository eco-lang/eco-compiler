// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test papExtend that saturates a closure with 0 captured values.
// This tests the n_values=0 path in the dynamic loop.

module {
  // Function that adds three integers
  llvm.func @add_three(%args: !llvm.ptr) -> i64 {
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
    %a_ptr = llvm.call @eco_resolve_hptr(%a_i64) : (i64) -> !llvm.ptr
    %b_ptr = llvm.call @eco_resolve_hptr(%b_i64) : (i64) -> !llvm.ptr
    %c_ptr = llvm.call @eco_resolve_hptr(%c_i64) : (i64) -> !llvm.ptr

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
    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> i64
    llvm.return %result : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %i30 = arith.constant 30 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value
    %b30 = eco.box %i30 : i64 -> !eco.value

    // Create PAP with 0 captured values (arity=3, captured=0)
    %pap0 = "eco.papCreate"() {
      function = @add_three,
      arity = 3 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    eco.dbg %pap0 : !eco.value
    // CHECK: <fn>

    // Saturate with all 3 arguments at once: 10 + 20 + 30 = 60
    %result = "eco.papExtend"(%pap0, %b10, %b20, %b30) {
      remaining_arity = 3 : i64
    } : (!eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: 60

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
