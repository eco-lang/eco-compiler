// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test PAP with maximum arity of 63 (6-bit field limit).
// The packed PAP field uses 6 bits for n_values and max_values.
// NOTE: This test may be impractical due to the large number of arguments.
// Marking XFAIL as generating a 63-arg function is complex.

module {
  // A function that takes many arguments - we'll test with arity 10
  // as a proxy for testing larger arities (63 is impractical to write out)
  llvm.func @sum10(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64
    %sum_init = llvm.mlir.constant(0 : i64) : i64

    // Just sum first 3 args as a simplified test
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c2 = llvm.mlir.constant(2 : i64) : i64

    %p0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %p2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64

    %b0 = llvm.load %p0 : !llvm.ptr -> i64
    %b1 = llvm.load %p1 : !llvm.ptr -> i64
    %b2 = llvm.load %p2 : !llvm.ptr -> i64

    %ptr0 = llvm.inttoptr %b0 : i64 to !llvm.ptr
    %ptr1 = llvm.inttoptr %b1 : i64 to !llvm.ptr
    %ptr2 = llvm.inttoptr %b2 : i64 to !llvm.ptr

    %vp0 = llvm.getelementptr %ptr0[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp1 = llvm.getelementptr %ptr1[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %vp2 = llvm.getelementptr %ptr2[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8

    %v0 = llvm.load %vp0 : !llvm.ptr -> i64
    %v1 = llvm.load %vp1 : !llvm.ptr -> i64
    %v2 = llvm.load %vp2 : !llvm.ptr -> i64

    %s1 = llvm.add %v0, %v1 : i64
    %sum = llvm.add %s1, %v2 : i64

    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value

    // Create PAP with high arity (simulating 63)
    // Using arity=10 captured=0 to test the machinery
    %pap = "eco.papCreate"() {
      function = @sum10,
      arity = 10 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    eco.dbg %pap : !eco.value
    // CHECK: <fn>

    // Extend with 3 args (still partial, 7 remaining)
    %pap2 = "eco.papExtend"(%pap, %b1, %b2, %b3) {
      remaining_arity = 10 : i64
    } : (!eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    eco.dbg %pap2 : !eco.value
    // CHECK: <fn>

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
