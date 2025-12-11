// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.papExtend creating a new unsaturated PAP (remaining_arity > newargs).
// This tests extending a closure without fully saturating it.

module {
  // A function that takes 4 arguments and computes a + b + c + d
  llvm.func @sum_four(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load and unbox all 4 arguments
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %a_ptr = llvm.inttoptr %a_i64 : i64 to !llvm.ptr
    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64

    %c1 = llvm.mlir.constant(1 : i64) : i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64
    %b_ptr = llvm.inttoptr %b_i64 : i64 to !llvm.ptr
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64

    %c2 = llvm.mlir.constant(2 : i64) : i64
    %ptr2 = llvm.getelementptr %args[%c2] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %c_i64 = llvm.load %ptr2 : !llvm.ptr -> i64
    %c_ptr = llvm.inttoptr %c_i64 : i64 to !llvm.ptr
    %c_val_ptr = llvm.getelementptr %c_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %c = llvm.load %c_val_ptr : !llvm.ptr -> i64

    %c3 = llvm.mlir.constant(3 : i64) : i64
    %ptr3 = llvm.getelementptr %args[%c3] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %d_i64 = llvm.load %ptr3 : !llvm.ptr -> i64
    %d_ptr = llvm.inttoptr %d_i64 : i64 to !llvm.ptr
    %d_val_ptr = llvm.getelementptr %d_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %d = llvm.load %d_val_ptr : !llvm.ptr -> i64

    // Sum all
    %ab = llvm.add %a, %b : i64
    %abc = llvm.add %ab, %c : i64
    %result_val = llvm.add %abc, %d : i64

    %result = llvm.call @eco_alloc_int(%result_val) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %i4 = arith.constant 4 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %b4 = eco.box %i4 : i64 -> !eco.value

    // Create PAP with no captured args (arity 4, remaining 4)
    %pap0 = "eco.papCreate"() {
      function = @sum_four,
      arity = 4 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value
    eco.dbg %pap0 : !eco.value
    // CHECK: <fn>

    // Extend with 1 arg (remaining 4 -> 3, still unsaturated)
    %pap1 = "eco.papExtend"(%pap0, %b1) {
      remaining_arity = 4 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pap1 : !eco.value
    // CHECK: <fn>

    // Extend with 1 more arg (remaining 3 -> 2, still unsaturated)
    %pap2 = "eco.papExtend"(%pap1, %b2) {
      remaining_arity = 3 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pap2 : !eco.value
    // CHECK: <fn>

    // Extend with 1 more arg (remaining 2 -> 1, still unsaturated)
    %pap3 = "eco.papExtend"(%pap2, %b3) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pap3 : !eco.value
    // CHECK: <fn>

    // Finally saturate with last arg (remaining 1 -> 0)
    %result = "eco.papExtend"(%pap3, %b4) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result : !eco.value
    // 1 + 2 + 3 + 4 = 10
    // CHECK: 10

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
