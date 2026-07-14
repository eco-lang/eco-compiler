// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Phase D static-IR enforcement: a papCreate annotated with
// `_result_kind = 1` (PK_Int) must lower to a wrapper whose LLVM
// return type is `i64` and whose body forwards the inner function's
// raw `i64` result without going through `eco_alloc_int`. The boxing
// site has moved to the caller (an `eco.box` op or the
// `eco_apply_closure_eval` helper's primitive→boxed conversion path),
// not the wrapper.

module {
  func.func @double_int(%x: i64) -> i64 {
    %c2 = arith.constant 2 : i64
    %result = arith.muli %x, %c2 : i64
    return %result : i64
  }

  // External sink so the closure isn't dead-code-eliminated.
  llvm.func @use_closure(!llvm.ptr<1>)

  func.func @main() -> i64 {
    %closure = "eco.papCreate"() {
      function = @double_int,
      arity = 1 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64,
      _result_kind = 1 : i8
    } : () -> !eco.value

    %as_ptr = builtin.unrealized_conversion_cast %closure : !eco.value to !llvm.ptr<1>
    llvm.call @use_closure(%as_ptr) : (!llvm.ptr<1>) -> ()

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// The wrapper exists and returns i64 natively. Name is suffixed with
// `_ri` (PK_Int return). `ret i64` confirms the native primitive
// return ABI.
// CHECK: define internal i64 @__closure_wrapper_typed_double_int_ri
// CHECK: ret i64

// Wrapper body forwards the inner function's i64 result directly —
// no boxing helpers are invoked anywhere in the module (the caller's
// `eco.box` or the `eco_apply_closure_eval` helper handles any
// boxing required at the boundary).
// CHECK-NOT: @eco_alloc_int
// CHECK-NOT: @eco_alloc_float
// CHECK-NOT: @eco_alloc_char

// The zero-capture papCreate interns (eco_intern_closure0, HEAP_033) with the wrapper pointer and the
// constants `i32 1` (arity) and `i8 1` (PK_Int) — confirming the
// wrapper is registered on the closure header as primitive-Int.
// CHECK: ptr @__closure_wrapper_typed_double_int_ri, i32 1, i64
