// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=FWD
// RUN: env ECO_LIST_MAP_EXPAND=0 %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=COLLAPSE
//
// plans/list-map-mlir-template.md Phase 2 / CGEN_078(e)(f): the shape
// `EcoListTemplate` expands `eco.list.map` into, and the shape its kill switch
// collapses to.
//
// FORWARD (default). One mark, one push per element inside the loop, one
// `eco_scratch_finish_fwd` after it. `finish_fwd` — not `finish` — is what
// makes the result forward-ordered without the accumulate+reverse double pass
// the foldr lowering pays.
//
// COLLAPSE (`ECO_LIST_MAP_EXPAND=0`). A `List_reverse` call followed by a
// forward-cons walk. That reproduces foldr's certified right-to-left
// application order exactly, which is what makes the switch usable on a
// LICENSED artifact without re-litigating policy D-4a. The deliberate double
// materialization is acceptable in a bisection-only arm. (The cons loop the
// collapse emits is then itself picked up by this same pass's cons-accumulator
// rewriter, so scratch calls appear on BOTH arms — the discriminator is
// `List_reverse`, present only on the collapse, and `finish_fwd` vs `finish`.)
//
// `eco.list_chunks` on a function is what arms the whole pass (chunks-off
// output stays byte-identical), so it is set here.

module {
  func.func private @cb$cap(%cap: !eco.value, %x: !eco.value) -> !eco.value {
    eco.return %x : !eco.value
  }

  func.func @main(%xs: !eco.value, %f: !eco.value, %c: !eco.value) -> !eco.value attributes {eco.list_chunks} {
    %r = eco.list.map %xs, %f captures(%c : !eco.value) {callee = @cb$cap, in_kind = 0 : i64, out_kind = 0 : i64} : !eco.value
    eco.return %r : !eco.value
  }
}

// FWD: llvm.call @eco_scratch_mark
// FWD: llvm.call @eco_scratch_push_boxed
// FWD: llvm.call @eco_scratch_finish_fwd
// FWD-NOT: @Elm_Kernel_List_reverse

// COLLAPSE: llvm.call @Elm_Kernel_List_reverse
