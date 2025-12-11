// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test multiple eco.global variables and their interaction.
// Tests store/load operations on multiple globals.

module {
  // Declare multiple globals
  eco.global @counter
  eco.global @accumulator
  eco.global @flag
  eco.global @message

  func.func @main() -> i64 {
    // Initialize globals with different types

    // counter = 0
    %i0 = arith.constant 0 : i64
    %b0 = eco.box %i0 : i64 -> !eco.value
    eco.store_global %b0, @counter

    // accumulator = 100
    %i100 = arith.constant 100 : i64
    %b100 = eco.box %i100 : i64 -> !eco.value
    eco.store_global %b100, @accumulator

    // flag = True (tag 1)
    %true_val = eco.constant True : !eco.value
    eco.store_global %true_val, @flag

    // message = "hello"
    %hello = eco.string_literal "hello" : !eco.value
    eco.store_global %hello, @message

    // Read and print initial values
    %c0 = eco.load_global @counter
    eco.dbg %c0 : !eco.value
    // CHECK: 0

    %a0 = eco.load_global @accumulator
    eco.dbg %a0 : !eco.value
    // CHECK: 100

    %f0 = eco.load_global @flag
    eco.dbg %f0 : !eco.value
    // CHECK: True

    %m0 = eco.load_global @message
    eco.dbg %m0 : !eco.value
    // CHECK: "hello"

    // Update counter to 5
    %i5 = arith.constant 5 : i64
    %b5 = eco.box %i5 : i64 -> !eco.value
    eco.store_global %b5, @counter

    // Update accumulator to counter + accumulator (5 + 100 = 105)
    %counter_val = eco.load_global @counter
    %accum_val = eco.load_global @accumulator

    // Unbox for arithmetic
    %cv = eco.unbox %counter_val : !eco.value -> i64
    %av = eco.unbox %accum_val : !eco.value -> i64
    %sum = eco.int.add %cv, %av : i64
    %bsum = eco.box %sum : i64 -> !eco.value
    eco.store_global %bsum, @accumulator

    // Update flag to False
    %false_val = eco.constant False : !eco.value
    eco.store_global %false_val, @flag

    // Update message
    %world = eco.string_literal "world" : !eco.value
    eco.store_global %world, @message

    // Read and print updated values
    %c1 = eco.load_global @counter
    eco.dbg %c1 : !eco.value
    // CHECK: 5

    %a1 = eco.load_global @accumulator
    eco.dbg %a1 : !eco.value
    // CHECK: 105

    %f1 = eco.load_global @flag
    eco.dbg %f1 : !eco.value
    // CHECK: False

    %m1 = eco.load_global @message
    eco.dbg %m1 : !eco.value
    // CHECK: "world"

    // Test reading one global multiple times
    %c2 = eco.load_global @counter
    %c3 = eco.load_global @counter
    eco.dbg %c2 : !eco.value
    eco.dbg %c3 : !eco.value
    // CHECK: 5
    // CHECK: 5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
