// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// SD-4: eco.construct.list has no verifier, and the lowering copies
// `head_kind` straight into the cons header's unboxed bits
// (EcoToLLVMHeap.cpp, ListConstructOpLowering: composeHeader(TagCons,
// headKind, ...)) while it stores the head by its SSA type (the comment there
// assumes "the head operand's type corresponds 1:1 with head_kind" but
// nothing checks it). Here the head is an !eco.value (kind 0) but
// head_kind = 1 (Int) and head_unboxed = true: the GC would never trace the
// boxed head, so a collection leaves a dangling pointer. The verifier must
// reject the op.

module {
  func.func @main() -> !eco.value {
    %nil = eco.constant Empty : !eco.value
    %i42 = arith.constant 42 : i64
    %h = eco.box %i42 : i64 -> !eco.value
    %l = eco.construct.list %h, %nil {head_unboxed = true, head_kind = 1} : !eco.value, !eco.value -> !eco.value
    eco.return %l : !eco.value
  }
}

// CHECK: error: 'eco.construct.list' op {{.*}}head_kind
