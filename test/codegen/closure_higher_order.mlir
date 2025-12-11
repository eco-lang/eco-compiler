// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test higher-order functions with closure dispatch using indirect calls.
// The apply_twice function calls an unknown function through its closure.

module {
  // Simple increment evaluator
  llvm.func @increment_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load and unbox args[0]
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %x_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %x_ptr = llvm.inttoptr %x_i64 : i64 to !llvm.ptr
    %val_ptr = llvm.getelementptr %x_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %x = llvm.load %val_ptr : !llvm.ptr -> i64

    // x + 1
    %one = llvm.mlir.constant(1 : i64) : i64
    %result = llvm.add %x, %one : i64

    // Box result
    %boxed = llvm.call @eco_alloc_int(%result) : (i64) -> !llvm.ptr
    llvm.return %boxed : !llvm.ptr
  }

  // Simple double evaluator
  llvm.func @double_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load and unbox args[0]
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %x_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %x_ptr = llvm.inttoptr %x_i64 : i64 to !llvm.ptr
    %val_ptr = llvm.getelementptr %x_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %x = llvm.load %val_ptr : !llvm.ptr -> i64

    // x * 2
    %two = llvm.mlir.constant(2 : i64) : i64
    %result = llvm.mul %x, %two : i64

    // Box result
    %boxed = llvm.call @eco_alloc_int(%result) : (i64) -> !llvm.ptr
    llvm.return %boxed : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  // Higher-order function: applies f to x twice
  // apply_twice f x = f (f x)
  func.func @apply_twice(%f: !eco.value, %x: !eco.value) -> !eco.value {
    // First application: f x (indirect call through closure)
    %first = "eco.call"(%f, %x) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value

    // Second application: f (f x)
    %second = "eco.call"(%f, %first) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value

    eco.return %second : !eco.value
  }

  func.func @main() -> i64 {
    %five = arith.constant 5 : i64
    %b5 = eco.box %five : i64 -> !eco.value

    // Create closure for @increment_eval
    %inc_closure = "eco.papCreate"() {
      function = @increment_eval,
      arity = 1 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    // apply_twice increment 5 = increment (increment 5) = 7
    %result1 = "eco.call"(%inc_closure, %b5) {callee = @apply_twice} : (!eco.value, !eco.value) -> !eco.value
    %r1 = eco.unbox %result1 : !eco.value -> i64
    eco.dbg %r1 : i64
    // CHECK: 7

    // Create closure for @double_eval
    %dbl_closure = "eco.papCreate"() {
      function = @double_eval,
      arity = 1 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    // apply_twice double 5 = double (double 5) = 20
    %result2 = "eco.call"(%dbl_closure, %b5) {callee = @apply_twice} : (!eco.value, !eco.value) -> !eco.value
    %r2 = eco.unbox %result2 : !eco.value -> i64
    eco.dbg %r2 : i64
    // CHECK: 20

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
