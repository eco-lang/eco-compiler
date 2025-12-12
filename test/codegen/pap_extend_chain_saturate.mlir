// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test chain of papExtend calls where final one saturates.
// Tests multi-step saturation logic.

module {
  // Function that sums 4 integers
  llvm.func @add_four(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %c3 = llvm.mlir.constant(3 : i64) : i64

    // Get pointers to each arg
    %p0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p3 = llvm.getelementptr %args[%c3] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    // Load boxed pointers
    %b0 = llvm.load %p0 : !llvm.ptr -> i64
    %b1 = llvm.load %p1 : !llvm.ptr -> i64
    %b2 = llvm.load %p2 : !llvm.ptr -> i64
    %b3 = llvm.load %p3 : !llvm.ptr -> i64

    // Convert to pointers and get value (offset 8 for ElmInt)
    %ptr0 = llvm.inttoptr %b0 : i64 to !llvm.ptr
    %ptr1 = llvm.inttoptr %b1 : i64 to !llvm.ptr
    %ptr2 = llvm.inttoptr %b2 : i64 to !llvm.ptr
    %ptr3 = llvm.inttoptr %b3 : i64 to !llvm.ptr

    %vp0 = llvm.getelementptr %ptr0[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp1 = llvm.getelementptr %ptr1[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp2 = llvm.getelementptr %ptr2[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp3 = llvm.getelementptr %ptr3[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %v0 = llvm.load %vp0 : !llvm.ptr -> i64
    %v1 = llvm.load %vp1 : !llvm.ptr -> i64
    %v2 = llvm.load %vp2 : !llvm.ptr -> i64
    %v3 = llvm.load %vp3 : !llvm.ptr -> i64

    // Sum all
    %s1 = llvm.add %v0, %v1 : i64
    %s2 = llvm.add %s1, %v2 : i64
    %sum = llvm.add %s2, %v3 : i64

    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value
    %b4 = eco.box %c4 : i64 -> !eco.value

    // Start with 1 captured
    %pap1 = "eco.papCreate"(%b1) {
      function = @add_four,
      arity = 4 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value

    // Extend with 1 more (still partial)
    %pap2 = "eco.papExtend"(%pap1, %b2) {
      remaining_arity = 3 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    // Extend with 1 more (still partial)
    %pap3 = "eco.papExtend"(%pap2, %b3) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    // Final extend saturates: 1 + 2 + 3 + 4 = 10
    %result = "eco.papExtend"(%pap3, %b4) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: 10

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
