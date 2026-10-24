// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// SD-25: eco.type_table lowering (TypeTableOpLowering, EcoToLLVMGlobals.cpp)
// must write the constraint byte of a kind-6 (Polymorphic) entry. The runtime
// reads it as EcoTypeInfo.data.polymorphic.constraint (TypeInfo.hpp, data[0]
// = byte 8 of the 20-byte entry; RuntimeExports.cpp print_typed_value's list
// arm compares it against EcoConstraintKind::Number). The front end emits
// [typeId, 6, constraint] with 0 = number, 1 = eco_value (TypeTable.elm
// addPolymorphicType). The lowering has no `case 6`, so the data union stays
// zeroed and every Polymorphic entry reads back as Number (0), i.e. an
// unconstrained (eco_value) type variable is mis-encoded as `number`.
//
// Entry 0 = [0, 6, 1] (eco_value): type_id 0, kind 6, pad x3, constraint 1.
// Entry 1 = [1, 6, 0] (number):    type_id 1, kind 6, pad x3, constraint 0.
//
// CHECK: @__eco_types_array = private constant [40 x i8] c"\00\00\00\00\06\00\00\00\01\00\00\00\00\00\00\00\00\00\00\00\01\00\00\00\06\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00"

module {
  eco.type_table {types = [[0, 6, 1], [1, 6, 0]], fields = [], ctors = [], func_args = [], strings = []}
  func.func @main() -> i64 {
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
