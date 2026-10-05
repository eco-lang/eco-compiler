// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// B14 (plans/wide-object-tail-kind-words-phase-0.md): construct ops must reject i1
// operands. Today an i1 is stored as zext 0/1 into a kind-0 (boxed) slot, which the GC
// would trace as a pointer; the front end always boxes Bool first.

module {
  func.func @bad_construct_i1(%b: i1, %x: !eco.value) -> !eco.value {
    %c = "eco.construct.custom"(%b, %x) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (i1, !eco.value) -> !eco.value
    return %c : !eco.value
  }
}

// CHECK: has i1 type
