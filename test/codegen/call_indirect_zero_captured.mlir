// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test indirect call on closure with no captured values.
// Edge case: the captured values loop body never executes.

module {
  // Simple double function as an evaluator
  llvm.func @double_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load args[0]
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %box_i64 = llvm.load %ptr0 : !llvm.ptr -> i64

    // Unbox
    %box_ptr = llvm.inttoptr %box_i64 : i64 to !llvm.ptr
    %val_ptr = llvm.getelementptr %box_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %val = llvm.load %val_ptr : !llvm.ptr -> i64

    // Double it
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %doubled = llvm.mul %val, %c2 : i64

    // Box result
    %result = llvm.call @eco_alloc_int(%doubled) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create closure with 0 captured values
    %closure = "eco.papCreate"() {
      function = @double_eval,
      arity = 1 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    eco.dbg %closure : !eco.value
    // CHECK: <fn>

    // Call indirectly with a single argument: 21 * 2 = 42
    %c21 = arith.constant 21 : i64
    %b21 = eco.box %c21 : i64 -> !eco.value

    %result = "eco.papExtend"(%closure, %b21) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
