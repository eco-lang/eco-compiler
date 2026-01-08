// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test indirect call through closure with 5+ captured values.
// This tests the loop-based captured value copying in CallOpLowering.

module {
  // Function that sums 6 arguments
  llvm.func @sum6_eval(%args: !llvm.ptr) -> i64 {
    %c8 = llvm.mlir.constant(8 : i64) : i64
    %sum = llvm.mlir.constant(0 : i64) : i64

    // Unroll: load and unbox each of 6 args
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %v0_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %v0_ptr = llvm.call @eco_resolve_hptr(%v0_i64) : (i64) -> !llvm.ptr
    %val0_ptr = llvm.getelementptr %v0_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a0 = llvm.load %val0_ptr : !llvm.ptr -> i64

    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %v1_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %v1_ptr = llvm.call @eco_resolve_hptr(%v1_i64) : (i64) -> !llvm.ptr
    %val1_ptr = llvm.getelementptr %v1_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a1 = llvm.load %val1_ptr : !llvm.ptr -> i64

    %c2 = llvm.mlir.constant(2 : i64) : i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %v2_i64 = llvm.load %ptr2 : !llvm.ptr -> i64
    %v2_ptr = llvm.call @eco_resolve_hptr(%v2_i64) : (i64) -> !llvm.ptr
    %val2_ptr = llvm.getelementptr %v2_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a2 = llvm.load %val2_ptr : !llvm.ptr -> i64

    %c3 = llvm.mlir.constant(3 : i64) : i64
    %ptr3 = llvm.getelementptr %args[%c3] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %v3_i64 = llvm.load %ptr3 : !llvm.ptr -> i64
    %v3_ptr = llvm.call @eco_resolve_hptr(%v3_i64) : (i64) -> !llvm.ptr
    %val3_ptr = llvm.getelementptr %v3_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a3 = llvm.load %val3_ptr : !llvm.ptr -> i64

    %c4 = llvm.mlir.constant(4 : i64) : i64
    %ptr4 = llvm.getelementptr %args[%c4] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %v4_i64 = llvm.load %ptr4 : !llvm.ptr -> i64
    %v4_ptr = llvm.call @eco_resolve_hptr(%v4_i64) : (i64) -> !llvm.ptr
    %val4_ptr = llvm.getelementptr %v4_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a4 = llvm.load %val4_ptr : !llvm.ptr -> i64

    %c5 = llvm.mlir.constant(5 : i64) : i64
    %ptr5 = llvm.getelementptr %args[%c5] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %v5_i64 = llvm.load %ptr5 : !llvm.ptr -> i64
    %v5_ptr = llvm.call @eco_resolve_hptr(%v5_i64) : (i64) -> !llvm.ptr
    %val5_ptr = llvm.getelementptr %v5_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a5 = llvm.load %val5_ptr : !llvm.ptr -> i64

    // Sum all 6
    %s01 = llvm.add %a0, %a1 : i64
    %s012 = llvm.add %s01, %a2 : i64
    %s0123 = llvm.add %s012, %a3 : i64
    %s01234 = llvm.add %s0123, %a4 : i64
    %total = llvm.add %s01234, %a5 : i64

    %boxed = llvm.call @eco_alloc_int(%total) : (i64) -> i64
    llvm.return %boxed : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64
    %c5 = arith.constant 5 : i64
    %c6 = arith.constant 6 : i64

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value
    %b4 = eco.box %c4 : i64 -> !eco.value
    %b5 = eco.box %c5 : i64 -> !eco.value
    %b6 = eco.box %c6 : i64 -> !eco.value

    // Create PAP with 5 captured arguments (tests the loop in indirect call)
    %pap = "eco.papCreate"(%b1, %b2, %b3, %b4, %b5) {function = @sum6_eval, arity = 6 : i64, num_captured = 5 : i64} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    // Extend with 1 more to saturate
    %result = "eco.papExtend"(%pap, %b6) {remaining_arity = 1 : i64} : (!eco.value, !eco.value) -> !eco.value

    // 1 + 2 + 3 + 4 + 5 + 6 = 21
    %unboxed = eco.unbox %result : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 21

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
