// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// REP_LLVM_002 EMISSION pin (plans/fold-proof-boxed-slot-crossings.md):
// boxed-slot i64 <-> ptr addrspace(1) crossings are emitted as calls to the
// declare-only gc-leaf barrier `__eco_slot_to_hptr` (NOT a bare
// llvm.inttoptr), so the pre-RS4GC AlwaysInliner ($cap inline prepass)
// cannot annihilate the tracked ptr<1> hop via
// `ptrtoint(inttoptr(x)) -> x` across an inlining seam. The gc-leaf attr is
// load-bearing: RS4GC must not statepoint the barrier, and
// bodyIsGCCallFree must keep classifying barriered bodies as GC-call-free.
// Companion fixture slot_cast_barriers_strip.mlir pins the post-RS4GC strip.
//
// NOTE: this pins the SHIPPING configuration (barriers default-on). Under
// ECO_SLOT_CAST_BARRIERS=0 the emission reverts to bare casts and this
// fixture would fail — intentional.
//
// CHECK: @__eco_slot_to_hptr(i64) -> !llvm.ptr<1> attributes {passthrough = ["gc-leaf-function"]}
// CHECK: llvm.call @__eco_slot_to_hptr({{.*}}) : (i64) -> !llvm.ptr<1>

module {
  func.func @main() -> i64 {
    %i1 = arith.constant 41 : i64
    %i2 = arith.constant 1 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %pair = eco.construct.custom(%b1, %b2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Boxed projection: load i64 slot word -> __eco_slot_to_hptr -> ptr<1>.
    %first = eco.project.custom %pair[0] : !eco.value -> !eco.value
    eco.dbg %first : !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
