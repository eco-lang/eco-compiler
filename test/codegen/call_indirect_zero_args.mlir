// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test papExtend saturation triggers evaluation.
// When papExtend provides the final argument, the closure should evaluate.

module {
  // Function that takes 2 arguments and returns their product
  llvm.func @mul2_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    %v0_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %v1_i64 = llvm.load %ptr1 : !llvm.ptr -> i64

    %v0_ptr = llvm.inttoptr %v0_i64 : i64 to !llvm.ptr
    %v1_ptr = llvm.inttoptr %v1_i64 : i64 to !llvm.ptr

    %val0_ptr = llvm.getelementptr %v0_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %val1_ptr = llvm.getelementptr %v1_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %a = llvm.load %val0_ptr : !llvm.ptr -> i64
    %b = llvm.load %val1_ptr : !llvm.ptr -> i64

    %product = llvm.mul %a, %b : i64

    %boxed = llvm.call @eco_alloc_int(%product) : (i64) -> !llvm.ptr
    llvm.return %boxed : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %c7 = arith.constant 7 : i64
    %c8 = arith.constant 8 : i64

    %b7 = eco.box %c7 : i64 -> !eco.value
    %b8 = eco.box %c8 : i64 -> !eco.value

    // Create a PAP with 1 captured arg
    %pap = "eco.papCreate"(%b7) {function = @mul2_eval, arity = 2 : i64, num_captured = 1 : i64} : (!eco.value) -> !eco.value

    // Extend to fully saturate - this should evaluate immediately and return the result
    %result = "eco.papExtend"(%pap, %b8) {remaining_arity = 1 : i64} : (!eco.value, !eco.value) -> !eco.value

    // 7 * 8 = 56
    %unboxed = eco.unbox %result : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 56

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
