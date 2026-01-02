// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test De Morgan's laws with boolean operations.
// De Morgan's laws:
//   NOT(a AND b) = (NOT a) OR (NOT b)
//   NOT(a OR b) = (NOT a) AND (NOT b)

module {
  func.func @main() -> i64 {
    %true = arith.constant true
    %false = arith.constant false

    // Test case 1: a=T, b=T
    // NOT(T AND T) = NOT(T) = F
    // (NOT T) OR (NOT T) = F OR F = F
    %a1 = eco.bool.and %true, %true : i1
    %lhs1 = eco.bool.not %a1 : i1
    %not_t = eco.bool.not %true : i1
    %rhs1 = eco.bool.or %not_t, %not_t : i1
    // Both should be False
    %boxed1 = eco.box %lhs1 : i1 -> !eco.value
    eco.dbg %boxed1 : !eco.value
    // CHECK: False
    %boxed2 = eco.box %rhs1 : i1 -> !eco.value
    eco.dbg %boxed2 : !eco.value
    // CHECK: False

    // Test case 2: a=T, b=F
    // NOT(T AND F) = NOT(F) = T
    // (NOT T) OR (NOT F) = F OR T = T
    %a2 = eco.bool.and %true, %false : i1
    %lhs2 = eco.bool.not %a2 : i1
    %not_f = eco.bool.not %false : i1
    %rhs2 = eco.bool.or %not_t, %not_f : i1
    // Both should be True
    %boxed3 = eco.box %lhs2 : i1 -> !eco.value
    eco.dbg %boxed3 : !eco.value
    // CHECK: True
    %boxed4 = eco.box %rhs2 : i1 -> !eco.value
    eco.dbg %boxed4 : !eco.value
    // CHECK: True

    // Test case 3: a=F, b=F
    // NOT(F AND F) = NOT(F) = T
    // (NOT F) OR (NOT F) = T OR T = T
    %a3 = eco.bool.and %false, %false : i1
    %lhs3 = eco.bool.not %a3 : i1
    %rhs3 = eco.bool.or %not_f, %not_f : i1
    // Both should be True
    %boxed5 = eco.box %lhs3 : i1 -> !eco.value
    eco.dbg %boxed5 : !eco.value
    // CHECK: True
    %boxed6 = eco.box %rhs3 : i1 -> !eco.value
    eco.dbg %boxed6 : !eco.value
    // CHECK: True

    // Second De Morgan's law: NOT(a OR b) = (NOT a) AND (NOT b)
    // Test case 4: a=T, b=T
    // NOT(T OR T) = NOT(T) = F
    // (NOT T) AND (NOT T) = F AND F = F
    %b1 = eco.bool.or %true, %true : i1
    %lhs4 = eco.bool.not %b1 : i1
    %rhs4 = eco.bool.and %not_t, %not_t : i1
    // Both should be False
    %boxed7 = eco.box %lhs4 : i1 -> !eco.value
    eco.dbg %boxed7 : !eco.value
    // CHECK: False
    %boxed8 = eco.box %rhs4 : i1 -> !eco.value
    eco.dbg %boxed8 : !eco.value
    // CHECK: False

    // Test case 5: a=F, b=F
    // NOT(F OR F) = NOT(F) = T
    // (NOT F) AND (NOT F) = T AND T = T
    %b2 = eco.bool.or %false, %false : i1
    %lhs5 = eco.bool.not %b2 : i1
    %rhs5 = eco.bool.and %not_f, %not_f : i1
    // Both should be True
    %boxed9 = eco.box %lhs5 : i1 -> !eco.value
    eco.dbg %boxed9 : !eco.value
    // CHECK: True
    %boxed10 = eco.box %rhs5 : i1 -> !eco.value
    eco.dbg %boxed10 : !eco.value
    // CHECK: True

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
