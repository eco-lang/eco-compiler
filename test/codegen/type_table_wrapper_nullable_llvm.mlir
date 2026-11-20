// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// eco.type_table lowering (EcoToLLVMGlobals.cpp) of the two kinds the representation passes add
// (plans/constructor-representation-levels.md E2, N1):
//
// Entry 0 = [0, 7, 0, 1]: a Wrapper (an erased wrapper, MONO_031), laid out as a Custom: type_id 0,
//   kind 7, pad x3, first_ctor 0, ctor_count 1, four zero bytes.
// Entry 1 = [1, 8, 2, 3, 4, 1]: a Nullable (REP_CONSTANT_003): type_id 1, kind 8, pad x3,
//   field_type_id 2, null_name 3 with the constant-bit flag in bit 31 (0x80000003), value_name 4.
//
// CHECK: @__eco_types_array = private constant [40 x i8] c"\00\00\00\00\07\00\00\00\00\00\00\00\01\00\00\00\00\00\00\00\01\00\00\00\08\00\00\00\02\00\00\00\03\00\00\80\04\00\00\00"

module {
  eco.type_table <{types = [[0, 7, 0, 1], [1, 8, 2, 3, 4, 1]], fields = [], ctors = [], func_args = [], strings = []}>
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
