// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test papExtend where new args exactly saturate the closure.
// This tests the exact boundary condition in saturation logic.

module {
  // Function that takes 3 arguments and returns their sum
  llvm.func @sum3_eval(%args: !llvm.ptr) -> !llvm.ptr {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c2 = llvm.mlir.constant(2 : i64) : i64

    // Load args[0], args[1], args[2]
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    %v0_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %v1_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %v2_i64 = llvm.load %ptr2 : !llvm.ptr -> i64

    // Unbox all three
    %v0_ptr = llvm.inttoptr %v0_i64 : i64 to !llvm.ptr
    %v1_ptr = llvm.inttoptr %v1_i64 : i64 to !llvm.ptr
    %v2_ptr = llvm.inttoptr %v2_i64 : i64 to !llvm.ptr

    %c8 = llvm.mlir.constant(8 : i64) : i64
    %val0_ptr = llvm.getelementptr %v0_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %val1_ptr = llvm.getelementptr %v1_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %val2_ptr = llvm.getelementptr %v2_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %a = llvm.load %val0_ptr : !llvm.ptr -> i64
    %b = llvm.load %val1_ptr : !llvm.ptr -> i64
    %c = llvm.load %val2_ptr : !llvm.ptr -> i64

    // Sum them
    %ab = llvm.add %a, %b : i64
    %sum = llvm.add %ab, %c : i64

    // Box result
    %boxed = llvm.call @eco_alloc_int(%sum) : (i64) -> !llvm.ptr
    llvm.return %boxed : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64

    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value
    %b30 = eco.box %c30 : i64 -> !eco.value

    // Create PAP with 1 captured arg, arity 3, so remaining = 2
    %pap1 = "eco.papCreate"(%b10) {function = @sum3_eval, arity = 3 : i64, num_captured = 1 : i64} : (!eco.value) -> !eco.value

    // Extend with exactly 2 args - should saturate and call
    %result = "eco.papExtend"(%pap1, %b20, %b30) {remaining_arity = 2 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value

    %unboxed = eco.unbox %result : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 60

    // Test 2: Create PAP with 2 captured, extend with exactly 1
    %pap2 = "eco.papCreate"(%b10, %b20) {function = @sum3_eval, arity = 3 : i64, num_captured = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %result2 = "eco.papExtend"(%pap2, %b30) {remaining_arity = 1 : i64} : (!eco.value, !eco.value) -> !eco.value

    %unboxed2 = eco.unbox %result2 : !eco.value -> i64
    eco.dbg %unboxed2 : i64
    // CHECK: 60

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
