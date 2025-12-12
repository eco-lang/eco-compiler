// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test PAP with high arity (tests packed field bit limits).
// The packed field uses 6 bits for n_values and max_values (max 63).

module {
  // Function that sums 8 integers
  llvm.func @sum8(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64
    %sum_init = llvm.mlir.constant(0 : i64) : i64

    // Unroll: load each arg, unbox, accumulate
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %c3 = llvm.mlir.constant(3 : i64) : i64
    %c4 = llvm.mlir.constant(4 : i64) : i64
    %c5 = llvm.mlir.constant(5 : i64) : i64
    %c6 = llvm.mlir.constant(6 : i64) : i64
    %c7 = llvm.mlir.constant(7 : i64) : i64

    // Get pointers to each arg
    %p0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p3 = llvm.getelementptr %args[%c3] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p4 = llvm.getelementptr %args[%c4] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p5 = llvm.getelementptr %args[%c5] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p6 = llvm.getelementptr %args[%c6] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p7 = llvm.getelementptr %args[%c7] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    // Load boxed pointers
    %b0 = llvm.load %p0 : !llvm.ptr -> i64
    %b1 = llvm.load %p1 : !llvm.ptr -> i64
    %b2 = llvm.load %p2 : !llvm.ptr -> i64
    %b3 = llvm.load %p3 : !llvm.ptr -> i64
    %b4 = llvm.load %p4 : !llvm.ptr -> i64
    %b5 = llvm.load %p5 : !llvm.ptr -> i64
    %b6 = llvm.load %p6 : !llvm.ptr -> i64
    %b7 = llvm.load %p7 : !llvm.ptr -> i64

    // Convert to pointers and get value (offset 8 for ElmInt)
    %ptr0 = llvm.inttoptr %b0 : i64 to !llvm.ptr
    %ptr1 = llvm.inttoptr %b1 : i64 to !llvm.ptr
    %ptr2 = llvm.inttoptr %b2 : i64 to !llvm.ptr
    %ptr3 = llvm.inttoptr %b3 : i64 to !llvm.ptr
    %ptr4 = llvm.inttoptr %b4 : i64 to !llvm.ptr
    %ptr5 = llvm.inttoptr %b5 : i64 to !llvm.ptr
    %ptr6 = llvm.inttoptr %b6 : i64 to !llvm.ptr
    %ptr7 = llvm.inttoptr %b7 : i64 to !llvm.ptr

    %vp0 = llvm.getelementptr %ptr0[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp1 = llvm.getelementptr %ptr1[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp2 = llvm.getelementptr %ptr2[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp3 = llvm.getelementptr %ptr3[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp4 = llvm.getelementptr %ptr4[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp5 = llvm.getelementptr %ptr5[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp6 = llvm.getelementptr %ptr6[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp7 = llvm.getelementptr %ptr7[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %v0 = llvm.load %vp0 : !llvm.ptr -> i64
    %v1 = llvm.load %vp1 : !llvm.ptr -> i64
    %v2 = llvm.load %vp2 : !llvm.ptr -> i64
    %v3 = llvm.load %vp3 : !llvm.ptr -> i64
    %v4 = llvm.load %vp4 : !llvm.ptr -> i64
    %v5 = llvm.load %vp5 : !llvm.ptr -> i64
    %v6 = llvm.load %vp6 : !llvm.ptr -> i64
    %v7 = llvm.load %vp7 : !llvm.ptr -> i64

    // Sum all
    %s1 = llvm.add %v0, %v1 : i64
    %s2 = llvm.add %s1, %v2 : i64
    %s3 = llvm.add %s2, %v3 : i64
    %s4 = llvm.add %s3, %v4 : i64
    %s5 = llvm.add %s4, %v5 : i64
    %s6 = llvm.add %s5, %v6 : i64
    %sum = llvm.add %s6, %v7 : i64

    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64
    %c5 = arith.constant 5 : i64
    %c6 = arith.constant 6 : i64
    %c7 = arith.constant 7 : i64
    %c8 = arith.constant 8 : i64

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value
    %b4 = eco.box %c4 : i64 -> !eco.value
    %b5 = eco.box %c5 : i64 -> !eco.value
    %b6 = eco.box %c6 : i64 -> !eco.value
    %b7 = eco.box %c7 : i64 -> !eco.value
    %b8 = eco.box %c8 : i64 -> !eco.value

    // Create PAP with 4 captured values
    %pap4 = "eco.papCreate"(%b1, %b2, %b3, %b4) {
      function = @sum8,
      arity = 8 : i64,
      num_captured = 4 : i64
    } : (!eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    eco.dbg %pap4 : !eco.value
    // CHECK: <fn>

    // Extend with remaining 4 to saturate: 1+2+3+4+5+6+7+8 = 36
    %result = "eco.papExtend"(%pap4, %b5, %b6, %b7, %b8) {
      remaining_arity = 4 : i64
    } : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: 36

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
