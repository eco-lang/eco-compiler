// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=IR
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// eco.hash of an Int, Float, Char or Bool is computed inline (plans/seq-data-structures-performance.md
// D1) and must equal the runtime walker's hash of the same value boxed (eco.hash of kind "value",
// which calls eco_hash_value): each case prints 1 when the two agree. The inline cases call nothing:
// no runtime entry for a primitive (eco_hash_i64, _f64, _char) appears in the lowered module.
// The values go through a call so nothing folds before lowering.

// IR-NOT: eco_hash_i64
// IR-NOT: eco_hash_f64
// IR-NOT: eco_hash_char
// IR: llvm.func {{.*}}@inline_int

module {
  func.func private @inline_int(%x: i64) -> i64 {
    %h = eco.hash %x <{kind = "int"}> : i64 -> i64
    eco.return %h : i64
  }

  func.func @main() -> i64 {
    %v0 = arith.constant 0 : i64
    %a0 = func.call @inline_int(%v0) : (i64) -> i64
    %bx0 = eco.box %v0 : i64 -> !eco.value
    %b0 = eco.hash %bx0 <{kind = "value"}> : !eco.value -> i64
    %e0 = arith.cmpi eq, %a0, %b0 : i64
    %z0 = arith.extui %e0 : i1 to i64
    %p0 = eco.box %z0 : i64 -> !eco.value
    eco.dbg %p0 : !eco.value
    // JIT: 1
    %v1 = arith.constant 1 : i64
    %a1 = func.call @inline_int(%v1) : (i64) -> i64
    %bx1 = eco.box %v1 : i64 -> !eco.value
    %b1 = eco.hash %bx1 <{kind = "value"}> : !eco.value -> i64
    %e1 = arith.cmpi eq, %a1, %b1 : i64
    %z1 = arith.extui %e1 : i1 to i64
    %p1 = eco.box %z1 : i64 -> !eco.value
    eco.dbg %p1 : !eco.value
    // JIT: 1
    %v2 = arith.constant -1 : i64
    %a2 = func.call @inline_int(%v2) : (i64) -> i64
    %bx2 = eco.box %v2 : i64 -> !eco.value
    %b2 = eco.hash %bx2 <{kind = "value"}> : !eco.value -> i64
    %e2 = arith.cmpi eq, %a2, %b2 : i64
    %z2 = arith.extui %e2 : i1 to i64
    %p2 = eco.box %z2 : i64 -> !eco.value
    eco.dbg %p2 : !eco.value
    // JIT: 1
    %v3 = arith.constant 9223372036854775807 : i64
    %a3 = func.call @inline_int(%v3) : (i64) -> i64
    %bx3 = eco.box %v3 : i64 -> !eco.value
    %b3 = eco.hash %bx3 <{kind = "value"}> : !eco.value -> i64
    %e3 = arith.cmpi eq, %a3, %b3 : i64
    %z3 = arith.extui %e3 : i1 to i64
    %p3 = eco.box %z3 : i64 -> !eco.value
    eco.dbg %p3 : !eco.value
    // JIT: 1
    %v4 = arith.constant -9223372036854775808 : i64
    %a4 = func.call @inline_int(%v4) : (i64) -> i64
    %bx4 = eco.box %v4 : i64 -> !eco.value
    %b4 = eco.hash %bx4 <{kind = "value"}> : !eco.value -> i64
    %e4 = arith.cmpi eq, %a4, %b4 : i64
    %z4 = arith.extui %e4 : i1 to i64
    %p4 = eco.box %z4 : i64 -> !eco.value
    eco.dbg %p4 : !eco.value
    // JIT: 1
    %v5 = arith.constant 123456789 : i64
    %a5 = func.call @inline_int(%v5) : (i64) -> i64
    %bx5 = eco.box %v5 : i64 -> !eco.value
    %b5 = eco.hash %bx5 <{kind = "value"}> : !eco.value -> i64
    %e5 = arith.cmpi eq, %a5, %b5 : i64
    %z5 = arith.extui %e5 : i1 to i64
    %p5 = eco.box %z5 : i64 -> !eco.value
    eco.dbg %p5 : !eco.value
    // JIT: 1
    %v6 = arith.constant 0.0 : f64
    %a6 = eco.hash %v6 <{kind = "float"}> : f64 -> i64
    %bx6 = eco.box %v6 : f64 -> !eco.value
    %b6 = eco.hash %bx6 <{kind = "value"}> : !eco.value -> i64
    %e6 = arith.cmpi eq, %a6, %b6 : i64
    %z6 = arith.extui %e6 : i1 to i64
    %p6 = eco.box %z6 : i64 -> !eco.value
    eco.dbg %p6 : !eco.value
    // JIT: 1
    %v7 = arith.constant -0.0 : f64
    %a7 = eco.hash %v7 <{kind = "float"}> : f64 -> i64
    %bx7 = eco.box %v7 : f64 -> !eco.value
    %b7 = eco.hash %bx7 <{kind = "value"}> : !eco.value -> i64
    %e7 = arith.cmpi eq, %a7, %b7 : i64
    %z7 = arith.extui %e7 : i1 to i64
    %p7 = eco.box %z7 : i64 -> !eco.value
    eco.dbg %p7 : !eco.value
    // JIT: 1
    %v8 = arith.constant 1.5 : f64
    %a8 = eco.hash %v8 <{kind = "float"}> : f64 -> i64
    %bx8 = eco.box %v8 : f64 -> !eco.value
    %b8 = eco.hash %bx8 <{kind = "value"}> : !eco.value -> i64
    %e8 = arith.cmpi eq, %a8, %b8 : i64
    %z8 = arith.extui %e8 : i1 to i64
    %p8 = eco.box %z8 : i64 -> !eco.value
    eco.dbg %p8 : !eco.value
    // JIT: 1
    %v9 = arith.constant 0x7FF8000000000000 : f64
    %a9 = eco.hash %v9 <{kind = "float"}> : f64 -> i64
    %bx9 = eco.box %v9 : f64 -> !eco.value
    %b9 = eco.hash %bx9 <{kind = "value"}> : !eco.value -> i64
    %e9 = arith.cmpi eq, %a9, %b9 : i64
    %z9 = arith.extui %e9 : i1 to i64
    %p9 = eco.box %z9 : i64 -> !eco.value
    eco.dbg %p9 : !eco.value
    // JIT: 1
    %v10 = arith.constant 0x7FF0000000000000 : f64
    %a10 = eco.hash %v10 <{kind = "float"}> : f64 -> i64
    %bx10 = eco.box %v10 : f64 -> !eco.value
    %b10 = eco.hash %bx10 <{kind = "value"}> : !eco.value -> i64
    %e10 = arith.cmpi eq, %a10, %b10 : i64
    %z10 = arith.extui %e10 : i1 to i64
    %p10 = eco.box %z10 : i64 -> !eco.value
    eco.dbg %p10 : !eco.value
    // JIT: 1
    %v11 = arith.constant -2.25e300 : f64
    %a11 = eco.hash %v11 <{kind = "float"}> : f64 -> i64
    %bx11 = eco.box %v11 : f64 -> !eco.value
    %b11 = eco.hash %bx11 <{kind = "value"}> : !eco.value -> i64
    %e11 = arith.cmpi eq, %a11, %b11 : i64
    %z11 = arith.extui %e11 : i1 to i64
    %p11 = eco.box %z11 : i64 -> !eco.value
    eco.dbg %p11 : !eco.value
    // JIT: 1
    %v12 = arith.constant 0 : i32
    %a12 = eco.hash %v12 <{kind = "char"}> : i32 -> i64
    %bx12 = eco.box %v12 : i32 -> !eco.value
    %b12 = eco.hash %bx12 <{kind = "value"}> : !eco.value -> i64
    %e12 = arith.cmpi eq, %a12, %b12 : i64
    %z12 = arith.extui %e12 : i1 to i64
    %p12 = eco.box %z12 : i64 -> !eco.value
    eco.dbg %p12 : !eco.value
    // JIT: 1
    %v13 = arith.constant 65 : i32
    %a13 = eco.hash %v13 <{kind = "char"}> : i32 -> i64
    %bx13 = eco.box %v13 : i32 -> !eco.value
    %b13 = eco.hash %bx13 <{kind = "value"}> : !eco.value -> i64
    %e13 = arith.cmpi eq, %a13, %b13 : i64
    %z13 = arith.extui %e13 : i1 to i64
    %p13 = eco.box %z13 : i64 -> !eco.value
    eco.dbg %p13 : !eco.value
    // JIT: 1
    %v14 = arith.constant 1114111 : i32
    %a14 = eco.hash %v14 <{kind = "char"}> : i32 -> i64
    %bx14 = eco.box %v14 : i32 -> !eco.value
    %b14 = eco.hash %bx14 <{kind = "value"}> : !eco.value -> i64
    %e14 = arith.cmpi eq, %a14, %b14 : i64
    %z14 = arith.extui %e14 : i1 to i64
    %p14 = eco.box %z14 : i64 -> !eco.value
    eco.dbg %p14 : !eco.value
    // JIT: 1
    %v15 = arith.constant true
    %a15 = eco.hash %v15 <{kind = "bool"}> : i1 -> i64
    %bx15 = eco.box %v15 : i1 -> !eco.value
    %b15 = eco.hash %bx15 <{kind = "value"}> : !eco.value -> i64
    %e15 = arith.cmpi eq, %a15, %b15 : i64
    %z15 = arith.extui %e15 : i1 to i64
    %p15 = eco.box %z15 : i64 -> !eco.value
    eco.dbg %p15 : !eco.value
    // JIT: 1
    %v16 = arith.constant false
    %a16 = eco.hash %v16 <{kind = "bool"}> : i1 -> i64
    %bx16 = eco.box %v16 : i1 -> !eco.value
    %b16 = eco.hash %bx16 <{kind = "value"}> : !eco.value -> i64
    %e16 = arith.cmpi eq, %a16, %b16 : i64
    %z16 = arith.extui %e16 : i1 to i64
    %p16 = eco.box %z16 : i64 -> !eco.value
    eco.dbg %p16 : !eco.value
    // JIT: 1
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
