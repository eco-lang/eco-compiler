// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test PAP with large arity (6 arguments).
// Creates closures and extends multiple times.

module {
  // Function that sums six integers
  llvm.func @sum_six(%args: !llvm.ptr) -> i64 {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Helper function to load and unbox arg at index
    %sum = llvm.mlir.constant(0 : i64) : i64

    // Load all 6 arguments
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %c3 = llvm.mlir.constant(3 : i64) : i64
    %c4 = llvm.mlir.constant(4 : i64) : i64
    %c5 = llvm.mlir.constant(5 : i64) : i64

    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr3 = llvm.getelementptr %args[%c3] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr4 = llvm.getelementptr %args[%c4] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr5 = llvm.getelementptr %args[%c5] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    %a0_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %a1_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %a2_i64 = llvm.load %ptr2 : !llvm.ptr -> i64
    %a3_i64 = llvm.load %ptr3 : !llvm.ptr -> i64
    %a4_i64 = llvm.load %ptr4 : !llvm.ptr -> i64
    %a5_i64 = llvm.load %ptr5 : !llvm.ptr -> i64

    // Unbox each
    %p0 = llvm.call @eco_resolve_hptr(%a0_i64) : (i64) -> !llvm.ptr
    %p1 = llvm.call @eco_resolve_hptr(%a1_i64) : (i64) -> !llvm.ptr
    %p2 = llvm.call @eco_resolve_hptr(%a2_i64) : (i64) -> !llvm.ptr
    %p3 = llvm.call @eco_resolve_hptr(%a3_i64) : (i64) -> !llvm.ptr
    %p4 = llvm.call @eco_resolve_hptr(%a4_i64) : (i64) -> !llvm.ptr
    %p5 = llvm.call @eco_resolve_hptr(%a5_i64) : (i64) -> !llvm.ptr

    %vp0 = llvm.getelementptr %p0[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp1 = llvm.getelementptr %p1[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp2 = llvm.getelementptr %p2[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp3 = llvm.getelementptr %p3[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp4 = llvm.getelementptr %p4[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp5 = llvm.getelementptr %p5[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %v0 = llvm.load %vp0 : !llvm.ptr -> i64
    %v1 = llvm.load %vp1 : !llvm.ptr -> i64
    %v2 = llvm.load %vp2 : !llvm.ptr -> i64
    %v3 = llvm.load %vp3 : !llvm.ptr -> i64
    %v4 = llvm.load %vp4 : !llvm.ptr -> i64
    %v5 = llvm.load %vp5 : !llvm.ptr -> i64

    // Sum all: 1+2+3+4+5+6 = 21
    %s1 = llvm.add %v0, %v1 : i64
    %s2 = llvm.add %s1, %v2 : i64
    %s3 = llvm.add %s2, %v3 : i64
    %s4 = llvm.add %s3, %v4 : i64
    %s5 = llvm.add %s4, %v5 : i64

    %result = llvm.call @eco_alloc_int(%s5) : (i64) -> i64
    llvm.return %result : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create boxed integers 1-6
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %i4 = arith.constant 4 : i64
    %i5 = arith.constant 5 : i64
    %i6 = arith.constant 6 : i64

    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %b4 = eco.box %i4 : i64 -> !eco.value
    %b5 = eco.box %i5 : i64 -> !eco.value
    %b6 = eco.box %i6 : i64 -> !eco.value

    // Create PAP capturing first 3 args: sum_six(1, 2, 3, _, _, _)
    %pap3 = "eco.papCreate"(%b1, %b2, %b3) {
      function = @sum_six,
      arity = 6 : i64,
      num_captured = 3 : i64
    } : (!eco.value, !eco.value, !eco.value) -> !eco.value

    eco.dbg %pap3 : !eco.value
    // CHECK: <fn>

    // Extend with arg 4
    %pap4 = "eco.papExtend"(%pap3, %b4) {
      remaining_arity = 3 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %pap4 : !eco.value
    // CHECK: <fn>

    // Extend with arg 5
    %pap5 = "eco.papExtend"(%pap4, %b5) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %pap5 : !eco.value
    // CHECK: <fn>

    // Extend with arg 6 - saturates: 1+2+3+4+5+6 = 21
    %result = "eco.papExtend"(%pap5, %b6) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: 21

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
