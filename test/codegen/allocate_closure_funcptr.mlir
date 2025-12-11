// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_closure with proper function pointer lookup.
// Tests that the closure evaluator is correctly set to the target function.

module {
  // Evaluator function that doubles its argument
  llvm.func @double_eval(%args: !llvm.ptr) -> !llvm.ptr {
    // Load args[0]
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %x_i64 = llvm.load %ptr0 : !llvm.ptr -> i64

    // Unbox
    %x_ptr = llvm.inttoptr %x_i64 : i64 to !llvm.ptr
    %c8 = llvm.mlir.constant(8 : i64) : i64
    %val_ptr = llvm.getelementptr %x_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %x = llvm.load %val_ptr : !llvm.ptr -> i64

    // Double
    %two = llvm.mlir.constant(2 : i64) : i64
    %result = llvm.mul %x, %two : i64

    // Box result
    %boxed = llvm.call @eco_alloc_int(%result) : (i64) -> !llvm.ptr
    llvm.return %boxed : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Allocate a closure for @double_eval with arity=1 (takes 1 argument)
    // The lowering should set the evaluator to point to @double_eval
    %closure = "eco.allocate_closure"() {
      function = @double_eval,
      arity = 1 : i64
    } : () -> !eco.value

    // Box argument
    %three = arith.constant 3 : i64
    %boxed = eco.box %three : i64 -> !eco.value

    // Attempt to call via papExtend (saturated)
    // This will fail because evaluator is null
    %result = "eco.papExtend"(%closure, %boxed) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    %unboxed = eco.unbox %result : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 6

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
