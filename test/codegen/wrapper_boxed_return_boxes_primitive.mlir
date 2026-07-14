// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Phase D control: confirm the wrapper DOES box when `_result_kind`
// is omitted (defaults to 0 / PK_Boxed). This is the legacy path
// every C++-kernel callsite relies on. The wrapper for a function
// that returns f64 must call `@eco_alloc_float` and return `ptr`.
//
// This is the inverse of `wrapper_primitive_return_float.mlir` and
// guards against the static-IR tests passing trivially (e.g. if the
// wrapper were elided entirely or if `_result_kind` were silently
// ignored everywhere).

module {
  func.func @double_float_boxed(%x: f64) -> f64 {
    %c2 = arith.constant 2.0 : f64
    %result = arith.mulf %x, %c2 : f64
    return %result : f64
  }

  llvm.func @use_closure(!llvm.ptr<1>)

  func.func @main() -> i64 {
    // _result_kind omitted ⇒ default 0 ⇒ PK_Boxed wrapper.
    %closure = "eco.papCreate"() {
      function = @double_float_boxed,
      arity = 1 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    %as_ptr = builtin.unrealized_conversion_cast %closure : !eco.value to !llvm.ptr<1>
    llvm.call @use_closure(%as_ptr) : (!llvm.ptr<1>) -> ()

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// Wrapper exists, returns `ptr` (boxed HPtr; no `_rf`/`_ri`/`_rc`
// suffix because it's the PK_Boxed cache slot).
// CHECK: define internal ptr @__closure_wrapper_typed_double_float_boxed
// CHECK: ret ptr

// Wrapper DOES box the inner function's f64 result via eco_alloc_float
// (the legacy path C++-kernel callers depend on).
// CHECK: @eco_alloc_float

// eco_intern_closure0 (HEAP_033) registers the wrapper; K = 0 (PK_Boxed) rides in the packed word (and the _boxed suffix).
// CHECK: ptr @__closure_wrapper_typed_double_float_boxed, i32 1, i64
