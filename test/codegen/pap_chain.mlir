// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test chaining partial applications: multiple closures from same function,
// each with different captured arguments.

module {
  // A function that computes a*x + b
  // Linear function: takes coefficients a, b and input x
  llvm.func @linear(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load args[0] = a (multiplier)
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %a_ptr = llvm.inttoptr %a_i64 : i64 to !llvm.ptr
    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64

    // Load args[1] = b (offset)
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %b_ptr = llvm.inttoptr %b_i64 : i64 to !llvm.ptr
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64

    // Load args[2] = x (input)
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %x_i64 = llvm.load %ptr2 : !llvm.ptr -> i64
    %x_ptr = llvm.inttoptr %x_i64 : i64 to !llvm.ptr
    %x_val_ptr = llvm.getelementptr %x_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %x = llvm.load %x_val_ptr : !llvm.ptr -> i64

    // Compute a*x + b
    %ax = llvm.mul %a, %x : i64
    %result_val = llvm.add %ax, %b : i64

    %result = llvm.call @eco_alloc_int(%result_val) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create some boxed integers
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %i5 = arith.constant 5 : i64
    %i10 = arith.constant 10 : i64
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %b5 = eco.box %i5 : i64 -> !eco.value
    %b10 = eco.box %i10 : i64 -> !eco.value

    // Create two different linear functions by partially applying different a,b:
    // f1(x) = 2*x + 3 (double plus 3)
    // f2(x) = 5*x + 10 (times 5 plus 10)

    %f1 = "eco.papCreate"(%b2, %b3) {
      function = @linear,
      arity = 3 : i64,
      num_captured = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    %f2 = "eco.papCreate"(%b5, %b10) {
      function = @linear,
      arity = 3 : i64,
      num_captured = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %f1 : !eco.value
    // CHECK: <fn>
    eco.dbg %f2 : !eco.value
    // CHECK: <fn>

    // Apply f1(5) = 2*5 + 3 = 13
    %r1 = "eco.papExtend"(%f1, %b5) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %r1 : !eco.value
    // CHECK: 13

    // Apply f2(5) = 5*5 + 10 = 35
    %r2 = "eco.papExtend"(%f2, %b5) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %r2 : !eco.value
    // CHECK: 35

    // Apply f1(10) = 2*10 + 3 = 23
    %r3 = "eco.papExtend"(%f1, %b10) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %r3 : !eco.value
    // CHECK: 23

    // Apply f2(2) = 5*2 + 10 = 20
    %r4 = "eco.papExtend"(%f2, %b2) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %r4 : !eco.value
    // CHECK: 20

    // Compose: f2(f1(2)) = f2(7) = 5*7 + 10 = 45
    // First compute f1(2) = 2*2 + 3 = 7
    %f1_2 = "eco.papExtend"(%f1, %b2) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %f1_2 : !eco.value
    // CHECK: 7

    // Then compute f2(7)
    %r5 = "eco.papExtend"(%f2, %f1_2) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %r5 : !eco.value
    // CHECK: 45

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
