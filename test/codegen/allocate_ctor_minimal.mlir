// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_ctor with minimal sizes, and the null-cons form for
// nullary ctors (HEAP_044/CGEN_079: eco.allocate_ctor with size = 0 &&
// scalar_bytes = 0 is a verifier error — nullary constructors are embedded
// null-cons constants).

module {
  func.func @main() -> i64 {
    // Nullary (unit-like): embedded null-cons constant, not an allocation.
    // The type-erased dbg fallback prints the embedded ctor index.
    %unit = eco.constant.null_cons 0 : !eco.value
    eco.dbg %unit : !eco.value
    // CHECK: <ctor 0>

    // Allocate with 0 fields but some scalar_bytes
    %scalar_only = eco.allocate_ctor {tag = 1 : i64, size = 0 : i64, scalar_bytes = 8 : i64} : !eco.value
    eco.dbg %scalar_only : !eco.value
    // CHECK: Ctor1

    // Allocate with 1 field, 0 scalar_bytes
    %one_field = eco.allocate_ctor {tag = 2 : i64, size = 1 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %one_field : !eco.value
    // CHECK: Ctor2

    // Different tags for the same (nullary) structure — distinct constants.
    %tag_10 = eco.constant.null_cons 10 : !eco.value
    eco.dbg %tag_10 : !eco.value
    // CHECK: <ctor 10>

    %tag_100 = eco.constant.null_cons 100 : !eco.value
    eco.dbg %tag_100 : !eco.value
    // CHECK: <ctor 100>

    // Capacity edge: the full 10-bit range is usable.
    %tag_max = eco.constant.null_cons 1023 : !eco.value
    eco.dbg %tag_max : !eco.value
    // CHECK: <ctor 1023>

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
