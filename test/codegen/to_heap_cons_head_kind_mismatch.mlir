// RUN: not %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Until 2026-10-30 ToHeapOp::verify (EcoOps.cpp) never checked a cons's head_kind / head_unboxed
// against the head's type (only ListConstructOp::verify did). The lowering (EcoToLLVMValueAgg.cpp) writes head_kind
// into the cons header but picks the stored word from the head type, so head_kind = 1 (Int) with a
// boxed head stores a heap pointer in a slot the header calls an unboxed Int: the GC never traces
// it, and the head object can be moved or freed under the list. The front end never sets head_kind
// on eco.to_heap (CGEN_025: eco.make.cons has no producer), so only hand-written MLIR reaches it.
//
// The verifier now rejects it, naming head_kind.
//
// CHECK: error: {{.*}}head_kind

module {
  func.func @bad(%h: !eco.value, %t: !eco.value) -> !eco.value {
    %c = eco.make.cons %h, %t
       : (!eco.value, !eco.value) -> !eco.cons<!eco.value, !eco.value>
    %r = eco.to_heap %c {head_kind = 1 : i64, head_unboxed = true}
       : (!eco.cons<!eco.value, !eco.value>) -> !eco.value
    return %r : !eco.value
  }
}
