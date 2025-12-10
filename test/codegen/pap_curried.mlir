// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test curried function pattern: simulating Elm's curried functions
// where each argument application returns a new closure until saturation.

module {
  // A function that computes a - b - c - d (left to right)
  // This demonstrates order matters: (((a - b) - c) - d)
  llvm.func @subtract_chain(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load all 4 arguments
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

    %c3 = llvm.mlir.constant(3 : i64) : i64
    %ptr3 = llvm.getelementptr %args[%c3] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %d_i64 = llvm.load %ptr3 : !llvm.ptr -> i64
    %d_ptr = llvm.inttoptr %d_i64 : i64 to !llvm.ptr
    %d_val_ptr = llvm.getelementptr %d_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %d = llvm.load %d_val_ptr : !llvm.ptr -> i64

    // Compute (((a - b) - c) - d)
    %r1 = llvm.sub %a, %b : i64
    %r2 = llvm.sub %r1, %c : i64
    %result_val = llvm.sub %r2, %d : i64

    %result = llvm.call @eco_alloc_int(%result_val) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create boxed integers
    %i100 = arith.constant 100 : i64
    %i10 = arith.constant 10 : i64
    %i5 = arith.constant 5 : i64
    %i3 = arith.constant 3 : i64
    %i1 = arith.constant 1 : i64
    %b100 = eco.box %i100 : i64 -> !eco.value
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b5 = eco.box %i5 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %b1 = eco.box %i1 : i64 -> !eco.value

    // Simulate curried function: subtract_chain 100
    // This creates a closure waiting for 3 more args
    %f1 = "eco.papCreate"(%b100) {
      function = @subtract_chain,
      arity = 4 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value
    eco.dbg %f1 : !eco.value
    // CHECK: <fn>

    // Apply one more arg: subtract_chain 100 10
    // Now waiting for 2 more args
    %f2 = "eco.papExtend"(%f1, %b10) {
      remaining_arity = 3 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %f2 : !eco.value
    // CHECK: <fn>

    // Apply one more: subtract_chain 100 10 5
    // Now waiting for 1 more arg
    %f3 = "eco.papExtend"(%f2, %b5) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %f3 : !eco.value
    // CHECK: <fn>

    // Final application: subtract_chain 100 10 5 3
    // Expected: (((100 - 10) - 5) - 3) = ((90 - 5) - 3) = (85 - 3) = 82
    %r1 = "eco.papExtend"(%f3, %b3) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %r1 : !eco.value
    // CHECK: 82

    // Now test reusing intermediate closures
    // Use f2 (subtract_chain 100 10) with different remaining args

    // subtract_chain 100 10 3 1 = (((100-10)-3)-1) = ((90-3)-1) = 86
    %r2 = "eco.papExtend"(%f2, %b3, %b1) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %r2 : !eco.value
    // CHECK: 86

    // Use f1 (subtract_chain 100) with different remaining args
    // subtract_chain 100 5 3 1 = (((100-5)-3)-1) = ((95-3)-1) = 91
    %r3 = "eco.papExtend"(%f1, %b5, %b3, %b1) {
      remaining_arity = 3 : i64
    } : (!eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %r3 : !eco.value
    // CHECK: 91

    // Use f3 (subtract_chain 100 10 5) with different final arg
    // subtract_chain 100 10 5 1 = (((100-10)-5)-1) = 84
    %r4 = "eco.papExtend"(%f3, %b1) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %r4 : !eco.value
    // CHECK: 84

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
