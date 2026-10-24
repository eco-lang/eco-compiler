// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// SD-4: eco.construct.tuple2 has no verifier, and the lowering copies
// `unboxed_bitmap` straight into the heap header (EcoToLLVMHeap.cpp,
// Tuple2ConstructOpLowering: composeHeader(TagTuple2, unboxedMask & 0xF, ...))
// while it stores each field by its SSA type. CGEN_026 / CGEN_003: the bitmap
// must equal the kinds of the operand MLIR types (2 bits per slot: 0 boxed,
// 1 Int, 2 Float, 3 Char). Here slot 0 is an i64 (kind 1) and slot 1 an
// !eco.value (kind 0), so the correct bitmap is 1; the op says 4 (slot 0
// boxed, slot 1 Int). The GC would trace the raw 42 as a pointer and skip the
// real pointer in slot 1. The verifier must reject the op.

module {
  func.func @main() -> !eco.value {
    %a = arith.constant 42 : i64
    %b = eco.constant Empty : !eco.value
    %t = eco.construct.tuple2 %a, %b {unboxed_bitmap = 4} : i64, !eco.value -> !eco.value
    eco.return %t : !eco.value
  }
}

// CHECK: error: 'eco.construct.tuple2' op {{.*}}unboxed_bitmap
