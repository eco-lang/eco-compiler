// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.dbg on all possible value kinds, including unboxed primitives.

module {
  func.func @main() -> i64 {
    // === Embedded Constants ===

    %nil = eco.constant Nil : !eco.value
    eco.dbg %nil : !eco.value
    // CHECK: []

    %true = eco.constant True : !eco.value
    eco.dbg %true : !eco.value
    // CHECK: True

    %false = eco.constant False : !eco.value
    eco.dbg %false : !eco.value
    // CHECK: False

    %unit = eco.constant Unit : !eco.value
    eco.dbg %unit : !eco.value
    // CHECK: ()

    %nothing = eco.constant Nothing : !eco.value
    eco.dbg %nothing : !eco.value
    // CHECK: Nothing

    %empty = eco.constant EmptyString : !eco.value
    eco.dbg %empty : !eco.value
    // CHECK: ""

    %empty_rec = eco.constant EmptyRec : !eco.value
    eco.dbg %empty_rec : !eco.value
    // CHECK: {}

    // === Unboxed Integers (i64) ===

    %ui0 = arith.constant 0 : i64
    eco.dbg %ui0 : i64
    // CHECK: 0

    %ui42 = arith.constant 42 : i64
    eco.dbg %ui42 : i64
    // CHECK: 42

    %uineg = arith.constant -999 : i64
    eco.dbg %uineg : i64
    // CHECK: -999

    %uilarge = arith.constant 1000000 : i64
    eco.dbg %uilarge : i64
    // CHECK: 1000000

    // === Unboxed Floats (f64) ===

    %uf0 = arith.constant 0.0 : f64
    eco.dbg %uf0 : f64
    // CHECK: 0

    %ufpi = arith.constant 3.14159 : f64
    eco.dbg %ufpi : f64
    // CHECK: 3.14159

    %ufneg = arith.constant -2.718 : f64
    eco.dbg %ufneg : f64
    // CHECK: -2.718

    %ufsci = arith.constant 1.5e10 : f64
    eco.dbg %ufsci : f64
    // CHECK: 1.5e

    // === Unboxed Characters (i16) ===

    %ucA = arith.constant 65 : i16
    eco.dbg %ucA : i16
    // CHECK: 'A'

    %uc0 = arith.constant 48 : i16
    eco.dbg %uc0 : i16
    // CHECK: '0'

    %ucnl = arith.constant 10 : i16
    eco.dbg %ucnl : i16
    // CHECK: '\n'

    %ucspace = arith.constant 32 : i16
    eco.dbg %ucspace : i16
    // CHECK: ' '

    %uclambda = arith.constant 955 : i16
    eco.dbg %uclambda : i16
    // CHECK: '

    // === Boxed Integers ===

    %i0 = arith.constant 0 : i64
    %b0 = eco.box %i0 : i64 -> !eco.value
    eco.dbg %b0 : !eco.value
    // CHECK: 0

    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    eco.dbg %b42 : !eco.value
    // CHECK: 42

    %ineg = arith.constant -123 : i64
    %bneg = eco.box %ineg : i64 -> !eco.value
    eco.dbg %bneg : !eco.value
    // CHECK: -123

    // === Boxed Floats ===

    %f0 = arith.constant 0.0 : f64
    %bf0 = eco.box %f0 : f64 -> !eco.value
    eco.dbg %bf0 : !eco.value
    // CHECK: 0

    %fpi = arith.constant 3.14159 : f64
    %bpi = eco.box %fpi : f64 -> !eco.value
    eco.dbg %bpi : !eco.value
    // CHECK: 3.14159

    %fneg = arith.constant -2.5 : f64
    %bfneg = eco.box %fneg : f64 -> !eco.value
    eco.dbg %bfneg : !eco.value
    // CHECK: -2.5

    // === Boxed Characters ===

    %cA = arith.constant 65 : i16
    %bA = eco.box %cA : i16 -> !eco.value
    eco.dbg %bA : !eco.value
    // CHECK: 'A'

    %c0 = arith.constant 48 : i16
    %b_zero = eco.box %c0 : i16 -> !eco.value
    eco.dbg %b_zero : !eco.value
    // CHECK: '0'

    %cnl = arith.constant 10 : i16
    %bnl = eco.box %cnl : i16 -> !eco.value
    eco.dbg %bnl : !eco.value
    // CHECK: '\n'

    // === Strings ===

    %str1 = eco.string_literal "hello" : !eco.value
    eco.dbg %str1 : !eco.value
    // CHECK: "hello"

    %str2 = eco.string_literal "" : !eco.value
    eco.dbg %str2 : !eco.value
    // CHECK: ""

    // === Lists (Cons cells) ===
    // Boxed values, so unboxed_bitmap = 0
    %l1 = eco.construct.custom(%b42, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %l1 : !eco.value
    // CHECK: [42]

    %l2 = eco.construct.custom(%b0, %l1) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %l2 : !eco.value
    // CHECK: [0, 42]

    // === Custom Constructors ===

    // Single field
    %ctor1 = eco.construct.custom(%b42) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %ctor1 : !eco.value
    // CHECK: Ctor0 42

    // Multiple fields
    %ctor2 = eco.construct.custom(%b42, %bpi, %bA) {tag = 5 : i64, size = 3 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %ctor2 : !eco.value
    // CHECK: Ctor5 42 3.14159 'A'

    // Nested constructor
    %nested = eco.construct.custom(%ctor1) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %nested : !eco.value
    // CHECK: Ctor1 (Ctor0 42)

    // === Allocated Objects ===

    %alloc_ctor = eco.allocate_ctor {tag = 99 : i64, size = 2 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %alloc_ctor : !eco.value
    // CHECK: Ctor99 <null> <null>

    %alloc_str = eco.allocate_string {length = 10 : i64} : !eco.value
    eco.dbg %alloc_str : !eco.value
    // CHECK: \u0000

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
