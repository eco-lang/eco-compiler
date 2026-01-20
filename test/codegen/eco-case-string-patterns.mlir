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
    eco.case %s : !eco.value [0, 1, 2] result_types [!eco.value] {
      // "foo" branch
      eco.return %s : !eco.value
    }, {
      // "bar" branch
      eco.return %s : !eco.value
    }, {
      // default branch
      eco.return %s : !eco.value
    } {case_kind = "str", string_patterns = ["foo", "bar"]}
    func.return %s : !eco.value
  }

  // CHECK: eco.case
  // CHECK-SAME: case_kind = "str"
  // CHECK-SAME: string_patterns = ["hello"]
  func.func @string_case_2way(%s: !eco.value) -> !eco.value {
    // 2-way string case: "hello", default
    eco.case %s : !eco.value [0, 1] result_types [!eco.value] {
      // "hello" branch
      eco.return %s : !eco.value
    }, {
      // default branch
      eco.return %s : !eco.value
    } {case_kind = "str", string_patterns = ["hello"]}
    func.return %s : !eco.value
  }

  // CHECK: eco.case
  // CHECK-SAME: case_kind = "str"
  // CHECK-SAME: string_patterns = [""]
  func.func @string_case_empty(%s: !eco.value) -> !eco.value {
    // Empty string pattern
    eco.case %s : !eco.value [0, 1] result_types [!eco.value] {
      // "" (empty string) branch
      eco.return %s : !eco.value
    }, {
      // default branch
      eco.return %s : !eco.value
    } {case_kind = "str", string_patterns = [""]}
    func.return %s : !eco.value
  }
}
