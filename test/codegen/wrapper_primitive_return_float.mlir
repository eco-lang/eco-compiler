// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Phase D static-IR enforcement: a papCreate annotated with
// `_result_kind = 2` (PK_Float) must lower to a wrapper whose LLVM
// return type is `double` and whose body forwards the inner
// function's raw `double` result without going through
// `eco_alloc_float`. The boxing site has moved to the caller.

module {
  func.func @double_float(%x: f64) -> f64 {
    %c2 = arith.constant 2.0 : f64
    %result = arith.mulf %x, %c2 : f64
    return %result : f64
  }

  llvm.func @use_closure(!llvm.ptr<1>)

  func.func @main() -> i64 {
    %closure = "eco.papCreate"() {
      function = @double_float,
      arity = 1 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64,
      _result_kind = 2 : i8
    } : () -> !eco.value

    %as_ptr = builtin.unrealized_conversion_cast %closure : !eco.value to !llvm.ptr<1>
    llvm.call @use_closure(%as_ptr) : (!llvm.ptr<1>) -> ()

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// Wrapper exists, returns double natively (suffix `_rf` = PK_Float).
// CHECK: define internal double @__closure_wrapper_typed_double_float_rf
// CHECK: ret double

// No boxing helper is invoked anywhere in the module.
// CHECK-NOT: @eco_alloc_int
// CHECK-NOT: @eco_alloc_float
// CHECK-NOT: @eco_alloc_char

// eco_intern_closure0 (HEAP_033) registers the wrapper; K = 2 (PK_Float) rides in the packed word (and the _rf suffix).
// CHECK: ptr @__closure_wrapper_typed_double_float_rf, i32 1, i64
