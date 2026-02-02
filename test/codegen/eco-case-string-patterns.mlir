// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Test eco.case with case_kind="str" and string_patterns attribute.
// String case requires:
// - scrutinee: !eco.value
// - case_kind = "str"
// - string_patterns: array of string literals (N-1 for N alternatives)
// - last alternative is the default (wildcard)

module {
  // CHECK: eco.case
  // CHECK-SAME: case_kind = "str"
  // CHECK-SAME: string_patterns = ["foo", "bar"]
  func.func @string_case_3way(%s: !eco.value) -> !eco.value {
    // 3-way string case: "foo", "bar", default
    %result = eco.case %s : !eco.value [0, 1, 2] -> (!eco.value) {case_kind = "str", string_patterns = ["foo", "bar"]} {
      // "foo" branch
      eco.yield %s : !eco.value
    }, {
      // "bar" branch
      eco.yield %s : !eco.value
    }, {
      // default branch
      eco.yield %s : !eco.value
    }
    return %result : !eco.value
  }

  // CHECK: eco.case
  // CHECK-SAME: case_kind = "str"
  // CHECK-SAME: string_patterns = ["hello"]
  func.func @string_case_2way(%s: !eco.value) -> !eco.value {
    // 2-way string case: "hello", default
    %result = eco.case %s : !eco.value [0, 1] -> (!eco.value) {case_kind = "str", string_patterns = ["hello"]} {
      // "hello" branch
      eco.yield %s : !eco.value
    }, {
      // default branch
      eco.yield %s : !eco.value
    }
    return %result : !eco.value
  }

  // CHECK: eco.case
  // CHECK-SAME: case_kind = "str"
  // CHECK-SAME: string_patterns = [""]
  func.func @string_case_empty(%s: !eco.value) -> !eco.value {
    // Empty string pattern
    %result = eco.case %s : !eco.value [0, 1] -> (!eco.value) {case_kind = "str", string_patterns = [""]} {
      // "" (empty string) branch
      eco.yield %s : !eco.value
    }, {
      // default branch
      eco.yield %s : !eco.value
    }
    return %result : !eco.value
  }
}
