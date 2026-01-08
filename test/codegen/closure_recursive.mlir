// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test closure stored in global and retrieved for use.
// Simplified version without actual recursion (which requires complex LLVM).

module {
  // Global to hold a closure
  eco.global @my_closure

  // Simple add function
  llvm.func @add_impl(%args: !llvm.ptr) -> i64 {
    %c0 = llvm.mlir.constant(0 : i64) : i64
    %c1 = llvm.mlir.constant(1 : i64) : i64
    %c8 = llvm.mlir.constant(8 : i64) : i64

    // Load args[0] and args[1]
    %ptr0 = llvm.getelementptr %args[%c0] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %ptr1 = llvm.getelementptr %args[%c1] : (!llvm.ptr, i64) -> !llvm.ptr, i64
    %a_i64 = llvm.load %ptr0 : !llvm.ptr -> i64
    %b_i64 = llvm.load %ptr1 : !llvm.ptr -> i64

    // Unbox
    %a_ptr = llvm.call @eco_resolve_hptr(%a_i64) : (i64) -> !llvm.ptr
    %b_ptr = llvm.call @eco_resolve_hptr(%b_i64) : (i64) -> !llvm.ptr
    %a_val_ptr = llvm.getelementptr %a_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %b_val_ptr = llvm.getelementptr %b_ptr[%c8] : (!llvm.ptr, i64) -> !llvm.ptr, i8
    %a = llvm.load %a_val_ptr : !llvm.ptr -> i64
    %b = llvm.load %b_val_ptr : !llvm.ptr -> i64

    // Add
    %sum = llvm.add %a, %b : i64
    %result = llvm.call @eco_alloc_int(%sum) : (i64) -> i64
    llvm.return %result : i64
  }

  llvm.func @eco_alloc_int(i64) -> i64
  llvm.func @eco_resolve_hptr(i64) -> !llvm.ptr

  func.func @main() -> i64 {
    // Create closure for add function
    %add_closure = "eco.papCreate"() {
      function = @add_impl,
      arity = 2 : i64,
      num_captured = 0 : i64
    } : () -> !eco.value

    // Store in global
    eco.store_global %add_closure, @my_closure

    // Load it back from global
    %loaded_closure = eco.load_global @my_closure
    eco.dbg %loaded_closure : !eco.value
    // CHECK: <fn>

    // Use the loaded closure: add(10, 20) = 30
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value

    // Extend with first arg
    %pap1 = "eco.papExtend"(%loaded_closure, %b10) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    // Extend with second arg - saturates
    %result = "eco.papExtend"(%pap1, %b20) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: 30

    // Store a different closure (partially applied)
    %i5 = arith.constant 5 : i64
    %b5 = eco.box %i5 : i64 -> !eco.value
    %pap_5 = "eco.papExtend"(%add_closure, %b5) {
      remaining_arity = 2 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.store_global %pap_5, @my_closure

    // Load and use: add5(7) = 12
    %add5 = eco.load_global @my_closure
    %i7 = arith.constant 7 : i64
    %b7 = eco.box %i7 : i64 -> !eco.value
    %result2 = "eco.papExtend"(%add5, %b7) {
      remaining_arity = 1 : i64
    } : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result2 : !eco.value
    // CHECK: 12

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
