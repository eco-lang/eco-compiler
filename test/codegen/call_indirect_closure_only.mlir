// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test calling fully saturated closures.
// When a PAP is created with num_captured == arity, it's immediately evaluated.

module {
  // A function that uses its captured value
  llvm.func @return_captured(%args: !llvm.ptr) -> i64 {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Get first (and only) captured arg
    %p0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b0 = llvm.load %p0 : !llvm.ptr -> i64
    %ptr0 = llvm.call @eco_resolve_hptr(%b0) : (i64) -> !llvm.ptr
    %vp0 = llvm.getelementptr %ptr0[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %val = llvm.load %vp0 : !llvm.ptr -> i64

    %result = llvm.call @eco_alloc_int(%val) : (i64) -> i64
    llvm.return %result : i64
  }

  // A function that takes 2 args and returns their sum
  llvm.func @sum2(%args: !llvm.ptr) -> i64 {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    %p0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    %b0 = llvm.load %p0 : !llvm.ptr -> i64
    %b1 = llvm.load %p1 : !llvm.ptr -> i64

    %ptr0 = llvm.call @eco_resolve_hptr(%b0) : (i64) -> !llvm.ptr
    %ptr1 = llvm.call @eco_resolve_hptr(%b1) : (i64) -> !llvm.ptr

    %vp0 = llvm.getelementptr %ptr0[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp1 = llvm.getelementptr %ptr1[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %v0 = llvm.load %vp0 : !llvm.ptr -> i64
    %v1 = llvm.load %vp1 : !llvm.ptr -> i64

    %sum = llvm.add %v0, %v1 : i64

    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> i64
    llvm.return %result : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %c100 = arith.constant 100 : i64
    %c200 = arith.constant 200 : i64
    %b100 = eco.box %c100 : i64 -> !eco.value
    %b200 = eco.box %c200 : i64 -> !eco.value

    // Test 1: Create PAP with 1 captured, then extend with 1 to saturate
    // arity=2, captured=1, extend with 1 -> fully saturated
    %pap1 = "eco.papCreate"(%b100) {
      function = @sum2,
      arity = 2 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value

    // Extend with 1 arg to saturate: 100 + 200 = 300
    %result1 = "eco.papExtend"(%pap1, %b200) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result1 : !eco.value
    // CHECK: 300

    // Test 2: Create another PAP and saturate
    %c50 = arith.constant 50 : i64
    %c25 = arith.constant 25 : i64
    %b50 = eco.box %c50 : i64 -> !eco.value
    %b25 = eco.box %c25 : i64 -> !eco.value

    %pap2 = "eco.papCreate"(%b50) {
      function = @sum2,
      arity = 2 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value

    %result2 = "eco.papExtend"(%pap2, %b25) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result2 : !eco.value
    // CHECK: 75

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
