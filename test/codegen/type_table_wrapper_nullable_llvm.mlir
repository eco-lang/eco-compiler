// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// eco.type_table lowering (EcoToLLVMGlobals.cpp) of the two kinds the representation passes add
// (plans/constructor-representation-levels.md E2, N1; null words: plans/constructor-representation-followups.md
// F2, HEAP_085):
//
// Entry 0 = [0, 7, 0, 1]: a Wrapper (an erased wrapper, MONO_031), laid out as a Custom: type_id 0,
//   kind 7, pad x3, first_ctor 0, ctor_count 1, four zero bytes.
// Entry 1 = [1, 8, 2, 3, 4, 1, 5]: a Nullable (REP_CONSTANT_003) whose null word is the null-cons word of
//   index 5: type_id 1, kind 8, pad x3, field_type_id 2, null_name 3 | (1 << 20) | (5 << 21) = 0x00B00003,
//   value_name 4.
// Entry 2 = [2, 8, 2, 3, 4, 0, 2]: a Nullable whose null word is the spare word of level 2: null_name
//   3 | (2 << 21) = 0x00400003.
//
// CHECK: @__eco_types_array = private constant [60 x i8] c"\00\00\00\00\07\00\00\00\00\00\00\00\01\00\00\00\00\00\00\00\01\00\00\00\08\00\00\00\02\00\00\00\03\00\B0\00\04\00\00\00\02\00\00\00\08\00\00\00\02\00\00\00\03\00@\00\04\00\00\00"

module {
  eco.type_table <{types = [[0, 7, 0, 1], [1, 8, 2, 3, 4, 1, 5], [2, 8, 2, 3, 4, 0, 2]], fields = [], ctors = [], func_args = [], strings = []}>
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
