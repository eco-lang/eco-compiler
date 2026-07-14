// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Phase D static-IR enforcement: a papCreate annotated with
// `_result_kind = 3` (PK_Char) must lower to a wrapper whose LLVM
// return type is `i16` and whose body forwards the inner function's
// raw `i16` result without going through `eco_alloc_char`. The boxing
// site has moved to the caller.

module {
  func.func @upper_char(%x: i16) -> i16 {
    %offset = arith.constant 32 : i16
    %result = arith.subi %x, %offset : i16
    return %result : i16
  }

  llvm.func @use_closure(!llvm.ptr<1>)

  func.func @main() -> i64 {
    %closure = "eco.papCreate"() {
      function = @upper_char,
      arity = 1 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64,
      _result_kind = 3 : i8
    } : () -> !eco.value

    %as_ptr = builtin.unrealized_conversion_cast %closure : !eco.value to !llvm.ptr<1>
    llvm.call @use_closure(%as_ptr) : (!llvm.ptr<1>) -> ()

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// Wrapper exists, returns i16 natively (suffix `_rc` = PK_Char).
// CHECK: define internal i16 @__closure_wrapper_typed_upper_char_rc
// CHECK: ret i16

// No boxing helper is invoked anywhere in the module.
// CHECK-NOT: @eco_alloc_int
// CHECK-NOT: @eco_alloc_float
// CHECK-NOT: @eco_alloc_char

// eco_intern_closure0 (HEAP_033) registers the wrapper; K = 3 (PK_Char) rides in the packed word (and the _rc suffix).
// CHECK: ptr @__closure_wrapper_typed_upper_char_rc, i32 1, i64
