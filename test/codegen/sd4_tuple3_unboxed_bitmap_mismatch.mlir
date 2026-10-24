// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// SD-4: eco.construct.tuple3 has no verifier, and the lowering copies
// `unboxed_bitmap` straight into the heap header (EcoToLLVMHeap.cpp,
// Tuple3ConstructOpLowering) while it stores each field by its SSA type.
// CGEN_026 / CGEN_003: the bitmap must equal the kinds of the operand MLIR
// types (2 bits per slot). Operands are (!eco.value, f64, i16), so the correct
// bitmap is 0 | 2<<2 | 3<<4 = 56; the op says 0 (all boxed), so the GC would
// trace the raw f64 and i16 bits as pointers. The verifier must reject it.

module {
  func.func @main() -> !eco.value {
    %a = eco.constant Empty : !eco.value
    %b = arith.constant 2.5 : f64
    %c = arith.constant 65 : i16
    %t = eco.construct.tuple3 %a, %b, %c {unboxed_bitmap = 0} : !eco.value, f64, i16 -> !eco.value
    eco.return %t : !eco.value
  }
}

// CHECK: error: 'eco.construct.tuple3' op {{.*}}unboxed_bitmap
