// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.project for extracting fields from multi-field constructors.

module {
  func.func @main() -> i64 {
    // Create a 4-field constructor with values [100, 200, 300, 400]
    %i100 = arith.constant 100 : i64
    %i200 = arith.constant 200 : i64
    %i300 = arith.constant 300 : i64
    %i400 = arith.constant 400 : i64
    %b100 = eco.box %i100 : i64 -> !eco.value
    %b200 = eco.box %i200 : i64 -> !eco.value
    %b300 = eco.box %i300 : i64 -> !eco.value
    %b400 = eco.box %i400 : i64 -> !eco.value

    %obj = eco.construct.custom(%b100, %b200, %b300, %b400) {tag = 7 : i64, size = 4 : i64} : (!eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %obj : !eco.value
    // CHECK: Ctor7 100 200 300 400

    // Project field 0
    %f0 = eco.project.custom %obj[0] : !eco.value -> !eco.value
    eco.dbg %f0 : !eco.value
    // CHECK: 100

    // Project field 1
    %f1 = eco.project.custom %obj[1] : !eco.value -> !eco.value
    eco.dbg %f1 : !eco.value
    // CHECK: 200

    // Project field 2
    %f2 = eco.project.custom %obj[2] : !eco.value -> !eco.value
    eco.dbg %f2 : !eco.value
    // CHECK: 300

    // Project field 3
    %f3 = eco.project.custom %obj[3] : !eco.value -> !eco.value
    eco.dbg %f3 : !eco.value
    // CHECK: 400

    // Create single-field constructor and project
    %single = eco.construct.custom(%b100) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %single : !eco.value
    // CHECK: Ctor1 100

    %single_f0 = eco.project.custom %single[0] : !eco.value -> !eco.value
    eco.dbg %single_f0 : !eco.value
    // CHECK: 100

    // Create constructor with mixed types (all boxed for now)
    %fpi = arith.constant 3.14 : f64
    %ch = arith.constant 65 : i16  // 'A'
    %bpi = eco.box %fpi : f64 -> !eco.value
    %bch = eco.box %ch : i16 -> !eco.value

    %mixed = eco.construct.custom(%b100, %bpi, %bch) {tag = 2 : i64, size = 3 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: Ctor2 100 3.14 'A'

    %mixed_f1 = eco.project.custom %mixed[1] : !eco.value -> !eco.value
    eco.dbg %mixed_f1 : !eco.value
    // CHECK: 3.14

    %mixed_f2 = eco.project.custom %mixed[2] : !eco.value -> !eco.value
    eco.dbg %mixed_f2 : !eco.value
    // CHECK: 'A'

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
