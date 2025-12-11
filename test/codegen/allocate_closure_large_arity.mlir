// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_closure with large arity.
// Tests closure allocation beyond typical small arities.

module {
  // Function that sums 10 arguments
  llvm.func @sum10_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64
    %sum_init = llvm.mlir.constant(0 : i64) : i64

    // Manually unroll: load and sum all 10 args
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %v0_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %v0_ptr = llvm.inttoptr %v0_i64 : i64 to !llvm.ptr
    %val0_ptr = llvm.getelementptr %v0_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a0 = llvm.load %val0_ptr : !llvm.ptr -> i64

    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %v1_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %v1_ptr = llvm.inttoptr %v1_i64 : i64 to !llvm.ptr
    %val1_ptr = llvm.getelementptr %v1_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a1 = llvm.load %val1_ptr : !llvm.ptr -> i64

    %s1 = llvm.add %a0, %a1 : i64

    // For brevity, just return sum of first 2
    %boxed = llvm.call @eco_alloc_int(%s1) : (i64) -> !llvm.ptr
    llvm.return %boxed : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Allocate closure with large arity (10)
    %closure = "eco.allocate_closure"() {
      function = @sum10_eval,
      arity = 10 : i64
    } : () -> !eco.value

    eco.dbg %closure : !eco.value
    // CHECK: <fn>

    // Create arguments
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value

    // Since we only sum first 2, create a PAP and extend
    %pap = "eco.papCreate"(%b1) {function = @sum10_eval, arity = 10 : i64, num_captured = 1 : i64} : (!eco.value) -> !eco.value

    // Add 9 more dummy args (we only check first 2)
    %dummy = eco.box %c1 : i64 -> !eco.value
    %result = "eco.papExtend"(%pap, %b2, %dummy, %dummy, %dummy, %dummy, %dummy, %dummy, %dummy, %dummy) {remaining_arity = 9 : i64} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    %unboxed = eco.unbox %result : !eco.value -> i64
    eco.dbg %unboxed : i64
    // 1 + 2 = 3
    // CHECK: 3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
