// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// REP_LLVM_002 STRIP pin (plans/fold-proof-boxed-slot-crossings.md): in the
// post-RS4GC LLVM IR dump, ZERO slot-cast barrier references survive
// (StripEcoCastBarriers rewrote every `__eco_slot_to_hptr` /
// `__eco_hptr_to_slot` call back to a bare cast and erased the decls — a
// survivor is additionally a report_fatal_error at compile time), and the
// restored inttoptr is present. Companion fixture
// slot_cast_barriers_emit.mlir pins the EMISSION side (pre-RS4GC barriers).
//
// CHECK-NOT: __eco_slot_to_hptr
// CHECK-NOT: __eco_hptr_to_slot
// CHECK: inttoptr

module {
  // Projections live behind a function boundary so kernel-opt-10's
  // project-of-construct folder (default-on) cannot fold them away — the
  // container arrives as a block argument, getDefiningOp is null, the fold
  // bails, and the barriered slot crossings this fixture pins are emitted.
  func.func private @readBoth(%pair: !eco.value) -> i64 {
    %first = eco.project.custom %pair[0] : !eco.value -> !eco.value
    eco.dbg %first : !eco.value

    %second = eco.project.custom %pair[1] : !eco.value -> !eco.value
    eco.dbg %second : !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }

  func.func @main() -> i64 {
    // Two boxed fields in a custom; the projections back out are
    // i64 -> ptr<1> boxed-slot crossings (barriered, then stripped).
    %i1 = arith.constant 41 : i64
    %i2 = arith.constant 1 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %pair = eco.construct.custom(%b1, %b2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %r = func.call @readBoth(%pair) : (!eco.value) -> i64
    return %r : i64
  }
}
