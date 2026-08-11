// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=MARK
// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s --check-prefix=EXP
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// kernel-opt-03 Phase 2: eco.value.eq is groundwork. Nothing in the compiler
// emits it yet (Phase 3 emission is not landed — the Phase-0 census measured the
// inline arms at 6.47% of non-Bool traffic against a 25% bar), so this fixture is
// its ONLY exercise and the only thing pinning the expansion's shape.
//
// MARK leg: the dialect lowering produces the declare-only __eco_value_eq marker.
// The fast/slow diamond cannot be built there — the pattern runs inside the Stage 2
// conversion, which is also lowering scf, so block surgery on a still-converting
// region is unavailable. That is why this is a marker at all.
//
// EXP leg: expandValueEqFastPath has replaced the marker with the three-arm
// diamond and erased the declaration. Arm 1 is word equality (which never
// disagrees with the kernel: eqHelp's `if (a == b) return true` runs before the
// tag switch). Arm 2 is the ptr_ind bit test, exactly equalRespectingConstants.
// Arm 3 calls the kernel and decodes against the True word 0x5.
//
// JIT leg: executes all three arms end to end.

module {
  func.func @main() -> i64 {
    %s1 = eco.string_literal "hello" : !eco.value
    %s2 = eco.string_literal "hello" : !eco.value
    %s3 = eco.string_literal "world" : !eco.value
    %t = eco.constant True : !eco.value
    %f = eco.constant False : !eco.value

    // MARK: call{{.*}}@__eco_value_eq
    // MARK-NOT: eq.same
    //
    // EXP: eq.same
    // EXP: eq.anyconst
    // EXP: @Elm_Kernel_Utils_equal
    // EXP-NOT: @__eco_value_eq

    // Arm 1: the SAME ssa value on both sides is word-equal.
    %same = eco.value.eq %s1, %s1 : !eco.value
    %same64 = arith.extui %same : i1 to i64
    eco.dbg %same64 : i64
    // JIT: 1

    // Arm 2: an embedded constant on one side, a heap pointer on the other ->
    // false without dereferencing either.
    %mixed = eco.value.eq %s1, %t : !eco.value
    %mixed64 = arith.extui %mixed : i1 to i64
    eco.dbg %mixed64 : i64
    // JIT: 0

    // Arm 2 both sides: two DISTINCT embedded constants.
    %consts = eco.value.eq %t, %f : !eco.value
    %consts64 = arith.extui %consts : i1 to i64
    eco.dbg %consts64 : i64
    // JIT: 0

    // Arm 3: two distinct heap pointers with equal contents -> the kernel says
    // true. This is the arm that proves the 0x5 True-word decode.
    %eqc = eco.value.eq %s1, %s2 : !eco.value
    %eqc64 = arith.extui %eqc : i1 to i64
    eco.dbg %eqc64 : i64
    // JIT: 1

    // Arm 3, unequal contents.
    %nec = eco.value.eq %s1, %s3 : !eco.value
    %nec64 = arith.extui %nec : i1 to i64
    eco.dbg %nec64 : i64
    // JIT: 0

    %z = arith.constant 0 : i64
    return %z : i64
  }
}
