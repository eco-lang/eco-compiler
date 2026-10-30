// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=IR
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// A Char is one code point (KERN_008, plans/char-simple-case-mapping.md): eco.char.toInt is a
// plain zero extension, and eco.char.lt compares the code points unsigned, with no sort key.
// U+E000 < U+10000 holds here, where JS UTF-16 order would give the opposite. The arguments go
// through calls so nothing is constant-folded before lowering.

// IR-LABEL: llvm.func {{.*}}@code
// IR-NOT: 2097151
// IR: llvm.zext
// IR-NOT: 2097151
// IR-LABEL: llvm.func {{.*}}@less
// IR-NOT: llvm.intr.fsh
// IR-NOT: llvm.shl
// IR: llvm.icmp "ult"
// IR-NOT: llvm.intr.fsh
// IR-NOT: llvm.shl
// IR-LABEL: llvm.func {{.*}}@main
// IR-NOT: eco_char_case_expansion

module {
  func.func private @code(%c: i32) -> i64 {
    %r = eco.char.toInt %c : i32 -> i64
    eco.return %r : i64
  }

  func.func private @less(%a: i32, %b: i32) -> i64 {
    %lt = eco.char.lt %a, %b : i32
    %r = arith.extui %lt : i1 to i64
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    %va = arith.constant 97 : i32
    %vb = arith.constant 98 : i32
    %r0 = func.call @less(%va, %vb) : (i32, i32) -> i64
    %b0 = eco.box %r0 : i64 -> !eco.value
    eco.dbg %b0 : !eco.value
    // JIT: 1
    %vE000 = arith.constant 57344 : i32
    %v10000 = arith.constant 65536 : i32
    %r1 = func.call @less(%vE000, %v10000) : (i32, i32) -> i64
    %b1 = eco.box %r1 : i64 -> !eco.value
    eco.dbg %b1 : !eco.value
    // JIT: 1
    %vmax = arith.constant 1114111 : i32
    %r2 = func.call @code(%vmax) : (i32) -> i64
    %b2 = eco.box %r2 : i64 -> !eco.value
    eco.dbg %b2 : !eco.value
    // JIT: 1114111
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
