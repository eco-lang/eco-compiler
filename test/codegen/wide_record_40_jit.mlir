// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Phase 3B (plans/wide-object-tail-kind-words-phase-3.md): a 40-field record with
// mixed kinds (i64, f64, i16, boxed) built by eco.construct.record, kept live across
// forced minor + major GCs, then projected. Slots >= 32 have their kinds in an
// extension kind word (HEAP_019); a wrong ext word makes the GC trace a raw value
// (crash under ECO_HEAP_VALIDATE) or lose a boxed one (stale value).

module {
  llvm.func @eco_minor_gc()
  llvm.func @eco_major_gc()

  func.func @main() -> i64 {
    %v0 = arith.constant 1000 : i64
    %v1 = arith.constant 1.5 : f64
    %v2 = arith.constant 67 : i16
    %r3 = arith.constant 2003 : i64
    %v3 = eco.box %r3 : i64 -> !eco.value
    %v4 = arith.constant 1004 : i64
    %v5 = arith.constant 5.5 : f64
    %v6 = arith.constant 71 : i16
    %r7 = arith.constant 2007 : i64
    %v7 = eco.box %r7 : i64 -> !eco.value
    %v8 = arith.constant 1008 : i64
    %v9 = arith.constant 9.5 : f64
    %v10 = arith.constant 75 : i16
    %r11 = arith.constant 2011 : i64
    %v11 = eco.box %r11 : i64 -> !eco.value
    %v12 = arith.constant 1012 : i64
    %v13 = arith.constant 13.5 : f64
    %v14 = arith.constant 79 : i16
    %r15 = arith.constant 2015 : i64
    %v15 = eco.box %r15 : i64 -> !eco.value
    %v16 = arith.constant 1016 : i64
    %v17 = arith.constant 17.5 : f64
    %v18 = arith.constant 83 : i16
    %r19 = arith.constant 2019 : i64
    %v19 = eco.box %r19 : i64 -> !eco.value
    %v20 = arith.constant 1020 : i64
    %v21 = arith.constant 21.5 : f64
    %v22 = arith.constant 87 : i16
    %r23 = arith.constant 2023 : i64
    %v23 = eco.box %r23 : i64 -> !eco.value
    %v24 = arith.constant 1024 : i64
    %v25 = arith.constant 25.5 : f64
    %v26 = arith.constant 65 : i16
    %r27 = arith.constant 2027 : i64
    %v27 = eco.box %r27 : i64 -> !eco.value
    %v28 = arith.constant 1028 : i64
    %v29 = arith.constant 29.5 : f64
    %v30 = arith.constant 69 : i16
    %r31 = arith.constant 2031 : i64
    %v31 = eco.box %r31 : i64 -> !eco.value
    %v32 = arith.constant 1032 : i64
    %v33 = arith.constant 33.5 : f64
    %v34 = arith.constant 73 : i16
    %r35 = arith.constant 2035 : i64
    %v35 = eco.box %r35 : i64 -> !eco.value
    %v36 = arith.constant 1036 : i64
    %v37 = arith.constant 37.5 : f64
    %v38 = arith.constant 77 : i16
    %r39 = arith.constant 2039 : i64
    %v39 = eco.box %r39 : i64 -> !eco.value
    %obj = eco.construct.record(%v0, %v1, %v2, %v3, %v4, %v5, %v6, %v7, %v8, %v9, %v10, %v11, %v12, %v13, %v14, %v15, %v16, %v17, %v18, %v19, %v20, %v21, %v22, %v23, %v24, %v25, %v26, %v27, %v28, %v29, %v30, %v31, %v32, %v33, %v34, %v35, %v36, %v37, %v38, %v39) {field_count = 40 : i64, slot_kinds = array<i8: 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0>} : (i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value, i64, f64, i16, !eco.value) -> !eco.value
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_minor_gc() : () -> ()
    llvm.call @eco_major_gc() : () -> ()
    %p0 = eco.project.record %obj[0] : !eco.value -> i64
    eco.dbg %p0 : i64
    %p1 = eco.project.record %obj[1] : !eco.value -> f64
    eco.dbg %p1 : f64
    %p2 = eco.project.record %obj[2] : !eco.value -> i16
    eco.dbg %p2 : i16
    %p3 = eco.project.record %obj[3] : !eco.value -> !eco.value
    %u3 = eco.unbox %p3 : !eco.value -> i64
    eco.dbg %u3 : i64
    %p31 = eco.project.record %obj[31] : !eco.value -> !eco.value
    %u31 = eco.unbox %p31 : !eco.value -> i64
    eco.dbg %u31 : i64
    %p32 = eco.project.record %obj[32] : !eco.value -> i64
    eco.dbg %p32 : i64
    %p33 = eco.project.record %obj[33] : !eco.value -> f64
    eco.dbg %p33 : f64
    %p34 = eco.project.record %obj[34] : !eco.value -> i16
    eco.dbg %p34 : i16
    %p35 = eco.project.record %obj[35] : !eco.value -> !eco.value
    %u35 = eco.unbox %p35 : !eco.value -> i64
    eco.dbg %u35 : i64
    %p38 = eco.project.record %obj[38] : !eco.value -> i16
    eco.dbg %p38 : i16
    %p39 = eco.project.record %obj[39] : !eco.value -> !eco.value
    %u39 = eco.unbox %p39 : !eco.value -> i64
    eco.dbg %u39 : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: 1000
// CHECK-NEXT: 1.5
// CHECK-NEXT: 'C'
// CHECK-NEXT: 2003
// CHECK-NEXT: 2031
// CHECK-NEXT: 1032
// CHECK-NEXT: 33.5
// CHECK-NEXT: 'I'
// CHECK-NEXT: 2035
// CHECK-NEXT: 'M'
// CHECK-NEXT: 2039
