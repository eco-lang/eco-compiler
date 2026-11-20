// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// The typed printer (print_typed_value, RuntimeExports.cpp) on the type kinds of the representation
// passes (plans/constructor-representation-levels.md E2, E2b, N1):
//
//   type 0: Float;  type 1: Wrapper `Q` over type 0 (an erased `type Q = Q Float`, MONO_031);
//   type 2: String; type 3: Nullable `Maybe String` (Nothing = Empty, Just x = x, REP_CONSTANT_003);
//   type 4: List of type 1.
//
// A wrapper prints its constructor and then the value as its field, whether the value is a boxed
// word or an unboxed list head (E2b); a nullable prints `Nothing` for Empty and `Just` and the value
// for anything else.

module {
  eco.type_table <{types = [[0, 0, 1], [1, 7, 0, 1], [2, 0, 4], [3, 8, 2, 2, 3, 0], [4, 1, 1]],
                   fields = [[1, 0]],
                   ctors = [[0, 0, 0, 1]],
                   func_args = [],
                   strings = ["Q", "field0", "Nothing", "Just"]}>
  func.func @main() -> i64 {
    %f = arith.constant 1.5 : f64
    %bf = eco.box %f : f64 -> !eco.value
    "eco.dbg"(%bf) {arg_type_ids = array<i64: 1>} : (!eco.value) -> ()
    // CHECK: Q 1.5

    %empty = eco.constant Empty : !eco.value
    "eco.dbg"(%empty) {arg_type_ids = array<i64: 3>} : (!eco.value) -> ()
    // CHECK: Nothing
    %s = eco.string_literal "x" : !eco.value
    "eco.dbg"(%s) {arg_type_ids = array<i64: 3>} : (!eco.value) -> ()
    // CHECK: Just "x"

    %g = arith.constant 2.5 : f64
    %l = eco.construct.list %g, %empty <{head_unboxed = true, head_kind = 2}> : f64, !eco.value -> !eco.value
    "eco.dbg"(%l) {arg_type_ids = array<i64: 4>} : (!eco.value) -> ()
    // CHECK: [Q 2.5]
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
