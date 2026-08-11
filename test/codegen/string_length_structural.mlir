// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s --check-prefix=ECO
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=MARK
//
// kernel-opt-04: eco.string.length is an INLINE-IR op, not a kernel call.
//
// ECO leg: the op survives the eco-to-eco pipeline unchanged — nothing folds
// it away and nothing rewrites it into Elm_Kernel_String_length.
//
// MARK leg: the eco-to-LLVM lowering replaces it with the declare-only
// `__eco_string_len_inline` marker (default; ECO_STRING_LEN_INLINE=0 would
// emit a plain Elm_Kernel_String_length call instead). The marker is expanded
// into the embedded-constant / header-load diamond by expandStringLenMarkers
// in EcoBackend.cpp, which runs before expandInlineDerefs and before every
// RS4GC flavour, so it never reaches codegen. Behaviour of the expanded form
// is pinned by string_length_forms.mlir; this fixture pins the SHAPE.

module {
  func.func @main() -> i64 {
    %s = eco.string_literal "hello" : !eco.value

    // ECO: eco.string.length
    // ECO-NOT: Elm_Kernel_String_length
    %n = eco.string.length %s

    // MARK: __eco_string_len_inline
    // MARK-NOT: Elm_Kernel_String_length
    return %n : i64
  }
}
