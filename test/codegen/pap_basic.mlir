// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test basic partial application: create a closure, then saturate it.
// Tests eco.papCreate and eco.papExtend with a simple 2-argument function.

module {
  // A simple function that adds two integers.
  // Takes args array: args[0] = a, args[1] = b
  // Returns boxed (a + b)
  llvm.func @add_two(%args: !llvm.ptr) -> i64 {
    // Load args[0] (first argument)
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64

    // Load args[1] (second argument)
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64

    // Unbox: values are boxed ElmInt HPointers, resolve to raw pointer then load value field at offset 8
    %a_ptr = llvm.call @eco_resolve_hptr(%a_i64) : (i64) -> !llvm.ptr
    %c8 = llvm.mlir.constant(8 : i64) : i64
    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64

    %b_ptr = llvm.call @eco_resolve_hptr(%b_i64) : (i64) -> !llvm.ptr
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64

    // Add
    %sum = llvm.add %a, %b : i64

    // Box the result by calling eco_alloc_int
    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> i64

    llvm.return %result : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create boxed integers
    %i5 = arith.constant 5 : i64
    %i7 = arith.constant 7 : i64
    %b5 = eco.box %i5 : i64 -> !eco.value
    %b7 = eco.box %i7 : i64 -> !eco.value

    // Create a partial application: add_two with first arg = 5
    // arity = 2 (function takes 2 args total)
    // num_captured = 1 (we're capturing 1 arg now)
    %pap = "eco.papCreate"(%b5) {
      function = @add_two,
      arity = 2 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value

    // Debug print the closure (shows as <fn>)
    eco.dbg %pap : !eco.value
    // CHECK: <fn>

    // Saturate the closure: apply second arg = 7
    // remaining_arity = 1 (closure needs 1 more arg)
    // This should call add_two(5, 7) = 12
    %result = "eco.papExtend"(%pap, %b7) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: 12

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
