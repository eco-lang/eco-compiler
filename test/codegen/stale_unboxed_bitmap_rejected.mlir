// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 3D (plans/wide-object-tail-kind-words-phase-3.md 3D.5, 3D-D3): the u64 kind
// bitmaps left the construct/closure op definitions; a leftover one (a stale pre-3C
// .mlir, or a missed fixture) is rejected instead of being carried silently as an
// unregistered discardable attribute.

module {
  func.func @stale(%i: i64) -> !eco.value {
    %c = eco.construct.custom(%i) {tag = 0 : i64, size = 1 : i64, slot_kinds = array<i8: 1>, unboxed_bitmap = 1 : i64} : (i64) -> !eco.value
    return %c : !eco.value
  }
}

// CHECK: stale attribute 'unboxed_bitmap'
