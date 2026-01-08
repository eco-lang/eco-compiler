// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test indirect closure calls (eco.call without callee attribute).
// Calls a closure through its evaluator function pointer using remaining_arity.

module {
  // Evaluator function that adds 1 to its argument
  // Takes pointer to args array, returns pointer to result
  llvm.func @add_one_eval(%args: !llvm.ptr) -> i64 {
    // Load args[0]
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %x_i64 = llvm.load %ptr0 : !llvm.ptr -> i64

    // Unbox: load value at offset 8
    %x_ptr = llvm.call @eco_resolve_hptr(%x_i64) : (i64) -> !llvm.ptr
    %c8 = llvm.mlir.constant(8 : i64) : i64
    %val_ptr = llvm.getelementptr %x_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %x = llvm.load %val_ptr : !llvm.ptr -> i64

    // Add 1
    %one = llvm.mlir.constant(1 : i64) : i64
    %result = llvm.add %x, %one : i64

    // Box result
    %boxed = llvm.call @eco_alloc_int(%result) : (i64) -> i64
    llvm.return %boxed : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create a closure wrapping @add_one_eval
    %closure = "eco.papCreate"() {
      function = @add_one_eval,
      arity = 1 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    // Box the argument
    %five = arith.constant 5 : i64
    %boxed_five = eco.box %five : i64 -> !eco.value

    // Indirect call: pass closure as first operand, no callee attr
    // This should dispatch through the closure's evaluator
    %result = "eco.call"(%closure, %boxed_five) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value

    // Expected: 6 (5 + 1)
    %unboxed = eco.unbox %result : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 6

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
