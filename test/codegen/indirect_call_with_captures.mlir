// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test indirect call through a closure that has captured values.
// The closure captures some arguments and the call provides the rest.

module {
  // Function: add(a, b) = a + b
  llvm.func @add_eval(%args: !llvm.ptr) -> i64 {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load args[0]
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %a_ptr = llvm.call @eco_resolve_hptr(%a_i64) : (i64) -> !llvm.ptr
    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64

    // Load args[1]
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %b_ptr = llvm.call @eco_resolve_hptr(%b_i64) : (i64) -> !llvm.ptr
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64

    %sum = llvm.add %a, %b : i64
    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> i64
    llvm.return %result : i64
  }

  // Function: mul(a, b) = a * b
  llvm.func @mul_eval(%args: !llvm.ptr) -> i64 {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %a_ptr = llvm.call @eco_resolve_hptr(%a_i64) : (i64) -> !llvm.ptr
    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64

    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %b_ptr = llvm.call @eco_resolve_hptr(%b_i64) : (i64) -> !llvm.ptr
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64

    %prod = llvm.mul %a, %b : i64
    %result = llvm.call @eco_alloc_int(%prod) : (i64) -> i64
    llvm.return %result : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %i5 = arith.constant 5 : i64
    %i7 = arith.constant 7 : i64
    %i10 = arith.constant 10 : i64
    %b5 = eco.box %i5 : i64 -> !eco.value
    %b7 = eco.box %i7 : i64 -> !eco.value
    %b10 = eco.box %i10 : i64 -> !eco.value

    // Create closure: add5 = add with first arg=5 captured
    %add5 = "eco.papCreate"(%b5) {
      function = @add_eval,
      arity = 2 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value
    eco.dbg %add5 : !eco.value
    // CHECK: <fn>

    // Indirect call: add5(7) = 5 + 7 = 12
    %result1 = "eco.call"(%add5, %b7) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result1 : !eco.value
    // CHECK: 12

    // Indirect call: add5(10) = 5 + 10 = 15
    %result2 = "eco.call"(%add5, %b10) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result2 : !eco.value
    // CHECK: 15

    // Create closure: mul7 = mul with first arg=7 captured
    %mul7 = "eco.papCreate"(%b7) {
      function = @mul_eval,
      arity = 2 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value

    // Indirect call: mul7(5) = 7 * 5 = 35
    %result3 = "eco.call"(%mul7, %b5) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result3 : !eco.value
    // CHECK: 35

    // Indirect call: mul7(10) = 7 * 10 = 70
    %result4 = "eco.call"(%mul7, %b10) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result4 : !eco.value
    // CHECK: 70

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
