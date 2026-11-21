// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// The F1 tagged-word ops (plans/constructor-representation-followups.md F1.2, CGEN_091-093, HEAP_086):
// eco.tag_word makes a pointer derived from a heap word with a constructor index in bits 43-52,
// eco.word_tag reads the index back and eco.untag clears it. Tagged words held in SSA values live across
// two minor collections, which move their objects: the statepoint machinery relocates them and the
// collectors keep their tags (F1.1), so afterwards each still names its (moved) object with its index.
//
//   %bare: a record { 41 } tagged 5 (a `Bare` constructor over a record field);
//   %boxed: a Custom with field 7, tagged 3 (a `Boxed` constructor);
//   %zero: tag 0 is the word itself.

module {
  llvm.func @eco_minor_gc()

  func.func @main() -> i64 {
    %i41 = arith.constant 41 : i64
    %rec = "eco.construct.record"(%i41) {field_count = 1 : i64, slot_kinds = array<i8: 1>} : (i64) -> !eco.value
    %bare = eco.tag_word %rec [5] : !eco.value -> !eco.value

    %i7 = arith.constant 7 : i64
    %cus = eco.construct.custom(%i7) <{slot_kinds = array<i8: 1>, tag = 3 : i64, size = 1 : i64}> : (i64) -> !eco.value
    %boxed = eco.tag_word %cus [3] : !eco.value -> !eco.value
    %zero = eco.tag_word %cus [0] : !eco.value -> !eco.value

    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_minor_gc() : () -> ()

    %t1 = eco.word_tag %bare : !eco.value -> i64
    eco.dbg %t1 : i64
    // CHECK: [eco.dbg] 5
    %r = eco.untag %bare : !eco.value -> !eco.value
    %f = eco.project.record %r[0] : !eco.value -> i64
    eco.dbg %f : i64
    // CHECK: [eco.dbg] 41

    %t2 = eco.word_tag %boxed : !eco.value -> i64
    eco.dbg %t2 : i64
    // CHECK: [eco.dbg] 3
    %c = eco.untag %boxed : !eco.value -> !eco.value
    %g = eco.project.custom %c[0] : !eco.value -> i64
    eco.dbg %g : i64
    // CHECK: [eco.dbg] 7

    %t0 = eco.word_tag %zero : !eco.value -> i64
    eco.dbg %t0 : i64
    // CHECK: [eco.dbg] 0

    %z = arith.constant 0 : i64
    return %z : i64
  }
}
