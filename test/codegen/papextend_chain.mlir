// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test chaining multiple papExtend calls: f(1)(2)(3)
// This simulates curried function application in Elm.

module {
  // Function that takes 4 arguments: a*b + c*d
  llvm.func @combine4_eval(%args: !llvm.ptr) -> i64 {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c2 = llvm.mlir.constant(2 : i64) : i64
    %c3 = llvm.mlir.constant(3 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load and unbox all 4 args
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr3 = llvm.getelementptr %args[%c3] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    %v0_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %v1_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %v2_i64 = llvm.load %ptr2 : !llvm.ptr -> i64
    %v3_i64 = llvm.load %ptr3 : !llvm.ptr -> i64

    %v0_ptr = llvm.call @eco_resolve_hptr(%v0_i64) : (i64) -> !llvm.ptr
    %v1_ptr = llvm.call @eco_resolve_hptr(%v1_i64) : (i64) -> !llvm.ptr
    %v2_ptr = llvm.call @eco_resolve_hptr(%v2_i64) : (i64) -> !llvm.ptr
    %v3_ptr = llvm.call @eco_resolve_hptr(%v3_i64) : (i64) -> !llvm.ptr

    %val0_ptr = llvm.getelementptr %v0_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %val1_ptr = llvm.getelementptr %v1_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %val2_ptr = llvm.getelementptr %v2_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %val3_ptr = llvm.getelementptr %v3_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %a = llvm.load %val0_ptr : !llvm.ptr -> i64
    %b = llvm.load %val1_ptr : !llvm.ptr -> i64
    %c = llvm.load %val2_ptr : !llvm.ptr -> i64
    %d = llvm.load %val3_ptr : !llvm.ptr -> i64

    // Compute a*b + c*d
    %ab = llvm.mul %a, %b : i64
    %cd = llvm.mul %c, %d : i64
    %result = llvm.add %ab, %cd : i64

    %boxed = llvm.call @eco_alloc_int(%result) : (i64) -> i64
    llvm.return %boxed : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64
    %c5 = arith.constant 5 : i64

    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value
    %b4 = eco.box %c4 : i64 -> !eco.value
    %b5 = eco.box %c5 : i64 -> !eco.value

    // Create initial PAP with 0 captured args
    %pap0 = "eco.papCreate"() {function = @combine4_eval, arity = 4 : i64, num_captured = 0 : i64} : () -> !eco.value

    // Chain: pap0(2) -> pap1
    %pap1 = "eco.papExtend"(%pap0, %b2) {remaining_arity = 4 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pap1 : !eco.value
    // CHECK: <fn>

    // Chain: pap1(3) -> pap2
    %pap2 = "eco.papExtend"(%pap1, %b3) {remaining_arity = 3 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pap2 : !eco.value
    // CHECK: <fn>

    // Chain: pap2(4) -> pap3
    %pap3 = "eco.papExtend"(%pap2, %b4) {remaining_arity = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pap3 : !eco.value
    // CHECK: <fn>

    // Final: pap3(5) -> result (saturates and calls)
    // Result = 2*3 + 4*5 = 6 + 20 = 26
    %result = "eco.papExtend"(%pap3, %b5) {remaining_arity = 1 : i64} : (!eco.value, !eco.value) -> !eco.value
    %unboxed = eco.unbox %result : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 26

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
