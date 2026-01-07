// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test map-like operation over a list using closure dispatch.
// This is a realistic test showing how closures would be used
// in functional programming patterns like List.map.

module {
  // Square evaluator
  llvm.func @square_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load and unbox args[0]
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %x_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %x_ptr = llvm.inttoptr %x_i64 : i64 to !llvm.ptr
    %val_ptr = llvm.getelementptr %x_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %x = llvm.load %val_ptr : !llvm.ptr -> i64

    // x * x
    %result = llvm.mul %x, %x : i64

    // Box result
    %boxed = llvm.call @eco_alloc_int(%result) : (i64) -> !llvm.ptr
    llvm.return %boxed : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create closure for @square_eval
    %square_fn = "eco.papCreate"() {
      function = @square_eval,
      arity = 1 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    // Build a simple list: [1, 2, 3] represented as nested Cons cells
    %one = arith.constant 1 : i64
    %two = arith.constant 2 : i64
    %three = arith.constant 3 : i64

    %nil = eco.constant Nil : !eco.value

    // Cons 3 Nil
    %boxed3 = eco.box %three : i64 -> !eco.value
    %list1 = eco.construct.custom(%boxed3, %nil) {tag = 1 : i64, size = 2 : i64}
      : (!eco.value, !eco.value) -> !eco.value

    // Cons 2 (Cons 3 Nil)
    %boxed2 = eco.box %two : i64 -> !eco.value
    %list2 = eco.construct.custom(%boxed2, %list1) {tag = 1 : i64, size = 2 : i64}
      : (!eco.value, !eco.value) -> !eco.value

    // Cons 1 (Cons 2 (Cons 3 Nil))
    %boxed1 = eco.box %one : i64 -> !eco.value
    %list3 = eco.construct.custom(%boxed1, %list2) {tag = 1 : i64, size = 2 : i64}
      : (!eco.value, !eco.value) -> !eco.value

    // Manually "map" square over each element using indirect closure calls

    // Get head of list (field 0), apply square
    %head1 = eco.project.custom %list3[0] : !eco.value -> !eco.value
    %squared1 = "eco.call"(%square_fn, %head1) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    %result1 = eco.unbox %squared1 : !eco.value -> i64
    eco.dbg %result1 : i64
    // CHECK: 1

    // Get second element, apply square
    %tail1 = eco.project.custom %list3[1] : !eco.value -> !eco.value
    %head2 = eco.project.custom %tail1[0] : !eco.value -> !eco.value
    %squared2 = "eco.call"(%square_fn, %head2) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    %result2 = eco.unbox %squared2 : !eco.value -> i64
    eco.dbg %result2 : i64
    // CHECK: 4

    // Get third element, apply square
    %tail2 = eco.project.custom %tail1[1] : !eco.value -> !eco.value
    %head3 = eco.project.custom %tail2[0] : !eco.value -> !eco.value
    %squared3 = "eco.call"(%square_fn, %head3) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    %result3 = eco.unbox %squared3 : !eco.value -> i64
    eco.dbg %result3 : i64
    // CHECK: 9

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
