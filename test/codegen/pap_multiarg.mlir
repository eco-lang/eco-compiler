// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test partial application with multi-argument functions (3+ args).
// Tests progressive argument capturing and final saturation.

module {
  // A function that computes (a + b) * (c + d)
  // Takes 4 boxed integer arguments
  llvm.func @quadfunc(%args: !llvm.ptr) -> !llvm.ptr {
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load args[0..3]
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

    // Compute (a + b) * (c + d)
    %ab = llvm.add %a, %b : i64
    %cd = llvm.add %c, %d : i64
    %result_val = llvm.mul %ab, %cd : i64

    // Box result
    %result = llvm.call @eco_alloc_int(%result_val) : (i64) -> !llvm.ptr
    llvm.return %result : !llvm.ptr
  }

  llvm.func @eco_alloc_int(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create boxed integers: 2, 3, 4, 5
    // Expected: (2 + 3) * (4 + 5) = 5 * 9 = 45
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %i4 = arith.constant 4 : i64
    %i5 = arith.constant 5 : i64
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %b4 = eco.box %i4 : i64 -> !eco.value
    %b5 = eco.box %i5 : i64 -> !eco.value

    // Test 1: Create PAP with 1 arg, extend with 3 to saturate
    %pap1 = "eco.papCreate"(%b2) {
      function = @quadfunc,
      arity = 4 : i64,
      num_captured = 1 : i64
    } : (!eco.value) -> !eco.value

    eco.dbg %pap1 : !eco.value
    // CHECK: <fn>

    // Saturate: remaining_arity=3, providing 3 args
    %result1 = "eco.papExtend"(%pap1, %b3, %b4, %b5) {
      remaining_arity = 3 : i64
    } : (!eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    eco.dbg %result1 : !eco.value
    // CHECK: 45

    // Test 2: Create PAP with 2 args, extend twice
    %pap2 = "eco.papCreate"(%b2, %b3) {
      function = @quadfunc,
      arity = 4 : i64,
      num_captured = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %pap2 : !eco.value
    // CHECK: <fn>

    // Extend with 1 more arg (still partial)
    %pap2_ext = "eco.papExtend"(%pap2, %b4) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %pap2_ext : !eco.value
    // CHECK: <fn>

    // Saturate with final arg
    %result2 = "eco.papExtend"(%pap2_ext, %b5) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result2 : !eco.value
    // CHECK: 45

    // Test 3: Create PAP with 3 args, saturate with 1
    %pap3 = "eco.papCreate"(%b2, %b3, %b4) {
      function = @quadfunc,
      arity = 4 : i64,
      num_captured = 3 : i64
    } : (!eco.value, !eco.value, !eco.value) -> !eco.value

    %result3 = "eco.papExtend"(%pap3, %b5) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result3 : !eco.value
    // CHECK: 45

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
